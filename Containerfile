# Reproducible enclave build for the PQ root key ceremony (`pq-ceremony`).
#
# Builds the in-enclave binary with the real NSM (`--features nitro`) statically
# against musl, then assembles a minimal `scratch` image containing just the
# binary and the pinned AWS Nitro root CA. The PCR0/1/2 this image measures to
# must be reproducible: `caution verify` rebuilds from this file and compares.
#
# Pin every StageX image by digest before deploying. Refresh with:
#   docker pull stagex/pallet-rust --platform linux/amd64
#   docker inspect stagex/pallet-rust --format '{{index .RepoDigests 0}}'
# then replace the placeholder digest below.

FROM --platform=linux/amd64 stagex/pallet-rust@sha256:59d4d0c9e232a05ecb99348f7216b521af1b914a430059dbdb9130018f2afde1 AS build

WORKDIR /app

ENV SOURCE_DATE_EPOCH=1
ENV CARGO_TARGET_DIR=/target
ENV CARGO_INCREMENTAL=0
ENV RUSTFLAGS="-C codegen-units=1 -C target-feature=+crt-static -C strip=symbols --remap-path-prefix=/app=. --remap-path-prefix=/target=target"

# Workspace manifest + lockfile first so the dependency set is pinned.
COPY Cargo.toml Cargo.lock ./
COPY .cargo ./.cargo
COPY crates ./crates

# Network-allowed fetch layer; everything after is hermetic.
RUN cargo fetch --locked --target "$(uname -m)-unknown-linux-musl"

# Hermetic compile: only the fetched, locked deps; real NSM via `nitro`.
RUN --network=none <<-'EOF'
	set -eux
	triple="$(uname -m)-unknown-linux-musl"
	cargo build --frozen --release --target "${triple}" \
		-p pq-ceremony --features nitro --bin pq-ceremony
	install -Dm755 "/target/${triple}/release/pq-ceremony" /pq-ceremony
EOF

# The public AWS Nitro root CA comes from the host build context, so git's
# exec-bit-only tracking makes its checkout mode `0666 & ~umask` (0644 on a
# umask-022 host, 0664 on umask-002). The enclave framework measures the app
# image's modes verbatim, so an unpinned mode makes PCR0/1 depend on the build
# host. Normalize it here, in-container, with a single chmod.
COPY aws_nitro_root.der /tmp/aws_nitro_root.der
RUN chmod 0644 /tmp/aws_nitro_root.der

FROM scratch AS run
# Both plain copies from the build stage, where all modes are deterministic.
# (Copying from the build stage — not the host context — also creates /app,
# /etc, /etc/pq at the default 0755, so they stay traversable.)
COPY --from=build /pq-ceremony /app/pq-ceremony
COPY --from=build /tmp/aws_nitro_root.der /etc/pq/aws_nitro_root.der
ENTRYPOINT ["/app/pq-ceremony"]
