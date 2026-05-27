#!/bin/bash
# mount.sh — mount a Dataverse dataset on ./data and stay in the
# foreground until Ctrl-C.
#
# If `.env` is missing, prompts for DV_HOST, DATASET_PID, and (optional)
# DV_TOKEN, then saves them so subsequent runs are non-interactive.
#
# Public datasets work without a token. A token is only needed for
# restricted files, draft versions, or owner-only datasets.
#
# Platforms: Linux + WSL2 (full host visibility via bind-mount);
# macOS (mount visible inside the container only — see the
# warn_mount_visibility output below).
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
source "./lib.sh"

require_docker

IMAGE_TAG="${IMAGE_TAG:-dataverse-mount:local}"
CONTAINER_NAME="${CONTAINER_NAME:-dv-mount}"
DATA_DIR="${DATA_DIR:-./data}"
ENV_FILE="${ENV_FILE:-.env}"

prompt() {
  local var="$1" label="$2" default="${3-}"
  local val
  if [[ -n "${default}" ]]; then
    read -r -p "${label} [${default}]: " val
    val="${val:-$default}"
  else
    read -r -p "${label}: " val
  fi
  printf -v "$var" "%s" "$val"
}

prompt_secret() {
  local var="$1" label="$2"
  local val
  read -r -s -p "${label}: " val
  echo
  printf -v "$var" "%s" "$val"
}

ensure_env() {
  if [[ -f "$ENV_FILE" ]]; then
    return
  fi
  cat <<'EOF'
No .env file found — let's create one. Press Enter to accept defaults.
The Dataverse API token is OPTIONAL: leave it blank to access public
datasets and public files as a guest.
EOF
  prompt DV_HOST       "Dataverse base URL"               "https://demo.dataverse.org"
  prompt DATASET_PID   "Dataset persistent ID (DOI)"      "doi:10.70122/FK2/PPIAXE"
  prompt_secret DV_TOKEN "API token (blank for guest access)"
  prompt DATASET_VERSION "Dataset version (e.g. :latest)" ":latest"
  prompt INGEST_FORMAT   "Tabular ingest form (original/archival)" "original"

  umask 077
  cat >"$ENV_FILE" <<EOF
DV_HOST=$DV_HOST
DATASET_PID=$DATASET_PID
DV_TOKEN=$DV_TOKEN
DATASET_VERSION=$DATASET_VERSION
INGEST_FORMAT=$INGEST_FORMAT
EOF
  echo "Saved $ENV_FILE."
}

ensure_image() {
  if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    return
  fi
  echo "Image $IMAGE_TAG not found, building (first time only, takes a few minutes)…"
  docker build -t "$IMAGE_TAG" .
}

ensure_data_dir() {
  mkdir -p "$DATA_DIR"
}

stop_stale() {
  # If a previous run died without removing the container, get rid of it.
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

ensure_env
ensure_image
ensure_data_dir
stop_stale

# Source the .env so we can use the values in the docker run command —
# specifically to forward DV_HOST / DATASET_PID into the container.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ADD_HOST_FLAGS=()
# Convenience for local dev: when the host points at a loopback
# address (localhost / 127.x in any form), the rdm-integration
# Dataverse hands back presigned URLs for `minio.localhost:9000`
# that the container can't resolve. Add a host entry transparently
# and switch to `--network host` so the container reaches the host's
# Dataverse port. (`--network host` is a Linux-only behaviour; on
# macOS Docker Desktop it's silently equivalent to bridge mode.)
if [[ "$DV_HOST" =~ ^https?://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?(/|$) ]]; then
  ADD_HOST_FLAGS+=(--add-host minio.localhost:127.0.0.1 --network host)
fi

ABS_DATA="$(abspath "$DATA_DIR")"

echo
echo "Mounting $DATASET_PID from $DV_HOST"
echo "  → $ABS_DATA (Ctrl-C to unmount)"
echo
warn_mount_visibility

# -t only when there's a real terminal — otherwise docker errors out
# (`stdin is not a terminal`) and prevents non-interactive smoke tests.
TTY_FLAGS=(-i)
if [[ -t 0 && -t 1 ]]; then TTY_FLAGS+=(-t); fi

# bind-propagation=rshared is meaningful only on Linux/WSL2. On macOS
# Docker Desktop the flag is accepted but the propagation never crosses
# the VM boundary, so the mount is container-internal there.
exec docker run --rm "${TTY_FLAGS[@]}" --name "$CONTAINER_NAME" \
  "${ADD_HOST_FLAGS[@]}" \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  --mount type=bind,source="$ABS_DATA",target=/mnt/dataset,bind-propagation=rshared \
  --env-file "$ENV_FILE" \
  "$IMAGE_TAG"
