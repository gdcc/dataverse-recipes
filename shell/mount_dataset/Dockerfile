# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Stage 1: build the rclone binary with the dataverse backend included.
# ---------------------------------------------------------------------------
#
# We clone the rclone fork at a pinned ref so reproducible builds don't
# depend on the build host. Override RCLONE_REPO/RCLONE_REF to point at
# a different fork or branch.
FROM golang:1.25-bookworm AS rclone-build

ARG RCLONE_REPO=https://github.com/ErykKul/rclone.git
ARG RCLONE_REF=dataverse-backend

WORKDIR /src
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${RCLONE_REF}" "${RCLONE_REPO}" rclone \
  && cd rclone \
  && go env -w GOFLAGS=-buildvcs=false \
  && go build -trimpath -ldflags "-s -w" -o /out/rclone ./

# ---------------------------------------------------------------------------
# Stage 2: runtime image.
# ---------------------------------------------------------------------------
#
# Default build = mount-only: rclone + FUSE + a tiny entrypoint.
# Build with --build-arg INCLUDE_GLOBUS=1 to additionally bundle Globus
# Connect Personal (~25 MB) for the optional `mount-globus` mode.
FROM debian:bookworm-slim AS runtime

ARG INCLUDE_GLOBUS=0
ARG GCP_URL=https://downloads.globus.org/globus-connect-personal/linux/stable/globusconnectpersonal-latest.tgz

ENV DEBIAN_FRONTEND=noninteractive
ENV INCLUDE_GLOBUS=${INCLUDE_GLOBUS}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       fuse3 \
       tini \
       tzdata \
  && rm -rf /var/lib/apt/lists/*

# /etc/fuse.conf must allow `user_allow_other` so the FUSE mount inside
# the container is reachable by other processes (host bind-mount, GCP)
# even though rclone runs unprivileged.
RUN echo 'user_allow_other' >> /etc/fuse.conf

# Optional: install Globus Connect Personal. The tgz is downloaded
# fresh each build; pin upstream by setting GCP_URL to a versioned
# release URL if you need reproducibility. GCP is a Python program
# so python3 is needed alongside the tarball.
RUN if [ "${INCLUDE_GLOBUS}" = "1" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends python3 \
      && rm -rf /var/lib/apt/lists/* \
      && mkdir -p /opt/gcp \
      && curl -fsSL "${GCP_URL}" -o /tmp/gcp.tgz \
      && tar -xzf /tmp/gcp.tgz -C /opt/gcp --strip-components=1 \
      && rm /tmp/gcp.tgz \
      && chmod +x /opt/gcp/globusconnectpersonal ; \
    else \
      echo "Skipping Globus Connect Personal (INCLUDE_GLOBUS=0)" ; \
    fi

# A non-root user owns mount state and any optional GCP credentials.
RUN groupadd --system --gid 1000 dvgr \
  && useradd  --system --uid 1000 --gid dvgr --home /home/dvgr --create-home --shell /bin/bash dvgr \
  && mkdir -p /home/dvgr/.globusonline /mnt/dataset \
  && chown -R dvgr:dvgr /home/dvgr /mnt/dataset \
  && if [ -d /opt/gcp ]; then chown -R dvgr:dvgr /opt/gcp ; fi

COPY --from=rclone-build /out/rclone /usr/local/bin/rclone
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER dvgr
WORKDIR /home/dvgr

# Default: just mount. The user bind-mounts /mnt/dataset to a host path
# and reads files there. To start Globus Connect Personal on top, pass
# `mount-globus` (requires INCLUDE_GLOBUS=1 at build time and a one-time
# `globus-setup` invocation).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["mount"]
