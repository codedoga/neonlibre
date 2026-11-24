# neonlibre

Container images of [Neon](https://github.com/neondatabase/neon), the open-source
serverless Postgres with separated storage and compute, built for **PostgreSQL
18**, with security and minor releases of PostgreSQL merged automatically.

> **Not affiliated with Neon or Databricks.** This is an independent, unofficial
> build of the open-source Neon code. "Neon" is a trademark of its owner and is
> used here only to say where the code comes from. For the managed service, see
> [neon.com](https://neon.com).

## What is in here

- **Neon**, from `neondatabase/neon`, with PostgreSQL 18 support added by
  [elliots/neon-pg18](https://github.com/elliots/neon-pg18). Why each change was
  needed is written up in [pg18changes.md](pg18changes.md).
- **PostgreSQL** from the Neon branch of [codedoga/postgres](https://github.com/codedoga/postgres)
  (`REL_18_STABLE_neon`), a fork of `neondatabase/postgres`.
  The branch carries one extra commit, `pgaio_io_complete_synchronously()`,
  which lets a network-backed storage manager complete AIO reads.
- On top of that, this repository adds:
  - fixes found while testing: control-file decoding for older clusters, and the
    Boost runtime for rdkit on v18;
  - PostgreSQL 18 builds of rum, plv8, pg_duckdb, pg_mooncake, pgrag and
    online_advisor, so it ships the same extension set as Neon's v17 image;
  - a storage image that ships PostgreSQL 18 and 19;
  - smaller images: binaries and libraries are stripped of debug info (symbols stay,
    so backtraces still name functions), and the storage image drops the aws CLI, the
    deprecated `postgres_install.tar.gz` and the compute-only Neon extensions;
  - pgrag's `rag_bge_small_en_v15` and `rag_jina_reranker_v1_tiny_en` download their
    ONNX model (about 127MB each) from Hugging Face on first use, so the compute needs
    outbound HTTPS to `huggingface.co` for them, and both need `shared_preload_libraries`;
  - CI that builds, tests and publishes everything on GitHub-hosted runners
    ([.github/workflows](.github/workflows)).

### PostgreSQL 19

> **PostgreSQL 19 support is experimental.** Neon has no official PG19 support; this is a port of
> Neon's patch set onto `REL_19_STABLE`. The build and a minor test subset pass (Postgres regress,
> isolation, VM bits, multixact, hot standby, branching). The full pytest suite and the extension
> test suites have not been run on v19. Two known gaps: the pageserver logs a `rel_size_v2`
> "relation already exists" warning on `CREATE DATABASE` (allowed for v19 in the tests, cause not
> found), and the WAL-redo paths for visibility-map bits and 64-bit multixact offsets are only
> covered by those tests. Do not use it for data you cannot lose. v18 is unaffected.

`compute-v19` is available (PostgreSQL from `REL_19_STABLE_neon` of `codedoga/postgres`,
`vendor/postgres-v19`). It is a first, smaller extension set than v18:

- **pg_mooncake**: not in v19. Its 0.1 line is dead upstream, and v18 only has it through a local port.
- **pgrag**: not in v19. The upstream repository is archived.
- **pgx_ulid**: not in v19. Upstream has no PostgreSQL 19 support.
- **Deferred to v19.1:** pg_jsonschema, pg_graphql, pg_tiktoken, pg_session_jwt and anon. They are
  pgrx extensions and need one pgrx 0.19.5 or later (the first with PostgreSQL 19) instead of the
  three versions the Dockerfile pins now. Without pg_session_jwt, `local_proxy` has nothing to
  validate JWTs against on v19 computes.
- **Not yet smoke-tested on v19:** pgrouting, rdkit, pg_uuidv7, pg_partman, pg_hashids,
  postgresql-unit, h3-pg, pgvector, timescaledb (a pre-release snapshot), pg_duckdb 1.2.2 and the
  extensions pinned to a commit instead of a release (rum, plv8, pg_repack, pgtap).
  Details are in the comments of [compute/compute-node.Dockerfile](compute/compute-node.Dockerfile).

Older PostgreSQL versions (14–17) are not built or shipped. Their headers are
still installed at build time, because Neon's Rust code generates bindings for
every version it knows.

## Images

All images are multi-arch (`linux/amd64`, `linux/arm64`).

| Image | Tags |
|---|---|
| `ghcr.io/codedoga/neonlibre/compute-v18` | `18.6.42`, `18.6`, `18`, `latest` |
| `ghcr.io/codedoga/neonlibre/compute-v19` | `19.0.1`, `19.0`, `19`, `latest` |
| `ghcr.io/codedoga/neonlibre/storage` | `42`, `latest` |

The numbers above are examples. The scheme is:

- **compute:** `<postgres major>.<postgres minor>.<n>`, where `<n>` counts the
  published builds of that image. A new number is published only when the image
  actually changed, and a tag is never reused.
- **storage:** `<n>`, counted the same way. It has no PostgreSQL version of its
  own; it contains PostgreSQL 18 and 19 for WAL redo and initdb.
- Every image is also tagged with the hash of its inputs (`<hash>`), once it has
  passed the tests. That is how CI knows what it does not need to build again.

This is ordinary semver as far as Dependabot is concerned. A PostgreSQL minor
release shows up as a minor update (`18.6.42` → `18.7.43`), and any other change
to the image as a patch update (`18.6.42` → `18.6.43`). The major version is part of the
image name, so a future major version would be a new image rather than an update.
Pin the full tag and let Dependabot move it:

```yaml
# .github/dependabot.yml in a repository that uses the images
version: 2
updates:
  - package-ecosystem: docker
    directory: /
    schedule:
      interval: weekly
```

```dockerfile
FROM ghcr.io/codedoga/neonlibre/compute-v18:18.6.42
```

The images are drop-in replacements for Neon's `compute-node-v18` and `neon`
images. [docker-compose/](docker-compose) shows how they fit together.

## How updates happen

| Workflow | When | What |
|---|---|---|
| [update-postgres](.github/workflows/update-postgres.yml) | weekly | Merges the newest `REL_18_*` and `REL_19_*` release tags into `REL_18_STABLE_neon` and `REL_19_STABLE_neon` of `codedoga/postgres` and opens a pull request bumping the submodule. It runs `build` on that branch and auto-merges once `ci-ok` passes. On a merge conflict it opens an issue instead. |
| [build](.github/workflows/build.yml) | on every push to `main`, and on pull requests | Builds and tests only what the change affects (below). Pushes to `main` publish the images that changed; pull requests do not. |
| [tests](.github/workflows/pg-tests.yml) | manual | Neon's full Python regression suite, sharded. It takes hours. |

`build` decides what to do from [ci/plan.py](ci/plan.py), which hashes the inputs
of every image: the Dockerfile stages it depends on, the files they copy and the
PostgreSQL submodule, and looks the hashes up in the registry. Anything already
built is skipped. A PostgreSQL minor update rebuilds the compute and storage
images. Changing one extension rebuilds its own stage, if it has one, and the
compute image, and leaves storage alone. A change to the CI scripts alone
rebuilds nothing.

Extension versions are not updated automatically, because an extension bump can
break compatibility. Change them in
[compute/compute-node.Dockerfile](compute/compute-node.Dockerfile) and let CI test
the result. Debian packages are updated when a security report calls for it, not
on a schedule.

## What CI tests before publishing

On both architectures, against a docker-compose
Neon stack (pageserver, three safekeepers, storage broker, minio):

1. **Smoke test** ([ci/compose-smoke.sh](ci/compose-smoke.sh)): write data,
   restart the compute, and read the data back. After the restart every page
   comes from the pageserver and WAL redo.
2. **`CREATE EXTENSION`** for every extension in the image
   ([ci/ext-test.sh](ci/ext-test.sh) `create`).
3. **Regression tests** of the extensions whose version or code differs from
   upstream Neon's PostgreSQL 17 build ([ci/ext-test.sh](ci/ext-test.sh) `run`).
4. **pg_duckdb** with `shared_preload_libraries`, including Neon's privilege
   grants ([ci/duckdb-test.sh](ci/duckdb-test.sh)).

Each script runs locally too, for example `PG_VERSION=18 ci/compose-smoke.sh`,
given images tagged `neonlibre/{neon,compute-node-v18,neon-test-extensions-v18}:ci`.

## Known limitations

- **PostgreSQL 18 runs with `io_method = sync`.** Reads complete inline, as on
  Neon's own v18. There is no asynchronous I/O to the pageserver yet.
- **Data checksums are off.** The pageserver synthesizes pages without checksums,
  so clusters are initialized with `--no-data-checksums`, and importing a cluster
  that has checksums is refused.
- **pgrag's model functions do not work as built.** `rag_bge_small_en_v15` and
  `rag_jina_reranker_v1_tiny_en` download their ONNX models from a Neon-internal
  URL set at build time (`REMOTE_ONNX_URL` in the Dockerfile). Rebuild with a URL
  you host to use them. The `rag` extension itself works.
- **These extensions need `shared_preload_libraries`:** pg_duckdb and pgaudit.
  **pg_cron** can only be created in the database named by `cron.database_name`.
- **pg_mooncake on PostgreSQL 18** is a local port of 0.1.3, the last release of
  the 0.1 series. Upstream's 0.2 is a different extension. As on Neon, it is
  meant to be gated behind `neon.unstable_extensions`.

## Licenses

Neon is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)),
and PostgreSQL under the PostgreSQL License. The images also contain third-party
extensions and libraries under their own licenses, some of them copyleft (PostGIS,
pgRouting and postgresql-unit are GPL). Every component, its version and its
license is listed in [LICENSES.md](LICENSES.md).

Upstream Neon's README, with its architecture overview and local development
instructions, is kept as [README.neon.md](README.neon.md).
