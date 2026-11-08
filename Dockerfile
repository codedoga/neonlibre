### Creates a storage Docker image with postgres, pageserver, safekeeper and proxy binaries.
### The image itself is mainly used as a container for the binaries and for starting e2e tests with custom parameters.
### By default, the binaries inside the image have some mock parameters and can start, but are not intended to be used
### inside this image in the real deployments.
ARG REPOSITORY=ghcr.io/neondatabase
ARG IMAGE=build-tools
ARG TAG=pinned
ARG DEBIAN_VERSION=trixie
ARG DEBIAN_FLAVOR=${DEBIAN_VERSION}-slim

# Here are the INDEX DIGESTS for the images we use.
# You can get them following next steps for now:
# 1. Get an authentication token from DockerHub:
#    TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" | jq -r .token)
# 2. Using that token, query index for the given tag:
#    curl -s -H "Authorization: Bearer $TOKEN" \
#       -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
#       "https://registry.hub.docker.com/v2/library/debian/manifests/bullseye-slim" \
#       -I | grep -i docker-content-digest
# 3. As a next step, TODO(fedordikarev): create script and schedule workflow to run these checks
#    and updates on regular bases and in automated way.
ARG TRIXIE_SLIM_SHA=sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
ARG BOOKWORM_SLIM_SHA=sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
ARG BULLSEYE_SLIM_SHA=sha256:e831d9a884d63734fe3dd9c491ed9a5a3d4c6a6d32c5b14f2067357c49b0b7e1

# Here we use ${var/search/replace} syntax, to check
# if base image is one of the images, we pin image index for.
# If var will match one the known images, we will replace it with the known sha.
# If no match, than value will be unaffected, and will process with no-pinned image.
ARG BASE_IMAGE_SHA=debian:${DEBIAN_FLAVOR}
ARG BASE_IMAGE_SHA=${BASE_IMAGE_SHA/debian:trixie-slim/debian@$TRIXIE_SLIM_SHA}
ARG BASE_IMAGE_SHA=${BASE_IMAGE_SHA/debian:bookworm-slim/debian@$BOOKWORM_SLIM_SHA}
ARG BASE_IMAGE_SHA=${BASE_IMAGE_SHA/debian:bullseye-slim/debian@$BULLSEYE_SLIM_SHA}

# Naive way:
#
# 1. COPY . .
# 1. make neon-pg-ext
# 2. cargo build <storage binaries>
#
# But to enable docker to cache intermediate layers, we perform a few preparatory steps:
#
# - Build all postgres versions, depending on just the contents of vendor/
# - Use cargo chef to build all rust dependencies

# 1. Build all postgres versions
FROM $REPOSITORY/$IMAGE:$TAG AS pg-build
WORKDIR /home/nonroot

COPY --chown=nonroot vendor/postgres-v14 vendor/postgres-v14
COPY --chown=nonroot vendor/postgres-v15 vendor/postgres-v15
COPY --chown=nonroot vendor/postgres-v16 vendor/postgres-v16
COPY --chown=nonroot vendor/postgres-v17 vendor/postgres-v17
COPY --chown=nonroot vendor/postgres-v18 vendor/postgres-v18
COPY --chown=nonroot Makefile Makefile
COPY --chown=nonroot postgres.mk postgres.mk
COPY --chown=nonroot scripts/ninstall.sh scripts/ninstall.sh

ENV BUILD_TYPE=release
# Only v18 is built and shipped. postgres_ffi's bindgen still needs the headers of
# every version it knows, which postgres-headers-install provides cheaply.
RUN set -e \
    && mold -run make -j $(nproc) -s postgres-headers-install \
    && mold -run make -j $(nproc) -s postgres-v18

# 2. Prepare cargo-chef recipe
FROM $REPOSITORY/$IMAGE:$TAG AS plan
WORKDIR /home/nonroot

COPY --chown=nonroot . .

RUN --mount=type=secret,uid=1000,id=SUBZERO_ACCESS_TOKEN \
    set -e \
    && if [ -s /run/secrets/SUBZERO_ACCESS_TOKEN ]; then \
        export CARGO_NET_GIT_FETCH_WITH_CLI=true && \
        git config --global url."https://$(cat /run/secrets/SUBZERO_ACCESS_TOKEN)@github.com/neondatabase/subzero".insteadOf "https://github.com/neondatabase/subzero" && \
        cargo add -p proxy subzero-core --git https://github.com/neondatabase/subzero --rev 396264617e78e8be428682f87469bb25429af88a; \
    fi \
    && cargo chef prepare --recipe-path recipe.json

# Main build image
FROM $REPOSITORY/$IMAGE:$TAG AS build
WORKDIR /home/nonroot
ARG GIT_VERSION=local
ARG BUILD_TAG
ARG ADDITIONAL_RUSTFLAGS=""
ARG IO_ALIGNMENT=512
ENV CARGO_FEATURES="default"

# 3. Build cargo dependencies. Note that this step doesn't depend on anything else than
# `recipe.json`, so the layer can be reused as long as none of the dependencies change.
COPY --from=plan     /home/nonroot/recipe.json                              recipe.json
RUN --mount=type=secret,uid=1000,id=SUBZERO_ACCESS_TOKEN \
    set -e \
    && if [ -s /run/secrets/SUBZERO_ACCESS_TOKEN ]; then \
        export CARGO_NET_GIT_FETCH_WITH_CLI=true && \
        git config --global url."https://$(cat /run/secrets/SUBZERO_ACCESS_TOKEN)@github.com/neondatabase/subzero".insteadOf "https://github.com/neondatabase/subzero"; \
    fi \
    && RUSTFLAGS="-Clinker=clang -Clink-arg=-fuse-ld=mold -Clink-arg=-Wl,--no-rosegment -Cforce-frame-pointers=yes ${ADDITIONAL_RUSTFLAGS}" cargo chef cook --locked --release --recipe-path recipe.json

# Perform the main build. We reuse the Postgres build artifacts from the intermediate 'pg-build'
# layer, and the cargo dependencies built in the previous step.
COPY --chown=nonroot --from=pg-build /home/nonroot/pg_install/ pg_install
COPY --chown=nonroot . .
COPY --chown=nonroot --from=plan     /home/nonroot/proxy/Cargo.toml         proxy/Cargo.toml
COPY --chown=nonroot --from=plan     /home/nonroot/Cargo.lock               Cargo.lock

RUN  --mount=type=secret,uid=1000,id=SUBZERO_ACCESS_TOKEN \
    set -e \
    && if [ -s /run/secrets/SUBZERO_ACCESS_TOKEN ]; then \
        export CARGO_FEATURES="${CARGO_FEATURES},rest_broker"; \
    fi \
    && if [ "$IO_ALIGNMENT" = "4k" ]; then \
        export CARGO_FEATURES="${CARGO_FEATURES},io-align-4k"; \
    elif [ "$IO_ALIGNMENT" = "512" ]; then \
        export CARGO_FEATURES="${CARGO_FEATURES},io-align-512"; \
    fi \
    && RUSTFLAGS="-Clinker=clang -Clink-arg=-fuse-ld=mold -Clink-arg=-Wl,--no-rosegment -Cforce-frame-pointers=yes ${ADDITIONAL_RUSTFLAGS}" cargo auditable build \
      --features $CARGO_FEATURES \
      --bin pg_sni_router  \
      --bin pageserver  \
      --bin pagectl  \
      --bin safekeeper  \
      --bin storage_broker  \
      --bin storage_controller  \
      --bin proxy  \
      --bin endpoint_storage \
      --bin neon_local \
      --bin storage_scrubber \
      --locked --release \
    && mold -run make -j $(nproc) -s neon-pg-ext-v18

# The release profile keeps full debug info (see Cargo.toml), which is most of each
# binary: pageserver is 407MB with it and 74MB without. Symbols stay, so backtraces still
# name functions. The storage image needs from the Neon extensions only what walredo
# loads (neon_walredo, neon_rmgr); neon.so and friends belong to the compute image.
RUN set -e \
    && strip --strip-debug target/release/pg_sni_router target/release/pageserver \
        target/release/pagectl target/release/safekeeper target/release/storage_broker \
        target/release/storage_controller target/release/proxy target/release/endpoint_storage \
        target/release/neon_local target/release/storage_scrubber \
    && rm -f pg_install/v18/lib/postgresql/neon.so pg_install/v18/lib/postgresql/neon_utils.so \
        pg_install/v18/lib/postgresql/neon_test_utils.so pg_install/v18/lib/*.a \
    && find pg_install/v18/bin pg_install/v18/lib -type f \( -perm -u+x -o -name '*.so*' \) \
        -exec sh -c 'for f; do strip --strip-debug "$f" 2>/dev/null || true; done' _ {} +

# Assemble the final image
FROM $BASE_IMAGE_SHA
WORKDIR /data

RUN set -e \
    && echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80-retries \
    && apt update \
    && apt install -y --no-install-recommends \
        libreadline8 \
        libseccomp2 \
        libssl3 \
        libstdc++6 \
        ca-certificates \
        curl \
    && rm -f /etc/apt/apt.conf.d/80-retries \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && useradd -d /data neon \
    && chown -R neon:neon /data

COPY --from=build --chown=neon:neon /home/nonroot/target/release/pg_sni_router       /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/pageserver          /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/pagectl             /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/safekeeper          /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/storage_broker      /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/storage_controller  /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/proxy               /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/endpoint_storage    /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/neon_local          /usr/local/bin
COPY --from=build --chown=neon:neon /home/nonroot/target/release/storage_scrubber    /usr/local/bin
COPY --from=build /home/nonroot/pg_install/v18 /usr/local/v18/

# By default, pageserver uses `.neon/` working directory in WORKDIR, so create one and fill it with the dummy config.
# Now, when `docker run ... pageserver` is run, it can start without errors, yet will have some default dummy values.
RUN mkdir -p /data/.neon/ && \
  echo "id=1234" > "/data/.neon/identity.toml" && \
  echo "broker_endpoint='http://storage_broker:50051'\n" \
       "pg_distrib_dir='/usr/local/'\n" \
       "listen_pg_addr='0.0.0.0:6400'\n" \
       "listen_http_addr='0.0.0.0:9898'\n" \
       "availability_zone='local'\n" \
  > /data/.neon/pageserver.toml && \
  chown -R neon:neon /data/.neon

VOLUME ["/data"]
USER neon
EXPOSE 6400
EXPOSE 9898

CMD ["/usr/local/bin/pageserver", "-D", "/data/.neon"]
