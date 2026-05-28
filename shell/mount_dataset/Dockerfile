# syntax=docker/dockerfile:1.7

# We download a pre-built rclone binary that includes the Dataverse
# backend. The default URL points at the fork's rolling release; once
# https://github.com/rclone/rclone/pull/9467 merges upstream, point
# RCLONE_BINARY_URL at the official rclone release download for your
# platform. To test backend changes from a different fork or branch,
# either rebuild that fork's binary and host it somewhere, or build
# rclone locally and `-v` mount it over `/usr/local/bin/rclone` at
# `docker run` time.
FROM debian:bookworm-slim AS runtime

ARG TARGETARCH
ARG RCLONE_RELEASE_BASE=https://github.com/ErykKul/rclone/releases/download/dataverse-backend-latest
ARG RCLONE_BINARY_URL=

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

# Download the pre-built rclone binary. The smoke test (`rclone version`)
# fails the build immediately if the URL is bad or the binary doesn't
# run on this architecture.
RUN url="${RCLONE_BINARY_URL:-${RCLONE_RELEASE_BASE}/rclone-linux-${TARGETARCH}}" \
  && echo "downloading rclone from $url" \
  && curl -fsSL -o /usr/local/bin/rclone "$url" \
  && chmod +x /usr/local/bin/rclone \
  && /usr/local/bin/rclone version

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
