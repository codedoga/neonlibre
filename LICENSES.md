# Third-party licenses in the compute images

This file lists the third-party components that end up in the PostgreSQL 18
compute image built from `compute/compute-node.Dockerfile`
(full `EXTENSIONS=all` build, Debian bookworm base). It covers what is shipped
in the final image, not build-only tooling. The versions are the ones pinned in
the Dockerfile. The licenses were read from each upstream project's
LICENSE/COPYING/COPYRIGHT file (or its metadata) at that exact tag or commit.

This is an informational summary, not legal advice. Each component's own
license text is authoritative. Third-party code bundled inside large components
(DuckDB, ONNX Runtime, V8, RDKit, the Rust crate graphs, the Go exporters) is
not listed component by component.

## Base pieces

| Component | v18 | License (SPDX) | Upstream | Notes |
|---|---|---|---|---|
| Neon (compute_ctl, fast_import, local_proxy, `pgxn/` extensions: neon, neon_rmgr, neon_utils, neon_walredo, neon_test_utils) | this repository | Apache-2.0 | https://github.com/neondatabase/neon | See `LICENSE` and `NOTICE`. Some files in `pgxn/` are derived from PostgreSQL sources and keep the PostgreSQL Global Development Group copyright notices. The Rust binaries statically link crates.io dependencies. `deny.toml` limits these to 0BSD, Apache-2.0, BSD-2/3-Clause, CC0-1.0, CDDL-1.0, ISC, MIT, MPL-2.0 and Unicode-3.0, plus Zlib for `const_format`. |
| PostgreSQL (Neon fork, server and `contrib/`; minor releases are merged automatically) | 18.x, pinned by `vendor/postgres-v18` | PostgreSQL | https://github.com/codedoga/postgres | See `vendor/postgres-vXX/COPYRIGHT`. Neon patches `pg_stat_statements` and `postgres_fdw` at build time (`compute/patches/`). Built with OpenSSL, ICU, libxml2, libxslt, LZ4, Zstd, OSSP uuid and readline from Debian. |
| Debian base image | same | various (mostly GPL/LGPL/BSD/MIT) | https://www.debian.org | Runtime packages come from Debian bookworm. On v18, Boost 1.83 comes from bookworm-backports. Each package's license is in `/usr/share/doc/<pkg>/copyright` inside the image. See "Copyleft and notable obligations" below. |

## Extensions and bundled components

| Component | v18 version | License (SPDX id) | Upstream URL | Notes |
|---|---|---|---|---|
| PostGIS | 3.6.0 | GPL-2.0-or-later | https://postgis.net (source: download.osgeo.org) | Copyleft. Some files use MIT, BSD-3-Clause or public domain (see `LICENSE.TXT`). Includes postgis_raster, postgis_topology, postgis_sfcgal, tiger_geocoder and address_standardizer. Links GEOS (LGPL-2.1-or-later), PROJ (MIT), GDAL (MIT) and protobuf-c (BSD-2-Clause) from Debian. |
| SFCGAL (built from source, installed to `/usr/local`) | 1.4.1 | LGPL-2.0-or-later (README/LICENSE); source headers say GPL-2.0-or-later | https://gitlab.com/sfcgal/SFCGAL | Copyleft. Upstream warns that a build against CGAL's GPL modules is effectively GPL-3.0-or-later. Compiled against Debian's header-only CGAL (`libcgal-dev`, GPL-3.0-or-later / LGPL-3.0-or-later per package). Debian's `libsfcgal1` is also installed. |
| pgRouting | 3.8.0 | GPL-2.0-or-later | https://github.com/pgRouting/pgrouting | Copyleft. Some parts are BSL-1.0 (Boost extensions) or MIT, per the upstream README. |
| plv8 | 3.2.5 (commit 094d1082) | PostgreSQL | https://github.com/plv8/plv8 | Neon patch applied (`compute/patches/plv8_*.patch`). |
| V8 (bundled by plv8 through `bnoordhuis/v8-cmake` @ 90d6634d) | 11.5.150.2 | BSD-3-Clause | https://github.com/bnoordhuis/v8-cmake (V8: https://v8.dev) | Statically linked into `plv8-*.so`. V8's own third-party parts are listed in `v8/LICENSE*`. |
| H3 core library | 4.2.0 | Apache-2.0 | https://github.com/uber/h3 | Installed under `/usr`. |
| h3-pg | 4.2.3 | Apache-2.0 | https://github.com/postgis/h3-pg | |
| postgresql-unit | 7.9 | GPL-3.0-or-later | https://github.com/df7cb/postgresql-unit | Copyleft. Its unit definitions come from GNU units (FSF, GPL-3.0-or-later). GitHub detects no license; the terms are in the README and `debian/copyright`. |
| pgvector | 0.8.1 | PostgreSQL | https://github.com/pgvector/pgvector | Neon patch applied. Also ships `vector--0.7.4.sql` from v0.7.4. |
| pgjwt | commit f3d82fd3 | MIT | https://github.com/michelp/pgjwt | |
| HypoPG | 1.4.1 | PostgreSQL | https://github.com/HypoPG/hypopg | |
| online_advisor | commit e24652f8 | PostgreSQL | https://github.com/knizhnik/online_advisor | |
| pg_hashids | 1.2.1 | MIT | https://github.com/iCyberon/pg_hashids | |
| RUM | 1.3.15 | PostgreSQL | https://github.com/postgrespro/rum | Neon patch applied. |
| pgTAP | 1.3.3 | PostgreSQL | https://github.com/theory/pgtap | License is declared in `META.json` and the README; the repo has no LICENSE file. |
| ip4r | 2.4.2 | PostgreSQL | https://github.com/RhodiumToad/ip4r | |
| prefix | 1.2.10 | PostgreSQL | https://github.com/dimitri/prefix | |
| postgresql-hll | 2.18 | Apache-2.0 | https://github.com/citusdata/postgresql-hll | |
| plpgsql_check | 2.8.2 | MIT | https://github.com/okbob/plpgsql_check | |
| TimescaleDB | 2.23.0 | Apache-2.0 (Apache-only build) | https://github.com/timescale/timescaledb | Built with `-DAPACHE_ONLY=ON`, which skips `add_subdirectory(tsl)`, so the Timescale License (TSL, source-available, not OSI-approved) code and the `timescaledb-tsl-*.so` module are not built or shipped. Telemetry is disabled at build time. |
| pg_hint_plan | REL18_1_8_0 | BSD-3-Clause | https://github.com/ossc-db/pg_hint_plan | |
| pg_cron | 1.6.6 | PostgreSQL | https://github.com/citusdata/pg_cron | Neon patch applied. |
| RDKit (PostgreSQL cartridge) | Release_2025_09_6 | BSD-3-Clause | https://github.com/rdkit/rdkit | Linked statically (`RDK_PGSQL_STATIC=ON`) with optional parts fetched at build time: InChI v1.07.3 (MIT, from the IUPAC-InChI GitHub releases), AvalonToolkit 2.0.5-pre.3 (BSD-3-Clause, Novartis), coordgenlibs (BSD-3-Clause) and maeparser (MIT). Links Boost 1.83 (BSL-1.0) from bookworm-backports. |
| pg_uuidv7 | 1.6.0 | MPL-2.0 | https://github.com/fboulnois/pg_uuidv7 | Weak copyleft at file level. Not modified by Neon. |
| pg_roaringbitmap | 0.5.4 | Apache-2.0 | https://github.com/ChenHuajun/pg_roaringbitmap | Bundles CRoaring. |
| pg-semver | 0.41.0 | PostgreSQL | https://github.com/theory/pg-semver | |
| pgrag (rag, rag_bge_small_en_v15, rag_jina_reranker_v1_tiny_en) | 0.1.4 | Apache-2.0 | https://github.com/neondatabase-labs/pgrag | Built with the `remote_onnx` feature: tokenizer and config files are compiled in, and the ONNX model weights are downloaded on first use from `REMOTE_ONNX_URL`. That URL is set at build time to a Neon-internal cluster address (`pg-ext-s3-gateway…svc.cluster.local`). Model licenses on Hugging Face: bge-small-en-v1.5 (BAAI) is MIT, jina-reranker-v1-tiny-en (Jina AI) is Apache-2.0. Uses pgrx 0.16.1. |
| ONNX Runtime (used by pgrag) | 1.18.1 | MIT | https://github.com/microsoft/onnxruntime | Built from source with a Neon patch. Its bundled dependencies are listed in upstream `ThirdPartyNotices.txt`. |
| pg_jsonschema | 0.3.4 | Apache-2.0 | https://github.com/supabase/pg_jsonschema | Rust/pgrx. |
| pg_graphql | 1.5.12 | Apache-2.0 | https://github.com/supabase/pg_graphql | Rust/pgrx. Neon patch applied. |
| pg_tiktoken | commit 0baf8d46 | Apache-2.0 | https://github.com/kelvich/pg_tiktoken | Rust/pgrx. |
| pgx_ulid | 0.2.2 | MIT | https://github.com/pksunkara/pgx_ulid | Rust/pgrx. |
| pg_session_jwt | 0.5.0 | Apache-2.0 | https://github.com/neondatabase/pg_session_jwt | Rust/pgrx. |
| PostgreSQL Anonymizer (anon) | 2.5.1 | PostgreSQL | https://gitlab.com/dalibo/postgresql_anonymizer | Rust/pgrx. Neon patch applied. |
| pgrx (Rust framework compiled into the Rust extensions above) | 0.16.1 | MIT | https://github.com/pgcentralfoundation/pgrx | Each Rust extension also statically links its own crates.io dependencies. |
| wal2json | 2.6 | BSD-3-Clause | https://github.com/eulerto/wal2json | |
| pg_ivm | 1.12 | PostgreSQL | https://github.com/sraoss/pg_ivm | |
| pg_partman | 5.1.0 | PostgreSQL | https://github.com/pgpartman/pg_partman | |
| pg_mooncake | 0.1.3 (with a Neon PG18 port patch) | MIT | https://github.com/Mooncake-Labs/pg_mooncake | Includes a Rust `delta` component (delta-rs based) and the DuckDB extensions httpfs, icu and json. Neon patches applied. |
| DuckDB (vendored by pg_mooncake, shared `libduckdb.so`) | 1.1.3 | MIT | https://github.com/duckdb/duckdb | Neon patch applied (`duckdb_v113.patch`). |
| pg_duckdb | 1.1.1 (commit 7b0db373) | MIT | https://github.com/duckdb/pg_duckdb | Neon patches applied. |
| DuckDB (vendored by pg_duckdb) | 1.4.3 (linked statically) | MIT | https://github.com/duckdb/duckdb | Users can download more DuckDB extensions at runtime with `duckdb.install_extension()`. Those carry their own licenses. |
| pg_repack | 1.5.2 | BSD-3-Clause | https://github.com/reorg/pg_repack | |
| pgAudit | 18.0 | PostgreSQL | https://github.com/pgaudit/pgaudit | No Neon patch (18.0 already contains it). |
| pgauditlogtofile | 1.6.4 | PostgreSQL | https://github.com/fmbiete/pgauditlogtofile | |

## Other bundled programs

| Component | v18 version | License (SPDX id) | Upstream URL | Notes |
|---|---|---|---|---|
| PgBouncer | 1.24.1 | ISC | https://github.com/pgbouncer/pgbouncer | Built from source. Includes the libusual (ISC) and uthash (BSD-1-Clause) submodules. Links libevent (BSD-3-Clause) and OpenSSL (Apache-2.0). |
| postgres_exporter | 0.17.1 | Apache-2.0 | https://github.com/prometheus-community/postgres_exporter | Upstream prebuilt release binary (Go, statically linked). |
| pgbouncer_exporter | 0.10.2 | MIT | https://github.com/prometheus-community/pgbouncer_exporter | Upstream prebuilt release binary (Go). |
| sql_exporter | 0.17.3 | MIT | https://github.com/burningalchemist/sql_exporter | Upstream prebuilt release binary (Go). |

## Copyleft and notable obligations

- **GPL-licensed PostgreSQL extensions:** PostGIS (GPL-2.0-or-later), pgRouting (GPL-2.0-or-later) and postgresql-unit (GPL-3.0-or-later) ship as binaries in the image.
  - Anyone who redistributes the image must make the corresponding source available for these components, under the terms of their licenses.
  - Each component's version is pinned above, and its source is the upstream tarball at that tag; Neon does not patch any of the three.
- **SFCGAL and CGAL:** SFCGAL 1.4.1 is LGPL-2.0-or-later according to its README and LICENSE, but its source headers say GPL-2.0-or-later.
  - It is compiled against CGAL, part of which is GPL-3.0-or-later.
  - SFCGAL upstream therefore says such a build is effectively GPL-3.0-or-later. Treat the shipped SFCGAL library and `postgis_sfcgal` as GPL-3.0-or-later.
- **LGPL libraries:** GEOS (LGPL-2.1-or-later) is dynamically linked from Debian.
- **MPL-2.0:** pg_uuidv7 is MPL-2.0. Source must be made available for MPL-covered files if they are distributed; they are not modified here.
- **Debian runtime packages:** some packages in the image are GPL-licensed, for example gdb, screen, procps, iproute2, rsyslog and libreadline8.
  - libreadline8 is GPL-3.0-or-later and is linked by `psql`.
  - The source is available from Debian, and the license terms are in `/usr/share/doc/*/copyright`.
- **TimescaleDB:** only the Apache-2.0 part is built (`APACHE_ONLY=ON`). The source-available Timescale License (TSL) features under `tsl/`, such as native compression and continuous aggregates, are absent. No non-OSI TimescaleDB code is shipped.
- **Patched third-party sources:** Neon applies local patches (in `compute/patches/`) to these permissively licensed components: PostgreSQL contrib, plv8, pgvector, RUM, pg_cron, pg_graphql, anon, ONNX Runtime, DuckDB, pg_duckdb and pg_mooncake. The patches are in this repository.
- **Attribution:** the BSD, MIT, ISC, Apache-2.0, BSL-1.0 and PostgreSQL licenses require keeping copyright and license notices when the software is redistributed. Apache-2.0 also requires keeping NOTICE files, for example Neon's `NOTICE`.
- **Runtime downloads:** pgrag downloads ONNX model weights at runtime (MIT and Apache-2.0 per their model cards), and pg_duckdb can install DuckDB extensions at runtime.
  - Neither is part of the image.
  - The pgrag download URL compiled into the image points to a Neon-internal host. Outside Neon's infrastructure, the model-backed pgrag functions cannot fetch their models unless the image is rebuilt with a different `REMOTE_ONNX_URL`.

## Unverified

- **Bundled code inside large components was not audited:** third-party code vendored inside DuckDB, ONNX Runtime, V8, RDKit and PostGIS, the full crates.io dependency trees of the pgrx extensions and the Neon binaries, and the Go module dependencies of the three exporters.
- **Debian package licenses** are quoted from general knowledge of the packages, not checked one by one against the copyright files in the image.
- **pgrag model files:** the license of the ONNX files served from the Neon-internal `REMOTE_ONNX_URL` is assumed to match the upstream Hugging Face models (BAAI/bge-small-en-v1.5: MIT; jinaai/jina-reranker-v1-tiny-en: Apache-2.0). The hosted files themselves were not inspected.
- **PostgreSQL Anonymizer data:** the license of the sample/fake-data files shipped under `data/` was not checked separately. The project as a whole is PostgreSQL-licensed.
