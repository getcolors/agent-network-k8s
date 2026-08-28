#!/bin/bash
# The agent pod's bridge container, one of two modes selected by agent.sh:
#
#   primary  — privoxy converts Claude Code's HTTP CONNECT to SOCKS5 with the
#              hostname passed through; the NetBird pod resolves it.
#   fallback — gost forwards localhost:8443 to the reverse proxy's overlay
#              address through SOCKS5; TLS runs end-to-end past it.
#
# Either way the pod's only network egress is the SOCKS5 listener, enforced
# by NetworkPolicy and probed by acceptance — the bridge is plumbing, never
# a boundary.
set -euo pipefail

mode=${1:?usage: bridge-entry.sh primary|fallback}

case "$mode" in
  primary)
    sed "s|__SOCKS_ADDR__|${SOCKS_ADDR}|" /etc/bridge/privoxy.config \
      > /run/bridge/privoxy.config
    exec privoxy --no-daemon /run/bridge/privoxy.config
    ;;
  fallback)
    exec gost -L "tcp://127.0.0.1:8443/${PROXY_OVERLAY_IP}:443" \
              -F "socks5://${SOCKS_ADDR}"
    ;;
  *)
    echo "bridge-entry: unknown mode $mode" >&2
    exit 2
    ;;
esac
