#!/bin/bash
# Tear down a dataset mount created by mount_dataset.sh: stop the
# container (which unmounts s3fs cleanly), defensively unmount any
# leftover FUSE mount, and remove the host mount point.
#
# See README.md for the full reference.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./unmount_dataset.sh <MOUNT_POINT>

Cleans up a dataset mount:
  - Stops the s3fs container associated with <MOUNT_POINT>.
  - Best-effort fusermount -u on <MOUNT_POINT>/.s3.
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

NAME_HASH="$(printf '%s' "$MOUNT_POINT" | sha1sum | cut -c1-12)"
CONTAINER_NAME="dv-mount-$NAME_HASH"

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "stopped $CONTAINER_NAME"
fi

# The container's clean shutdown drops the FUSE mount, but if it died
# abnormally a stale mount entry can be left behind.
if command -v fusermount >/dev/null 2>&1; then
  fusermount -uz "$MOUNT_POINT/.s3" >/dev/null 2>&1 || true
fi

rm -rf "$MOUNT_POINT/files"
rmdir "$MOUNT_POINT/.s3" 2>/dev/null || rm -rf "$MOUNT_POINT/.s3"

if rmdir "$MOUNT_POINT" 2>/dev/null; then
  echo "removed $MOUNT_POINT"
else
  echo "note: $MOUNT_POINT not empty after cleanup; left in place"
fi
