#!/bin/bash
# reset.sh — wipe local state so the recipe starts from scratch:
#   - .env (Dataverse URL, dataset PID, API token, ingest format)
#   - ./data (the FUSE mountpoint; empty when nothing is mounted)
#   - ./globus-state (Globus Connect Personal credentials)
#   - any legacy named Docker volume from earlier layouts
#
# This handles only the LOCAL half. If you registered a Globus
# endpoint, it stays listed on Globus's side until you also delete
# it via:
#   https://app.globus.org/file-manager/collections
# (pick your collection → menu → Delete). Without that, the dead
# endpoint stays in your Globus account.
#
# Usage:
#   ./reset.sh           # prompts before deleting
#   ./reset.sh -y        # skip the confirmation prompt
set -uo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
source "./lib.sh"

ENV_FILE="${ENV_FILE:-.env}"
DATA_DIR="${DATA_DIR:-./data}"
GCP_STATE_DIR="${GCP_STATE_DIR:-./globus-state}"
LEGACY_VOLUME="${LEGACY_VOLUME:-dataverse-globus-state}"

assume_yes=0
case "${1-}" in
  -y|--yes) assume_yes=1 ;;
esac

abs_path_or_self() {
  if [[ -e "$1" ]]; then abspath "$1"; else echo "$1"; fi
}
abs_env="$(abs_path_or_self "$ENV_FILE")"
abs_data="$(abs_path_or_self "$DATA_DIR")"
abs_state="$(abs_path_or_self "$GCP_STATE_DIR")"

echo "About to reset all local state for this recipe:"
[[ -f "$abs_env"   ]] && echo "  - rm $abs_env"      || echo "  - (no $ENV_FILE present; will skip)"
[[ -d "$abs_data"  ]] && echo "  - rm -rf $abs_data"  || echo "  - (no $DATA_DIR present; will skip)"
[[ -d "$abs_state" ]] && echo "  - rm -rf $abs_state" || echo "  - (no $GCP_STATE_DIR present; will skip)"
if docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1; then
  echo "  - docker volume rm $LEGACY_VOLUME   (old named-volume layout, if any)"
fi
echo
echo "If you registered a Globus endpoint, also delete it on Globus's side:"
echo "  https://app.globus.org/file-manager/collections"
echo "  → pick your collection → menu → Delete"
echo

if [[ $assume_yes -ne 1 ]]; then
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

# Stop running containers first so we don't yank state out from under them.
for name in dv-mount dv-mount-globus; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "Stopping container $name…"
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
done

# Clear any stale FUSE mount before removing the directory.
if [[ -d "$abs_data" ]] && is_mountpoint "$abs_data"; then
  echo "Unmounting stale FUSE mount at $abs_data…"
  fuse_unmount "$abs_data" || true
fi

if [[ -f "$abs_env" ]]; then
  echo "Removing $abs_env…"
  rm -f "$abs_env"
fi

if [[ -d "$abs_data" ]]; then
  echo "Removing $abs_data…"
  rm -rf "$abs_data"
fi

if [[ -d "$abs_state" ]]; then
  # Files inside may be owned by the container's UID (1000). That's
  # fine for rm — we only need write+execute on the parent dir.
  echo "Removing $abs_state…"
  rm -rf "$abs_state"
fi

if docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1; then
  echo "Removing legacy Docker volume $LEGACY_VOLUME…"
  docker volume rm "$LEGACY_VOLUME" >/dev/null || \
    echo "warn: could not remove volume (in use?); rerun later or 'docker volume rm -f'"
fi

cat <<'EOF'

Local state cleared. If you registered a Globus endpoint, finish on
Globus's side:
  1. Visit https://app.globus.org/file-manager/collections
  2. Pick the dataverse-mount-* endpoint
  3. Menu → Delete

Next run of ./mount.sh or ./mount-globus.sh starts from scratch.
EOF
