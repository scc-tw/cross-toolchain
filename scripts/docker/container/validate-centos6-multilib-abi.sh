#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'usage: %s <target-gcc> <sysroot>\n' "${0##*/}" >&2
}

if (( $# != 2 )); then
    usage
    exit 2
fi

readonly TARGET_GCC=$1
readonly SYSROOT=$2

if [[ "${TARGET_GCC}" == */* ]]; then
    if [[ ! -x "${TARGET_GCC}" ]]; then
        printf 'FAIL: compiler is not executable: %s\n' "${TARGET_GCC}" >&2
        exit 1
    fi
elif ! command -v "${TARGET_GCC}" >/dev/null 2>&1; then
    printf 'FAIL: compiler command not found: %s\n' "${TARGET_GCC}" >&2
    exit 1
fi

if [[ ! -d "${SYSROOT}" ]]; then
    printf 'FAIL: sysroot is not a directory: %s\n' "${SYSROOT}" >&2
    exit 1
fi

for stub in stubs-32.h stubs-64.h; do
    if [[ ! -f "${SYSROOT}/usr/include/gnu/${stub}" ]]; then
        printf 'FAIL: required header is missing: %s\n' \
            "${SYSROOT}/usr/include/gnu/${stub}" >&2
        exit 1
    fi
done

check_abi() {
    local label=$1
    local gcc_flag=$2
    local pointer_size=$3
    local word_size=$4
    local mutex_size=$5
    local uintptr_limit=$6
    local -a gcc_flags=()

    if [[ -n "${gcc_flag}" ]]; then
        gcc_flags+=("${gcc_flag}")
    fi

    printf 'checking %s... ' "${label}"
    if ! "${TARGET_GCC}" --sysroot="${SYSROOT}" "${gcc_flags[@]}" \
        -std=gnu11 -x c -fsyntax-only - <<EOF
#include <stdint.h>
#include <stddef.h>
#include <bits/wordsize.h>
#include <pthread.h>

#ifndef __WORDSIZE
# error "__WORDSIZE is not defined"
#elif __WORDSIZE != ${word_size}
# error "__WORDSIZE does not match the selected ABI"
#endif

#if UINTPTR_MAX != ${uintptr_limit}
# error "UINTPTR_MAX does not match the selected ABI"
#endif

_Static_assert(sizeof(void *) == ${pointer_size}, "unexpected pointer size");
_Static_assert(sizeof(uintptr_t) == ${pointer_size}, "unexpected uintptr_t size");
_Static_assert(sizeof(intptr_t) == ${pointer_size}, "unexpected intptr_t size");
_Static_assert(sizeof(size_t) == ${pointer_size}, "unexpected size_t size");
_Static_assert(sizeof(ptrdiff_t) == ${pointer_size}, "unexpected ptrdiff_t size");
_Static_assert(sizeof(long) == ${pointer_size}, "unexpected long size");
_Static_assert(sizeof(pthread_mutex_t) == ${mutex_size}, "unexpected pthread_mutex_t size");
_Static_assert(sizeof(pthread_cond_t) == 48, "unexpected pthread_cond_t size");
EOF
    then
        printf 'FAIL\n' >&2
        return 1
    fi
    printf 'PASS\n'
}

check_abi 'm64 (default)' '' 8 64 40 UINT64_MAX
check_abi 'm32 (-m32)' '-m32' 4 32 24 UINT32_MAX

printf 'PASS: CentOS 6 multilib ABI headers validated\n'
