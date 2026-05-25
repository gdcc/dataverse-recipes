#!/bin/bash
# Tear down a dataset mount created by mount_dataset.sh.
#
# Handles both modes the mount script can produce:
#   - Linux/WSL2 (Docker): stops the s3fs container.
#   - macOS (native): umounts the FUSE mount.
# Both paths end with the host mount point cleaned up.
#
# See README.md for the full reference.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./unmount_dataset.sh <MOUNT_POINT>

Cleans up a dataset mount:
  - Stops the dv-mount-<hash> Docker container if one is running (Linux/WSL2).
  - Best-effort fusermount/umount on <MOUNT_POINT>/.s3 (macOS native).
  - Removes <MOUNT_POINT>/files, <MOUNT_POINT>/.s3, and <MOUNT_POINT>.
EOF
}

if [[ "${1-}" == "-h" ]] || [[ "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${1-}" ]]; then
  usage >&2
  exit 1
fi

MOUNT_POINT="$1"
if [[ "$MOUNT_POINT" != /* ]]; then
  MOUNT_POINT="$(pwd)/$MOUNT_POINT"
fi

if [[ ! -d "$MOUNT_POINT" ]]; then
  echo "error: $MOUNT_POINT is not a directory" >&2
  exit 1
fi

# Linux/WSL2: a Docker container named after the mount point hash may exist.
if command -v docker >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1; then
  NAME_HASH="$(printf '%s' "$MOUNT_POINT" | sha1sum | cut -c1-12)"
  CONTAINER_NAME="dv-mount-$NAME_HASH"
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "stopped $CONTAINER_NAME"
  fi
fi

# Drop any leftover FUSE mount — clean-shutdown of either mode unmounts on
# its own, but a crashed s3fs (or `kill -9`) can leave the entry behind.
case "$(uname)" in
  Darwin)
    if mount | grep -qE " on $MOUNT_POINT/\\.s3 \\(.*\\)\$|on $MOUNT_POINT/\\.s3 "; then
      umount "$MOUNT_POINT/.s3" 2>/dev/null \
        || diskutil unmount force "$MOUNT_POINT/.s3" 2>/dev/null \
        || true
    fi
    ;;
  Linux)
    if command -v fusermount >/dev/null 2>&1; then
      fusermount -uz "$MOUNT_POINT/.s3" >/dev/null 2>&1 || true
    fi
    ;;
esac

rm -rf "$MOUNT_POINT/files"
rmdir "$MOUNT_POINT/.s3" 2>/dev/null || rm -rf "$MOUNT_POINT/.s3"

if rmdir "$MOUNT_POINT" 2>/dev/null; then
  echo "removed $MOUNT_POINT"
else
  echo "note: $MOUNT_POINT not empty after cleanup; left in place"
fi
