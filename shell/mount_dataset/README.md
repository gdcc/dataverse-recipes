# mount_dataset

Mount any [Dataverse](https://dataverse.org) dataset as a real
filesystem with one command. Optionally publish the mount as a
personal [Globus](https://www.globus.org) endpoint for fast
cross-institution transfers.

## What this does, in plain English

A Dataverse dataset is normally something you download file-by-file
through a website. This recipe lets you **browse it as if it were a
folder on your own computer** — with the original folder structure
and filenames preserved. Open files in your editor, `ls` and `grep`
them, point a script at them, whatever — they behave like real files.
Under the hood the bytes are fetched on-demand from Dataverse, so
there's no upfront download and no disk space needed for the whole
dataset. That's the basic mode (`./mount.sh`).

The second mode (`./mount-globus.sh`) layers a personal Globus
endpoint on top of the same mount. Globus is the standard tool for
moving TBs of research data between institutions — much faster and
more resilient than scp/rsync over long distances. Run this script
and your machine becomes a Globus endpoint serving the dataset
(folder/file names preserved at the destination); point any other
Globus endpoint at it — say your HPC cluster's scratch storage —
and Globus pulls the whole dataset over.

**Almost no setup.** Three pieces of information: the Dataverse URL,
the dataset DOI, and optionally an API token if the files aren't
public. The Globus mode adds one extra one-time browser login (the
script walks you through it) — credentials persist locally so later
runs go straight to "endpoint online."

**Nothing required from anyone else.** No paid Globus subscription,
no Globus Connect Server, no Globus S3 connector, no Dataverse-side
plugin, no operator changes. The traditional "Dataverse + managed
Globus" path needs all of those — usually only realistic for
institutions with dedicated data-engineering staff. This recipe
needs none of them: it talks to any standard Dataverse and runs
Globus Connect Personal under Globus's free tier. Everything happens
inside one Docker container on your own machine.

**Works with any Dataverse storage backend.** The recipe only uses
the standard Native API (`/api/datasets/.../versions/...` and
`/api/access/datafile/{id}`), so it works the same on instances
backed by local filesystem, S3, Swift, or anything else Dataverse
supports. If the instance is on S3 *with* direct-download enabled,
the backend automatically picks up the presigned-URL redirect and
streams bytes straight from S3 (cutting Dataverse out of the data
path); otherwise it streams through Dataverse's access endpoint with
HTTP `Range` requests. Either way, only the bytes you actually read
are fetched.

```text
           ┌──────────────────────────┐
           │   docker container       │     Dataverse API
           │  ┌────────────────────┐  │     (bytes proxied, or
 ./data ◄──┼──┤ FUSE mount         │  │     302 to presigned S3
  (host)   │  │ rclone backend     │──┼──►  when available)
           │  └────────────────────┘  │
           │  ┌────────────────────┐  │
           │  │ (optional)         │  │     Globus Transfer ◄── any
           │  │ Globus Connect     │  │                          Globus
           │  │ Personal           │  │                          client
           │  └────────────────────┘  │
           └──────────────────────────┘
```

## Quickstart

The recipe is one folder in a larger `dataverse-recipes` repository.
A sparse checkout pulls just this directory so you don't fetch the
whole repo:

```bash
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/gdcc/dataverse-recipes.git
cd dataverse-recipes
git sparse-checkout add shell/mount_dataset
cd shell/mount_dataset
./mount.sh
```

On the first run, `mount.sh` prompts for your Dataverse URL, dataset
DOI, and (optionally) an API token, saves them to `.env`, builds the
Docker image, and brings the mount up at `./data` in the foreground.
Ctrl-C unmounts cleanly. Subsequent runs read `.env` and just go.

```bash
# In another terminal, while mount.sh is running:
ls -R ./data
cat ./data/path/to/file.txt
```

## Prerequisites

- Docker (Engine on Linux; Docker Desktop on macOS or WSL2 on
  Windows).
- For the Globus mode: a free Globus account at
  https://app.globus.org.

### Platform notes

| Platform        | Mount mode                                     | Globus mode  |
| ---             | ---                                            | ---          |
| Linux           | ✅ full host visibility via bind-mount         | ✅ full       |
| WSL2 (Windows)  | ✅ same as Linux (clone *inside* WSL for speed) | ✅ full       |
| macOS           | ⚠️ visible inside container only (see below)    | ✅ full       |

On macOS, Docker Desktop runs containers inside a hidden Linux VM.
FUSE works fine inside that VM, but the mount events don't propagate
back to the macOS filesystem — so `./data` on the host won't show
files even while the container is happily serving them. Three
workarounds: (a) browse via `docker exec -it dv-mount ls /mnt/dataset`,
(b) use the Globus mode and pull the dataset to a Globus endpoint
running natively on your Mac, or (c) skip Docker entirely and run
rclone natively — see [Running without Docker](#running-without-docker-native-rclone)
below.

## Four scripts

- **`./mount.sh`** — mount the dataset on `./data` in the foreground.
  Ctrl-C unmounts.
- **`./mount-globus.sh`** — mount + publish as a Globus endpoint. On
  first run, walks you through the Globus device-code login.
- **`./unmount.sh`** — stop whichever container is running and clear
  any stale FUSE mount.
- **`./reset.sh`** — wipe all local state for this recipe (`.env`,
  `./data`, `./globus-state`) so the next run starts from scratch.
  Prints the URL to delete the Globus endpoint on Globus's side too.

## Configuration

All settings live in `.env` (auto-created on first run from prompts;
copy `sample.env` and edit by hand if you prefer).

| Variable           | Required for         | Description |
| ---                | ---                  | --- |
| `DV_HOST`          | always               | Dataverse base URL, no trailing slash. |
| `DATASET_PID`      | always               | Persistent ID, e.g. `doi:10.5072/FK2/ABCD`. |
| `DV_TOKEN`         | optional             | Dataverse API token. Blank → guest access. |
| `DATASET_VERSION`  | optional             | `:latest` (default), `:draft`, `:latest-published`, or `1.0`/`2.0`/…. |
| `INGEST_FORMAT`    | optional             | `original` (default) or `archival`. |
| `VFS_CACHE_MODE`   | optional             | rclone VFS cache mode. Default `minimal`. |
| `VFS_CACHE_MAX_AGE`| optional             | How long cached bytes stay valid. Default `1h`. |
| `RCLONE_LOG_LEVEL` | optional             | `DEBUG`/`INFO`/`NOTICE`/`ERROR`. Default `INFO`. |

## What happens during restarts and interruptions

- **Container restart / host reboot / laptop sleep.** Globus Transfer
  tracks each task server-side. When the endpoint disconnects
  mid-transfer the task pauses and resumes once the endpoint comes
  back. On our side, restarting the script re-fetches the file list,
  re-uses the Globus credentials in `./globus-state/`, and the
  endpoint reconnects automatically.
- **Mid-stream connection breaks.** On a long single-file transfer
  the backend transparently re-issues with `Range: bytes=N-` and
  continues. On S3-direct instances that also covers the case where
  the presigned URL expires mid-stream (typically a 1-hour AWS TTL):
  the backend detects the failure, fetches a fresh URL, and resumes.
  On proxy-mode instances (non-S3 storage, or S3 without
  direct-download) the access URL doesn't expire, so it's just a
  range continuation.
- **Dataset gets a new version while we're running.** The file list
  is frozen at mount time so it can't shift under an in-progress
  transfer. New / removed files only show up after a restart.

## Resetting for a demo or fresh start

`./reset.sh` wipes all local state for this recipe: `.env`, `./data`,
`./globus-state/`, and any legacy named Docker volume.

```bash
./unmount.sh   # stop the container if it's running
./reset.sh     # wipe .env + ./data + ./globus-state/
```

If you also registered a Globus endpoint, the endpoint stays on
Globus's side until you delete it there too: open
https://app.globus.org/file-manager/collections, find the endpoint
(named whatever you typed during setup, default
`dataverse-mount-<hostname>`), menu → **Delete**.

Next `./mount.sh` or `./mount-globus.sh` walks you through the
prompts again from a clean slate.

## Tabular files (CSV, Stata, SPSS, …)

Dataverse "ingests" tabular uploads: it parses the file and stores
both the original bytes and a normalised `.tab` archival form. The
default (`INGEST_FORMAT=original`) exposes the file under its
original name with a verifiable MD5 — what most users want. Set
`INGEST_FORMAT=archival` to expose Dataverse's post-ingest form
instead (no MD5, no reliable size).

## Read-only

The backend is intentionally read-only:

- `Put`, `Update`, `Remove`, `Mkdir`, `Rmdir` all return errors.
- `rclone mount` runs with `--read-only`.

Globus transfers **from** this endpoint to elsewhere work; transfers
**to** this endpoint don't. To upload, use the Dataverse UI or its
Native API directly.

## Under the hood

The Docker image is built locally on first run. It's a multi-stage
build:

- Stage 1 (`golang:1.25`): clones a fork of [rclone](https://rclone.org)
  that adds the Dataverse backend (read-only, works against any
  Dataverse storage driver via the Native API, auto-uses S3 presigned
  redirects when available, tabular-ingest handling, mid-stream
  resume on long transfers) and compiles the `rclone` binary.
- Stage 2 (`debian:bookworm-slim`): FUSE3, `tini`, `ca-certificates`,
  and — when built with `--build-arg INCLUDE_GLOBUS=1` (which
  `mount-globus.sh` does automatically) — Globus Connect Personal.

The rclone fork lives at
[ErykKul/rclone, branch `dataverse-backend`](https://github.com/ErykKul/rclone/tree/dataverse-backend/backend/dataverse).
When the backend is upstreamed (proposal in flight at
[rclone/rclone](https://github.com/rclone/rclone)) the Dockerfile's
build args will point at upstream and this note goes away.

## Building from source manually

By default `./mount.sh` pulls `ghcr.io/erykkul/dataverse-mount:latest` (and `:latest-globus` for the Globus mode). Pulls fall back to a local build if the image isn't reachable. To force a local build instead, point `IMAGE_TAG` somewhere else:

```bash
IMAGE_TAG=dataverse-mount:local ./mount.sh
```

Or to build the image by hand:

```bash
docker build -t dataverse-mount:local .                                      # mount-only
docker build --build-arg INCLUDE_GLOBUS=1 -t dataverse-mount:local-globus .  # + Globus
```

Point the build at a different pre-built rclone binary (e.g. for
testing backend changes from a different fork's release page):

```bash
docker build \
  --build-arg RCLONE_BINARY_URL=https://example.com/path/to/rclone-linux-amd64 \
  -t dataverse-mount:local .
```

Or override `RCLONE_RELEASE_BASE` if you mirror the binaries on a
different host but keep the `rclone-linux-<arch>` naming. To test a
locally-built rclone binary, skip the build args and `-v` mount your
binary at runtime: `docker run -v $PWD/rclone:/usr/local/bin/rclone …`.

## Running without Docker (native rclone)

The Docker-based scripts above are the supported path, but everything
in this recipe also works with rclone installed natively on the host.
Useful especially on macOS to bypass Docker Desktop's FUSE-in-VM
limitation — a native rclone mount surfaces directly on the host
filesystem the way it does on Linux.

**1. Install a FUSE driver:**

| Platform | FUSE driver | Install |
| ---      | ---         | ---     |
| Linux    | kernel FUSE3 | `apt install fuse3` (or distro equivalent) |
| macOS    | [macFUSE](https://osxfuse.github.io) | `brew install --cask macfuse`, then approve the kext in Recovery Mode on Apple Silicon / recent Intel — or skip the kext entirely and use rclone's experimental `nfsmount` (see below) |
| Windows  | [WinFsp](https://winfsp.dev) | Install the latest stable release. Userspace driver, no kernel-approval steps. |

**2. Install rclone with the Dataverse backend.** Until the backend
lands upstream in [`rclone/rclone`](https://github.com/rclone/rclone),
download a pre-built binary from the fork's release page at
<https://github.com/ErykKul/rclone/releases/tag/dataverse-backend-latest>:

```bash
# Pick the file for your platform: rclone-linux-amd64,
# rclone-linux-arm64, rclone-darwin-arm64 (Apple Silicon),
# or rclone-windows-amd64.exe. Intel-Mac users: build from source
# (see "Or `go build`…" note below).
curl -fsSL -o rclone \
  https://github.com/ErykKul/rclone/releases/download/dataverse-backend-latest/rclone-darwin-arm64
chmod +x rclone
./rclone version | head -1                    # smoke test
```

(Or `go build` from `ErykKul/rclone` branch `dataverse-backend` if you
prefer building from source — needs Go 1.25+.) When the backend is
upstreamed, switch to the official packages: `brew install rclone` /
`winget install Rclone.Rclone` / `apt install rclone`.

**3. Configure a remote:**

```bash
./rclone config create dv dataverse \
  host=https://demo.dataverse.org \
  dataset_pid=doi:10.70122/FK2/PPIAXE
# add token=YOUR-TOKEN for restricted/draft datasets
```

**4. Mount:**

```bash
./rclone mount --read-only dv: ~/dv-mount         # Linux / macOS (macFUSE)
./rclone nfsmount --read-only dv: ~/dv-mount      # macOS without macFUSE
.\rclone.exe mount --read-only dv: X:             # Windows (WinFsp)
```

Stop with `Ctrl-C`, or `umount ~/dv-mount` (`fusermount -u` on Linux)
from another terminal.

**Globus on the native path.** Install [Globus Connect
Personal](https://www.globus.org/globus-connect-personal) — native
installers for Linux/macOS/Windows — and point `-restrict-paths` at
the mountpoint (e.g. `-restrict-paths "R$HOME/dv-mount"`). Same free
tier, same UX, no Docker.

## License

The recipe itself follows the
[dataverse-recipes top-level LICENSE](../../LICENSE).

The image bundles:

- rclone (MIT) at the pinned ref.
- *(only when built with `INCLUDE_GLOBUS=1`)* Globus Connect Personal,
  downloaded at build time from https://downloads.globus.org. GCP is
  distributed under Globus's own license. See
  https://www.globus.org/legal/license.
