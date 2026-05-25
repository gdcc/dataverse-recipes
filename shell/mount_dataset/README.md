# Mount a Dataverse Dataset as a Local Filesystem

## Purpose

Expose a Dataverse dataset's files as a read-only directory on the local
filesystem, with the dataset's folder structure and human-readable file
names preserved. Useful for ad-hoc inspection, batch tooling, or any
local-filesystem-shaped pipeline (a Python notebook, a converter, a
checksum sweep) without copying the bytes out of S3.

The implementation runs `s3fs` inside a Docker container that
bind-mounts a directory from the host with `:rshared` propagation, so
the s3fs FUSE mount and the friendly-name symlinks both appear on the
host filesystem — no SMB / WebDAV / NFS layer in front of them.

## Features

- Preserves directory labels and display names from Dataverse —
  `files/raw/data.csv` rather than `42` or `s3://bucket/abc...`.
- Optional Dataverse API key: public datasets work without one; provide
  a key to reach drafts and restricted files the key can read.
- Read-only by design (`s3fs ... ro`).
- Bytes stream from S3 on demand — nothing is copied to local disk.
- The container runs s3fs as the host user, so the symlinks on the host
  are owned by you (no `sudo` needed to browse or remove them).

## Platform support

| Host | Status | Notes |
|---|---|---|
| **Linux** | Supported | Native FUSE — works out of the box. |
| **Windows (WSL2)** | Supported | Run from inside a WSL2 distro; the mount lives at the Linux path you pass for `MOUNT_POINT` and is reachable from Windows Explorer at `\\wsl$\<distro>\<path>`. |
| **macOS** | Limited | The symlinks appear on the macOS host, but the s3fs bytes do not. See "macOS notes" below. |
| **Native Windows** | Not supported | Use WSL2. |

The macOS limitation isn't a bug in this script — it's how Docker
Desktop's host↔VM file sharing works. The s3fs FUSE mount runs inside
the Linux VM that Docker Desktop manages, and the VirtioFS / gRPC FUSE
layer that bridges files between the VM and macOS doesn't propagate
FUSE mounts that originate inside a container. The directory tree
(symlinks) gets through fine; the bytes the symlinks point to do not.

## What you need to install

### Linux

- Docker Engine. The Compose plugin is not required for these scripts.
- `bash`, `curl`, `sha1sum` — present on every standard distro.

That's it. Everything else (`s3fs`, `python3`, `tini`) ships inside the
Docker image that `mount_dataset.sh` builds on first run.

### Windows (WSL2)

- WSL2 with a Linux distribution installed (Ubuntu, Debian, etc.).
- Docker Desktop with the WSL2 integration enabled for that distro,
  *or* Docker Engine installed inside the distro.

Then run the script from inside the WSL2 shell. The mount appears at
the path you pass for `MOUNT_POINT` inside the distro and is reachable
from Windows Explorer via `\\wsl$\<distro>\<path>`.

### macOS

You have three honest options on macOS:

1. **Use the script as-is** — the friendly symlink tree appears on the
   host filesystem (you'll see `files/...` populated immediately), but
   the symlinks resolve to a `.s3/` directory whose contents are not
   propagated up from the container. So `ls files/` works, but
   `cat files/some-file.csv` does not. Useful for inspecting the
   *structure* of a dataset without downloading its bytes.
2. **Run the script inside a Linux VM** (Lima, Colima, OrbStack with a
   Linux machine, etc.) and access the mount from inside that VM. From
   there it behaves like Linux.
3. **Mount the bucket natively** without this script — install
   [macFUSE](https://osxfuse.github.io/) and
   [s3fs-fuse for macOS](https://github.com/awsgeek/s3fs-fuse), then
   mount the bucket directly with the `s3fs` CLI. You lose the
   friendly-name layer (you'll see hash filenames inside the bucket
   path), but you get fully working file reads.

There is no Docker-only path to a fully working macOS mount of an
in-container FUSE filesystem today.

## How it works

1. `mount_dataset.sh` fetches the dataset's file list from
   `GET /api/datasets/:persistentId/versions/<v>/files`. If `DV_TOKEN`
   is set, the request is authenticated with `X-Dataverse-key`;
   without it, only public-dataset access is possible.
2. The script builds the `rdm-dataset-mount:local` image (first run
   only) and starts a container that:
   - Bind-mounts `<MOUNT_POINT>` from the host to `/mount` inside the
     container with `:rshared` propagation.
   - Builds relative symlinks at `/mount/files/<directoryLabel>/<label>`
     pointing into `/mount/.s3/<identifier>/...`.
   - `chown`s the friendly tree and the empty mount points to the host
     user's UID/GID.
   - Runs `s3fs` in the foreground to mount the bucket at `/mount/.s3`.
3. On Linux (and WSL2), the `:rshared` propagation means everything in
   `/mount` inside the container is visible at `<MOUNT_POINT>` on the
   host — including the FUSE mount.

```
<MOUNT_POINT>/
├── .s3/                       # s3fs mount of the bucket (read-only)
│   └── <authority>/<identifier>/<storageIdentifier>
└── files/                     # friendly tree (relative symlinks into .s3/)
    ├── raw/
    │   └── data.csv -> ../../.s3/10.5072/FK2/ABCDEF/abc123-deadbeef
    └── docs/
        └── readme.md -> ../../.s3/10.5072/FK2/ABCDEF/def789-cafebabe
```

The symlinks use relative paths so they resolve from both the
container's view (`/mount/files -> /mount/.s3`) and the host's view
(`<MOUNT_POINT>/files -> <MOUNT_POINT>/.s3`).

Reads of any file under `<MOUNT_POINT>/files/...` are served directly
from S3 on demand — nothing is copied to local disk.

## Inputs

All inputs are environment variables. Set them inline on the command
line, or copy `sample.env` to `.env` next to the script and edit it
(the script sources `.env` automatically if present).

| Variable | Required | Purpose |
|---|---|---|
| `DV_URL` | yes | Dataverse base URL, e.g. `https://demo.dataverse.org`. |
| `DV_PID` | yes | Dataset persistent ID, e.g. `doi:10.5072/FK2/XXXXX`. |
| `S3_ENDPOINT` | yes | S3 endpoint URL. |
| `S3_ACCESS_KEY` | yes | S3 access key ID. |
| `S3_SECRET_KEY` | yes | S3 secret access key. |
| `DV_TOKEN` | no | Dataverse API key. Omit for public-only access. |
| `DV_VERSION` | no | Dataset version, default `:latest`. |
| `S3_BUCKET` | no | S3 bucket name, default `dataverse`. |
| `USE_PATH_STYLE` | no | `1` (default) = path-style S3 addressing, `0` = virtual-host. |
| `MOUNT_POINT` | no | Host path to mount the dataset into, default `./mount-<identifier>`. |

## Examples

### Public dataset, default mount point

```bash
DV_URL=https://demo.dataverse.org \
DV_PID=doi:10.5072/FK2/PUBLIC1 \
S3_ENDPOINT=https://s3.example.com \
S3_ACCESS_KEY=AKIA... \
S3_SECRET_KEY=... \
./mount_dataset.sh
```

Output:

```
linked 12 file(s)

Dataset mounted at: /home/me/mount-10.5072_FK2_PUBLIC1/files
  s3 bucket at:     /home/me/mount-10.5072_FK2_PUBLIC1/.s3
  container:        dv-mount-abc123def456

Tear down with:
  ./unmount_dataset.sh '/home/me/mount-10.5072_FK2_PUBLIC1'
```

### Private dataset, explicit mount point

```bash
DV_URL=https://my.dataverse.example \
DV_TOKEN=11111111-2222-3333-4444-555555555555 \
DV_PID=doi:10.5072/FK2/PRIVATE \
DV_VERSION=:draft \
S3_ENDPOINT=https://s3.example.com \
S3_ACCESS_KEY=... S3_SECRET_KEY=... \
MOUNT_POINT=/tmp/mydataset \
./mount_dataset.sh
```

### Inspecting the mount

```bash
ls /tmp/mydataset/files                       # see the dataset's directory layout
md5sum /tmp/mydataset/files/raw/data.csv
python3 -c "import pandas as pd; print(pd.read_csv('/tmp/mydataset/files/raw/data.csv').head())"
```

### Tear down

```bash
./unmount_dataset.sh /tmp/mydataset
```

## Permissions and access model

- The Dataverse API call honours `DV_TOKEN` (if provided): a file
  appears in the listing only when the token can read it. Without a
  token, only files visible to anonymous users appear.
- The actual byte read of any listed file goes through the s3fs mount
  inside the container, using `S3_ACCESS_KEY` / `S3_SECRET_KEY`. Those
  need read access to the bucket. If a file is listed by the API but
  the S3 credentials can't read its object, `cat <file>` fails with a
  permission error from the s3fs layer; the symlink still exists.
- The mount is read-only.
- The symlinks on the host are owned by you (UID/GID passed through to
  the container). You can browse, read, or delete them without `sudo`.

## Caveats

- **Ingested tabular files.** When Dataverse ingests a `.sav`/`.dta`/
  etc. file, the storage identifier in the API response points to the
  ingested TSV variant, not the original upload. Reading
  `files/foo.sav` therefore serves the converted TSV bytes. Use the
  Dataverse access API with `?format=original` if you need the
  original-format bytes.
- **Latency.** Every byte read is a remote S3 call. Sequential reads
  are fine; random-access patterns over large binary files will be
  slow.
- **First-run build time.** The `rdm-dataset-mount:local` image is
  built from [`dataset-mount/Dockerfile`](dataset-mount/Dockerfile) on
  first invocation (Debian-slim + s3fs + python3, roughly 20 s).
  Subsequent runs use the cached image.
- **Stale containers.** If `mount_dataset.sh` is interrupted before
  printing success, the container may be left running. Find it with
  `docker ps --filter name=dv-mount-` and stop it with
  `./unmount_dataset.sh <MOUNT_POINT>` or `docker stop <name>`.

## Files

- `mount_dataset.sh` — entry point: fetches the dataset's file list,
  builds the image if needed, starts the container, prints the host
  mount paths.
- `unmount_dataset.sh` — stops the container and cleans up the mount
  point.
- `sample.env` — template for the supported environment variables.
- `dataset-mount/Dockerfile` — image definition (Debian-slim + s3fs +
  python3 + tini).
- `dataset-mount/entrypoint.sh` — runs inside the container: builds
  symlinks, then execs s3fs in the foreground.
- `dataset-mount/build_symlinks.py` — parses the Dataverse manifest
  and creates the relative-path symlink tree.
