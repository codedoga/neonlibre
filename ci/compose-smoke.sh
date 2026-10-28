#!/usr/bin/env bash
# Smoke test of the storage + compute images: write data, restart the compute
# (fresh basebackup, so every read goes through the pageserver and walredo)
# and check that the data survived.
#
#   PG_VERSION=18 ci/compose-smoke.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

trap '[[ "${KEEP_UP:-0}" == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT
dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d --build compute1
wait_ready

version="$(sql 'select version()')"; echo "${version}"
[[ "${version}" == "PostgreSQL ${PG_VERSION}."* ]] || die "compute is not PostgreSQL ${PG_VERSION}"
sql 'create table smoke as select g, md5(g::text) as h from generate_series(1, 200000) g'
sql 'create index on smoke (h)'
before="$(sql 'select count(*), sum(g), min(h) from smoke')"
echo "before restart: ${before}"

dc restart compute1
wait_ready
after="$(sql 'set enable_seqscan = off; select count(*), sum(g), min(h) from smoke')"
echo "after restart:  ${after}"
[[ "${before}" == "${after}" ]] || die "data differs after compute restart"
echo "SMOKE OK"
