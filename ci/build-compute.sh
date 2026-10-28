#!/usr/bin/env bash
# Build the compute image in pieces that each fit a GitHub-hosted runner's 6 hour
# job limit, sharing work through registry caches.
#
#   ci/build-compute.sh <pg> <arch> base                 build-deps + Postgres
#   ci/build-compute.sh <pg> <arch> stage <group>        one group of heavy extension stages
#   ci/build-compute.sh <pg> <arch> final <image-ref>    compute + extension-tests images, pushed
#
# <pg> is 17 or 18, <arch> amd64 or arm64. REGISTRY (e.g. ghcr.io/codedoga/neonlibre)
# holds the caches under ${REGISTRY}/cache:compute-v<pg>-<arch>-<name>, and the stage jobs
# also push each heavy stage as an image, ${REGISTRY}/stage:compute-v<pg>-<arch>-<target>-<sha>.
# The final build takes those images as named build contexts instead of rebuilding the
# stages: importing the stage jobs' caches did not give cache hits there in practice, and
# rebuilding them all in one job ran the runner out of memory.
set -euo pipefail

pg="${1:?pg}"; arch="${2:?arch}"; mode="${3:?mode}"; shift 3
: "${REGISTRY:?}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Heavy stages, grouped so that each group builds well within one job.
stage_targets() {
    case "$1" in
    postgis)  echo postgis-build pgrouting-build ;;
    rdkit)    echo rdkit-build ;;
    plv8)     echo plv8-build ;;
    duckdb)   echo pg_duckdb-build ;;
    mooncake) echo pg_mooncake-build ;;
    pgrag)    echo pgrag-build ;;
    pgrx)     echo pg_jsonschema-build pg_graphql-build pg_tiktoken-build pgx_ulid-build \
                   pgx_ulid-pgrx12-build pg_session_jwt-build pg-anon-pg-build ;;
    *) echo "unknown stage group $1" >&2; return 1 ;;
    esac
}
STAGE_GROUPS="postgis rdkit plv8 duckdb mooncake pgrag pgrx"

cache() { echo "${REGISTRY}/cache:compute-v${pg}-${arch}-$1"; }
sha="${SHA:-$(git -C "${ROOT}" rev-parse --short=12 HEAD)}"
# shortcut: one image per commit and stage accumulates in GHCR; add a cleanup job if that grows too large.
stage_image() { echo "${REGISTRY}/stage:compute-v${pg}-${arch}-$1-${sha}"; }

# build <target|""> <cache-name> [extra buildx args...]; "" builds the final, unnamed stage.
build() {
    local target="$1" name="$2" g t; shift 2
    local args=(--cache-from "type=registry,ref=$(cache base)")
    if [[ "${mode}" == final ]]; then
        for g in ${STAGE_GROUPS}; do
            for t in $(stage_targets "${g}"); do args+=(--build-context "${t}=docker-image://$(stage_image "${t}")"); done
        done
        args+=(--cache-from "type=registry,ref=$(cache "${name}")")
    elif [[ "${name}" != base ]]; then
        args+=(--cache-from "type=registry,ref=$(cache "${name}")")
    fi
    [[ -z "${target}" ]] || args+=(--target "${target}")
    docker buildx build \
        --platform "linux/${arch}" \
        -f "${ROOT}/compute/compute-node.Dockerfile" \
        --build-arg PG_VERSION="v${pg}" \
        --build-arg DEBIAN_VERSION=bookworm \
        --build-arg BUILD_TAG="${BUILD_TAG:-ci}" \
        --build-arg GIT_VERSION="${GIT_VERSION:-$(git -C "${ROOT}" rev-parse HEAD)}" \
        "${args[@]}" \
        --cache-to "type=registry,ref=$(cache "${name}"),mode=max,ignore-error=true" \
        --progress=plain "$@" "${ROOT}"
}

case "${mode}" in
base)  build pg-build-with-cargo base ;;
stage) for t in $(stage_targets "${1:?group}"); do build "${t}" "${t}" --push -t "$(stage_image "${t}")"; done ;;
final)
    ref="${1:?image ref, e.g. ghcr.io/codedoga/neonlibre/compute-v18:ci-<sha>-amd64}"
    label="org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-codedoga/neonlibre}"
    build "" final --label "${label}" --push -t "${ref}"
    build extension-tests tests --label "${label}" --push -t "${ref/compute-v${pg}/test-extensions-v${pg}}"
    ;;
*) echo "unknown mode ${mode}" >&2; exit 2 ;;
esac
