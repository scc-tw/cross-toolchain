# capsule8 / cydroned cross-build image — Linux x86_64 host, multi-glibc target.
#
# Sibling to toolchain/build.sh (which builds a Mac arm64-native toolchain via
# crosstool-ng). This image is for CI / Docker workflows where Mac-native
# binaries can't run.
#
# Built around AmanoTeam/obggcc — prebuilt cross-toolchains with full sysroots
# for many glibc versions (2.3 through 2.39). We default to glibc 2.11 wrapper:
# obggcc skips the exact 2.12 entry, but binaries linked against 2.11 run on
# any glibc >= 2.11 (CentOS 6, RHEL 5+, every newer distro).
#
# HOST: Linux x86_64. On Apple Silicon Mac this runs under Rosetta 2 (~30-40%
# slower than native amd64). On Linux x86_64 servers it runs at full speed.
#
# Usage:
#   # Build (pin platform; obggcc has no arm64 host build):
#   docker build --platform=linux/amd64 -t capsule8/cross-builder:glibc211 toolchain/
#
#   # Use to compile cgo Go binary:
#   docker run --rm --platform=linux/amd64 -v $PWD:/work \
#     capsule8/cross-builder:glibc211 \
#     bash -c 'CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build ./cmd/sensor'
#
#   # Override target glibc (any value present in obggcc release):
#   docker run --rm --platform=linux/amd64 -v $PWD:/work \
#     -e CC=x86_64-unknown-linux-gnu2.17-gcc \
#     -e CXX=x86_64-unknown-linux-gnu2.17-g++ \
#     capsule8/cross-builder:glibc211 ...

FROM --platform=linux/amd64 debian:bookworm-slim

ARG OBGGCC_RELEASE=gcc-15
ARG CMAKE_VERSION=4.3.2
ARG GO_VERSION=1.22.12

# Host build tools. bookworm's gcc / make / pkg-config build whatever runs on
# the host (build scripts, codegen). Cross-target work goes through obggcc.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        git \
        make \
        ninja-build \
        pkg-config \
        python3 \
        file \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# obggcc: GCC 15.2 + binutils + per-glibc sysroots (~395 MB tarball, ~14
# variants 2.3 through 2.39, each a full sysroot ~3200 files).
RUN curl -fsSL https://github.com/AmanoTeam/obggcc/releases/download/${OBGGCC_RELEASE}/x86_64-unknown-linux-gnu.tar.xz \
      | tar -xJ -C /opt \
    && ls /opt/obggcc/bin | head -20

ENV PATH=/opt/obggcc/bin:/opt/obggcc/x86_64-unknown-linux-gnu/bin:$PATH \
    CC=x86_64-unknown-linux-gnu2.11-gcc \
    CXX=x86_64-unknown-linux-gnu2.11-g++ \
    AR=x86_64-unknown-linux-gnu-ar \
    RANLIB=x86_64-unknown-linux-gnu-ranlib \
    STRIP=x86_64-unknown-linux-gnu-strip \
    OBJCOPY=x86_64-unknown-linux-gnu-objcopy

# Kitware official cmake binary. Built against glibc 2.17, runs on any newer
# host (bookworm = glibc 2.36 → fine).
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz \
      | tar -xz -C /opt
ENV PATH=/opt/cmake-${CMAKE_VERSION}-linux-x86_64/bin:$PATH

# Go (cgo support). 1.22.x is last release supporting macOS 10.15 — kept
# in sync with the macOS deployment target floor (capsule8 ships to old Macs).
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
      | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:$PATH \
    GOPATH=/go \
    GOTOOLCHAIN=local

WORKDIR /work

# Sanity check available at build time so a broken obggcc download is caught.
RUN ${CC} --version | head -1 \
    && cmake --version | head -1 \
    && go version
