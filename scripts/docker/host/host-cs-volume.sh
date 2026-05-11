#!/usr/bin/env bash
# Create / attach / detach a case-sensitive HFS+ sparseimage on macOS host.
# Used to give docker container's /opt/x-tools mount a case-sensitive backing,
# which ct-ng requires for installing Linux kernel headers (Kconfig vs kconfig.h
# etc.) and other case-colliding files.
#
# Why HFS+ not APFS: existing macOS-host build.sh path uses "Case-sensitive
# Journaled HFS+" because APFS variants are "suspected to interact badly with
# ncurses' parallel build" (see crosstool_ng_explained.md Mechanism 6
# Finding #B). Even though we're inside a Linux container (where ncurses is
# built on overlay FS, not directly on APFS), the install-step writes through
# to the volume, and HFS+ is the proven combo. Don't introduce new risk.
#
# Usage:
#   bash scripts/docker/host/host-cs-volume.sh attach
#   bash scripts/docker/host/host-cs-volume.sh detach
#   bash scripts/docker/host/host-cs-volume.sh path     # print mount path (for $(...))
#   bash scripts/docker/host/host-cs-volume.sh status   # check if attached
#
# After `attach`, mount point is /Volumes/capsule8-xtools/ (regardless of where
# the sparseimage file lives).
#
# Sparseimage size: starts ~30 MB on disk, grows on demand. We give it a 10 GB
# logical size — toolchain install is ~300-500 MB but multiple targets later.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SPARSE="${REPO_ROOT}/_xtools.sparseimage"   # in repo dir, gitignored
VOLNAME="capsule8-xtools"
MOUNT="/Volumes/${VOLNAME}"
SIZE="10g"

cmd="${1:-help}"

case "${cmd}" in
    attach)
        if [[ ! -f "${SPARSE}" ]]; then
            echo "Creating case-sensitive HFS+ sparseimage at ${SPARSE} (${SIZE} max)..."
            # 'Case-sensitive Journaled HFS+' matches messense's working CI +
            # avoids speculative APFS interaction with ncurses parallel build.
            hdiutil create \
                -size "${SIZE}" \
                -fs "Case-sensitive Journaled HFS+" \
                -type SPARSE \
                -volname "${VOLNAME}" \
                "${SPARSE%.sparseimage}" >/dev/null
        fi

        if mount | grep -q " on ${MOUNT} "; then
            echo "Already attached at ${MOUNT}"
        else
            echo "Attaching ${SPARSE} → ${MOUNT}..."
            hdiutil attach "${SPARSE}" >/dev/null
        fi
        echo "${MOUNT}"
        ;;

    detach)
        if mount | grep -q " on ${MOUNT} "; then
            echo "Detaching ${MOUNT}..."
            hdiutil detach "${MOUNT}"
        else
            echo "Not attached — nothing to detach."
        fi
        ;;

    path)
        # Just print the mount path; do not attach. For use in:
        #   docker run -v "$(host-cs-volume.sh path):/opt/x-tools" ...
        # Caller is responsible for attaching first.
        echo "${MOUNT}"
        ;;

    status)
        if [[ ! -f "${SPARSE}" ]]; then
            echo "sparseimage not created yet at ${SPARSE}"
            exit 1
        fi
        if mount | grep -q " on ${MOUNT} "; then
            echo "✓ attached: ${MOUNT}"
            df -h "${MOUNT}" | tail -1
        else
            echo "✗ not attached. Run: bash $0 attach"
            exit 1
        fi
        ;;

    *)
        cat <<EOF
Usage: $0 {attach|detach|path|status}

  attach   Create sparseimage if missing, attach it. Output: mount path.
  detach   Detach the volume (sparseimage file kept, can re-attach later).
  path     Print mount path without attaching (use after 'attach').
  status   Check whether the volume is currently attached.

Volume is at /Volumes/${VOLNAME}/ when attached.
Sparseimage file lives at ${SPARSE} (gitignored).
EOF
        exit 1
        ;;
esac
