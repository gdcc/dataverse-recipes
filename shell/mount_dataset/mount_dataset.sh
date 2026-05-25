#!/bin/bash
# Mount a Dataverse dataset's files onto the local filesystem with the
# dataset's folder structure and human-readable file names preserved.
#
# Two execution modes, picked automatically from `uname`:
#
#   - Linux / WSL2: runs s3fs inside a Docker container that bind-mounts
#     a host directory with `:rshared` propagation. The host's only
#     dependencies are Docker, bash, curl, sha1sum.
#
#   - macOS: runs s3fs natively on the host (Docker Desktop's host↔VM
#     file sharing does not propagate in-container FUSE mounts, so the
#     Docker path can't work). Requires macFUSE, s3fs, python3 — the
#     script checks for them and points at the brew install commands
#     if any are missing.
#
# Both paths produce the same on-disk layout:
#
#   <MOUNT_POINT>/
#   ├── .s3/                    # s3fs mount of the bucket
#   └── files/                  # friendly tree, relative symlinks into .s3/
#
# See README.md for the full reference.

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

# --- Validate inputs --------------------------------------------------------

: "${DV_URL:?DV_URL not set; see ./mount_dataset.sh --help}"
: "${DV_PID:?DV_PID not set; see ./mount_dataset.sh --help}"
: "${S3_ENDPOINT:?S3_ENDPOINT not set; see ./mount_dataset.sh --help}"
: "${S3_ACCESS_KEY:?S3_ACCESS_KEY not set; see ./mount_dataset.sh --help}"
: "${S3_SECRET_KEY:?S3_SECRET_KEY not set; see ./mount_dataset.sh --help}"

S3_BUCKET="${S3_BUCKET:-dataverse}"
DV_VERSION="${DV_VERSION:-:latest}"
USE_PATH_STYLE="${USE_PATH_STYLE:-1}"
DV_TOKEN="${DV_TOKEN:-}"

# --- OS dispatch ------------------------------------------------------------

case "$(uname)" in
  Linux)   OS_KIND=linux ;;
  Darwin)  OS_KIND=macos ;;
  *)       echo "error: unsupported OS: $(uname)" >&2; exit 1 ;;
esac

# Common host tools, both modes.
for tool in curl; do
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

# Default mount point if not set; make absolute either way.
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

# Fetch the file manifest (both modes).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_TMP="$(mktemp)"
cleanup_manifest() { rm -f "$MANIFEST_TMP"; }
trap cleanup_manifest EXIT

CURL_AUTH=()
if [[ -n "$DV_TOKEN" ]]; then
  CURL_AUTH=(-H "X-Dataverse-key: $DV_TOKEN")
fi

LIST_URL="${DV_URL%/}/api/datasets/:persistentId/versions/${DV_VERSION}/files?persistentId=${DV_PID}"

if ! curl -sfL "${CURL_AUTH[@]}" "$LIST_URL" -o "$MANIFEST_TMP"; then
  echo "error: failed to fetch file list from $LIST_URL" >&2
  echo "       (verify DV_URL, DV_PID, DV_VERSION; supply DV_TOKEN for non-public datasets)" >&2
  exit 1
fi

mkdir -p "$MOUNT_POINT"

S3FS_ARGS_VAL="ro"
if [[ "$USE_PATH_STYLE" == "1" ]]; then
  S3FS_ARGS_VAL="use_path_request_style,$S3FS_ARGS_VAL"
fi

# --- macOS native path ------------------------------------------------------

if [[ "$OS_KIND" == "macos" ]]; then
  missing=()
  command -v s3fs >/dev/null 2>&1 || missing+=("s3fs")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  if [[ ! -d /Library/Filesystems/macfuse.fs ]]; then
    missing+=("macFUSE")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    cat >&2 <<EOF
error: missing prerequisites on macOS: ${missing[*]}

To install:
  brew install --cask macfuse                 # FUSE for macOS
  brew install gromgit/fuse/s3fs-mac          # s3fs built against macFUSE
  brew install python                         # if python3 isn't already present

After installing macFUSE you must approve the system extension in
System Settings → Privacy & Security, then reboot.

Then re-run ./mount_dataset.sh.
EOF
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
  fi

  mkdir -p "$MOUNT_POINT/.s3" "$MOUNT_POINT/files"

  # s3fs reads credentials from a 0600 file referenced by -o passwd_file=.
  CREDS_TMP="$(mktemp)"
  chmod 600 "$CREDS_TMP"
  echo "$S3_ACCESS_KEY:$S3_SECRET_KEY" > "$CREDS_TMP"
  cleanup_native() {
    rm -f "$CREDS_TMP" "$MANIFEST_TMP"
  }
  trap cleanup_native EXIT

  if ! s3fs "$S3_BUCKET" "$MOUNT_POINT/.s3" \
       -o "url=$S3_ENDPOINT,$S3FS_ARGS_VAL,umask=0022,passwd_file=$CREDS_TMP"; then
    echo "error: s3fs mount failed" >&2
    rm -rf "$MOUNT_POINT"
    exit 1
  fi

  python3 "$SCRIPT_DIR/dataset-mount/build_symlinks.py" \
      "$MANIFEST_TMP" "$MOUNT_POINT/.s3" "$MOUNT_POINT/files" "$IDENTIFIER"

  cat <<EOF

Dataset mounted at: $MOUNT_POINT/files
  s3 bucket at:     $MOUNT_POINT/.s3
  mount type:       native s3fs (macOS)

Tear down with:
  ./unmount_dataset.sh '$MOUNT_POINT'
EOF
  exit 0
fi

# --- Linux / WSL2 Docker path ----------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required on PATH (Linux/WSL2 path)" >&2
  echo "       install Docker Engine, or Docker Desktop with WSL2 integration." >&2
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  exit 1
fi

IMAGE="rdm-dataset-mount:local"
IMAGE_CTX="$SCRIPT_DIR/dataset-mount"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE (first run only)..."
  docker build -t "$IMAGE" "$IMAGE_CTX"
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

# Wait for s3fs to mount, signalled by the dataset's identifier directory
# being listable inside the bucket.
TIMEOUT=30
READY=0
for ((i=1; i<=TIMEOUT; i++)); do
  if [[ -d "$MOUNT_POINT/.s3/$IDENTIFIER" ]]; then
    READY=1
    break
  fi
  sleep 1
done

if [[ "$READY" == "1" ]]; then
  cat <<EOF

Dataset mounted at: $MOUNT_POINT/files
  s3 bucket at:     $MOUNT_POINT/.s3
  container:        $CONTAINER_NAME

Tear down with:
  ./unmount_dataset.sh '$MOUNT_POINT'
EOF
else
  echo "error: s3fs mount not ready after ${TIMEOUT}s — container logs follow:" >&2
  docker logs "$CONTAINER_NAME" >&2 2>/dev/null || true
  echo "       clean up with: ./unmount_dataset.sh '$MOUNT_POINT'" >&2
  exit 1
fi
