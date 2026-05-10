#!/usr/bin/env bash
# Bootstrap ct-ng 1.25.0 from local release tarball + apply our patches.
# Idempotent: skips work if tmp/ct-ng-1.25/ already has ct-ng.
#
# Why this exists:
#   - brew installs ct-ng 1.28 (latest), but 1.28 dropped glibc 2.12 support
#     (commit 6d5227b, 2022-05). 1.25 is the last release with glibc 2.12.
#   - We download ct-ng-1.25.0 as the official release tarball (NOT GitHub
#     archive .tar.gz) because release tarball ships with a pre-bootstrapped
#     `configure`. GitHub archive requires running `./bootstrap` first which
#     needs bash 4+, but macOS /bin/bash is 3.2 (chicken-and-egg).
#   - Install goes to repo-local tmp/ct-ng-1.25/ to avoid conflict with
#     brew's 1.28 in /opt/homebrew/.
#   - Apply our 4 macOS 26 patches automatically (see toolchain/patches/
#     and the inline modifications below).
#
# Usage:
#   bash toolchain/bootstrap-ctng.sh
#
# After bootstrap, run:
#   bash toolchain/build-1.25.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CT_NG_PREFIX="${REPO_ROOT}/tmp/ct-ng-1.25"
CT_NG_BIN="${CT_NG_PREFIX}/bin/ct-ng"

if [[ -x "${CT_NG_BIN}" ]]; then
    echo "ct-ng 1.25 already installed at ${CT_NG_PREFIX} — skipping bootstrap."
    echo "(rm -rf ${CT_NG_PREFIX} to force re-install)"
    exit 0
fi

echo "=== 1/6  prereq: brew packages ==="
if ! command -v brew >/dev/null 2>&1; then
    echo "ERROR: Homebrew required. Install: https://brew.sh" >&2
    exit 1
fi
for pkg in autoconf automake bash bison gawk gettext gnu-sed gnu-tar help2man libtool make ncurses; do
    if ! brew list --formula "${pkg}" >/dev/null 2>&1; then
        echo "Installing ${pkg}..."
        brew install "${pkg}"
    fi
done

echo
echo "=== 2/6  extract release tarball ==="
TARBALL="${REPO_ROOT}/toolchain/vendor/ct-ng-1.25.0-release.tar.xz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "Tarball missing — downloading from upstream..."
    mkdir -p "${REPO_ROOT}/toolchain/vendor"
    curl -fsSL -o "${TARBALL}" \
        "https://github.com/crosstool-ng/crosstool-ng/releases/download/crosstool-ng-1.25.0/crosstool-ng-1.25.0.tar.xz"
fi
EXTRACT_DIR="${REPO_ROOT}/tmp/ct-ng-build"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar xJf "${TARBALL}" -C "${EXTRACT_DIR}"
SRC_DIR="${EXTRACT_DIR}/crosstool-ng-1.25.0"

echo
echo "=== 3/6  configure + make + make install ==="
BREW_PREFIX="$(brew --prefix)"
export PATH="${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin:${BREW_PREFIX}/opt/gnu-tar/libexec/gnubin:${BREW_PREFIX}/opt/coreutils/libexec/gnubin:${BREW_PREFIX}/opt/findutils/libexec/gnubin:${BREW_PREFIX}/opt/gawk/libexec/gnubin:${BREW_PREFIX}/opt/make/libexec/gnubin:${BREW_PREFIX}/opt/binutils/bin:/usr/bin:/bin:/usr/sbin:/sbin:${BREW_PREFIX}/bin"
export CONFIG_SHELL=/bin/bash
export LANG=C
export LC_ALL=C
export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

cd "${SRC_DIR}"
./configure --prefix="${CT_NG_PREFIX}"
make -j"$(sysctl -n hw.ncpu)"
make install
cd "${REPO_ROOT}"

echo
echo "=== 4/6  apply 4 manual modifications to installed ct-ng ==="
# (a) ct-ng Makefile: bash → brew bash 5 (need bash 4+ for ${var^^} syntax)
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    's|^export bash *= */bin/bash|export bash         = /opt/homebrew/opt/bash/bin/bash|' \
    "${CT_NG_PREFIX}/bin/ct-ng"
echo "  ✓ ct-ng Makefile bash → brew bash 5"

# (b) paths.sh: same bash change
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    's|^export bash="/bin/bash"|export bash="/opt/homebrew/opt/bash/bin/bash"|' \
    "${CT_NG_PREFIX}/share/crosstool-ng/paths.sh"
echo "  ✓ paths.sh bash → brew bash 5"

# (c) zlib mirror: zlib.net withdrew 1.2.12 (CVE), use fossils archive
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    "s|mirrors='http://downloads.sourceforge.net/project/libpng/zlib/\${CT_ZLIB_VERSION} https://www.zlib.net/'|mirrors='https://www.zlib.net/fossils https://www.zlib.net/'|" \
    "${CT_NG_PREFIX}/share/crosstool-ng/packages/zlib/package.desc"
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    "s|default \"http://downloads.sourceforge.net/project/libpng/zlib/\${CT_ZLIB_VERSION} https://www.zlib.net/\"|default \"https://www.zlib.net/fossils https://www.zlib.net/\"|" \
    "${CT_NG_PREFIX}/share/crosstool-ng/config/versions/zlib.in"
echo "  ✓ zlib mirror → fossils archive"

# (d) ncurses: pre-patch configure for LANG=C (fixes gawk silent fail)
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    '/CT_DoLog EXTRA "Configuring ncurses"/a\
    /opt/homebrew/opt/gnu-sed/bin/gsed -i \\\
        -e "s|^\\$as_unset LANG .*|LANG=C; export LANG|" \\\
        -e "s|^\\$as_unset LC_ALL .*|LC_ALL=C; export LC_ALL|" \\\
        "${CT_SRC_DIR}/ncurses/configure"' \
    "${CT_NG_PREFIX}/share/crosstool-ng/scripts/build/companion_libs/220-ncurses.sh"
"${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin/sed" -i \
    's|"${CT_SRC_DIR}/ncurses/configure"                                   \\\\$|LANG=C LC_ALL=C \\\\\n    ${CONFIG_SHELL} \\\\\n    "${CT_SRC_DIR}/ncurses/configure"                                   \\\\|' \
    "${CT_NG_PREFIX}/share/crosstool-ng/scripts/build/companion_libs/220-ncurses.sh" || true
echo "  ✓ 220-ncurses.sh LANG=C patch"

echo
echo "=== 5/6  copy our 2 patches to ct-ng package dirs ==="
cp "${REPO_ROOT}/toolchain/patches/zlib-1.2.12-0002-fix-fdopen-macos.patch" \
   "${CT_NG_PREFIX}/share/crosstool-ng/packages/zlib/1.2.12/0002-fix-fdopen-macos.patch"
cp "${REPO_ROOT}/toolchain/patches/linux-2.6.32.71-0001-fix-unifdef-strlcpy-macos.patch" \
   "${CT_NG_PREFIX}/share/crosstool-ng/packages/linux/2.6.32.71/0001-fix-unifdef-strlcpy-macos.patch"
echo "  ✓ zlib fdopen patch"
echo "  ✓ linux unifdef patch"

echo
echo "=== 6/6  verify ==="
"${CT_NG_BIN}" version | head -3
echo
echo "✅ ct-ng 1.25 ready at ${CT_NG_PREFIX}"
echo "Next: bash toolchain/build-1.25.sh"
