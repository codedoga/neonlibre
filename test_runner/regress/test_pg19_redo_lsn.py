from __future__ import annotations

import io

from fixtures.neon_fixtures import NeonEnv
from fixtures.utils import query_scalar


def test_prune_freeze_redo_sets_page_lsn(neon_simple_env: NeonEnv):
    """
    Invariant: after walredo of a heap PRUNE/FREEZE/VISIBLE (or multi-insert with
    ALL_FROZEN_SET) record, the heap page LSN (and the VM page LSN, when the VM
    bit is set by the record) must be >= the LSN where the operation started.
    Neon must set the page LSN in heap redo even when wal_log_hints is off, i.e.
    heap_xlog_prune_freeze must not gate PageSetLSN on XLogHintBitIsNeeded().
    A page LSN that lags behind makes pageserver/compute disagree about page
    versions (stale pages, bogus "page LSN newer than WAL" or lost-update bugs).

    Pages are re-read from the pageserver (buffers cleared) via pageinspect.
    """
    env = neon_simple_env
    endpoint = env.endpoints.create_start("main", config_lines=["wal_log_hints=off"])
    conn = endpoint.connect()
    cur = conn.cursor()
    cur.execute("CREATE EXTENSION pageinspect")
    cur.execute("CREATE EXTENSION neon_test_utils")

    def cur_lsn() -> str:
        return query_scalar(cur, "SELECT pg_current_wal_insert_lsn()")

    def page_lsn_ge(rel: str, fork: str, start: str) -> bool:
        # Re-fetch from pageserver, then compare page header LSN with `start`.
        endpoint.clear_buffers(cursor=cur)
        return query_scalar(
            cur,
            f"SELECT (page_header(get_raw_page('{rel}', '{fork}', 0))).lsn >= '{start}'::pg_lsn",
        )

    def vm_bits(rel: str) -> int:
        # First byte after the 24-byte page header: bits for heap block 0
        # (bit0 = all-visible, bit1 = all-frozen).
        return query_scalar(cur, f"SELECT get_byte(get_raw_page('{rel}', 'vm', 0), 24) & 3")

    cur.execute("CREATE TABLE t (id int, filler text)")
    cur.execute("INSERT INTO t SELECT g, 'x' FROM generate_series(1, 100) g")

    # VACUUM FREEZE: prune/freeze record + VM set, heap and VM page LSN must advance.
    start = cur_lsn()
    cur.execute("VACUUM (FREEZE) t")
    assert page_lsn_ge("t", "main", start), "heap page LSN behind VACUUM FREEZE record"
    assert page_lsn_ge("t", "vm", start), "VM page LSN behind VACUUM FREEZE record"
    assert vm_bits("t") == 3, "all-visible/all-frozen not set after VACUUM FREEZE"

    # DELETE + plain VACUUM: pure prune record (no freeze plans).
    cur.execute("DELETE FROM t WHERE id <= 50")
    prev = query_scalar(cur, "SELECT (page_header(get_raw_page('t', 'main', 0))).lsn")
    start = cur_lsn()
    cur.execute("VACUUM t")
    assert page_lsn_ge("t", "main", start), "heap page LSN behind prune record"
    # Monotonic w.r.t. the previous page version.
    assert query_scalar(
        cur, f"SELECT (page_header(get_raw_page('t', 'main', 0))).lsn >= '{prev}'::pg_lsn"
    )

    # COPY FREEZE into a table created in the same xact: multi-insert sets
    # ALL_FROZEN_SET together with the VM bit.
    cur.execute("BEGIN")
    cur.execute("CREATE TABLE cf (id int)")
    start = cur_lsn()
    cur.copy_expert("COPY cf FROM STDIN WITH (FREEZE)", io.StringIO("\n".join(map(str, range(100))) + "\n"))
    cur.execute("COMMIT")
    assert page_lsn_ge("cf", "main", start), "heap page LSN behind COPY FREEZE record"
    assert page_lsn_ge("cf", "vm", start), "VM page LSN behind COPY FREEZE record"
    assert vm_bits("cf") == 3, "all-visible/all-frozen not set by COPY FREEZE"
