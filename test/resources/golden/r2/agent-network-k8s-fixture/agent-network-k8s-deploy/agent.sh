#!/usr/bin/env bash
# The two-pod application: the NetBird client in netstack/SOCKS5 mode and the
# isolated agent. Applied here, after bootstrap, because both manifests carry
# facts that exist only now — the minted endpoint hostname and the reverse
# proxy's overlay address — and reconciled on every converge: a drifted
# mapping re-renders the manifest and Kubernetes rolls the pod.
#
# The bridge mode is selected by a scripted gate: the primary design (privoxy
# passing the hostname through for remote resolution) is probed against the
# live SOCKS5 listener, and the fallback (gost forwarding to the overlay IP,
# TLS end-to-end past it) is applied when the pinned build will not serve
# hostname CONNECTs. Both are identity-preserving — the only reachable
# destination is the overlay address through the WireGuard tunnel.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
MAN="$DIR/manifests"
STATE=${STATE_DIR:?}
GW=agent-network-gateway
AG=agent-network-agent
umask 077

if [[ -d /dev/shm ]]; then KEY_FILE=/dev/shm/agent-network-k8s-setup-key
else KEY_FILE="$STATE/setup-key"; fi

log() { echo "agent-network-k8s-agent: $*" >&2; }

# shellcheck disable=SC1091
source "$STATE/registry.env"

apply() {
  kubectl apply --dry-run=server -f "$1" >/dev/null \
    || { log "admission rejected $1"; exit 1; }
  kubectl apply -f "$1"
}

PAT=$(kubectl -n "$GW" get secret an-pat -o jsonpath='{.data.value}' | base64 -d)
API="https://agent-network-k8s.example.com/api"
api() { curl -fsS -X "$1" "$API$2" -H "Authorization: Token $PAT"; }

# --- the run facts the manifests need ----------------------------------------

endpoint=$(api GET /agent-network/settings | jq -r '.endpoint // empty')
[[ -n $endpoint ]] || { log "FATAL: no endpoint; run bootstrap first"; exit 1; }
printf '%s' "$endpoint" > "$STATE/endpoint"

# The reverse proxy's overlay address: what management's synthesized DNS zone
# would serve TUN-mode peers, supplied statically because netstack mode has
# no NetBird DNS. Before the agent enrolls the proxy is the only peer; after,
# it is the peer that is not the recorded agent.
agent_peer=$(cat "$STATE/agent-peer-id" 2>/dev/null || true)
proxy_ip=$(api GET /peers | jq -r --arg a "${agent_peer:-none}" \
  '[.[] | select(.id != $a)] | .[0].ip // empty')
[[ -n $proxy_ip ]] || { log "FATAL: no proxy peer is registered on the overlay"; exit 1; }
peer_count=$(api GET /peers | jq -r --arg a "${agent_peer:-none}" \
  '[.[] | select(.id != $a)] | length')
if [[ $peer_count != 1 ]]; then
  log "FATAL: expected exactly one non-agent peer (the reverse proxy), found $peer_count"
  exit 1
fi
printf '%s' "$proxy_ip" > "$STATE/proxy-overlay-ip"
log "endpoint $endpoint at proxy overlay address $proxy_ip"

traefik_internal=$(kubectl -n "$GW" get svc traefik-internal -o jsonpath='{.spec.clusterIP}')
image="$REGISTRY_URN/agent@$(cat "$STATE/agent-image-digest")"

tmpdir=$(mktemp -d /dev/shm/an-k8s.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# --- the SOCKS5 pod ----------------------------------------------------------

kubectl -n "$AG" create configmap socks-entry \
  --from-file=socks-entry.sh="$DIR/socks-entry.sh" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

sed -e "s|__TRAEFIK_INTERNAL_IP__|$traefik_internal|" \
    -e "s|__PROXY_OVERLAY_IP__|$proxy_ip|" \
    -e "s|__ENDPOINT__|$endpoint|" \
    "$MAN/netbird-client.yaml" > "$tmpdir/netbird-client.yaml"
apply "$tmpdir/netbird-client.yaml"

# First enrollment: the pod's entrypoint waits (bounded) for the key the
# bootstrap staged; stream it over exec stdin into the memory-backed volume.
if [[ -s $KEY_FILE ]]; then
  log "waiting for the client pod to accept the setup key"
  pod=""
  for _ in $(seq 1 60); do
    pod=$(kubectl -n "$AG" get pod -l app=netbird-client \
            -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null \
          | awk '{print $1}')
    [[ -n $pod ]] && break
    sleep 5
  done
  [[ -n $pod ]] || { log "FATAL: the client pod never started"; exit 1; }
  kubectl -n "$AG" exec -i "$pod" -- sh -c 'umask 077; cat > /run/netbird/setup.key' < "$KEY_FILE"
  log "setup key streamed"
fi

log "waiting for the client to connect"
kubectl -n "$AG" rollout status deployment/netbird-client --timeout=900s

# Enrollment verified, then the credential that made it possible is closed.
bash "$DIR/bootstrap.sh" --post-enroll

socks_ip=$(kubectl -n "$AG" get svc socks -o jsonpath='{.spec.clusterIP}')

# --- the agent pod, primary mode first ---------------------------------------

render_agent() { # render_agent VARIANT-FILE
  sed -e "s|__AGENT_IMAGE__|$image|" \
      -e "s|__ENDPOINT__|$endpoint|" \
      -e "s|__SOCKS_IP__|$socks_ip|" \
      -e "s|__PROXY_OVERLAY_IP__|$proxy_ip|" \
      "$1"
}

mode=$(cat "$STATE/bridge-mode" 2>/dev/null || echo primary)
render_agent "$MAN/agent-$mode.yaml" > "$tmpdir/agent.yaml"
apply "$tmpdir/agent.yaml"
log "waiting for the agent pod ($mode mode)"
kubectl -n "$AG" rollout status deployment/agent --timeout=900s

# --- the bridge-mode gate ----------------------------------------------------
#
# Probe hostname CONNECT through the live SOCKS5 listener from the agent
# container. Any HTTP status at all means the CONNECT and the TLS handshake
# traversed the tunnel; 000 means the pinned build would not serve the
# hostname form, and the fallback is applied.

if [[ $mode == primary ]]; then
  code=$(kubectl -n "$AG" exec deploy/agent -c claude -- \
    env -u HTTPS_PROXY -u HTTP_PROXY \
    curl -sk -o /dev/null -w '%{http_code}' --max-time 20 \
    --socks5-hostname "$socks_ip:1080" "https://$endpoint/" || true)
  if [[ ${code:-000} == 000 ]]; then
    log "hostname CONNECT is not served by the pinned SOCKS5 build; switching to the fallback bridge"
    mode=fallback
    render_agent "$MAN/agent-fallback.yaml" > "$tmpdir/agent.yaml"
    apply "$tmpdir/agent.yaml"
    kubectl -n "$AG" rollout status deployment/agent --timeout=600s
  else
    log "hostname CONNECT works (HTTP $code); primary bridge stands"
  fi
fi
printf '%s' "$mode" > "$STATE/bridge-mode"
log "application converged in $mode bridge mode"
