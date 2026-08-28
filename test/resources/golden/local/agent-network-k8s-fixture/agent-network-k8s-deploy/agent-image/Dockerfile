# The isolated agent's image, built in-cluster by kaniko from pinned inputs:
# the Node base by digest, Claude Code from a committed integrity-hashed
# lockfile, privoxy at the exact Debian version, gost checksum-verified from
# its release. The goldens' claim about what runs here is a claim about
# bytes, not about whatever a floating tag meant that day.
#
# Both the claude and the bridge container run this image as the non-root
# node user (uid 1000), restricted-PSA clean: no capabilities, no privilege
# escalation, read-only root with explicit writable mounts.
FROM node:22-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 procps \
      privoxy=3.0.34-1 \
 && rm -rf /var/lib/apt/lists/*

# gost, the fallback bridge: exact version, tarball verified against the
# sha256 desired state pins.
RUN set -eu; \
    v="3.2.6"; \
    curl -fsSL -o /tmp/gost.tgz \
      "https://github.com/go-gost/gost/releases/download/v${v}/gost_${v}_linux_amd64.tar.gz"; \
    echo "b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b  /tmp/gost.tgz" | sha256sum -c -; \
    tar -xzf /tmp/gost.tgz -C /usr/local/bin gost; \
    chmod 0755 /usr/local/bin/gost; \
    rm -f /tmp/gost.tgz

# Claude Code from the committed lockfile: npm ci refuses anything whose
# integrity hash drifted from what the package repository reviewed.
COPY package.json package-lock.json /opt/claude/
RUN cd /opt/claude && npm ci --omit=dev \
 && ln -s /opt/claude/node_modules/.bin/claude /usr/local/bin/claude

COPY bridge-entry.sh /usr/local/bin/bridge-entry.sh
COPY privoxy.config /etc/bridge/privoxy.config
RUN chmod 0755 /usr/local/bin/bridge-entry.sh

# Versions the acceptance suite prints; a mismatch with desired state fails it.
RUN { claude --version; privoxy --version 2>&1 | head -1; gost -V; } > /etc/agent-versions

USER node
