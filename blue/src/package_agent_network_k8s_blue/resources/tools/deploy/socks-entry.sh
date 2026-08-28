#!/bin/sh
# State-aware entry for the SOCKS5 (NetBird client) pod.
#
# When the state volume already holds an enrolled identity, start and
# reconnect immediately — no key involved, which is what every reschedule,
# node drain and healthy re-converge does. Only when state is absent does
# this wait for the one-off setup key the launcher streams over
# `kubectl exec` stdin into the memory-backed /run/netbird — bounded, with
# an explicit failure, never an indefinite wait.
#
# Everything is wired through NB_* environment variables set on the pod
# (NB_DAEMON_ADDR, NB_LOG_FILE, netstack and SOCKS5 settings): the pinned
# 0.77.1 client silently ignores the equivalent command-line flags on
# `service run`, verified in-pod. The profile config defaults to
# /var/lib/netbird/default.json — already on the state volume.
set -eu

STATE=/var/lib/netbird
KEY=/run/netbird/setup.key
MGMT="https://<{ agent-network-host }>"

log() { echo "socks-entry: $*" >&2; }

netbird service run &
daemon=$!

i=0
until netbird status >/dev/null 2>&1; do
  i=$((i+1))
  [ "$i" -ge 60 ] && { log "daemon did not answer"; exit 1; }
  sleep 1
done

# A config whose management URL is not this deployment's is poison, not
# state: it comes from a failed first enrollment (the daemon persists the
# default api.netbird.io URL before any login) and every later `up` keeps
# dialing the wrong control plane. Wipe it and enroll fresh — an enrolled
# identity always carries this deployment's URL.
MGMT_HOST="<{ agent-network-host }>"
if [ -s "$STATE/default.json" ] \
   && ! grep -q "\"$MGMT_HOST" "$STATE/default.json" 2>/dev/null; then
  log "config points at a foreign management host; discarding stale state"
  rm -f "$STATE/default.json" "$STATE/state.json" "$STATE/active_profile.json"
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  netbird service run &
  daemon=$!
  i=0
  until netbird status >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -ge 60 ] && { log "daemon did not answer"; exit 1; }; sleep 1
  done
fi

# The daemon writes default.json the moment it starts, so a config file is
# NOT evidence of enrollment; the daemon's own status is. NeedsLogin means no
# identity — wait (bounded) for the streamed key. Anything else means the
# state volume holds an enrolled identity and a plain `up` reconnects.
if netbird status 2>&1 | grep -qiE 'NeedsLogin|not logged in'; then
  log "no enrolled identity; waiting for the setup key (bounded)"
  i=0
  while [ ! -s "$KEY" ]; do
    i=$((i+1))
    [ "$i" -ge 900 ] && { log "no setup key arrived within 15 minutes"; exit 1; }
    sleep 1
  done
  log "enrolling with the one-off setup key"
  netbird up --setup-key-file "$KEY" --management-url "$MGMT"
else
  log "enrolled state present; reconnecting without a key"
  netbird up --management-url "$MGMT" || true
fi

log "client is up; holding"
wait "$daemon"
