#!/usr/bin/env bash
# Phase 1.4 prep step: extract REAL CentOS 6 sysroot from vault RPMs
#
# Why: ct-ng 1.25 + glibc 2.12.1 multilib unified install has many
# arch-specific headers overwritten by i386 versions (Error #19, #25 multilib
# whack-a-mole). Real CentOS 6 production sysroot has Red Hat backports
# (PTRACE_GETREGSET, multi-arch-aware bits/wordsize.h, full sys/reg.h, etc.)
# that vanilla glibc 2.12.1 + kernel 2.6.32 lacks.
#
# 用法 (host macOS):
#   bash scripts/docker/host/prepare-centos6-real-sysroot.sh
#
# 產物:
#   /Volumes/capsule8-xtools/_phase1-real-sysroot/
#       ├── usr/include/        (RHEL 6.10 production headers + RH backports)
#       ├── usr/lib64/          (libgcc, libstdc++, etc.)
#       ├── lib64/              (libc.so.6, libpthread.so.0, ld-linux-x86-64.so.2)
#       └── ...
#
# 後續 build-phase1-gdbserver.sh 用 --sysroot=/opt/x-tools/_phase1-real-sysroot
# 取代 ct-ng 那個有 multilib 缺陷的 sysroot

set -euo pipefail

# ---- CentOS 6.10 RPM URLs ----
# CentOS 6 EOL'd 2020-11-30. Mirror: vault.centos.org, kernel.org archive
readonly VAULT_BASE="https://vault.centos.org/6.10"

# RPMs from base (6.10) — could also use updates/6.10/ for latest minor patches
readonly RPMS=(
    # glibc 家族 (2.12 with full RH backports for el6 → 1.212.el6)
    "os/x86_64/Packages/glibc-2.12-1.212.el6.x86_64.rpm"
    "os/x86_64/Packages/glibc-common-2.12-1.212.el6.x86_64.rpm"
    "os/x86_64/Packages/glibc-headers-2.12-1.212.el6.x86_64.rpm"
    "os/x86_64/Packages/glibc-devel-2.12-1.212.el6.x86_64.rpm"
    "os/x86_64/Packages/glibc-static-2.12-1.212.el6.x86_64.rpm"

    # Linux kernel headers (2.6.32 with RH backports → 754.el6)
    "os/x86_64/Packages/kernel-headers-2.6.32-754.el6.x86_64.rpm"

    # libgcc + libstdc++ (gcc 4.4.7 era — 過時但 ABI 不會撞 GCC 15 cross 編出的 binary)
    "os/x86_64/Packages/libgcc-4.4.7-23.el6.x86_64.rpm"
    "os/x86_64/Packages/libstdc++-4.4.7-23.el6.x86_64.rpm"
    "os/x86_64/Packages/libstdc++-devel-4.4.7-23.el6.x86_64.rpm"
)

# ---- Paths (macOS host) ----
readonly SPARSE_MNT=/Volumes/capsule8-xtools
readonly SYSROOT_OUT="${SPARSE_MNT}/_phase1-real-sysroot"
readonly RPM_CACHE="${SPARSE_MNT}/_phase1-rpm-cache"

default_docker_platform() {
    case "$(uname -m)" in
        x86_64|amd64) echo linux/amd64 ;;
        arm64|aarch64) echo linux/arm64 ;;
        *) echo "" ;;
    esac
}

readonly DOCKER_PLATFORM="${DOCKER_PLATFORM:-$(default_docker_platform)}"
DOCKER_PLATFORM_ARGS=()
if [[ -n "${DOCKER_PLATFORM}" ]]; then
    DOCKER_PLATFORM_ARGS=(--platform="${DOCKER_PLATFORM}")
fi

# ---- Sanity ----
if [[ ! -d "${SPARSE_MNT}" ]]; then
    echo "ERROR: ${SPARSE_MNT} 沒 mount。先跑 host-cs-volume.sh 開 sparseimage" >&2
    exit 1
fi

mkdir -p "${RPM_CACHE}" "${SYSROOT_OUT}"

# ---- Step 1: download RPMs to cache ----
echo "=== Step 1: download RPMs ==="
for path in "${RPMS[@]}"; do
    fname="$(basename "${path}")"
    if [[ ! -f "${RPM_CACHE}/${fname}" ]]; then
        echo "  downloading ${fname}..."
        curl -fSL --retry 3 -o "${RPM_CACHE}/${fname}" "${VAULT_BASE}/${path}"
    else
        echo "  cached: ${fname}"
    fi
done

ls -lh "${RPM_CACHE}/"*.rpm

# ---- Step 2: extract RPMs ----
# macOS 預設沒 rpm2cpio + cpio，跑一個 ubuntu container 處理
echo
echo "=== Step 2: extract RPMs into ${SYSROOT_OUT} ==="
docker run --rm \
    "${DOCKER_PLATFORM_ARGS[@]}" \
    -v "${RPM_CACHE}:/rpms:ro" \
    -v "${SYSROOT_OUT}:/sysroot" \
    ubuntu:24.04 \
    bash -euxc '
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y --no-install-recommends rpm2cpio cpio file >/dev/null
        cd /sysroot
        for r in /rpms/*.rpm; do
            rpm2cpio "$r" | cpio -idmv 2>/dev/null
        done

        echo
        echo "--- 修正 absolute symlinks (target=/lib64/x → relative) ---"
        find /sysroot -type l -lname "/*" | while read l; do
            target=$(readlink "$l")
            new_target=$(echo "$target" | sed "s|^/|../|")
            ln -sf "$new_target" "$l"
        done

        echo
        echo "--- 驗證關鍵 header ---"
        echo "  PTRACE_GETREGSET 在 sys/ptrace.h:"
        grep -c PTRACE_GETREGSET /sysroot/usr/include/sys/ptrace.h || echo "  MISSING!"
        echo "  ORIG_RAX 在 sys/reg.h:"
        grep -c ORIG_RAX /sysroot/usr/include/sys/reg.h || echo "  MISSING!"
        echo "  __WORDSIZE 在 bits/wordsize.h:"
        grep "__WORDSIZE" /sysroot/usr/include/bits/wordsize.h | head -3
        echo "  libc.so.6 in lib64:"
        ls -la /sysroot/lib64/libc.so.6 2>&1 | head -1

        echo
        echo "--- 解 RPM 後 sysroot 大小 ---"
        du -sh /sysroot
    '

echo
echo "=== ✓ /Volumes/capsule8-xtools/_phase1-real-sysroot/ 準備好 ==="
echo
echo "Container 內可用路徑: /opt/x-tools/_phase1-real-sysroot/"
echo "下一步: bash scripts/docker/container/build-phase1-gdbserver.sh (用 --sysroot 指這個)"
