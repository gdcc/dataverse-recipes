#!/bin/bash
# Entrypoint for the dataset-mount image. Mounts the S3 bucket via s3fs at
# /mount/.s3 inside the container, builds friendly-name symlinks under
# /mount/files, chowns everything to the host user, then execs s3fs in the
# foreground so the container stays alive for the lifetime of the mount.
#
# /mount is bind-mounted from the host with :rshared so on Linux the FUSE
# mount and the symlinks are visible directly on the host filesystem. The
# host directory layout matches the container's exactly, so the relative
# symlinks resolve identically from both sides.
#
# Inputs (env):
#   AWS_S3_BUCKET            S3 bucket name.
#   AWS_S3_ACCESS_KEY_ID     S3 access key ID.
#   AWS_S3_SECRET_ACCESS_KEY S3 secret access key.
#   AWS_S3_URL               S3 endpoint URL.
#   DATASET_IDENTIFIER       Dataset identifier (PID without protocol prefix).
#   FILE_MANIFEST            Path inside the container to the manifest JSON.
#   S3FS_ARGS                Extra s3fs options; default
#                            "use_path_request_style,ro".
#   HOST_UID, HOST_GID       Host user IDs to chown the symlinks to so the
#                            host user owns them.

set -euo pipefail

: "${AWS_S3_BUCKET:?missing}"
: "${AWS_S3_ACCESS_KEY_ID:?missing}"
: "${AWS_S3_SECRET_ACCESS_KEY:?missing}"
: "${AWS_S3_URL:?missing}"
: "${DATASET_IDENTIFIER:?missing}"
: "${FILE_MANIFEST:?missing}"

S3FS_ARGS="${S3FS_ARGS:-use_path_request_style,ro}"
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

# s3fs reads credentials from a 0600 file at /etc/passwd-s3fs by default.
echo "$AWS_S3_ACCESS_KEY_ID:$AWS_S3_SECRET_ACCESS_KEY" > /etc/passwd-s3fs
chmod 600 /etc/passwd-s3fs

mkdir -p /mount/.s3 /mount/files

# Build friendly-name symlinks first. Their targets won't exist until
# s3fs mounts a few lines below, but that's fine — symlinks are happy
# pointing at not-yet-existing paths, and the host sees them appear
# immediately through the rshared bind mount.
python3 /build_symlinks.py "$FILE_MANIFEST" /mount/.s3 /mount/files "$DATASET_IDENTIFIER"

# Hand the friendly tree (and the empty mount points the container
# created itself) over to the host user so the host can browse/delete
# them without sudo. /mount itself is a bind-mount from the host and is
# already owned by the host user — leave it alone.
chown "$HOST_UID:$HOST_GID" /mount/.s3 /mount/files
chown -hR "$HOST_UID:$HOST_GID" /mount/files

# Exec s3fs in the foreground; this becomes PID 1 (under tini). When the
# container receives SIGTERM, s3fs unmounts cleanly and the container exits.
exec s3fs "$AWS_S3_BUCKET" /mount/.s3 \
    -o "url=$AWS_S3_URL,$S3FS_ARGS,umask=0022,allow_other,uid=$HOST_UID,gid=$HOST_GID" \
    -f
