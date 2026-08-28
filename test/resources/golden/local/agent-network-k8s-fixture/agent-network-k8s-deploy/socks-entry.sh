#!/bin/sh
# State-aware entry for the SOCKS5 (NetBird client) pod.
#
# When the state volume already holds an enrolled identity, start and
# reconnect immediately — no key involved, which is what every reschedule,
# node drain and healthy re-converge does. Only when state is absent does
# this wait for the one-off setup key the launcher streams over
# `kubectl exec` stdin into the memory-backed /run/netbird — bounded, with
# an explicit failure, never an indefinite wait.
set -eu

STATE=/var/lib/netbird
SOCK="unix://$STATE/daemon.sock"
KEY=/run/netbird/setup.key
MGMT="https://agent-network-k8s.example.com"

log() { echo "socks-entry: $*" >&2; }
nb() { netbird --daemon-addr "$SOCK" "$@"; }

netbird service run --config "$STATE/config.json" --daemon-addr "$SOCK" \
  --log-file console --log-level info &
daemon=$!

i=0
until nb status >/dev/null 2>&1; do
  i=$((i+1))
  [ "$i" -ge 60 ] && { log "daemon did not answer"; exit 1; }
  sleep 1
done

if [ -s "$STATE/config.json" ] && nb status 2>&1 | grep -qvi 'NeedsLogin'; then
  log "enrolled state present; reconnecting without a key"
  nb up --management-url "$MGMT" || true
else
  log "no enrolled state; waiting for the setup key (bounded)"
  i=0
  while [ ! -s "$KEY" ]; do
    i=$((i+1))
    [ "$i" -ge 900 ] && { log "no setup key arrived within 15 minutes"; exit 1; }
    sleep 1
  done
  log "enrolling with the one-off setup key"
  nb up --setup-key-file "$KEY" --management-url "$MGMT"
fi

log "client is up; holding"
wait "$daemon"
