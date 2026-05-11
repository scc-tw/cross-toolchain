#!/usr/bin/env bash
# Build standalone gdbserver for x86_64-centos6-linux-gnu (Phase 1.4)
#
# Why standalone (not via ct-ng):
#   ct-ng 1.25 編 gdbserver 走 multilib 路徑 (x86_64 + i686 都編)，撞 Phase 1
#   Error #20: gdb/gdbserver/linux-x86-low.cc:216 'RAX' was not declared
#   (-m32 sub-build 撞老 glibc 2.12 ptrace.h vs GDB 16.3 source)
#
#   Survey (5/9 fetch sourceware GDB build docs) 證實：直接從 GDB 16.3 source
#   single-target build (--target=x86_64-... 沒 --enable-targets=all) 不會
#   觸發 -m32 sub-build → 不撞 RAX 衝突。
#
# 怎麼用:
#   docker run --rm --platform=linux/arm64 \
#       -v /Volumes/capsule8-xtools:/opt/x-tools \
#       -v "$PWD/_logs:/build" \
#       -v "$PWD/scripts/docker/container:/scripts:ro" \
#       --entrypoint /scripts/build-phase1-gdbserver.sh \
#       finalfantasyliu/cross-toolbox:phase1
#
# 產物:
#   /opt/x-tools/x86_64-centos6-linux-gnu/x86_64-centos6-linux-gnu/debug-root/usr/bin/gdbserver
#   (跟 Phase 2 同樣 layout — ct-ng 慣例)
#
# 預期時間: ~3-5 min (gdbserver 只是 GDB source 的小子集)

set -euo pipefail

# ---- Constants ----
readonly TARGET=x86_64-centos6-linux-gnu
readonly CROSS_PREFIX=/opt/x-tools/${TARGET}
# 用真 CentOS 6.10 sysroot (從 vault.centos.org 抽 RPM)，不用 ct-ng 那有
# multilib 缺陷的 sysroot。先跑 prepare-centos6-real-sysroot.sh 準備好。
readonly REAL_SYSROOT=/opt/x-tools/_phase1-real-sysroot
readonly GDB_VERSION=16.3
# SHA256 from sourceware (survey 5/9 confirmed)
readonly GDB_SHA256=bcfcd095528a987917acf9fff3f1672181694926cc18d609c99d0042c00224c5
readonly WORK=/tmp/gdbserver-build
readonly SRC="${WORK}/src"
readonly BUILD_DIR="${WORK}/build"
# Install root: ct-ng convention is sysroot-sibling debug-root/
readonly DEBUG_ROOT="${CROSS_PREFIX}/${TARGET}/debug-root"

# ---- Per-run log dir (matches docker-build-target.sh pattern) ----
readonly LOGS=/build
readonly RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$(printf '%04x' $(( RANDOM * RANDOM % 65536 )))"
readonly RUN_LOGS="${LOGS}/run-gdbserver-${RUN_ID}"
mkdir -p "${RUN_LOGS}"
echo "${RUN_ID}" > "${LOGS}/.last-run-id"

copy_logs() {
    local rc=$?
    set +e
    cp -f "${BUILD_DIR}/config.log"   "${RUN_LOGS}/config.log"        2>/dev/null
    cp -f "${WORK}/build.stdout.log"  "${RUN_LOGS}/build.stdout.log"  2>/dev/null
    {
        printf 'run_id=%s task=phase1-gdbserver exit=%s ts=%s\n' \
            "${RUN_ID}" "${rc}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${RUN_LOGS}/run-summary.txt"
    ( cd "${LOGS}" && rm -f latest && ln -sf "run-gdbserver-${RUN_ID}" latest ) 2>/dev/null
    set -e
    return "${rc}"
}
trap copy_logs EXIT

# ---- Sanity checks ----
echo "=== Phase 1.4: standalone gdbserver build for ${TARGET} ==="
if [[ ! -x "${CROSS_PREFIX}/bin/${TARGET}-gcc" ]]; then
    echo "ERROR: cross-gcc not found at ${CROSS_PREFIX}/bin/${TARGET}-gcc" >&2
    echo "請確認 -v /Volumes/capsule8-xtools:/opt/x-tools 有掛上" >&2
    exit 1
fi
"${CROSS_PREFIX}/bin/${TARGET}-gcc" --version | head -1

# ---- Set up cross-build env ----
export PATH="${CROSS_PREFIX}/bin:${PATH}"

# ---- 用真 CentOS 6.10 sysroot 取代 ct-ng 那有缺陷的 ----
# ct-ng 1.25 + glibc 2.12.1 multilib install 在 unified sysroot 下 last-write-wins，
# i386 版本蓋掉 x86_64 版本，導致 GDB 16.3 build 撞一連串雷:
# 1. ORIG_RAX 沒定義 (sys/reg.h 是 i386)
# 2. __WORDSIZE 寫死 32 (bits/wordsize.h 是 i386)
# 3. pthread_mutex_t 大小錯 (bits/pthreadtypes.h 是 i386)
# 4. PTRACE_GETREGSET 沒定義 (kernel headers 沒 RH 的 backport)
# 5. ... 預期還會有更多
#
# 解法: 用 vault.centos.org 抓 RHEL 6.10 production RPMs 抽出真 sysroot
# (先跑 prepare-centos6-real-sysroot.sh 一次性準備)
if [[ ! -d "${REAL_SYSROOT}" || ! -f "${REAL_SYSROOT}/usr/include/stdio.h" ]]; then
    echo "ERROR: ${REAL_SYSROOT} 沒準備好" >&2
    echo "先在 host 跑: bash scripts/docker/host/prepare-centos6-real-sysroot.sh" >&2
    exit 1
fi
echo "=== using real CentOS 6.10 sysroot: ${REAL_SYSROOT} ==="
echo "  glibc.so:"
ls "${REAL_SYSROOT}/lib64/libc-"*.so 2>/dev/null | head -1
echo "  ORIG_RAX in sys/reg.h:"
grep -c ORIG_RAX "${REAL_SYSROOT}/usr/include/sys/reg.h" 2>/dev/null || echo "  MISSING"

# ---- Download GDB 16.3 source ----
mkdir -p "${SRC}"
cd "${SRC}"
if [[ ! -f gdb-${GDB_VERSION}.tar.xz ]]; then
    echo "=== downloading gdb-${GDB_VERSION}.tar.xz ==="
    curl -fSL --retry 3 -o gdb-${GDB_VERSION}.tar.xz \
        "https://sourceware.org/pub/gdb/releases/gdb-${GDB_VERSION}.tar.xz"
fi

echo "=== verifying SHA256 ==="
echo "${GDB_SHA256}  gdb-${GDB_VERSION}.tar.xz" | sha256sum -c -

if [[ ! -d gdb-${GDB_VERSION} ]]; then
    echo "=== extracting ==="
    tar xJf gdb-${GDB_VERSION}.tar.xz
fi

# ---- Configure ----
# Single-target (no --enable-targets=all) → 不觸發 -m32 sub-build → 不撞 RAX
# --disable-* 一堆: gdb/binutils/ld/gas/sim/gprof 都不要，只要 gdbserver
# --without-python/expat/guile: 避免 sysroot 缺 .so
# --with-static-standard-libraries: libstdc++ + libgcc 靜態 link，跨 glibc patch level 安全
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
echo "=== configure (with REAL sysroot ${REAL_SYSROOT}) ==="
# --sysroot=${REAL_SYSROOT} 透過 CFLAGS/CXXFLAGS/LDFLAGS 覆蓋 cross-gcc 內建的 sysroot
# (cross-gcc 內建 sysroot=/opt/x-tools/...../sysroot — 那是有缺陷的 ct-ng 那個)
# rpath-link 確保 link 時找得到 /opt/x-tools/_phase1-real-sysroot/lib64 的 libc 等
SYSROOT_FLAGS="--sysroot=${REAL_SYSROOT}"
LINK_FLAGS="${SYSROOT_FLAGS} -Wl,--rpath-link=${REAL_SYSROOT}/lib64:${REAL_SYSROOT}/usr/lib64"

# glibc 2.12 sys/ptrace.h 的 enum 不含 PTRACE_GETREGSET / PTRACE_SETREGSET
# (kernel 2.6.34+ 加，但 glibc 還沒同步進 enum)。從 linux/ptrace.h 拿 0x4204/0x4205
# 直接 -D 注入。GDB 16.3 source 假設這個常數存在 (legitimate 假設，因為現代 glibc 都有)。
PTRACE_DEFINES="-DPTRACE_GETREGSET=0x4204 -DPTRACE_SETREGSET=0x4205"

CFLAGS="${SYSROOT_FLAGS} ${PTRACE_DEFINES}" \
CXXFLAGS="${SYSROOT_FLAGS} ${PTRACE_DEFINES}" \
LDFLAGS="${LINK_FLAGS}" \
"${SRC}/gdb-${GDB_VERSION}/configure" \
    --host="${TARGET}" \
    --target="${TARGET}" \
    --prefix=/usr \
    --with-sysroot="${REAL_SYSROOT}" \
    --disable-gdb \
    --disable-gdbtk \
    --disable-shared \
    --disable-inprocess-agent \
    --disable-werror \
    --disable-binutils \
    --disable-ld \
    --disable-gas \
    --disable-sim \
    --disable-gprof \
    --disable-gprofng \
    --without-python \
    --without-guile \
    --without-expat \
    --with-static-standard-libraries 2>&1 | tee "${WORK}/build.stdout.log"

# ---- Build ----
echo "=== make all-gdbserver ==="
make -j"$(nproc)" all-gdbserver 2>&1 | tee -a "${WORK}/build.stdout.log"

# ---- Install ----
# ct-ng 習慣 install 到 sysroot 旁的 debug-root/，方便 tar 拷到 target
# DESTDIR 把 /usr/bin → ${DEBUG_ROOT}/usr/bin
echo "=== install to ${DEBUG_ROOT} ==="
# ct-ng PREFIX_DIR_RO 把 parent 設 RO，install 前要先 chmod
chmod -R u+w "${CROSS_PREFIX}/${TARGET}" 2>/dev/null || true
mkdir -p "${DEBUG_ROOT}"
make install-gdbserver DESTDIR="${DEBUG_ROOT}" 2>&1 | tee -a "${WORK}/build.stdout.log"

# Some configure paths use 'usr/local' not 'usr' — normalize.
if [[ -x "${DEBUG_ROOT}/usr/local/bin/gdbserver" && ! -e "${DEBUG_ROOT}/usr/bin/gdbserver" ]]; then
    mkdir -p "${DEBUG_ROOT}/usr/bin"
    mv "${DEBUG_ROOT}/usr/local/bin/gdbserver" "${DEBUG_ROOT}/usr/bin/gdbserver"
fi

# ---- Verify ----
GDBSERVER_BIN="${DEBUG_ROOT}/usr/bin/gdbserver"
if [[ ! -x "${GDBSERVER_BIN}" ]]; then
    echo "FAIL: ${GDBSERVER_BIN} not produced" >&2
    find "${DEBUG_ROOT}" -name "gdbserver*" -type f >&2
    exit 1
fi

echo
echo "=== ✅ gdbserver built ==="
file "${GDBSERVER_BIN}"
ls -l "${GDBSERVER_BIN}"
"${CROSS_PREFIX}/bin/${TARGET}-readelf" -d "${GDBSERVER_BIN}" 2>/dev/null \
    | grep -E "NEEDED|SONAME" | head -10

echo
echo "Phase 1.4 complete. gdbserver located at:"
echo "  ${GDBSERVER_BIN}"
echo
echo "部署到 CentOS 6 機器："
echo "  scp ${GDBSERVER_BIN} target:/usr/bin/gdbserver"
echo "  ssh target gdbserver :1234 ./your-app"
