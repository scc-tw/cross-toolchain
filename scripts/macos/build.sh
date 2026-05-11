#!/usr/bin/env bash
# Build x86_64-centos6-linux-gnu cross-toolchain (GCC 11.2 + glibc 2.12.1).
# Matches reference's toolchain exactly: same target tuple, same GCC, same glibc.
#
# Driver around a project-local ct-ng 1.25.0 install (1.25 is the last release
# that ships glibc 2.12; brew's current 1.28 dropped it).
#
# Usage:
#   bash scripts/macos/build.sh                                  # default defconfig
#   bash scripts/macos/build.sh path/to/other.defconfig          # alternate config
#
# Environment overrides:
#   WORK_DIR=/path  ct-ng work / build dir (default: <repo>/tmp/ct-x86_64-centos6)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEFCONFIG="${1:-${REPO_ROOT}/configs/x86_64-centos6-glibc212.defconfig}"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/tmp/ct-x86_64-centos6}"

# Project-local ct-ng 1.25.0 install. Built from upstream release tarball.
CT_NG_PREFIX="${REPO_ROOT}/tmp/ct-ng-1.25"
CT_NG_BIN="${CT_NG_PREFIX}/bin/ct-ng"

if [[ ! -f "${DEFCONFIG}" ]]; then
    echo "ERROR: defconfig not found: ${DEFCONFIG}" >&2
    exit 1
fi

if [[ ! -x "${CT_NG_BIN}" ]]; then
    echo "ERROR: ct-ng 1.25 not installed at ${CT_NG_PREFIX}." >&2
    echo "Run: bash ${REPO_ROOT}/scripts/macos/bootstrap-ctng.sh" >&2
    exit 1
fi

# Brew dependencies (same set as 1.28 path; ct-ng's host-side build needs them).
if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew required on macOS host. Install: https://brew.sh" >&2
    exit 1
fi

REQUIRED_BREW=(
    autoconf automake bash binutils bison gawk
    gettext gnu-sed gnu-tar help2man libtool
    make ncurses readline texinfo wget xz zstd
)
for pkg in "${REQUIRED_BREW[@]}"; do
    if ! brew list --formula "${pkg}" >/dev/null 2>&1; then
        echo "Installing missing dep: ${pkg}"
        brew install "${pkg}"
    fi
done
hash -r

# PATH ordering — same rationale as build.sh (1.28 path).
# /bin first so `bash` resolves to /bin/bash 3.2 (no CoreFoundation linkage),
# avoiding macOS 26's fork-safety abort in autoconf subshells.
BREW_PREFIX="$(brew --prefix)"
export PATH="\
/bin:/usr/bin:\
${BREW_PREFIX}/opt/make/libexec/gnubin:\
${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin:\
${BREW_PREFIX}/opt/gnu-tar/libexec/gnubin:\
${BREW_PREFIX}/opt/bison/bin:\
${BREW_PREFIX}/opt/libtool/libexec/gnubin:\
${PATH}:\
${BREW_PREFIX}/opt/binutils/bin"

export BASH=/bin/bash
export CONFIG_SHELL=/bin/bash
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

# Use brew GCC 14 as host C/C++ compiler instead of Apple Clang 21.
# Apple Clang 21 ships with libc++ 21 whose <__locale> header uses C++23/26
# attribute syntax (__abi_tag__ on using-declarations etc.) that GCC 11
# source's expectations from 2021 can't parse — stage-1 GCC build dies
# with "'__abi_tag__' attribute only applies to..." errors.
# brew GCC 14 brings libstdc++ 14 (different stdlib family from libc++),
# which is what GCC 11 source was designed to bootstrap with.
#
# ct-ng explicitly aborts if CC/CXX env vars are set ("Don't set CC. It
# screws up the build"). The supported way is to make `gcc` / `g++` in
# PATH resolve to brew gcc-14. Brew names them with a -14 suffix
# (gcc-14, g++-14), so we create a small wrapper directory with unsuffixed
# symlinks and put it first in PATH. ar/ranlib/nm stay Apple's (those work
# fine, only the C++ stdlib parsing was the problem).
GCC14_PREFIX="${BREW_PREFIX}/opt/gcc@14"
WRAPPERS="${REPO_ROOT}/tmp/gcc14-wrappers"
if [[ -x "${GCC14_PREFIX}/bin/gcc-14" ]]; then
    rm -rf "${WRAPPERS}"
    mkdir -p "${WRAPPERS}"
    ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/gcc"
    ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/g++"
    ln -sf "${GCC14_PREFIX}/bin/gcc-14" "${WRAPPERS}/cc"
    ln -sf "${GCC14_PREFIX}/bin/g++-14" "${WRAPPERS}/c++"
    # Prepend wrappers BEFORE /bin:/usr/bin so they win against Apple's clang.
    export PATH="${WRAPPERS}:${PATH}"
fi

# CRITICAL: ncurses' configure unsets LANG, which causes gawk to silently emit
# nothing for mk-1st.awk. Setting LANG=C globally + the LANG=C patch in
# 220-ncurses.sh together cover both invocation paths.
export LANG=C
export LC_ALL=C

# NOTE: do NOT put -I${BREW_PREFIX}/opt/binutils/include in CPPFLAGS.
# brew's binutils 2.46+ ships ansidecl.h with PTR macro removed; if it
# shadows binutils-2.38's own libiberty/../include/ansidecl.h, libiberty
# fails to compile (objalloc.c:95: 'PTR' undeclared).
# Same hazard for -L brew binutils lib (might pull in 2.46 .a). Keep ncurses.
export LDFLAGS="-L${BREW_PREFIX}/opt/bison/lib -L${BREW_PREFIX}/opt/ncurses/lib"
export CPPFLAGS="-I${BREW_PREFIX}/opt/ncurses/include"
export PKG_CONFIG_PATH="${BREW_PREFIX}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# Use the project-local ct-ng 1.25 wrapper for all subsequent calls.
ct-ng() { "${CT_NG_BIN}" "$@"; }

CT_VERSION="$(ct-ng version 2>&1 | awk 'NR==1 {print $NF}')"
echo "crosstool-ng version: ${CT_VERSION}"

GCC_PIN="$(awk -F'"' '/^CT_GCC_VERSION=/{print $2}' "${DEFCONFIG}")"
GLIBC_PIN="$(awk -F'"' '/^CT_GLIBC_VERSION=/{print $2}' "${DEFCONFIG}")"
echo "  defconfig pins GCC ${GCC_PIN} + glibc ${GLIBC_PIN}"

# Set up work directory. Must be on case-sensitive FS (Linux + glibc source
# have files differing only by case). Default macOS APFS is case-insensitive,
# so create a sparseimage and remap onto it.
mkdir -p "${WORK_DIR}"
touch "${WORK_DIR}/.cscheck-A" "${WORK_DIR}/.cscheck-a"
CS_COUNT=$(find "${WORK_DIR}" -maxdepth 1 -name '.cscheck-*' | wc -l | tr -d ' ')
rm -f "${WORK_DIR}/.cscheck-A" "${WORK_DIR}/.cscheck-a"

PREFIX_BASE="${HOME}/x-tools"
if [[ "${CS_COUNT}" -lt 2 ]]; then
    VOLNAME="$(basename "${WORK_DIR}")"
    SPARSE="${WORK_DIR%/*}/${VOLNAME}.sparseimage"
    MOUNT_POINT="/Volumes/${VOLNAME}"

    echo "WORK_DIR is on case-INsensitive FS; setting up case-sensitive sparseimage..."
    if [[ ! -f "${SPARSE}" ]]; then
        # 'Case-sensitive Journaled HFS+' (matches messense's working CI).
        # APFS variants suspected to interact badly with ncurses' parallel build.
        hdiutil create -type SPARSE -size 30g -fs "Case-sensitive Journaled HFS+" \
            -volname "${VOLNAME}" "${SPARSE%.sparseimage}" >/dev/null
    fi

    if ! mount | grep -q " on ${MOUNT_POINT} "; then
        hdiutil attach "${SPARSE}" >/dev/null
    fi

    rmdir "${WORK_DIR}" 2>/dev/null || true
    WORK_DIR="${MOUNT_POINT}/build"
    PREFIX_BASE="${MOUNT_POINT}/x-tools"
    mkdir -p "${WORK_DIR}" "${PREFIX_BASE}"

    echo "  → WORK_DIR remapped to: ${WORK_DIR}"
    echo "  → install prefix base:  ${PREFIX_BASE}"
    echo "  → sparseimage:          ${SPARSE}"
    echo "  → unmount when done:    hdiutil detach ${MOUNT_POINT}"
fi

cd "${WORK_DIR}"
DEFCONFIG="${DEFCONFIG}" ct-ng defconfig

# Override CT_PREFIX_DIR to live on the case-sensitive volume (if any).
# Use \${CT_TARGET} literal so ct-ng evaluates it at build time.
awk -v new="CT_PREFIX_DIR=\"${PREFIX_BASE}/\${CT_TARGET}\"" \
    '/^CT_PREFIX_DIR=/{print new; next} 1' .config > .config.new \
    && mv .config.new .config

echo "===================="
echo "ct-ng build starting in ${WORK_DIR}"
echo "Expect ~30 min on M1/M2 Mac."
echo "Build log: ${WORK_DIR}/build.log"
echo "===================="

# Always extract logs (success OR failure) into repo's tmp/ so they're
# accessible without re-mounting the sparseimage.
LOG_OUTDIR="${REPO_ROOT}/tmp/last-build-logs-1.25"
extract_logs() {
    local rc=$?
    rm -rf "${LOG_OUTDIR}"
    mkdir -p "${LOG_OUTDIR}"
    [[ -f "${WORK_DIR}/build.log" ]] && cp "${WORK_DIR}/build.log" "${LOG_OUTDIR}/build.log" 2>/dev/null
    [[ -f "${WORK_DIR}/.config" ]] && cp "${WORK_DIR}/.config" "${LOG_OUTDIR}/.config" 2>/dev/null
    find "${WORK_DIR}/.build" -name "config.log" 2>/dev/null | while read -r cfg; do
        rel="${cfg#${WORK_DIR}/.build/}"
        dest="${LOG_OUTDIR}/${rel}"
        mkdir -p "$(dirname "${dest}")"
        cp "${cfg}" "${dest}"
    done
    echo
    echo "logs copied to ${LOG_OUTDIR}/ (accessible without re-mounting sparseimage)"
    return $rc
}
trap extract_logs EXIT

ct-ng build

# Verify result. Target tuple is x86_64-centos6-linux-gnu (vendor="centos6").
PREFIX="${PREFIX_BASE}/x86_64-centos6-linux-gnu"
GCC_BIN="${PREFIX}/bin/x86_64-centos6-linux-gnu-gcc"

if [[ ! -x "${GCC_BIN}" ]]; then
    echo "ERROR: build finished but ${GCC_BIN} not found." >&2
    exit 1
fi

echo
echo "✓ Toolchain installed at: ${PREFIX}"
"${GCC_BIN}" --version | head -1
echo "  sysroot: $("${GCC_BIN}" -print-sysroot)"

LIBC_PATH="${PREFIX}/x86_64-centos6-linux-gnu/sysroot/lib/libc.so.6"
if [[ -f "${LIBC_PATH}" ]]; then
    echo
    echo "  glibc symbol versions in sysroot libc (top 3):"
    "${PREFIX}/bin/x86_64-centos6-linux-gnu-objdump" -T "${LIBC_PATH}" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -3 | sed 's/^/    /'
fi

echo
echo "Use in your build:"
echo "  export PATH=${PREFIX}/bin:\$PATH"
echo "  CC=x86_64-centos6-linux-gnu-gcc CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \\"
echo "    go build ./cmd/sensor"
