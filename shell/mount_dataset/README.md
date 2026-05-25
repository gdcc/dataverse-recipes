# Mount a Dataverse Dataset as a Local Filesystem

## Purpose

Expose a Dataverse dataset's files as a read-only directory on the local
filesystem, with the dataset's folder structure and human-readable file
names preserved. Useful for ad-hoc inspection, batch tooling, or any
local-filesystem-shaped pipeline (a Python notebook, a converter, a
checksum sweep) without copying the bytes out of S3.

The script picks the right execution mode automatically based on your
OS:

- **Linux / WSL2** — runs `s3fs` inside a Docker container that
  bind-mounts a host directory with `:rshared` propagation. The host's
  only dependency is Docker (plus standard shell tools); `s3fs`,
  `python3` and friends live inside the container image.
- **macOS** — runs `s3fs` natively on the host. Docker Desktop's
  host-VM file sharing does not propagate in-container FUSE mounts on
  macOS, so the Docker path can't work there; native s3fs (via
  macFUSE) does. The script checks for the required tools and points
  at the exact `brew install` commands if anything is missing.

Both paths produce the same on-disk layout, so `unmount_dataset.sh`,
the `files/` tree, and everything downstream are identical.

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

| Host | Status | Mode |
|---|---|---|
| **Linux** | Supported | Docker (no host-side `s3fs`/`python3` install). |
| **Windows (WSL2)** | Supported | Docker, same as Linux — run from inside the WSL2 distro; reachable from Windows Explorer at `\\wsl$\<distro>\<path>`. |
| **macOS** | Supported | Native `s3fs` via macFUSE. The script detects macOS and switches modes automatically. |
| **Native Windows** | Not supported | Use WSL2. |

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

```bash
brew install --cask macfuse            # FUSE for macOS
brew install gromgit/fuse/s3fs-mac     # s3fs built against macFUSE
brew install python                    # if python3 is not already present
```

After installing macFUSE you must approve the system extension in
**System Settings → Privacy & Security**, then reboot. This is a
one-time setup imposed by macOS, not by this recipe.

`bash` and `curl` ship with macOS. The script checks for the three
tools above on every run and prints the exact `brew install` commands
again if any are missing.

Why no Docker on macOS? Docker Desktop runs containers inside a Linux
VM and bridges files between that VM and macOS via VirtioFS / gRPC
FUSE. That bridge handles regular file contents but does not propagate
FUSE mounts that originate inside the container, so an s3fs mount made
in a container is invisible to native macOS apps. Running s3fs
natively on macOS sidesteps the bridge entirely.

## How it works

Common steps (both modes):

1. `mount_dataset.sh` fetches the dataset's file list from
   `GET /api/datasets/:persistentId/versions/<v>/files`. If `DV_TOKEN`
   is set, the request is authenticated with `X-Dataverse-key`;
   without it, only public-dataset access is possible.
2. `<MOUNT_POINT>/.s3/` and `<MOUNT_POINT>/files/` are created on the
   host, and the friendly tree is built as relative symlinks from
   `files/<directoryLabel>/<label>` into `../../.s3/<identifier>/...`.

**Linux / WSL2 (Docker mode):**

3a. The script builds the `rdm-dataset-mount:local` image (first run
    only) and starts a container that bind-mounts `<MOUNT_POINT>` to
    `/mount` inside the container with `:rshared` propagation, then
    runs `s3fs` in the foreground to mount the bucket at `/mount/.s3`.
    The container also `chown`s the symlinks to the host user, so the
    on-disk tree is owned by you without `sudo`.
4a. The `:rshared` propagation makes the in-container FUSE mount
    visible on the host at `<MOUNT_POINT>/.s3`, so the symlinks under
    `files/` resolve to real S3-backed bytes.

**macOS (native mode):**

3b. The script verifies `s3fs`, `python3`, and macFUSE are installed
    (printing `brew install` commands if not), then writes the S3
    credentials to a 0600 tempfile and runs `s3fs` natively. The FUSE
    mount happens directly on the macOS filesystem, no Docker.
4b. `python3` runs `dataset-mount/build_symlinks.py` directly on the
    host to build the symlink tree.

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
- **First-run build time (Linux/WSL2 only).** The
  `rdm-dataset-mount:local` image is built from
  [`dataset-mount/Dockerfile`](dataset-mount/Dockerfile) on first
  invocation (Debian-slim + s3fs + python3, roughly 20 s). Subsequent
  runs use the cached image. If you edit anything under `dataset-mount/`
  later, `docker image rm rdm-dataset-mount:local` to force a rebuild.
- **Stale containers (Linux/WSL2 only).** If `mount_dataset.sh` is
  interrupted before printing success, the container may be left
  running. Find it with `docker ps --filter name=dv-mount-` and stop
  it with `./unmount_dataset.sh <MOUNT_POINT>` or `docker stop <name>`.
- **macOS kernel-extension approval.** First-time macFUSE installs
  require approving a system extension in **System Settings → Privacy
  & Security**, followed by a reboot. macOS will keep blocking the
  s3fs mount with a cryptic "operation not permitted" error until that
  approval is given.

## Files

- `mount_dataset.sh` — entry point: detects the OS, fetches the
  dataset's file list, dispatches to the Docker path (Linux/WSL2) or
  the native-s3fs path (macOS), prints the host mount paths.
- `unmount_dataset.sh` — stops the Docker container if there is one,
  unmounts the FUSE mount (`fusermount -uz` on Linux, `umount` on
  macOS), and removes the mount point.
- `sample.env` — template for the supported environment variables.
- `dataset-mount/build_symlinks.py` — parses the Dataverse manifest
  and creates the relative-path symlink tree. Reused by both modes
  (invoked inside the container on Linux/WSL2; invoked directly on
  macOS).
- `dataset-mount/Dockerfile` — image definition for the Linux/WSL2
  path (Debian-slim + s3fs + python3 + tini). Unused on macOS.
- `dataset-mount/entrypoint.sh` — runs inside the container on the
  Linux/WSL2 path: builds symlinks, then execs s3fs in the foreground.
  Unused on macOS.
