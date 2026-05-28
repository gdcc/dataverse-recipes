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

```text
           ┌──────────────────────────┐
           │   docker container       │
           │  ┌────────────────────┐  │     Dataverse  ──► presigned S3 URL
 ./data ◄──┼──┤ FUSE mount         │  │           ▲
  (host)   │  │ rclone backend     │──┼───────────┘
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
files even while the container is happily serving them. Two
workarounds: (a) browse via `docker exec -it dv-mount ls /mnt/dataset`,
or (b) use the Globus mode and pull the dataset to a Globus endpoint
running natively on your Mac.

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
- **Presigned-URL expiry mid-stream** (long single-file transfer
  through a 1-hour AWS URL TTL). The rclone backend detects this,
  fetches a fresh URL, and re-issues with `Range: bytes=N-` —
  invisibly to the caller.
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
  that adds the Dataverse backend (read-only, presigned-URL caching,
  tabular-ingest handling, mid-stream resume on long transfers) and
  compiles the `rclone` binary.
- Stage 2 (`debian:bookworm-slim`): FUSE3, `tini`, `ca-certificates`,
  and — when built with `--build-arg INCLUDE_GLOBUS=1` (which
  `mount-globus.sh` does automatically) — Globus Connect Personal.

The rclone fork lives at
[ErykKul/rclone, branch `dataverse-backend`](https://github.com/ErykKul/rclone/tree/dataverse-backend/backend/dataverse).
When the backend is upstreamed (proposal in flight at
[rclone/rclone](https://github.com/rclone/rclone)) the Dockerfile's
build args will point at upstream and this note goes away.

## Building from source manually

The scripts auto-build on first run. To build by hand:

```bash
docker build -t dataverse-mount:local .                                      # mount-only
docker build --build-arg INCLUDE_GLOBUS=1 -t dataverse-mount:local-globus .  # + Globus
```

Build against a different rclone fork or branch (e.g. for testing
backend changes):

```bash
docker build \
  --build-arg RCLONE_REPO=https://github.com/your-fork/rclone.git \
  --build-arg RCLONE_REF=your-branch \
  -t dataverse-mount:local .
```

## License

The recipe itself follows the
[dataverse-recipes top-level LICENSE](../../LICENSE).

The image bundles:

- rclone (MIT) at the pinned ref.
- *(only when built with `INCLUDE_GLOBUS=1`)* Globus Connect Personal,
  downloaded at build time from https://downloads.globus.org. GCP is
  distributed under Globus's own license. See
  https://www.globus.org/legal/license.
