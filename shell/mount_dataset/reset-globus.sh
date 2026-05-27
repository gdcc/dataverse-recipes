#!/bin/bash
# reset-globus.sh — wipe the local Globus endpoint credentials so the
# next ./mount-globus.sh run registers a fresh endpoint.
#
# This handles only the LOCAL half. The endpoint also has to be
# deleted on Globus's side via:
#   https://app.globus.org/file-manager/collections
# (pick your collection → menu → Delete). Without that, the dead
# endpoint stays listed in your Globus account.
#
# Usage:
#   ./reset-globus.sh           # prompts before deleting
#   ./reset-globus.sh -y        # skip the confirmation prompt
set -uo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
source "./lib.sh"

GCP_STATE_DIR="${GCP_STATE_DIR:-./globus-state}"
LEGACY_VOLUME="${LEGACY_VOLUME:-dataverse-globus-state}"

assume_yes=0
case "${1-}" in
  -y|--yes) assume_yes=1 ;;
esac

if [[ -e "$GCP_STATE_DIR" ]]; then
  abs_state="$(abspath "$GCP_STATE_DIR")"
else
  abs_state="$GCP_STATE_DIR"
fi

# Show what's about to happen.
echo "About to reset the local Globus endpoint state:"
if [[ -d "$abs_state" ]]; then
  echo "  - rm -rf $abs_state"
else
  echo "  - (no $abs_state directory present; will skip)"
fi
if docker volume inspect "$LEGACY_VOLUME" >/dev/null 2>&1; then
  echo "  - docker volume rm $LEGACY_VOLUME   (old named-volume layout, if any)"
fi
echo
echo "AFTER this, also delete the endpoint on Globus's side:"
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

# Stop the running container first so we don't yank state out from
# under it.
for name in dv-mount-globus; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    echo "Stopping container $name…"
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
done

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

Local state cleared. To finish:
  1. Visit https://app.globus.org/file-manager/collections
  2. Pick the dataverse-mount-* endpoint
  3. Menu → Delete

Next run of ./mount-globus.sh will register a fresh endpoint.
EOF
