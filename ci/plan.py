#!/usr/bin/env python3
"""Decide what this CI run has to build and test.

Every image is tagged with the hash of its inputs (ci/input_hash.py), so an
image whose tag already exists is not built again. A compute or storage image
also gets its plain <hash> tag once it has passed the tests; while that tag is
missing, the tests run. The result is printed as GitHub Actions outputs
(name=json), one per job matrix.

    REGISTRY=ghcr.io/owner/neonlibre ci/plan.py >> "$GITHUB_OUTPUT"
"""
import json
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from input_hash import input_hash, parse

PG_VERSIONS = ["18"]
ARCHES = ["amd64", "arm64"]
# Shared bases, built in this order by one job; later ones build on earlier ones.
BASES = ["pg-build", "pg-build-with-cargo", "rust-extensions-build",
         "rust-extensions-build-pgrx12", "rust-extensions-build-pgrx14"]
# Heavy extension stages: one job each, built on the bases.
HEAVY = ["postgis-build", "pgrouting-build", "rdkit-build", "plv8-build", "pg_duckdb-build",
         "pg_mooncake-build", "pgrag-build", "pg_jsonschema-build", "pg_graphql-build",
         "pg_tiktoken-build", "pgx_ulid-build", "pgx_ulid-pgrx12-build", "pg_session_jwt-build",
         "pg-anon-pg-build"]
COMPUTE_DOCKERFILE = "compute/compute-node.Dockerfile"
# Both Dockerfiles copy the whole context for their Rust builds (compute_ctl, the Neon
# extensions, the storage binaries), and none of those read these paths.
CONTEXT_IGNORE = ["compute", "docker-compose", "ci", ".github"]


def check_inherited_args(dockerfile):
    """Fail if a stage relies on an ARG it inherits through a stage that CI replaces with
    a prebuilt image: BuildKit does not see that ARG then, and the build fails late."""
    _, stages, _ = parse(Path(dockerfile).read_text())
    replaced = set(BASES + HEAVY)

    def args(lines, used):
        found = set()
        for line in lines:
            if used and not re.match(r"\s*ARG\s", line):
                found |= {a or b for a, b in re.findall(r"\$\{([A-Za-z_]\w*)[^}]*\}|\$([A-Za-z_]\w*)", line)}
            elif not used:
                found |= set(re.findall(r"^\s*ARG\s+([A-Za-z_]\w*)", line))
        return found

    problems = []
    for name, st in stages.items():
        chain, parent = [name], st["parent"]
        while parent in stages and parent not in replaced:
            chain.append(parent)
            parent = stages[parent]["parent"]
        if parent not in replaced:
            continue
        inherited, p = set(), parent
        while p in stages:
            inherited |= args(stages[p]["lines"], used=False)
            p = stages[p]["parent"]
        for s in chain:
            missing = (args(stages[s]["lines"][1:], used=True) & inherited) - args(stages[s]["lines"], used=False)
            if missing:
                problems.append(f"{s}: uses {sorted(missing)} inherited through {parent}; declare it with ARG")
    if problems:
        raise SystemExit("\n".join(problems))


def exists(ref):
    return subprocess.run(["docker", "buildx", "imagetools", "inspect", ref],
                          capture_output=True).returncode == 0


def pg_full_version(pg):
    configure = Path(f"vendor/postgres-v{pg}/configure").read_text()
    return re.search(r"^PACKAGE_VERSION='([^']+)'", configure, re.M).group(1)


def main():
    check_inherited_args(COMPUTE_DOCKERFILE)
    reg = os.environ["REGISTRY"]
    retest = os.environ.get("RETEST") == "true"
    refs = {}  # key -> image ref; checked against the registry in one go below
    hashes = {}
    for pg in PG_VERSIONS:
        args = {"PG_VERSION": f"v{pg}", "DEBIAN_VERSION": "bookworm"}
        for t in BASES + HEAVY + ["", "extension-tests"]:
            hashes[pg, t] = input_hash(COMPUTE_DOCKERFILE, t, args, [f"vendor/postgres-v{pg}"],
                                       ignore=CONTEXT_IGNORE)
        for arch in ARCHES:
            for t in BASES + HEAVY:
                refs[pg, t, arch] = f"{reg}/stage:v{pg}-{t}-{hashes[pg, t]}-{arch}"
            refs[pg, "", arch] = f"{reg}/compute-v{pg}:{hashes[pg, '']}-{arch}"
            refs[pg, "extension-tests", arch] = f"{reg}/test-extensions-v{pg}:{hashes[pg, 'extension-tests']}-{arch}"
        refs[pg, "tested"] = f"{reg}/compute-v{pg}:{hashes[pg, '']}"
    storage = input_hash("Dockerfile", "", {"DEBIAN_VERSION": "bookworm"},
                         [f"vendor/postgres-v{v}" for v in ["14", "15", "16", "17", "18"]],
                         ignore=CONTEXT_IGNORE)
    for arch in ARCHES:
        refs["storage", arch] = f"{reg}/storage:{storage}-{arch}"
    refs["storage", "tested"] = f"{reg}/storage:{storage}"

    with ThreadPoolExecutor(16) as pool:
        have = dict(zip(refs, pool.map(exists, refs.values())))

    plan = {"base": [], "stages": [], "compute": [], "storage": [], "test": [], "images": []}
    for pg in PG_VERSIONS:
        for arch in ARCHES:
            bases = [{"target": t, "ref": refs[pg, t, arch], "build": not have[pg, t, arch]} for t in BASES]
            if any(b["build"] for b in bases):
                plan["base"].append({"pg": pg, "arch": arch, "targets": bases})
            base_ctx = " ".join(f"{t}={refs[pg, t, arch]}" for t in BASES)
            for t in HEAVY:
                if not have[pg, t, arch]:
                    plan["stages"].append({"pg": pg, "arch": arch, "target": t,
                                           "ref": refs[pg, t, arch], "contexts": base_ctx})
            final, tests = refs[pg, "", arch], refs[pg, "extension-tests", arch]
            if not have[pg, "", arch] or not have[pg, "extension-tests", arch]:
                plan["compute"].append({
                    "pg": pg, "arch": arch,
                    "final": "" if have[pg, "", arch] else final,
                    "tests": "" if have[pg, "extension-tests", arch] else tests,
                    "contexts": base_ctx + " " + " ".join(f"{t}={refs[pg, t, arch]}" for t in HEAVY)})
            # A new storage image serves both PostgreSQL versions, so it is tested with both.
            if retest or not have["storage", "tested"] or not have[pg, "tested"]:
                plan["test"].append({"pg": pg, "arch": arch, "compute": final, "tests": tests,
                                     "storage": refs["storage", arch]})
        plan["images"].append({"name": f"compute-v{pg}", "hash": hashes[pg, ""],
                               "version": pg_full_version(pg)})
    for arch in ARCHES:
        if not have["storage", arch]:
            plan["storage"].append({"arch": arch, "ref": refs["storage", arch]})
    plan["images"].append({"name": "storage", "hash": storage, "version": ""})

    for k, v in plan.items():
        print(f"{k}={json.dumps(v, separators=(',', ':'))}")


if __name__ == "__main__":
    main()
