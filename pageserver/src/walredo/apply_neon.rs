use anyhow::Context;
use byteorder::{ByteOrder, LittleEndian};
use bytes::BytesMut;
use pageserver_api::key::Key;
use pageserver_api::reltag::SlruKind;
use postgres_ffi::v14::nonrelfile_utils::{
    mx_offset_to_flags_bitshift, mx_offset_to_flags_offset, mx_offset_to_member_offset,
    transaction_id_set_status,
};
use postgres_ffi::{BLCKSZ, pg_constants};
use postgres_ffi_types::forknum::VISIBILITYMAP_FORKNUM;
use tracing::*;
use utils::lsn::Lsn;
use wal_decoder::models::record::NeonWalRecord;

/// Can this request be served by neon redo functions
/// or we need to pass it to wal-redo postgres process?
pub(crate) fn can_apply_in_neon(rec: &NeonWalRecord) -> bool {
    // Currently, we don't have bespoken Rust code to replay any
    // Postgres WAL records. But everything else is handled in neon.
    #[allow(clippy::match_like_matches_macro)]
    match rec {
        NeonWalRecord::Postgres {
            will_init: _,
            rec: _,
        } => false,
        _ => true,
    }
}

pub(crate) fn apply_in_neon(
    record: &NeonWalRecord,
    lsn: Lsn,
    key: Key,
    page: &mut BytesMut,
) -> Result<(), anyhow::Error> {
    match record {
        NeonWalRecord::Postgres {
            will_init: _,
            rec: _,
        } => {
            anyhow::bail!("tried to pass postgres wal record to neon WAL redo");
        }
        //
        // Code copied from PostgreSQL `visibilitymap_prepare_truncate` function in `visibilitymap.c`
        //
        NeonWalRecord::TruncateVisibilityMap {
            trunc_byte,
            trunc_offs,
        } => {
            // sanity check that this is modifying the correct relation
            let (rel, _) = key.to_rel_block().context("invalid record")?;
            assert!(
                rel.forknum == VISIBILITYMAP_FORKNUM,
                "TruncateVisibilityMap record on unexpected rel {rel}"
            );
            let map = &mut page[pg_constants::MAXALIGN_SIZE_OF_PAGE_HEADER_DATA..];
            map[*trunc_byte + 1..].fill(0u8);
            /*----
             * Mask out the unwanted bits of the last remaining byte.
             *
             * ((1 << 0) - 1) = 00000000
             * ((1 << 1) - 1) = 00000001
             * ...
             * ((1 << 6) - 1) = 00111111
             * ((1 << 7) - 1) = 01111111
             *----
             */
            map[*trunc_byte] &= (1 << *trunc_offs) - 1;
        }
        NeonWalRecord::ClearVisibilityMapFlags {
            new_heap_blkno,
            old_heap_blkno,
            flags,
        } => {
            // sanity check that this is modifying the correct relation
            let (rel, blknum) = key.to_rel_block().context("invalid record")?;
            assert!(
                rel.forknum == VISIBILITYMAP_FORKNUM,
                "ClearVisibilityMapFlags record on unexpected rel {rel}"
            );
            if let Some(heap_blkno) = *new_heap_blkno {
                // Calculate the VM block and offset that corresponds to the heap block.
                let map_block = pg_constants::HEAPBLK_TO_MAPBLOCK(heap_blkno);
                let map_byte = pg_constants::HEAPBLK_TO_MAPBYTE(heap_blkno);
                let map_offset = pg_constants::HEAPBLK_TO_OFFSET(heap_blkno);

                // Check that we're modifying the correct VM block.
                assert!(map_block == blknum);

                // equivalent to PageGetContents(page)
                let map = &mut page[pg_constants::MAXALIGN_SIZE_OF_PAGE_HEADER_DATA..];

                map[map_byte as usize] &= !(flags << map_offset);
                // The page should never be empty, but we're checking it anyway as a precaution, so that if it is empty for some reason anyway, we don't make matters worse by setting the LSN on it.
                if !postgres_ffi::page_is_new(page) {
                    postgres_ffi::page_set_lsn(page, lsn);
                }
            }

            // Repeat for 'old_heap_blkno', if any
            if let Some(heap_blkno) = *old_heap_blkno {
                let map_block = pg_constants::HEAPBLK_TO_MAPBLOCK(heap_blkno);
                let map_byte = pg_constants::HEAPBLK_TO_MAPBYTE(heap_blkno);
                let map_offset = pg_constants::HEAPBLK_TO_OFFSET(heap_blkno);

                assert!(map_block == blknum);

                let map = &mut page[pg_constants::MAXALIGN_SIZE_OF_PAGE_HEADER_DATA..];

                map[map_byte as usize] &= !(flags << map_offset);
                // The page should never be empty, but we're checking it anyway as a precaution, so that if it is empty for some reason anyway, we don't make matters worse by setting the LSN on it.
                if !postgres_ffi::page_is_new(page) {
                    postgres_ffi::page_set_lsn(page, lsn);
                }
            }
        }
        NeonWalRecord::SetVisibilityMapFlags { heap_blkno, flags } => {
            let (rel, blknum) = key.to_rel_block().context("invalid record")?;
            assert!(
                rel.forknum == VISIBILITYMAP_FORKNUM,
                "SetVisibilityMapFlags record on unexpected rel {rel}"
            );
            assert!(pg_constants::HEAPBLK_TO_MAPBLOCK(*heap_blkno) == blknum);
            let map_byte = pg_constants::HEAPBLK_TO_MAPBYTE(*heap_blkno);
            let map_offset = pg_constants::HEAPBLK_TO_OFFSET(*heap_blkno);
            let map = &mut page[pg_constants::MAXALIGN_SIZE_OF_PAGE_HEADER_DATA..];
            map[map_byte as usize] |= flags << map_offset;
            if !postgres_ffi::page_is_new(page) {
                postgres_ffi::page_set_lsn(page, lsn);
            }
        }
        // Non-relational WAL records are handled here, with custom code that has the
        // same effects as the corresponding Postgres WAL redo function.
        NeonWalRecord::ClogSetCommitted { xids, timestamp } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::Clog,
                "ClogSetCommitted record with unexpected key {key}"
            );
            for &xid in xids {
                let pageno = xid / pg_constants::CLOG_XACTS_PER_PAGE;
                let expected_segno = pageno / pg_constants::SLRU_PAGES_PER_SEGMENT;
                let expected_blknum = pageno % pg_constants::SLRU_PAGES_PER_SEGMENT;

                // Check that we're modifying the correct CLOG block.
                assert!(
                    segno == expected_segno,
                    "ClogSetCommitted record for XID {xid} with unexpected key {key}"
                );
                assert!(
                    blknum == expected_blknum,
                    "ClogSetCommitted record for XID {xid} with unexpected key {key}"
                );

                transaction_id_set_status(xid, pg_constants::TRANSACTION_STATUS_COMMITTED, page);
            }

            // Append the timestamp
            if page.len() == BLCKSZ as usize + 8 {
                page.truncate(BLCKSZ as usize);
            }
            if page.len() == BLCKSZ as usize {
                page.extend_from_slice(&timestamp.to_be_bytes());
            } else {
                warn!(
                    "CLOG blk {} in seg {} has invalid size {}",
                    blknum,
                    segno,
                    page.len()
                );
            }
        }
        NeonWalRecord::ClogSetAborted { xids } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::Clog,
                "ClogSetAborted record with unexpected key {key}"
            );
            for &xid in xids {
                let pageno = xid / pg_constants::CLOG_XACTS_PER_PAGE;
                let expected_segno = pageno / pg_constants::SLRU_PAGES_PER_SEGMENT;
                let expected_blknum = pageno % pg_constants::SLRU_PAGES_PER_SEGMENT;

                // Check that we're modifying the correct CLOG block.
                assert!(
                    segno == expected_segno,
                    "ClogSetAborted record for XID {xid} with unexpected key {key}"
                );
                assert!(
                    blknum == expected_blknum,
                    "ClogSetAborted record for XID {xid} with unexpected key {key}"
                );

                transaction_id_set_status(xid, pg_constants::TRANSACTION_STATUS_ABORTED, page);
            }
        }
        NeonWalRecord::MultixactOffsetCreate { mid, moff } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::MultiXactOffsets,
                "MultixactOffsetCreate record with unexpected key {key}"
            );
            // Compute the block and offset to modify.
            // See RecordNewMultiXact in PostgreSQL sources.
            let pageno = mid / pg_constants::MULTIXACT_OFFSETS_PER_PAGE as u32;
            let entryno = mid % pg_constants::MULTIXACT_OFFSETS_PER_PAGE as u32;
            let offset = (entryno * 4) as usize;

            // Check that we're modifying the correct multixact-offsets block.
            let expected_segno = pageno / pg_constants::SLRU_PAGES_PER_SEGMENT;
            let expected_blknum = pageno % pg_constants::SLRU_PAGES_PER_SEGMENT;
            assert!(
                segno == expected_segno,
                "MultiXactOffsetsCreate record for multi-xid {mid} with unexpected key {key}"
            );
            assert!(
                blknum == expected_blknum,
                "MultiXactOffsetsCreate record for multi-xid {mid} with unexpected key {key}"
            );

            LittleEndian::write_u32(&mut page[offset..offset + 4], *moff);
        }
        NeonWalRecord::MultixactOffsetCreatePair {
            mid,
            moff,
            next_moff,
        } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::MultiXactOffsets,
                "MultixactOffsetCreatePair record with unexpected key {key}"
            );
            let pageno = mid / pg_constants::MULTIXACT_OFFSETS_PER_PAGE as u32;
            let entryno = mid % pg_constants::MULTIXACT_OFFSETS_PER_PAGE as u32;

            let expected_segno = pageno / pg_constants::SLRU_PAGES_PER_SEGMENT;
            let expected_blknum = pageno % pg_constants::SLRU_PAGES_PER_SEGMENT;
            assert!(
                segno == expected_segno && blknum == expected_blknum,
                "MultixactOffsetCreatePair record for multi-xid {mid} with unexpected key {key}"
            );
            // The caller only builds this record when both entries share a page.
            assert!(
                entryno + 1 < pg_constants::MULTIXACT_OFFSETS_PER_PAGE as u32,
                "MultixactOffsetCreatePair record for multi-xid {mid} crosses a page boundary"
            );

            let offset = (entryno * 4) as usize;
            LittleEndian::write_u32(&mut page[offset..offset + 4], *moff);
            LittleEndian::write_u32(&mut page[offset + 4..offset + 8], *next_moff);
        }
        NeonWalRecord::MultixactMembersCreate { moff, members } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::MultiXactMembers,
                "MultixactMembersCreate record with unexpected key {key}"
            );
            for (i, member) in members.iter().enumerate() {
                let offset = moff + i as u32;

                // Compute the block and offset to modify.
                // See RecordNewMultiXact in PostgreSQL sources.
                let pageno = offset / pg_constants::MULTIXACT_MEMBERS_PER_PAGE as u32;
                let memberoff = mx_offset_to_member_offset(offset);
                let flagsoff = mx_offset_to_flags_offset(offset);
                let bshift = mx_offset_to_flags_bitshift(offset);

                // Check that we're modifying the correct multixact-members block.
                let expected_segno = pageno / pg_constants::SLRU_PAGES_PER_SEGMENT;
                let expected_blknum = pageno % pg_constants::SLRU_PAGES_PER_SEGMENT;
                assert!(
                    segno == expected_segno,
                    "MultiXactMembersCreate record for offset {moff} with unexpected key {key}"
                );
                assert!(
                    blknum == expected_blknum,
                    "MultiXactMembersCreate record for offset {moff} with unexpected key {key}"
                );

                let mut flagsval = LittleEndian::read_u32(&page[flagsoff..flagsoff + 4]);
                flagsval &= !(((1 << pg_constants::MXACT_MEMBER_BITS_PER_XACT) - 1) << bshift);
                flagsval |= member.status << bshift;
                LittleEndian::write_u32(&mut page[flagsoff..flagsoff + 4], flagsval);
                LittleEndian::write_u32(&mut page[memberoff..memberoff + 4], member.xid);
            }
        }
        NeonWalRecord::MultixactOffsetCreateV19 {
            mid,
            moff,
            next_moff,
        } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::MultiXactOffsets,
                "MultixactOffsetCreateV19 record with unexpected key {key}"
            );
            // PG19 RecordNewMultiXact(): 8-byte entries, BLCKSZ / 8 per page.
            let per_page = pg_constants::MULTIXACT_OFFSETS_PER_PAGE_V19 as u32;
            let pageno = mid / per_page;
            let entryno = (mid % per_page) as usize;
            assert!(
                segno == pageno / pg_constants::SLRU_PAGES_PER_SEGMENT
                    && blknum == pageno % pg_constants::SLRU_PAGES_PER_SEGMENT,
                "MultixactOffsetCreateV19 record for multi-xid {mid} with unexpected key {key}"
            );
            let offset = entryno * 8;
            LittleEndian::write_u64(&mut page[offset..offset + 8], *moff);
            if let Some(next_moff) = next_moff {
                // The caller only sets next_moff when both entries share a page.
                assert!(
                    entryno + 1 < per_page as usize,
                    "MultixactOffsetCreateV19 record for multi-xid {mid} crosses a page boundary"
                );
                LittleEndian::write_u64(&mut page[offset + 8..offset + 16], *next_moff);
            }
        }
        NeonWalRecord::MultixactMembersCreateV19 { moff, members } => {
            let (slru_kind, segno, blknum) = key.to_slru_block().context("invalid record")?;
            assert_eq!(
                slru_kind,
                SlruKind::MultiXactMembers,
                "MultixactMembersCreateV19 record with unexpected key {key}"
            );
            let per_page = pg_constants::MULTIXACT_MEMBERS_PER_PAGE as u64;
            let pages_per_segment = u64::from(pg_constants::SLRU_PAGES_PER_SEGMENT);
            for (i, member) in members.iter().enumerate() {
                let offset = moff + i as u64;
                let pageno = offset / per_page;
                assert!(
                    u64::from(segno) == pageno / pages_per_segment
                        && u64::from(blknum) == pageno % pages_per_segment,
                    "MultixactMembersCreateV19 record for offset {moff} with unexpected key {key}"
                );
                // A page holds whole member groups, so the in-page position depends only on
                // offset % MULTIXACT_MEMBERS_PER_PAGE and the 32-bit helpers apply.
                let inpage = (offset % per_page) as u32;
                let memberoff = mx_offset_to_member_offset(inpage);
                let flagsoff = mx_offset_to_flags_offset(inpage);
                let bshift = mx_offset_to_flags_bitshift(inpage);

                let mut flagsval = LittleEndian::read_u32(&page[flagsoff..flagsoff + 4]);
                flagsval &= !(((1 << pg_constants::MXACT_MEMBER_BITS_PER_XACT) - 1) << bshift);
                flagsval |= member.status << bshift;
                LittleEndian::write_u32(&mut page[flagsoff..flagsoff + 4], flagsval);
                LittleEndian::write_u32(&mut page[memberoff..memberoff + 4], member.xid);
            }
        }
        NeonWalRecord::AuxFile { .. } => {
            // No-op: this record will never be created in aux v2.
            warn!("AuxFile record should not be created in aux v2");
        }
        #[cfg(feature = "testing")]
        NeonWalRecord::Test {
            append,
            clear,
            will_init,
            only_if,
        } => {
            use bytes::BufMut;
            if *will_init {
                assert!(*clear, "init record must be clear to ensure correctness");
                assert!(
                    page.is_empty(),
                    "init record must be the first entry to ensure correctness"
                );
            }
            if *clear {
                page.clear();
            }
            if let Some(only_if) = only_if {
                if page != only_if.as_bytes() {
                    return Err(anyhow::anyhow!(
                        "the current image does not match the expected image, cannot append"
                    ));
                }
            }
            page.put_slice(append.as_bytes());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use bytes::BufMut;
    use pageserver_api::key::slru_block_to_key;
    use postgres_ffi::walrecord::v19::XlMultiXactCreate;

    use super::*;

    /// PG19: decode a hand-built xl_multixact_create (4 padding bytes, then uint64 moff) and
    /// check the 8-byte / 1024-per-page offsets entry and the 64-bit members position.
    #[test]
    fn multixact_v19_create() {
        let moff: u64 = (1 << 32) + 5; // does not fit the pre-v19 32-bit offset
        let mut buf = BytesMut::new();
        buf.put_u32_le(1025); // mid
        buf.put_u32_le(0); // padding
        buf.put_u64_le(moff);
        buf.put_u32_le(1); // nmembers
        buf.put_u32_le(777); // members[0].xid
        buf.put_u32_le(3); // members[0].status
        let rec = XlMultiXactCreate::decode(&mut buf.freeze());
        assert_eq!((rec.mid, rec.moff, rec.nmembers), (1025, moff, 1));
        assert_eq!((rec.members[0].xid, rec.members[0].status), (777, 3));

        // Multixact 1025: offsets page 1, entry 1 -> bytes 8..16, next entry 16..24.
        let mut page = BytesMut::zeroed(BLCKSZ as usize);
        let key = slru_block_to_key(SlruKind::MultiXactOffsets, 0, 1);
        let off_rec = NeonWalRecord::MultixactOffsetCreateV19 {
            mid: rec.mid,
            moff,
            next_moff: Some(moff + 1),
        };
        apply_in_neon(&off_rec, Lsn(0), key, &mut page).unwrap();
        assert_eq!(LittleEndian::read_u64(&page[8..16]), moff);
        assert_eq!(LittleEndian::read_u64(&page[16..24]), moff + 1);
        assert!(page[..8].iter().chain(&page[24..]).all(|&b| b == 0));

        // Offset 2^32+5: members page 2625285 = segment 82040 block 5, in-page member 1041
        // (group 260 -> flags at 5200, xid at 5208, bit shift 8).
        let mut page = BytesMut::zeroed(BLCKSZ as usize);
        let key = slru_block_to_key(SlruKind::MultiXactMembers, 82040, 5);
        let mem_rec = NeonWalRecord::MultixactMembersCreateV19 {
            moff,
            members: rec.members,
        };
        apply_in_neon(&mem_rec, Lsn(0), key, &mut page).unwrap();
        assert_eq!(LittleEndian::read_u32(&page[5200..5204]), 3 << 8);
        assert_eq!(LittleEndian::read_u32(&page[5208..5212]), 777);
    }
}
