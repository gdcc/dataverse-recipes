#!/bin/bash
# lib.sh — portable helpers shared by mount.sh / mount-globus.sh /
# unmount.sh / reset.sh.
#
# Sourced, never executed directly. Functions only; no top-level
# side effects.

# detect_platform prints one of: linux | wsl | darwin | unknown.
# WSL2 reports `Linux` from uname but has "microsoft" in /proc/version.
detect_platform() {
  local u
  u="$(uname -s)"
  case "$u" in
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo wsl
      else
        echo linux
      fi
      ;;
    Darwin) echo darwin ;;
    *) echo unknown ;;
  esac
}

# abspath canonicalises a path to an absolute one without symlink
# resolution. `readlink -f` works on GNU systems but not on macOS's
# BSD readlink; this implementation works on both.
abspath() {
  local p="$1"
  if [[ -z "$p" ]]; then
    echo ""
    return
  fi
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  else
    local dir base
    dir="$(dirname -- "$p")"
    base="$(basename -- "$p")"
    if [[ -d "$dir" ]]; then
      printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
    else
      echo "$p"
    fi
  fi
}

# is_mountpoint returns 0 iff $1 is a current mountpoint. Linux's
# util-linux ships `mountpoint`; macOS doesn't, so we parse `mount`
# output there.
is_mountpoint() {
  local p="$1"
  [[ -d "$p" ]] || return 1
  case "$(detect_platform)" in
    darwin)
      local abs
      abs="$(abspath "$p")"
      mount | awk '{print $3}' | grep -qxF "$abs"
      ;;
    *)
      mountpoint -q "$p" 2>/dev/null
      ;;
  esac
}

# fuse_unmount unmounts a FUSE filesystem at $1 using the
# platform-appropriate tool. No-op if not mounted.
fuse_unmount() {
  local p="$1"
  is_mountpoint "$p" || return 0
  case "$(detect_platform)" in
    darwin)
      umount "$p" 2>/dev/null \
        || diskutil unmount force "$p" >/dev/null 2>&1 \
        || return 1
      ;;
    *)
      fusermount3 -uz "$p" 2>/dev/null \
        || fusermount  -uz "$p" 2>/dev/null \
        || return 1
      ;;
  esac
}

# require_docker errors out early with a clear message if Docker is
# missing or not reachable. Same behaviour across all platforms; on
# macOS the relevant client is Docker Desktop, on Linux it's dockerd.
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not installed" >&2
    case "$(detect_platform)" in
      darwin) echo "  Install Docker Desktop: https://docs.docker.com/desktop/install/mac-install/" >&2 ;;
      wsl)    echo "  Install Docker Desktop with WSL2 backend: https://docs.docker.com/desktop/install/windows-install/" >&2 ;;
      *)      echo "  Install Docker Engine: https://docs.docker.com/engine/install/" >&2 ;;
    esac
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    case "$(detect_platform)" in
      darwin) echo "ERROR: Docker Desktop is installed but not running. Open Docker Desktop and try again." >&2 ;;
      wsl)    echo "ERROR: Docker Desktop is installed but not running. Open Docker Desktop on Windows and try again." >&2 ;;
      *)      echo "ERROR: docker daemon not reachable (is dockerd running? are you in the 'docker' group?)" >&2 ;;
    esac
    exit 1
  fi
}

# warn_mount_visibility prints a one-time warning on platforms where
# the FUSE bind-mount won't be visible on the host (currently macOS:
# Docker Desktop's VM boundary blocks mount propagation back to the
# host filesystem).
warn_mount_visibility() {
  case "$(detect_platform)" in
    darwin)
      cat >&2 <<'EOF'
Heads-up: on macOS, the mount is visible inside the container only —
not on your Mac filesystem. To browse the dataset on Mac:
  docker exec -it dv-mount ls /mnt/dataset
  docker exec -it dv-mount cat /mnt/dataset/path/to/file
For most use cases (large-scale transfers), use mount-globus.sh
instead — Globus moves bytes between your endpoint and any other
Globus destination directly, no host-side bind mount needed.

EOF
      ;;
  esac
}
