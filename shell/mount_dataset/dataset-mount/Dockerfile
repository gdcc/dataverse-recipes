# Image for mount_dataset.sh: mounts a Dataverse dataset's underlying S3
# bucket read-only with s3fs and builds a friendly-name symlink tree on top.
#
# The container's mount point is bind-mounted from the host with
# `:rshared` propagation, so on Linux (and Linux-under-WSL2) the s3fs
# FUSE mount and the symlinks are both visible directly on the host
# filesystem — no SMB / WebDAV layer needed.
#
# Built locally by mount_dataset.sh on first run. Not published.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       s3fs \
       python3 \
       fuse3 \
       ca-certificates \
       tini \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY build_symlinks.py /build_symlinks.py
RUN chmod +x /entrypoint.sh /build_symlinks.py

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
