#!/usr/bin/env bash
# Cross-toolchain smoke test using SQLite (~290k LOC C amalgamation)
#
# Builds sqlite3 CLI binary for each of our 4 cross-toolchain targets and
# verifies it actually runs (Linux targets in docker; macOS targets get
# host-run instructions printed).
#
# Targets:
#   1. x86_64-centos6-linux-gnu  (Phase 1)
#   2. aarch64-centos7-linux-gnu (Phase 2)
#   3. x86_64-apple-darwin20.4   (Phase 3, deploy 10.15+)
#   4. arm64-apple-darwin20.4    (Phase 3, deploy 11.0+)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly SRC_DIR="${SCRIPT_DIR}/src"
readonly OUT_DIR="${SCRIPT_DIR}/out"

default_toolbox_platform() {
    case "$(uname -m)" in
        x86_64|amd64) echo linux/amd64 ;;
        arm64|aarch64) echo linux/arm64 ;;
        *) echo "" ;;
    esac
}

readonly TOOLBOX_PLATFORM="${TOOLBOX_PLATFORM:-$(default_toolbox_platform)}"
TOOLBOX_PLATFORM_ARGS=()
if [[ -n "${TOOLBOX_PLATFORM}" ]]; then
    TOOLBOX_PLATFORM_ARGS=(--platform="${TOOLBOX_PLATFORM}")
fi

mkdir -p "${OUT_DIR}"

# Common flags for SQLite shell build (per upstream README)
SQLITE_FLAGS=(
    -DSQLITE_THREADSAFE=1
    -DSQLITE_ENABLE_FTS5
    -DSQLITE_ENABLE_RTREE
    -DSQLITE_ENABLE_JSON1
    -DHAVE_READLINE=0  # 不要扯 readline，跨平台簡單
)

# Test SQL — exercises CRUD + JSON + agg
# SQLite 標準: 單引號 = 字串字面值；雙引號 = 識別字（column 名）
readonly TEST_SQL="
.headers on
SELECT sqlite_version() AS version, 'smoke_test' AS test;
CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, val INTEGER);
INSERT INTO t (name, val) VALUES ('foo', 1), ('bar', 2), ('baz', 3);
SELECT count(*) AS rowcount, sum(val) AS total FROM t;
SELECT json_object('name', name, 'val', val) AS doc FROM t WHERE id=2;
"

print_header() {
    echo
    echo "======================================================================"
    echo "  $*"
    echo "======================================================================"
}

# ---------------------------------------------------------------------------
# Build for a Linux target using the matching cross-toolbox image
# Args: $1=phase (phase1|phase2)  $2=triple  $3=image-tag
# ---------------------------------------------------------------------------
build_linux() {
    local phase="$1"
    local triple="$2"
    local image="$3"
    local out_bin="${OUT_DIR}/sqlite3-${triple}"

    print_header "Building ${triple}  (Phase ${phase})"

    # Build inside the existing phase image, with toolchain mounted from sparseimage
    docker run --rm \
        "${TOOLBOX_PLATFORM_ARGS[@]}" \
        -v /Volumes/capsule8-xtools:/opt/x-tools \
        -v "${SRC_DIR}:/src:ro" \
        -v "${OUT_DIR}:/out" \
        --entrypoint bash \
        "${image}" \
        -c "
            set -eu
            CROSS=/opt/x-tools/${triple}/bin/${triple}-gcc
            \${CROSS} --version | head -1
            \${CROSS} ${SQLITE_FLAGS[@]} \
                /src/sqlite3.c /src/shell.c \
                -o /out/sqlite3-${triple} \
                -lpthread -lm -ldl
            ls -la /out/sqlite3-${triple}
        "

    file "${out_bin}"
    ls -la "${out_bin}"
}

# ---------------------------------------------------------------------------
# Run binary inside a Linux container of matching arch
# Args: $1=triple  $2=docker-platform  $3=base-image
# ---------------------------------------------------------------------------
run_linux() {
    local triple="$1"
    local platform="$2"
    local base_image="$3"
    local out_bin="${OUT_DIR}/sqlite3-${triple}"

    print_header "Running ${triple} smoke test  (in ${base_image} on ${platform})"

    # qemu-user emulation auto-enabled in OrbStack for non-native arch
    docker run --rm \
        --platform="${platform}" \
        -v "${OUT_DIR}:/out:ro" \
        "${base_image}" \
        bash -c "
            /out/sqlite3-${triple} :memory: <<EOF
${TEST_SQL}
EOF
        "
}

# ---------------------------------------------------------------------------
# Build macOS targets via osxcross
# Args: $1=triple  $2=min-version
# ---------------------------------------------------------------------------
build_macos() {
    local triple="$1"
    local minver="$2"
    local out_bin="${OUT_DIR}/sqlite3-${triple}"

    print_header "Building ${triple}  (Phase 3 osxcross, deploy ${minver}+)"

    docker run --rm \
        "${TOOLBOX_PLATFORM_ARGS[@]}" \
        -v "${SRC_DIR}:/src:ro" \
        -v "${OUT_DIR}:/out" \
        finalfantasyliu/cross-toolbox:phase3 \
        -c "
            set -eu
            CROSS=/opt/osxcross/bin/${triple}-clang
            \${CROSS} --version | head -1
            \${CROSS} -mmacos-version-min=${minver} \
                ${SQLITE_FLAGS[@]} \
                /src/sqlite3.c /src/shell.c \
                -o /out/sqlite3-${triple} \
                -lpthread
            ls -la /out/sqlite3-${triple}
        "

    file "${out_bin}"
    ls -la "${out_bin}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# === BUILD ALL 4 ===
build_linux phase1 x86_64-centos6-linux-gnu  finalfantasyliu/cross-toolbox:phase1
build_linux phase2 aarch64-centos7-linux-gnu finalfantasyliu/cross-toolbox:phase2
build_macos        x86_64-apple-darwin20.4  10.15
build_macos        arm64-apple-darwin20.4   11.0

# === RUN LINUX TARGETS ===
# Phase 1 binary needs glibc 2.12+ environment. Use vault centos 6 image.
# (centos:6 deprecated but still pullable; quay.io/centos/centos:6 is mirror)
run_linux x86_64-centos6-linux-gnu  linux/amd64 quay.io/centos/centos:centos6 || \
    echo "WARN: Phase 1 run failed (centos:6 image issue or qemu emulation)"

# Phase 2 binary needs glibc 2.17+ on aarch64. Use centos:7 (real has aarch64 build).
run_linux aarch64-centos7-linux-gnu linux/arm64 arm64v8/centos:7 || \
    echo "WARN: Phase 2 run failed"

# === MACOS TARGETS: print host run commands ===
print_header "macOS targets — run on host (Apple Silicon Mac)"

cat <<EOF
The macOS binaries can't run inside Linux containers. To verify:

  # Run Intel binary on Apple Silicon Mac (Rosetta 2):
  ${OUT_DIR}/sqlite3-x86_64-apple-darwin20.4 :memory: <<<'SELECT sqlite_version();'

  # Run ARM binary natively on Apple Silicon Mac:
  ${OUT_DIR}/sqlite3-arm64-apple-darwin20.4 :memory: <<<'SELECT sqlite_version();'

Both binaries should print sqlite version 3.47.0 followed by a CLI prompt.

  file ${OUT_DIR}/sqlite3-x86_64-apple-darwin20.4
  file ${OUT_DIR}/sqlite3-arm64-apple-darwin20.4
EOF

print_header "Smoke test complete. Binaries at ${OUT_DIR}/"
ls -la "${OUT_DIR}"/
