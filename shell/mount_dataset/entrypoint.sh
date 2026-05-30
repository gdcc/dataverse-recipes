#!/bin/bash
# entrypoint.sh — primary deliverable: mount a Dataverse dataset on
# /mnt/dataset. Globus Connect Personal is an optional layer.
#
# Modes (the first positional argument, default `mount`):
#
#   mount         — mount the dataset and block on rclone. The user
#                   bind-mounts /mnt/dataset to a host path to access
#                   files. No Globus involved. *(default)*
#   mount-globus  — same mount as above, plus start GCP in the
#                   foreground so the dataset is reachable as a
#                   Globus endpoint. Requires that the image was
#                   built with INCLUDE_GLOBUS=1 and that
#                   `globus-setup` has run once before.
#   globus-setup  — one-time GCP endpoint registration using
#                   GLOBUS_SETUP_KEY (obtained from the Globus web UI
#                   at https://app.globus.org/collections/gcp).
#   status        — diagnostic: is the mount live? is GCP running?
#   shell         — drop into a bash shell. For debugging the image.
#
# Required env in `mount`/`mount-globus`: DV_HOST, DATASET_PID.
# Optional env: DV_TOKEN (blank = guest access to public datasets),
# DATASET_VERSION (default :latest), INGEST_FORMAT (default original),
# VFS_CACHE_MODE (default minimal), VFS_CACHE_MAX_AGE (default 1h),
# DIR_CACHE_TIME (default 1000h — the listing is frozen at mount time so
# there is nothing to expire; lower it only when mounting a live draft
# you expect to change under you),
# RCLONE_LOG_LEVEL (default INFO).

set -euo pipefail

MOUNTPOINT="${MOUNTPOINT:-/mnt/dataset}"
GCP_DIR="${GCP_DIR:-/opt/gcp}"
GCP_STATE="${GCP_STATE:-/home/dvgr/.globusonline}"
RCLONE_CONFIG_DIR="${RCLONE_CONFIG_DIR:-/home/dvgr/.config/rclone}"
RCLONE_CONFIG="${RCLONE_CONFIG:-$RCLONE_CONFIG_DIR/rclone.conf}"
RCLONE_LOG_FILE="${RCLONE_LOG_FILE:-/home/dvgr/rclone.log}"

mode="${1:-mount}"
shift || true

log() { printf '[entrypoint] %s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    fail "$var is required for '$mode' mode (set with -e $var=...)"
  fi
}

require_globus_installed() {
  if [[ ! -x "$GCP_DIR/globusconnectpersonal" ]]; then
    fail "Globus Connect Personal is not installed in this image. Rebuild with --build-arg INCLUDE_GLOBUS=1, or use the globus-enabled image tag."
  fi
}

write_rclone_conf() {
  mkdir -p "$RCLONE_CONFIG_DIR"
  umask 077
  cat >"$RCLONE_CONFIG" <<EOF
[dataverse]
type = doi
host = $DV_HOST
token = ${DV_TOKEN:-}
dataset_pid = $DATASET_PID
version = ${DATASET_VERSION:-:latest}
ingest_format = ${INGEST_FORMAT:-original}
EOF
}

# Used by mount-globus. Starts rclone as a *supervised background job*
# (not --daemon) so we keep its PID: the caller waits on it and tears the
# whole stack down if the mount dies. Otherwise GCP would keep serving a
# now-empty directory and a transfer would silently deliver nothing.
RCLONE_PID=""
start_mount_supervised() {
  mkdir -p "$MOUNTPOINT"
  log "starting rclone mount on $MOUNTPOINT (supervised)"
  rclone mount dataverse: "$MOUNTPOINT" \
    --allow-other \
    --allow-non-empty \
    --read-only \
    --vfs-cache-mode "${VFS_CACHE_MODE:-minimal}" \
    --vfs-cache-max-age "${VFS_CACHE_MAX_AGE:-1h}" \
    --dir-cache-time "${DIR_CACHE_TIME:-1000h}" \
    --umask 022 \
    --log-level "${RCLONE_LOG_LEVEL:-INFO}" \
    --log-file "$RCLONE_LOG_FILE" &
  RCLONE_PID=$!

  # rclone serves a beat after launch; poll briefly. 30s is generous; a
  # healthy mount comes up in ~1s. Bail early if rclone exits during
  # startup (bad config/auth) rather than waiting the full window.
  log "waiting for $MOUNTPOINT to become a live mountpoint"
  for _ in $(seq 1 30); do
    if mountpoint -q "$MOUNTPOINT" && ls "$MOUNTPOINT" >/dev/null 2>&1; then
      log "mount is live"
      return 0
    fi
    if ! kill -0 "$RCLONE_PID" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  log "rclone log tail:"
  tail -30 "$RCLONE_LOG_FILE" || true
  kill "$RCLONE_PID" 2>/dev/null || true
  fail "mount did not come up within 30s"
}

unmount_quiet() {
  fusermount3 -uz "$MOUNTPOINT" 2>/dev/null \
    || fusermount  -uz "$MOUNTPOINT" 2>/dev/null \
    || true
}

case "$mode" in
  mount)
    require_env DV_HOST
    require_env DATASET_PID
    # DV_TOKEN is OPTIONAL — empty means guest access for public
    # datasets and public files. The rclone backend skips the
    # X-Dataverse-Key header when the token is empty.

    write_rclone_conf
    mkdir -p "$MOUNTPOINT"

    # Run rclone in the foreground — this is the simplest contract:
    # the container's lifetime IS the mount's lifetime. tini forwards
    # signals so docker stop unmounts cleanly.
    #
    # --allow-non-empty: when the user bind-mounts `/mnt/dataset` to a
    # host directory with `bind-propagation=rshared` (the recommended
    # rclone-in-docker pattern), the bind mount makes `/mnt/dataset`
    # look like an existing mountpoint and rclone's safety check
    # would refuse. The check is for "user pointed at a non-empty
    # local dir by accident"; in our case the dir IS empty, it's just
    # a propagation-mode bind, so it's safe to skip.
    log "mounting Dataverse dataset on $MOUNTPOINT (foreground)"
    exec rclone mount dataverse: "$MOUNTPOINT" \
      --allow-other \
      --allow-non-empty \
      --read-only \
      --vfs-cache-mode "${VFS_CACHE_MODE:-minimal}" \
      --vfs-cache-max-age "${VFS_CACHE_MAX_AGE:-1h}" \
      --dir-cache-time "${DIR_CACHE_TIME:-1000h}" \
      --umask 022 \
      --log-level "${RCLONE_LOG_LEVEL:-INFO}"
    ;;

  mount-globus)
    require_env DV_HOST
    require_env DATASET_PID
    # DV_TOKEN is OPTIONAL (see mount mode above).
    require_globus_installed
    [[ -d "$GCP_STATE" ]] || fail "GCP state not found at $GCP_STATE. Run 'globus-setup' first."
    # GCP v3.x stores credentials under $GCP_STATE/lta/. Older versions
    # put gridmap at the top level. Accept either.
    if [[ ! -f "$GCP_STATE/lta/gridmap" && ! -f "$GCP_STATE/gridmap" ]]; then
      fail "GCP state at $GCP_STATE looks empty (no gridmap). Run 'globus-setup' first."
    fi

    write_rclone_conf
    start_mount_supervised

    log "$MOUNTPOINT top-level:"
    ls -la "$MOUNTPOINT" | head -10 || true

    # Tell GCP exactly which paths to expose. By default it would
    # share the user's $HOME (only rclone.log lives there). We want
    # the dataset, read-only.
    GCP_PATHS="${GCP_RESTRICT_PATHS:-R$MOUNTPOINT}"
    log "starting Globus Connect Personal (restrict-paths=$GCP_PATHS)"
    cd "$GCP_DIR"
    ./globusconnectpersonal -start -restrict-paths "$GCP_PATHS" &
    GCP_PID=$!

    # Supervise BOTH the mount and GCP. cleanup runs once, on EXIT; the
    # signal traps just turn docker stop / Ctrl-C into an exit so that
    # same cleanup fires. It unmounts and stops whichever process is
    # still alive — so neither a GCP crash nor an rclone-mount death can
    # leave the other half running. (A dead mount under a live GCP
    # endpoint would otherwise serve an empty directory and silently
    # deliver nothing — the worst outcome for the long transfers this
    # mode exists for.)
    cleanup() {
      log "shutting down; unmounting $MOUNTPOINT"
      unmount_quiet
      if [[ -n "${GCP_PID:-}" ]]; then
        kill -TERM "$GCP_PID" 2>/dev/null || true
      fi
      if [[ -n "${RCLONE_PID:-}" ]]; then
        kill -TERM "$RCLONE_PID" 2>/dev/null || true
      fi
      wait 2>/dev/null || true
    }
    trap cleanup EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT

    # Block until EITHER process exits; the EXIT trap then tears the
    # survivor down. Exit non-zero so an orchestrator (docker restart
    # policy, compose) treats a mid-session death as the failure it is.
    wait -n "$RCLONE_PID" "$GCP_PID" || true
    log "a supervised process exited; shutting everything down"
    exit 1
    ;;

  globus-setup)
    require_globus_installed
    mkdir -p "$GCP_STATE"
    cd "$GCP_DIR"
    # Two ways to register, both still supported by GCP's `-setup`:
    #   1. Pass `GLOBUS_SETUP_KEY`. Legacy path — Globus's web UI no
    #      longer hands these out, but if you have one from elsewhere
    #      it still works.
    #   2. Pass `GLOBUS_ENDPOINT_NAME` (or accept the default). Modern
    #      path — GCP's device-code OAuth flow prompts you to open a
    #      URL, log into Globus in your browser, paste a verification
    #      code back. Requires `docker run -it` so the prompts reach
    #      your terminal.
    if [[ -n "${GLOBUS_SETUP_KEY:-}" ]]; then
      log "registering with provided GLOBUS_SETUP_KEY"
      ./globusconnectpersonal -setup --setup-key "$GLOBUS_SETUP_KEY"
    else
      name="${GLOBUS_ENDPOINT_NAME:-dataverse-mount-$(hostname)}"
      log "registering new endpoint '$name' (device-code flow — follow the prompts)"
      ./globusconnectpersonal -setup --name "$name"
    fi
    log "GCP setup complete. State persisted at $GCP_STATE."
    ;;

  status)
    if mountpoint -q "$MOUNTPOINT"; then
      log "$MOUNTPOINT: mounted"
    else
      log "$MOUNTPOINT: NOT mounted"
    fi
    if [[ -x "$GCP_DIR/globusconnectpersonal" ]]; then
      if pgrep -f globusconnectpersonal >/dev/null 2>&1; then
        log "GCP: running"
      else
        log "GCP: installed but not running"
      fi
    else
      log "GCP: not installed in this image"
    fi
    ;;

  shell)
    exec bash -i
    ;;

  *)
    fail "unknown mode: $mode (expected: mount | mount-globus | globus-setup | status | shell)"
    ;;
esac
