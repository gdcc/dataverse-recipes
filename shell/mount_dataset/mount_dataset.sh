#!/bin/bash
# Mount a Dataverse dataset's files onto the local filesystem with the
# dataset's folder structure and human-readable file names preserved.
#
# Architecture:
#   - A Docker container runs s3fs to read the dataset's underlying S3
#     bucket (read-only) and builds friendly-name symlinks on top.
#   - The container's mount point is bind-mounted from the host with
#     `:rshared` propagation, so the s3fs FUSE mount and the symlinks
#     are visible directly on the host filesystem.
#   - The container runs s3fs in the foreground; stopping the container
#     unmounts s3fs cleanly.
#
# Host requirements: docker, curl, bash. The s3fs / python3 / tini
# dependencies live inside the container image.
#
# See README.md for the full reference, including OS-specific notes.

set -euo pipefail

# Optional: load environment variables from a .env file next to this script.
SCRIPT_DIR_INIT="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR_INIT/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_INIT/.env"
fi

usage() {
  cat <<'EOF'
Usage: DV_URL=... DV_PID=... S3_ENDPOINT=... S3_ACCESS_KEY=... S3_SECRET_KEY=... \
       ./mount_dataset.sh

Required environment:
  DV_URL          Dataverse base URL, e.g. https://demo.dataverse.org
  DV_PID          Dataset persistent ID, e.g. doi:10.5072/FK2/XXXXX
  S3_ENDPOINT     S3 endpoint URL, e.g. https://s3.example.com
  S3_ACCESS_KEY   S3 access key ID
  S3_SECRET_KEY   S3 secret access key

Optional:
  DV_TOKEN        Dataverse API key. Omit for public-only access; provide to
                  reach anything the key can read (drafts, restricted, etc.).
  DV_VERSION      Dataset version (default: :latest). E.g. :draft, 1.0.
  S3_BUCKET       S3 bucket name (default: dataverse).
  USE_PATH_STYLE  1 = path-style S3 addressing (default), 0 = virtual-host.
  MOUNT_POINT     Host path to mount the dataset into
                  (default: ./mount-<identifier>).

On success, prints the path to the friendly tree on the host. Run
  ./unmount_dataset.sh <MOUNT_POINT>
to release the mount.
EOF
}

if [[ "${1-}" == "-h" ]] || [[ "${1-}" == "--help" ]]; then
  usage
  exit 0
fi

: "${DV_URL:?DV_URL not set; see ./mount_dataset.sh --help}"
: "${DV_PID:?DV_PID not set; see ./mount_dataset.sh --help}"
: "${S3_ENDPOINT:?S3_ENDPOINT not set; see ./mount_dataset.sh --help}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY not set; see ./mount_dataset.sh --help}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY not set; see ./mount_dataset.sh --help}"

S3_BUCKET="${S3_BUCKET:-dataverse}"
DV_VERSION="${DV_VERSION:-:latest}"
USE_PATH_STYLE="${USE_PATH_STYLE:-1}"
DV_TOKEN="${DV_TOKEN:-}"

for tool in docker curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required on PATH" >&2
    exit 1
  fi
done

# Derive the dataset identifier (everything after the first ':' in the PID).
IDENTIFIER="${DV_PID#*:}"
if [[ "$IDENTIFIER" == "$DV_PID" ]]; then
  echo "error: DV_PID must be protocol-prefixed (e.g. doi:10.5072/FK2/XXXXX)" >&2
  exit 1
fi

# Default mount point if not set; make absolute either way (docker -v needs it).
DEFAULT_MOUNT="./mount-$(echo "$IDENTIFIER" | tr '/' '_')"
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT}"
if [[ "$MOUNT_POINT" != /* ]]; then
  MOUNT_POINT="$(pwd)/$MOUNT_POINT"
fi

if [[ -e "$MOUNT_POINT" ]]; then
  echo "error: mount point already exists: $MOUNT_POINT" >&2
  echo "       run ./unmount_dataset.sh '$MOUNT_POINT' first, or pick another MOUNT_POINT" >&2
  exit 1
fi

mkdir -p "$MOUNT_POINT"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="rdm-dataset-mount:local"
IMAGE_CTX="$SCRIPT_DIR/dataset-mount"

# Build the image on first run.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE (first run only)..."
  docker build -t "$IMAGE" "$IMAGE_CTX"
fi

# Fetch the file manifest before starting the container.
CURL_AUTH=()
if [[ -n "$DV_TOKEN" ]]; then
  CURL_AUTH=(-H "X-Dataverse-key: $DV_TOKEN")
fi

LIST_URL="${DV_URL%/}/api/datasets/:persistentId/versions/${DV_VERSION}/files?persistentId=${DV_PID}"
MANIFEST_TMP="$(mktemp)"
cleanup_manifest() { rm -f "$MANIFEST_TMP"; }
trap cleanup_manifest EXIT

if ! curl -sfL "${CURL_AUTH[@]}" "$LIST_URL" -o "$MANIFEST_TMP"; then
  echo "error: failed to fetch file list from $LIST_URL" >&2
  echo "       (verify DV_URL, DV_PID, DV_VERSION; supply DV_TOKEN for non-public datasets)" >&2
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  exit 1
fi

S3FS_ARGS_VAL="ro"
if [[ "$USE_PATH_STYLE" == "1" ]]; then
  S3FS_ARGS_VAL="use_path_request_style,$S3FS_ARGS_VAL"
fi

NAME_HASH="$(printf '%s' "$MOUNT_POINT" | sha1sum | cut -c1-12)"
CONTAINER_NAME="dv-mount-$NAME_HASH"

if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "error: a container named '$CONTAINER_NAME' already exists." >&2
  echo "       run ./unmount_dataset.sh '$MOUNT_POINT' first." >&2
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  exit 1
fi

# Run the container detached. `:rshared` on the bind mount is the bit that
# makes the in-container s3fs FUSE mount visible on the host filesystem.
docker run -d --rm \
  --name "$CONTAINER_NAME" \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  -v "$MOUNT_POINT:/mount:rshared" \
  -v "$MANIFEST_TMP:/manifest.json:ro" \
  --env "AWS_S3_BUCKET=$S3_BUCKET" \
  --env "AWS_S3_ACCESS_KEY_ID=$S3_ACCESS_KEY" \
  --env "AWS_S3_SECRET_ACCESS_KEY=$S3_SECRET_KEY" \
  --env "AWS_S3_URL=$S3_ENDPOINT" \
  --env "S3FS_ARGS=$S3FS_ARGS_VAL" \
  --env "DATASET_IDENTIFIER=$IDENTIFIER" \
  --env "FILE_MANIFEST=/manifest.json" \
  --env "HOST_UID=$(id -u)" \
  --env "HOST_GID=$(id -g)" \
  "$IMAGE" >/dev/null

# On Linux/WSL2 wait for the FUSE mount to propagate through to the host.
# On macOS it never will (Docker Desktop host↔VM file sharing doesn't
# carry in-container FUSE mounts), so don't waste 30s waiting.
IS_MACOS=0
if [[ "$(uname)" == "Darwin" ]]; then
  IS_MACOS=1
fi

READY=0
if [[ "$IS_MACOS" == "0" ]]; then
  TIMEOUT=30
  for ((i=1; i<=TIMEOUT; i++)); do
    if [[ -d "$MOUNT_POINT/.s3/$IDENTIFIER" ]]; then
      READY=1
      break
    fi
    sleep 1
  done
fi

if [[ "$READY" == "1" ]]; then
  cat <<EOF

Dataset mounted at: $MOUNT_POINT/files
  s3 bucket at:     $MOUNT_POINT/.s3
  container:        $CONTAINER_NAME

Tear down with:
  ./unmount_dataset.sh '$MOUNT_POINT'
EOF
elif [[ "$IS_MACOS" == "1" ]]; then
  cat <<EOF

Friendly symlink tree at: $MOUNT_POINT/files
  container:              $CONTAINER_NAME

Note: on macOS the symlink tree above is visible, but its targets
(under $MOUNT_POINT/.s3/) are not — Docker Desktop's host↔VM file
sharing does not propagate in-container FUSE mounts. File reads will
fail. See README.md ("What you need to install" → "macOS") for the
alternatives.

Tear down with:
  ./unmount_dataset.sh '$MOUNT_POINT'
EOF
else
  echo "error: s3fs mount not ready after ${TIMEOUT}s — container logs follow:" >&2
  docker logs "$CONTAINER_NAME" >&2 2>/dev/null || true
  echo "       clean up with: ./unmount_dataset.sh '$MOUNT_POINT'" >&2
  exit 1
fi
