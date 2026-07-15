#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${REPO_ROOT}/_out-gcc16/x86_64-centos6-linux-gnu}"
readonly CC="${TOOLCHAIN_DIR}/bin/x86_64-centos6-linux-gnu-gcc"
readonly CXX="${TOOLCHAIN_DIR}/bin/x86_64-centos6-linux-gnu-g++"
readonly ABI_VALIDATOR="${REPO_ROOT}/scripts/docker/container/validate-centos6-multilib-abi.sh"
readonly CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
readonly CENTOS6_IMAGE="${CENTOS6_IMAGE:-quay.io/centos/centos@sha256:9aae95c8043f4e401178d68006756dc68982ae6d0693b71a714754227ce0abc6}"
readonly RUNTIME_TIMEOUT="${RUNTIME_TIMEOUT:-30s}"

if [[ ! -x "${CC}" || ! -x "${CXX}" ]]; then
    echo "missing Phase 1 GCC 16 compilers under: ${TOOLCHAIN_DIR}/bin" >&2
    exit 2
fi
if ! command -v "${CONTAINER_ENGINE}" >/dev/null 2>&1; then
    echo "container engine not found: ${CONTAINER_ENGINE}" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "timeout command not found" >&2
    exit 2
fi

"${ABI_VALIDATOR}" "${CC}" "$("${CC}" -print-sysroot)"

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

static_flags=(-std=c++17 -static-libstdc++ -static-libgcc)
"${CXX}" "${static_flags[@]}" -O0 \
    "${SCRIPT_DIR}/centos6-libstdcxx-o2-repro.cpp" -o "${work_dir}/repro-o0"
"${CXX}" "${static_flags[@]}" -O2 \
    "${SCRIPT_DIR}/centos6-libstdcxx-o2-repro.cpp" -o "${work_dir}/repro-o2"
"${CXX}" "${static_flags[@]}" -O2 -fno-inline \
    "${SCRIPT_DIR}/centos6-libstdcxx-o2-repro.cpp" -o "${work_dir}/repro-o2-no-inline"
"${CXX}" -std=c++17 -O2 \
    "${SCRIPT_DIR}/centos6-libstdcxx-o2-repro.cpp" -o "${work_dir}/repro-o2-dynamic"
cp -L "$("${CXX}" -print-file-name=libstdc++.so.6)" "${work_dir}/"
cp -L "$("${CXX}" -print-file-name=libgcc_s.so.1)" "${work_dir}/"

set +e
runtime_output="$(timeout "${RUNTIME_TIMEOUT}" "${CONTAINER_ENGINE}" run --rm \
    -v "${work_dir}:/repro:ro,Z" \
    "${CENTOS6_IMAGE}" \
    sh -c '
        printf test > /tmp/centos6-libstdcxx-o2-repro-input
        set +e
        /repro/repro-o0
        o0=$?
        /repro/repro-o2
        o2=$?
        /repro/repro-o2-no-inline
        no_inline=$?
        LD_LIBRARY_PATH=/repro /repro/repro-o2-dynamic
        dynamic=$?
        printf "RESULT O0=%s O2=%s O2_fno_inline=%s O2_dynamic=%s\n" \
            "$o0" "$o2" "$no_inline" "$dynamic"
    '
    2>&1)"
container_status=$?
set -e
printf '%s\n' "${runtime_output}"

if [[ ${container_status} -ne 0 ]]; then
    echo "ERROR: CentOS 6 container did not complete (status ${container_status})." >&2
    exit 2
fi
if [[ ! ${runtime_output} =~ RESULT[[:space:]]+O0=([0-9]+)[[:space:]]+O2=([0-9]+)[[:space:]]+O2_fno_inline=([0-9]+)[[:space:]]+O2_dynamic=([0-9]+) ]]; then
    echo "ERROR: CentOS 6 container returned no parseable result." >&2
    exit 2
fi

o0="${BASH_REMATCH[1]}"
o2="${BASH_REMATCH[2]}"
no_inline="${BASH_REMATCH[3]}"
dynamic="${BASH_REMATCH[4]}"
if [[ ${o0} -ne 0 || ${o2} -ne 0 || ${no_inline} -ne 0 || ${dynamic} -ne 0 ]]; then
    echo "FAIL: libstdc++ runtime gate failed: O0=${o0} O2=${o2} O2_fno_inline=${no_inline} O2_dynamic=${dynamic}" >&2
    echo "Current affected toolchain normally fails both optimized variants." >&2
    exit 1
fi

echo "PASS: optimized static and dynamic libstdc++ file-stream code runs on CentOS 6."
