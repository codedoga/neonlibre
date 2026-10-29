#!/usr/bin/env bash
# Extension tests of the compute image on a real Neon stack.
#
#   PG_VERSION=18 ci/ext-test.sh create          CREATE EXTENSION for every available extension
#   PG_VERSION=18 ci/ext-test.sh run <ext>...    regression tests of docker-compose/ext-src/<ext>-src
#
# Each subcommand starts the stack and tears it down again (KEEP_UP=1 keeps it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export COMPOSE_PROFILES=test-extensions

# Created on purpose only where they can be: preload-only libraries and pg_cron
# (which may only be created in cron.database_name) are checked separately below.
EXPECTED_CREATE_FAILURES="neon_rmgr pg_cron pg_duckdb pgaudit"

up() {
    dc down -v --remove-orphans >/dev/null 2>&1 || true
    dc up -d --build
    wait_ready
    sql 'select version()'
    # Same preparation as docker-compose/docker_compose_test.sh.
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "${tmp}"/{pg_hint_plan-src,postgis-src}
    dc cp neon-test-extensions:/ext-src/postgis-src/raster/test "${tmp}/postgis-src/test" || true
    dc cp neon-test-extensions:/ext-src/postgis-src/regress/00-regress-install "${tmp}/postgis-src/00-regress-install" || true
    dc cp neon-test-extensions:/ext-src/pg_hint_plan-src/data "${tmp}/pg_hint_plan-src/data" || true
    dc exec -T compute1 touch /var/db/postgres/compute/compute_ctl_temp_override.conf
    dc exec -T compute1 mkdir -p /tmp/pgis_reg/pgis_reg_tmp /ext-src/postgis-src/raster /ext-src/postgis-src/regress
    if [[ -d "${tmp}/postgis-src/test" ]]; then dc cp "${tmp}/postgis-src/test" compute1:/ext-src/postgis-src/raster/test; fi
    if [[ -d "${tmp}/postgis-src/00-regress-install" ]]; then dc cp "${tmp}/postgis-src/00-regress-install" compute1:/ext-src/postgis-src/regress; fi
    if [[ -d "${tmp}/pg_hint_plan-src/data" ]]; then dc cp "${tmp}/pg_hint_plan-src/data" compute1:/ext-src/pg_hint_plan-src/; fi
}

trap '[[ "${KEEP_UP:-0}" == 1 ]] || dc down -v --remove-orphans >/dev/null 2>&1' EXIT

case "${1:-}" in
create)
    up
    failed=()
    exts=()   # no mapfile: keeps this runnable with macOS bash 3.2
    while IFS= read -r e; do exts+=("${e}"); done < <(sql "select name from pg_available_extensions
        where name not in (select extname from pg_extension) order by 1")
    for e in "${exts[@]}"; do
        # Each extension in its own scratch database so one failure cannot mask another.
        db="ct_$(tr -c 'a-z0-9_\n' _ <<<"${e}")"
        sql "create database ${db}" >/dev/null
        if out="$(sql "create extension \"${e}\" cascade" "${db}" 2>&1)"; then
            echo "ok      ${e}"
        else
            echo "FAILED  ${e}: ${out//$'\n'/ }"
            [[ " ${EXPECTED_CREATE_FAILURES} " == *" ${e} "* ]] || failed+=("${e}")
        fi
        sql "drop database ${db} with (force)" >/dev/null
    done
    sql "create extension if not exists pg_cron" >/dev/null && echo "ok      pg_cron (in postgres)"
    echo "${#exts[@]} extensions tried; unexpected failures: ${failed[*]:-none}"
    ((${#failed[@]} == 0))
    ;;
run)
    shift; (($#)) || die "usage: run <ext>..."
    up
    rc=0
    for e in "$@"; do
        d="${e%-src}-src"
        # run-tests.sh runs every dir not in SKIP; skip all but this one.
        skip="$(dc exec -T neon-test-extensions ls /ext-src | grep -vx "${d}" | paste -sd, -)"
        # One retry: some suites are timing-sensitive, e.g. rum's predicate-rum isolation
        # test, where serializable isolation may abort an extra transaction.
        if dc exec -T -e USE_PGXS=1 -e SKIP="${skip}" neon-test-extensions /run-tests.sh /ext-src; then
            echo "PASSED  ${d}"
        elif echo "RETRY   ${d}" && dc exec -T -e USE_PGXS=1 -e SKIP="${skip}" neon-test-extensions /run-tests.sh /ext-src; then
            echo "PASSED  ${d} (on retry)"
        else
            echo "FAILED  ${d}"; rc=1
        fi
    done
    exit "${rc}"
    ;;
*) die "usage: $0 create|run <ext>..." ;;
esac
