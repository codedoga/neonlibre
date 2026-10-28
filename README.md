# neonlibre

Container images of [Neon](https://github.com/neondatabase/neon), the open-source
serverless Postgres with separated storage and compute, built for **PostgreSQL 17
and 18**, with security and minor releases of PostgreSQL merged automatically.

> **Not affiliated with Neon or Databricks.** This is an independent, unofficial
> build of the open-source Neon code. "Neon" is a trademark of its owner and is
> used here only to say where the code comes from. For the managed service, see
> [neon.com](https://neon.com).

## What is in here

- **Neon**, from `neondatabase/neon`, with PostgreSQL 18 support added by
  [elliots/neon-pg18](https://github.com/elliots/neon-pg18). Why each change was
  needed is written up in [pg18changes.md](pg18changes.md).
- **PostgreSQL** from the Neon branches of [codedoga/postgres](https://github.com/codedoga/postgres)
  (`REL_17_STABLE_neon`, `REL_18_STABLE_neon`), a fork of `neondatabase/postgres`.
  The v18 branch carries one extra commit, `pgaio_io_complete_synchronously()`,
  which lets a network-backed storage manager complete AIO reads.
- On top of that, this repository adds:
  - fixes found while testing: control-file decoding for older clusters, and the
    Boost runtime for rdkit on v18;
  - PostgreSQL 18 builds of rum, plv8, pg_duckdb, pg_mooncake, pgrag and
    online_advisor, so v18 ships the same extension set as v17;
  - a storage image that ships only PostgreSQL 17 and 18;
  - CI that builds, tests and publishes everything on GitHub-hosted runners
    ([.github/workflows](.github/workflows)).

Older PostgreSQL versions (14–16) are not built or shipped. Their headers are
still installed at build time, because Neon's Rust code generates bindings for
every version it knows.

## Images

All images are multi-arch (`linux/amd64`, `linux/arm64`).

| Image | Tags |
|---|---|
| `ghcr.io/codedoga/neonlibre/compute-v18` | `18.6.42`, `18.6`, `18`, `latest` |
| `ghcr.io/codedoga/neonlibre/compute-v17` | `17.11.42`, `17.11`, `17`, `latest` |
| `ghcr.io/codedoga/neonlibre/storage` | `42`, `latest` |

The numbers above are examples. The scheme is:

- **compute:** `<postgres major>.<postgres minor>.<build>`. `<build>` increases
  with every published build, including rebuilds that only pick up Debian
  security updates. A tag is never reused.
- **storage:** `<build>`. It has no PostgreSQL version of its own: it contains
  both 17 and 18, for WAL redo and initdb.
- Images with the same `<build>` were built and tested together.

This is ordinary semver as far as Dependabot is concerned. A PostgreSQL minor
release shows up as a minor update (`18.6.42` → `18.7.43`), and a rebuild as a
patch update (`18.6.42` → `18.6.43`). Each major version is its own image, so
Dependabot never proposes 17 → 18. Pin the full tag and let Dependabot move it:

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

The images are drop-in replacements for Neon's `compute-node-v17/v18` and `neon`
images. [docker-compose/](docker-compose) shows how they fit together.

## How updates happen

| Workflow | When | What |
|---|---|---|
| [update-postgres](.github/workflows/update-postgres.yml) | weekly | Merges the newest `REL_17_*` / `REL_18_*` release tag into the Neon branches of `codedoga/postgres`, bumps the submodules, then builds, tests and publishes. On a merge conflict it opens an issue instead. |
| [build](.github/workflows/build.yml) | weekly, on every push to `main`, and on pull requests | Builds every image and runs the tests below. Scheduled runs and pushes to `main` publish; pull requests do not. The weekly run picks up Debian security updates. |
| [tests](.github/workflows/pg-tests.yml) | manual | Neon's full Python regression suite, sharded. It takes hours. |

Extension versions are not updated automatically, because an extension bump can
break compatibility. Change them in
[compute/compute-node.Dockerfile](compute/compute-node.Dockerfile) and let CI test
the result.

## What CI tests before publishing

For each of PostgreSQL 17 and 18, on both architectures, against a docker-compose
Neon stack (pageserver, three safekeepers, storage broker, minio):

1. **Smoke test** ([ci/compose-smoke.sh](ci/compose-smoke.sh)): write data,
   restart the compute, and read the data back. After the restart every page
   comes from the pageserver and WAL redo.
2. **`CREATE EXTENSION`** for every extension in the image
   ([ci/ext-test.sh](ci/ext-test.sh) `create`).
3. **Regression tests** of the extensions whose version or code differs from
   upstream Neon's v17 build ([ci/ext-test.sh](ci/ext-test.sh) `run`).
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
