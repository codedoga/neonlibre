#!/usr/bin/env bash
# pg_duckdb on a Neon compute: it needs shared_preload_libraries, so it is not
# covered by `ext-test.sh create`. Checks that queries run through DuckDB, that
# Neon's GRANTs to neon.privileged_role_name are in place, and that DuckDB still
# reads the table after a compute restart (pages then come from the pageserver).
#
#   PRELOAD_EXTRA=pg_duckdb PG_VERSION=18 ci/duckdb-test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ ",${PRELOAD_EXTRA:-}," == *,pg_duckdb,* ]] || die "run with PRELOAD_EXTRA=pg_duckdb"

trap '[[ "${KEEP_UP:-0}" == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT
dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d --build compute1
wait_ready

sql 'create extension pg_duckdb'
sql "select 'pg_duckdb ' || extversion from pg_extension where extname = 'pg_duckdb'"
sql 'create table duck_t as select g, g % 7 as k from generate_series(1, 300000) g'
q='select k, count(*), sum(g) from duck_t group by k order by k'
[[ "$(sql "set duckdb.force_execution = true; explain ${q}")" == *DuckDB* ]] || die "plan does not use DuckDB"
expected="$(sql "${q}")"
[[ "$(sql "set duckdb.force_execution = true; ${q}")" == "${expected}" ]] || die "DuckDB result differs"

# install_extension() takes (text) in 0.3.x and (text, text) in 1.x; check whichever exists.
grants="$(sql "select bool_and(has_function_privilege(current_setting('neon.privileged_role_name'), p.oid, 'EXECUTE'))
                 and has_table_privilege(current_setting('neon.privileged_role_name'), 'duckdb.extensions', 'SELECT,INSERT,UPDATE,DELETE')
                 and has_sequence_privilege(current_setting('neon.privileged_role_name'), 'duckdb.extensions_table_seq', 'USAGE')
               from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'duckdb' and p.proname = 'install_extension'")"
[[ "${grants}" == t ]] || die "privileged role is missing pg_duckdb grants"

dc restart compute1
wait_ready
[[ "$(sql "set duckdb.force_execution = true; ${q}")" == "${expected}" ]] || die "DuckDB result differs after restart"
echo "DUCKDB OK"
