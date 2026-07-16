#!/usr/bin/env bash
# Entry point inside the finalfantasyliu/cross-toolbox container.
#
# Runs ct-ng to build one cross-toolchain target. The defconfig name is the
# only argument. ct-ng's work dir lives on the container's overlay FS (which
# is case-sensitive — required by ct-ng since glibc + Linux source has names
# differing only by case). We then copy build.log + .config + stdout out to
# /build (host bind mount) so the host always has them, even on failure.
#
# Usage (from host):
#   mkdir -p _out _logs
#   docker run --rm \
#     --platform=<builder-platform> \
#     -v "$PWD/_out:/opt/x-tools" \
#     -v "$PWD/_logs:/build" \
#     finalfantasyliu/cross-toolbox:phase1 \
#     x86_64-centos6-glibc212-gcc16
#
# On failure:
#   - _logs/build.log (real ct-ng log, copied from container)
#   - _logs/build.stdout.log (this script's tee'd output)
#   - _logs/.config (the resolved kconfig the failed build used)
#   - _logs/defconfig (the defconfig fed in)
#   - container exits non-zero so CI / `set -e` callers detect failure
#
# Iteration loop:
#   1. tweak defconfig in configs/
#   2. re-run docker run (defconfig changes need image rebuild — fast, only
#      final COPY layer)
#   3. inspect _logs/build.log on failure
#   4. if source patch needed, drop in
#      patches/ct-ng-gcc16-backport/packages/<pkg>/<ver>/

set -euxo pipefail
# pipefail: with `cmd | tee log`, ensure cmd's failure propagates.
# Without it, tee's exit (always 0 if it writes) masks ct-ng's failure.

DEFCONFIG_NAME="${1:?usage: docker-build-target.sh <defconfig-basename-without-.defconfig>}"
CONFIGS_DIR="${CONFIGS_DIR:-/configs}"
SRC="${CONFIGS_DIR}/${DEFCONFIG_NAME}.defconfig"

if [[ ! -f "${SRC}" ]]; then
    echo "ERROR: defconfig not found: ${SRC}" >&2
    echo "Available defconfigs in ${CONFIGS_DIR}:" >&2
    ls "${CONFIGS_DIR}/" >&2
    exit 1
fi

# WORK = ct-ng work dir, must be on case-sensitive FS. Container overlay2 ✓.
# LOGS = host bind mount, may be case-insensitive (macOS APFS). Only logs go
#        here, not ct-ng's .build/ work tree.
# See docker_experiments.md Error #3 for why this split exists.
WORK=/home/ctuser/work
LOGS=/build

# Per-run ID so iterations don't overwrite each other's logs.
# Format: YYYYMMDD-HHMMSS-XXXX (4 hex random) — sortable + unique enough.
# Each run lands in /build/run-<id>/, plus we update /build/latest -> run-<id>.
RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$(printf '%04x' $(( RANDOM * RANDOM % 65536 )))"
RUN_LOGS="${LOGS}/run-${RUN_ID}"
mkdir -p "${RUN_LOGS}"
echo "${RUN_ID}" > "${LOGS}/.last-run-id"

mkdir -p "${WORK}"
cd "${WORK}"

# Sync logs + .config to host mount, into the per-run dir.
# Run on EXIT (success or failure) so we always have logs to inspect.
copy_logs_to_host() {
    local rc=$?
    set +e
    cp -f "${WORK}/build.log"        "${RUN_LOGS}/build.log"        2>/dev/null
    cp -f "${WORK}/build.log.bz2"    "${RUN_LOGS}/build.log.bz2"    2>/dev/null
    cp -f "${WORK}/.config"          "${RUN_LOGS}/.config"          2>/dev/null
    cp -f "${WORK}/defconfig"        "${RUN_LOGS}/defconfig"        2>/dev/null
    cp -f "${WORK}/build.stdout.log" "${RUN_LOGS}/build.stdout.log" 2>/dev/null
    # write a one-line summary so grep across runs is easy
    {
        printf 'run_id=%s defconfig=%s exit=%s ts=%s\n' \
            "${RUN_ID}" "${DEFCONFIG_NAME}" "${rc}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${RUN_LOGS}/run-summary.txt"
    # update "latest" pointer (a symlink in /build/) so user can do:
    #   cat _logs/latest/build.log
    # without having to discover the run-id manually
    ( cd "${LOGS}" && rm -f latest && ln -sf "run-${RUN_ID}" latest ) 2>/dev/null
    set -e
    return "${rc}"
}
trap copy_logs_to_host EXIT

cp "${SRC}" defconfig

# ct-ng reads "defconfig" file via DEFCONFIG=defconfig env, current dir.
DEFCONFIG=defconfig ct-ng defconfig

echo "=== resolved .config (key knobs) ==="
grep -E "^CT_(GCC|GLIBC|GDB|BINUTILS|LINUX|MULTILIB|TARGET_VENDOR)" .config || true
echo "==="

echo "=== ct-ng build starting (work dir: ${WORK}; logs: ${LOGS}) ==="
date

# tee inside ${WORK} so the trap can copy it out at exit.
# pipefail propagates ct-ng failure even though tee returns 0.
ct-ng build 2>&1 | tee "${WORK}/build.stdout.log"

echo "=== ct-ng build finished ==="
date

# Locate produced toolchain.
# CT_TARGET is a derived value (composed at build-time from CT_ARCH +
# CT_TARGET_VENDOR + CT_KERNEL + CT_LIBC), NOT written to .config. So we
# can't grep it. Instead reach the install dir reflectively: take
# CT_PREFIX_DIR's parent (e.g. "/opt/x-tools") and pick the most recently
# modified subdir — that's the one ct-ng just installed to.
PREFIX_TEMPLATE=$(awk -F'"' '/^CT_PREFIX_DIR=/{print $2}' .config)
PREFIX_PARENT=$(dirname "${PREFIX_TEMPLATE}")
PREFIX=$(ls -1dt "${PREFIX_PARENT}"/*/ 2>/dev/null | head -1)
PREFIX="${PREFIX%/}"

if [[ -z "${PREFIX}" || ! -d "${PREFIX}" ]]; then
    echo "FAIL: ct-ng reported success but no install dir under ${PREFIX_PARENT}" >&2
    exit 1
fi

TARGET=$(basename "${PREFIX}")
GCC_BIN="${PREFIX}/bin/${TARGET}-gcc"
SYSROOT="${PREFIX}/${TARGET}/sysroot"

if [[ ! -x "${GCC_BIN}" ]]; then
    echo "FAIL: install dir ${PREFIX} exists but ${GCC_BIN} missing/non-exec" >&2
    exit 1
fi

check_wordsize() {
    local label="$1"
    local cflag="$2"
    local want_pointer="$3"
    local want_wordsize="$4"
    local want_uintptr="$5"
    local args=()
    local macros pointer_size wordsize uintptr_max

    if [[ -n "${cflag}" ]]; then
        args+=("${cflag}")
    fi

    macros=$(printf '#include <stdint.h>\n#include <bits/wordsize.h>\n' \
        | "${GCC_BIN}" "${args[@]}" -dM -E -x c -)
    pointer_size=$(awk '/^#define __SIZEOF_POINTER__/ {print $3}' <<<"${macros}" | tail -1)
    wordsize=$(awk '/^#define __WORDSIZE / {print $3}' <<<"${macros}" | tail -1)
    uintptr_max=$(awk '/^#define UINTPTR_MAX / {print substr($0, index($0, $3))}' <<<"${macros}" | tail -1)

    echo "  ${label}: __SIZEOF_POINTER__=${pointer_size:-missing} __WORDSIZE=${wordsize:-missing} UINTPTR_MAX=${uintptr_max:-missing}"

    if [[ "${pointer_size}" != "${want_pointer}" \
       || "${wordsize}" != "${want_wordsize}" \
       || "${uintptr_max}" != "${want_uintptr}" ]]; then
        echo "FAIL: ${label} glibc headers disagree with target pointer width" >&2
        exit 1
    fi
}

echo
echo "=== smoke test ==="
"${GCC_BIN}" --version | head -1
echo "sysroot: ${SYSROOT}"

echo "target header sanity:"
if [[ "${TARGET}" == "x86_64-centos6-linux-gnu" ]]; then
    /usr/local/bin/validate-centos6-multilib-abi.sh "${GCC_BIN}" "${SYSROOT}"

    echo "optimized C++ runtime sanity:"
    CXX_BIN="${PREFIX}/bin/${TARGET}-g++"
    CXX_REPRO_SOURCE=/usr/local/share/cross-toolchain/centos6-libstdcxx-o2-repro.cpp
    CXX_CANCEL_SOURCE=/usr/local/share/cross-toolchain/pthread-cancel-cxx-unwind.cpp
    CXX_GATE_DIR="${WORK}/centos6-libstdcxx-runtime-gate"
    CXX_RUNTIME_LIB_DIR=$(dirname "$("${CXX_BIN}" -print-file-name=libstdc++.so.6)")
    rm -rf "${CXX_GATE_DIR}"
    mkdir -p "${CXX_GATE_DIR}"
    printf test > /tmp/centos6-libstdcxx-o2-repro-input
    "${CXX_BIN}" -std=c++17 -O2 -static-libstdc++ -static-libgcc \
        "${CXX_REPRO_SOURCE}" -o "${CXX_GATE_DIR}/repro-static"
    "${CXX_BIN}" -std=c++17 -O2 \
        "${CXX_REPRO_SOURCE}" -o "${CXX_GATE_DIR}/repro-dynamic"
    timeout 30s "${CXX_GATE_DIR}/repro-static"
    LD_LIBRARY_PATH="${CXX_RUNTIME_LIB_DIR}" \
        timeout 30s "${CXX_GATE_DIR}/repro-dynamic"
    echo "PASS: optimized static and dynamic C++ runtime sanity"

    echo "pthread cancellation C++ unwind sanity:"
    "${CXX_BIN}" -std=c++17 -O2 -pthread -static-libstdc++ -static-libgcc \
        "${CXX_CANCEL_SOURCE}" -o "${CXX_GATE_DIR}/cancel-static-libgcc"
    "${CXX_BIN}" -std=c++17 -O2 -pthread -static-libstdc++ -shared-libgcc \
        "${CXX_CANCEL_SOURCE}" -o "${CXX_GATE_DIR}/cancel-shared-libgcc"
    timeout 30s "${SYSROOT}/lib64/ld-linux-x86-64.so.2" \
        --library-path "${SYSROOT}/lib64:${SYSROOT}/usr/lib64:${CXX_RUNTIME_LIB_DIR}" \
        "${CXX_GATE_DIR}/cancel-static-libgcc"
    timeout 30s "${SYSROOT}/lib64/ld-linux-x86-64.so.2" \
        --library-path "${SYSROOT}/lib64:${SYSROOT}/usr/lib64:${CXX_RUNTIME_LIB_DIR}" \
        "${CXX_GATE_DIR}/cancel-shared-libgcc"
    echo "PASS: static and shared libgcc pthread cancellation C++ unwind sanity"

    run_sysroot_cxx_gate() {
        local label="$1"
        local cflag="$2"
        local loader="$3"
        local library_path="$4"
        local binary="${CXX_GATE_DIR}/repro-sysroot-${label}"

        if [[ ! -x "${loader}" ]]; then
            echo "FAIL: ${label} sysroot loader missing/non-exec: ${loader}" >&2
            exit 1
        fi

        "${CXX_BIN}" "${cflag}" -std=c++17 -O2 \
            "${CXX_REPRO_SOURCE}" -o "${binary}"
        timeout 30s "${loader}" --library-path "${library_path}" "${binary}"
    }

    echo "sysroot-loader C++ runtime sanity:"
    run_sysroot_cxx_gate \
        m64 -m64 \
        "${SYSROOT}/lib64/ld-linux-x86-64.so.2" \
        "${SYSROOT}/lib64:${SYSROOT}/usr/lib64"
    run_sysroot_cxx_gate \
        m32 -m32 \
        "${SYSROOT}/lib/ld-linux.so.2" \
        "${SYSROOT}/lib:${SYSROOT}/usr/lib"
    echo "PASS: optimized m64 and m32 C++ runtime sanity through sysroot loaders"
else
    check_wordsize "default" "" 8 64 "(18446744073709551615UL)"
fi

LIBC="${SYSROOT}/lib/libc.so.6"
[[ -f "${LIBC}" ]] || LIBC="${SYSROOT}/lib64/libc.so.6"
if [[ -f "${LIBC}" ]]; then
    echo "GLIBC versions in sysroot libc (top 3):"
    "${PREFIX}/bin/${TARGET}-objdump" -T "${LIBC}" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -3 | sed 's/^/  /'
fi

echo
echo "✅ ${TARGET} toolchain built at ${PREFIX}"
