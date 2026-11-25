#!/bin/bash

# like restore_from_wal.sh, but takes existing initdb.tar.zst

set -euxo pipefail

PG_BIN=$1
WAL_PATH=$2
DATA_DIR=$3
PORT=$4
PG_VERSION=$5
echo "port=$PORT" >> "$DATA_DIR"/postgresql.conf
echo "shared_preload_libraries='\$libdir/neon_rmgr.so'" >> "$DATA_DIR"/postgresql.conf
# Offset of the REDO record inside WAL segment 1 (16MB segments). Parse the LSN rather than
# cutting columns: v19 prints LSNs zero-padded (0/014E8320), so `cut -c 42-` returned the
# whole LSN, dd then copied the full initdb segment over the timeline WAL.
REDO_LSN=$("$PG_BIN"/pg_controldata -D "$DATA_DIR" | grep -F "REDO location" | awk '{print $NF}')
declare -i REDO_POS=$(( 0x${REDO_LSN#*/} & 0xFFFFFF ))
# XLogRecord header (24) + short data header (2) + sizeof(CheckPoint): 88 up to v18, 96 on v19
CHECKPOINT_SIZE=88
if [ "$PG_VERSION" -ge 19 ]; then CHECKPOINT_SIZE=96; fi
declare -i WAL_SIZE=$REDO_POS+26+CHECKPOINT_SIZE
"$PG_BIN"/pg_ctl -D "$DATA_DIR" -l "$DATA_DIR/logfile.log" start
"$PG_BIN"/pg_ctl -D "$DATA_DIR" -l "$DATA_DIR/logfile.log" stop -m immediate
cp "$DATA_DIR"/pg_wal/000000010000000000000001 "$DATA_DIR"
cp "$WAL_PATH"/* "$DATA_DIR"/pg_wal/
for partial in "$DATA_DIR"/pg_wal/*.partial ; do mv "$partial" "${partial%.partial}" ; done
dd if="$DATA_DIR"/000000010000000000000001 of="$DATA_DIR"/pg_wal/000000010000000000000001 bs=$WAL_SIZE count=1 conv=notrunc
rm -f "$DATA_DIR"/000000010000000000000001
