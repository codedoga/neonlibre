#!/usr/bin/env bash
# PostgreSQL's own regression suite on the compute image, then a compute restart.
#
# The regression suite leaves behind almost every kind of object PostgreSQL has
# (unlogged tables and sequences, every index AM, toast, partitions, ...). The restart
# takes a fresh basebackup, so afterwards every page is read back through the
# pageserver and walredo. The check is that the regression database dumps the same
# before and after, and that amcheck accepts every btree index afterwards.
#
#   PG_VERSION=18 ci/pg-regress-test.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export COMPOSE_PROFILES=test-extensions

# Tests whose output differs on a Neon compute for reasons that are not bugs.
EXPECTED_FAILURES="${EXPECTED_FAILURES:-}"

R=/postgres/src/test/regress
OUT="$(mktemp -d)"
trap '[[ "${KEEP_UP:-0}" == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT
dc down -v --remove-orphans >/dev/null 2>&1 || true
dc up -d --build
wait_ready

# pg_regress runs in the test container; the server needs regress.so in its libdir
# (next to contrib's autoinc and refint) and the input files at the same path, for
# server-side COPY.
dc exec -T neon-test-extensions make -s -C "${R}" all
dc cp "neon-test-extensions:${R}" "${OUT}/regress"
dc exec -T -u root compute1 mkdir -p "$(dirname "${R}")"
dc cp "${OUT}/regress" "compute1:${R}"
dc cp "${OUT}/regress/regress.so" compute1:/usr/local/lib/regress.so

set +e
dc exec -T -w "${R}" neon-test-extensions ./pg_regress \
    --inputdir=. --outputdir=/tmp/regress-out --bindir=/usr/local/pgsql/bin \
    --dlpath=/usr/local/lib --host=compute1 --port=55433 --user=cloud_admin \
    --schedule=parallel_schedule 2>&1 | tee "${OUT}/regress.log"
set -e
unexpected=()
while read -r t; do
    [[ " ${EXPECTED_FAILURES} " == *" ${t} "* ]] || unexpected+=("${t}")
done < <(sed -nE 's/^not ok +[0-9]+ +[+-]? *([^ ]+).*/\1/p' "${OUT}/regress.log")
grep -qE '^# All [0-9]+ tests passed|^ok ' "${OUT}/regress.log" || die "pg_regress did not run"
if ((${#unexpected[@]})); then
    dc exec -T neon-test-extensions head -c 200000 /tmp/regress-out/regression.diffs || true
    die "unexpected regression failures: ${unexpected[*]}"
fi

dump() { dc exec -T neon-test-extensions /usr/local/pgsql/bin/pg_dump -h compute1 -p 55433 -U cloud_admin -d regression; }
dump > "${OUT}/before.sql"
echo "dumped $(wc -l < "${OUT}/before.sql") lines before restart"

dc restart compute1
wait_ready
dump > "${OUT}/after.sql"
diff -u "${OUT}/before.sql" "${OUT}/after.sql" | head -200 || die "regression database differs after compute restart"
sql 'create extension if not exists amcheck' regression >/dev/null
checked="$(sql "select count(bt_index_check(c.oid, true)) from pg_index i
    join pg_class c on c.oid = i.indexrelid join pg_am a on a.oid = c.relam
    where a.amname = 'btree' and c.relkind = 'i' and c.relpersistence <> 't' and i.indisvalid" regression)"
echo "amcheck: ${checked} btree indexes OK"
echo "PG_REGRESS OK"
