# shellcheck shell=bash
# Shared helpers for the ci/ scripts: run docker-compose/ against locally tagged images.
#
# Images are expected under REPOSITORY (default "neonlibre") with tag TAG (default "ci"):
#   ${REPOSITORY}/neon:${TAG}                                     storage
#   ${REPOSITORY}/compute-node-v${PG_VERSION}:${TAG}              compute
#   ${REPOSITORY}/neon-test-extensions-v${PG_VERSION}:${TAG}      extension tests
# PG_VERSION is the major version, 17 or 18.

set -euo pipefail

: "${PG_VERSION:?set PG_VERSION to 17 or 18}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPOSITORY="${REPOSITORY:-neonlibre}" TAG="${TAG:-ci}" PG_VERSION PG_TEST_VERSION="${PG_VERSION}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-neonlibre-ci-v${PG_VERSION}}"
# The minio image pinned in docker-compose.yml (quay.io) and minio/mc are no longer pullable.
export MINIO_IMAGE="${MINIO_IMAGE:-pgsty/minio:RELEASE.2026-04-17T00-00-00Z}"
# PRELOAD_EXTRA=a,b appends libraries to shared_preload_libraries.
export CI_CONFIGS_DIR="${CI_CONFIGS_DIR:-$(mktemp -d)}"

OVERRIDE="${CI_CONFIGS_DIR}/override.yml"
# No host ports (we only use exec), so nothing clashes with whatever else runs on the host.
cat > "${OVERRIDE}" <<'EOF'
services:
  minio:          { ports: !reset [], image: "${MINIO_IMAGE}" }
  minio_create_buckets: { image: "${MINIO_IMAGE}" }
  pageserver:
    ports: !reset []
    volumes: ["${CI_CONFIGS_DIR}/pageserver:/data/.neon/"]
  safekeeper1:    { ports: !reset [] }
  safekeeper2:    { ports: !reset [] }
  safekeeper3:    { ports: !reset [] }
  storage_broker: { ports: !reset [] }
  compute1:
    ports: !reset []
    volumes: ["${CI_CONFIGS_DIR}/configs:/var/db/postgres/configs/"]
EOF
# The containers run as their own users (pageserver: neon, compute: postgres), so the
# directories they get must be readable, and the pageserver's writable, by anyone.
# A copy of pageserver_config also keeps tenant data out of the checkout.
mkdir -p "${CI_CONFIGS_DIR}/configs" "${CI_CONFIGS_DIR}/pageserver"
cp "${ROOT}/docker-compose/pageserver_config/"{identity,pageserver}.toml "${CI_CONFIGS_DIR}/pageserver/"
chmod 755 "${CI_CONFIGS_DIR}" "${CI_CONFIGS_DIR}/configs"
chmod 777 "${CI_CONFIGS_DIR}/pageserver"
chmod 666 "${CI_CONFIGS_DIR}/pageserver/"*.toml
jq --arg extra "${PRELOAD_EXTRA:-}" '(.spec.cluster.settings[] | select(.name=="shared_preload_libraries").value)
    |= (if $extra == "" then . else . + "," + $extra end)' \
    "${ROOT}/docker-compose/compute_wrapper/var/db/postgres/configs/config.json" > "${CI_CONFIGS_DIR}/configs/config.json"
chmod 644 "${CI_CONFIGS_DIR}/configs/config.json"

die() { echo "error: $*" >&2; exit 1; }
dc() { docker compose -f "${ROOT}/docker-compose/docker-compose.yml" -f "${OVERRIDE}" "$@"; }
sql() { dc exec -T compute1 psql -XAtq -h localhost -U cloud_admin -p 55433 -d "${2:-postgres}" -c "$1"; }
wait_ready() {
    for _ in $(seq 1 120); do sql 'select 1' >/dev/null 2>&1 && return 0; sleep 3; done
    dc logs --tail 100 compute1 pageserver; die "compute did not become ready"
}
