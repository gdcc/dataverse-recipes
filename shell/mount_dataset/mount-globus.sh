#!/bin/bash
# mount-globus.sh — same as mount.sh but also brings up a personal
# Globus endpoint on top of the FUSE mount.
#
# First run does a one-time Globus device-code login. Endpoint
# credentials live in ./globus-state/ on the host (gitignored). To
# fully wipe and re-register, use ./reset.sh.
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
source "./lib.sh"

require_docker

IMAGE_TAG="${IMAGE_TAG:-dataverse-mount:local-globus}"
CONTAINER_NAME="${CONTAINER_NAME:-dv-mount-globus}"
DATA_DIR="${DATA_DIR:-./data}"
ENV_FILE="${ENV_FILE:-.env}"
GCP_STATE_DIR="${GCP_STATE_DIR:-./globus-state}"

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
  echo "Image $IMAGE_TAG not found, building with Globus included (5–10 minutes)…"
  docker build --build-arg INCLUDE_GLOBUS=1 -t "$IMAGE_TAG" .
}

ensure_data_dir() {
  mkdir -p "$DATA_DIR"
}

ensure_globus_state() {
  mkdir -p "$GCP_STATE_DIR"
  local abs_state
  abs_state="$(abspath "$GCP_STATE_DIR")"

  # `lta/gridmap` is the marker that GCP -setup has been completed
  # successfully against this state directory.
  if [[ -f "$abs_state/lta/gridmap" ]]; then
    return
  fi

  echo
  echo "No Globus endpoint registered yet — let's set one up."
  prompt GLOBUS_ENDPOINT_NAME "Endpoint name (shows in Globus UI)" \
    "dataverse-mount-$(hostname)"

  echo
  echo "Running globusconnectpersonal -setup. Follow the prompts:"
  echo "  - It'll print a https://auth.globus.org/v2/oauth2/device URL + code"
  echo "  - Open the URL in your browser, log into Globus, paste the code"
  echo

  local setup_tty=(-i)
  if [[ -t 0 && -t 1 ]]; then setup_tty+=(-t); fi
  docker run --rm "${setup_tty[@]}" \
    --mount type=bind,source="$abs_state",target=/home/dvgr/.globusonline \
    -e "GLOBUS_ENDPOINT_NAME=$GLOBUS_ENDPOINT_NAME" \
    "$IMAGE_TAG" globus-setup

  echo
  echo "Endpoint registered. State saved at $abs_state."
}

stop_stale() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

ensure_env
ensure_image
ensure_data_dir
ensure_globus_state
stop_stale

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

ADD_HOST_FLAGS=()
# See mount.sh for why this regex matches any loopback form.
if [[ "$DV_HOST" =~ ^https?://(localhost|127\.[0-9]+\.[0-9]+\.[0-9]+)(:[0-9]+)?(/|$) ]]; then
  ADD_HOST_FLAGS+=(--add-host minio.localhost:127.0.0.1 --network host)
fi

ABS_DATA="$(abspath "$DATA_DIR")"
ABS_STATE="$(abspath "$GCP_STATE_DIR")"

echo
echo "Mounting $DATASET_PID from $DV_HOST"
echo "  → $ABS_DATA (also exposed via Globus endpoint at /mnt/dataset)"
echo "  Globus state: $ABS_STATE  (rm -rf to reset; also delete the endpoint"
echo "                              at https://app.globus.org/file-manager/collections)"
echo "  Ctrl-C to stop the endpoint and unmount."
echo

TTY_FLAGS=(-i)
if [[ -t 0 && -t 1 ]]; then TTY_FLAGS+=(-t); fi

exec docker run --rm "${TTY_FLAGS[@]}" --name "$CONTAINER_NAME" \
  "${ADD_HOST_FLAGS[@]}" \
  --cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined \
  --mount type=bind,source="$ABS_DATA",target=/mnt/dataset,bind-propagation=rshared \
  --mount type=bind,source="$ABS_STATE",target=/home/dvgr/.globusonline \
  --env-file "$ENV_FILE" \
  "$IMAGE_TAG" mount-globus
