#!/usr/bin/env bash
# Build one target of the compute Dockerfile and push it.
#
#   ci/build-compute.sh <pg> <arch> <target|""> <ref> [<stage>=<image-ref>]...
#
# "" builds the final image. Each <stage>=<image-ref> replaces that stage with an
# image built earlier (ci/plan.py decides which), so it is never rebuilt here.
# CACHE_REF, if set, is used as a registry cache for the steps that are built.
set -euo pipefail

pg="${1:?pg}"; arch="${2:?arch}"; target="$3"; ref="${4:?ref}"; shift 4
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

args=()
for ctx in "$@"; do
    name="${ctx%%=*}"
    [[ "${name}" == "${target}" ]] || args+=(--build-context "${name}=docker-image://${ctx#*=}")
done
[[ -z "${target}" ]] || args+=(--target "${target}")
if [[ -n "${CACHE_REF:-}" ]]; then
    args+=(--cache-from "type=registry,ref=${CACHE_REF}"
           --cache-to "type=registry,ref=${CACHE_REF},mode=max,ignore-error=true")
fi

docker buildx build \
    --platform "linux/${arch}" \
    -f "${ROOT}/compute/compute-node.Dockerfile" \
    --build-arg PG_VERSION="v${pg}" \
    --build-arg DEBIAN_VERSION=bookworm \
    --build-arg BUILD_TAG="${BUILD_TAG:-ci}" \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-codedoga/neonlibre}" \
    "${args[@]}" --push -t "${ref}" --progress=plain "${ROOT}"
