#!/usr/bin/env bash
# End-to-end proof that the demo demonstrates what it claims.
#
# A green stack proves almost nothing here: every pod can be Ready while the
# agent quietly has internet access, or while the SOCKS listener proxies
# anywhere, or while the endpoint denies everything, or while requests flow
# unmetered. Each gate asserts the specific fact the demo stands on, negative
# space included:
#
#   1. OUTER isolation — raw TCP from the agent container to the internet,
#      the API server, kube-dns, the metadata address and every gateway
#      service must fail; the single allowed path must succeed (the control
#      probe, so breakage cannot masquerade as isolation).
#   1b. INNER isolation — the same destinations THROUGH the SOCKS5 listener
#      must fail: NetworkPolicy cannot constrain what a CONNECT names, so
#      the netstack property "only the overlay is dialable" is probed on
#      every converge, never assumed.
#   2. the tunnel is up;
#   3. the keyless call traverses policy and server-side key injection (with
#      the deliberately fake upstream key the expected outcome is Anthropic's
#      own 401 relayed through the proxy); 3b/3c the two denial classes;
#   4. headless Claude Code takes the same governed path;
#   5. external denial — from a scrubbed environment on this workstation,
#      the endpoint answers an outside caller with the bare pre-identity 403;
#   6. attribution and limits read back as desired state says;
#   7. credential hygiene and versions.
#
# --isolation-only re-runs gates 1+1b; --post-disrupt runs 1, 1b, 2 and 3 —
# what the disruption suite re-asserts after each bounce.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
STATE=${STATE_DIR:?}
GW=agent-network-gateway
AG=agent-network-agent
HOST="agent-network-k8s.example.com"
API="https://$HOST/api"
ALLOWED="claude-haiku-4-5-20251001"
DENIED="claude-sonnet-4-5-20250929"
UNCLAIMED="model-that-no-provider-claims-3c"

log() { echo "agent-network-k8s-smoke: $*" >&2; }

PAT=$(kubectl -n "$GW" get secret an-pat -o jsonpath='{.data.value}' | base64 -d)
api() { curl -fsS -X "$1" "$API$2" -H "Authorization: Token $PAT" \
          -H 'content-type: application/json' ${3:+--data "$3"}; }

ENDPOINT=$(cat "$STATE/endpoint")
MODE=$(cat "$STATE/bridge-mode" 2>/dev/null || echo primary)
PROXY_OVERLAY_IP=$(cat "$STATE/proxy-overlay-ip")
LB_IP=$(cat "$STATE/lb-ip")
SOCKS_IP=$(kubectl -n "$AG" get svc socks -o jsonpath='{.spec.clusterIP}')
KUBE_API_IP=$(kubectl -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
KUBE_DNS_IP=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.96.0.10")
TRAEFIK_INT=$(kubectl -n "$GW" get svc traefik-internal -o jsonpath='{.spec.clusterIP}')
SERVER_IP=$(kubectl -n "$GW" get svc netbird-server -o jsonpath='{.spec.clusterIP}')

if [[ $MODE == fallback ]]; then EP_URL="https://$ENDPOINT:8443"; else EP_URL="https://$ENDPOINT"; fi

in_agent() { kubectl -n "$AG" exec deploy/agent -c claude -- "$@"; }

# --- endpoint-mapping drift (checked before every probe run) -----------------
#
# The embedded proxy peer never appears in /api/peers; the authoritative
# address is the network map management pushes the client — the same source
# agent.sh rendered the mapping from.

check_drift() {
  # Same selection rule as agent.sh: stale registrations linger, the newest
  # (greatest xid in the synthesized fqdn) is the live proxy.
  local live
  live=$(kubectl -n "$AG" exec deploy/netbird-client -- \
           netbird status --json 2>/dev/null \
         | jq -r '[.peers.details[]? | {id: (.fqdn // ""), ip: .netbirdIp}]
                  | sort_by(.id) | last.ip // empty' | cut -d/ -f1)
  if [[ -z "$live" || "$live" != "$PROXY_OVERLAY_IP" ]]; then
    log "FAIL: the proxy overlay address drifted ($PROXY_OVERLAY_IP -> ${live:-none}); re-run create"
    exit 1
  fi
}

# --- gate 1: outer isolation -------------------------------------------------

gate_isolation() {
  log "gate 1: outer isolation (raw TCP from the agent container)"
  # IPv6 targets included: VKE's Calico gives pods a unique-local address
  # and a link-local default route as dual-stack plumbing, so the parent's
  # route-table-shape assertion does not translate — reachability is the
  # claim, and it is probed per family.
  for target in "1.1.1.1/443" "8.8.8.8/53" "140.82.121.4/443" "9.9.9.9/443" \
                "2606:4700:4700::1111/443" "2001:4860:4860::8888/53" \
                "169.254.169.254/80" "$KUBE_API_IP/443" "$KUBE_DNS_IP/53" \
                "$TRAEFIK_INT/443" "$SERVER_IP/80"; do
    host=${target%/*}; port=${target##*/}
    if in_agent timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
      log "FAIL: the agent reached $host:$port directly; its only egress must be the SOCKS5 pod"
      exit 1
    fi
  done
  if in_agent ip -o link show 2>/dev/null | grep -qE '(wt|netbird|tun)'; then
    log "FAIL: the agent pod carries a tunnel interface; it must hold no overlay leg"
    exit 1
  fi
  if in_agent ip -6 addr show scope global 2>/dev/null \
       | grep -oE 'inet6 [0-9a-f:]+' | grep -qvE 'inet6 (fd|fc)'; then
    log "FAIL: the agent holds a globally routable IPv6 address"
    exit 1
  fi
  # The control probe: the one path the agent may use must work, or the
  # failures above prove breakage rather than isolation.
  if ! in_agent timeout 5 bash -c "</dev/tcp/$SOCKS_IP/1080" 2>/dev/null; then
    log "FAIL: the agent cannot reach the SOCKS5 pod; the failures above are breakage, not isolation"
    exit 1
  fi
  log "gate 1 passed"

  log "gate 1b: inner isolation (CONNECT through the SOCKS5 listener)"
  socks_code() { # destination reachable through the proxy? 000 = refused
    local out
    out=$(in_agent env -u HTTPS_PROXY -u HTTP_PROXY \
      curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5 "$SOCKS_IP:1080" "$1" 2>/dev/null || true)
    echo "${out:-000}"
  }
  for url in "https://1.1.1.1/" "http://169.254.169.254/" \
             "https://$KUBE_API_IP/" "https://$TRAEFIK_INT/" "http://$SERVER_IP/"; do
    code=$(socks_code "$url")
    if [[ $code != 000 ]]; then
      log "FAIL: the SOCKS5 listener proxied $url (HTTP $code); only the overlay may be dialable"
      exit 1
    fi
  done
  # Hostname-form CONNECTs — the primary bridge's actual escape surface:
  # remote resolution at the listener must serve the endpoint mapping and
  # nothing else (public names have no resolver there: the pod's DNS egress
  # is denied and netstack dials only the overlay).
  socks_host_code() {
    local out
    out=$(in_agent env -u HTTPS_PROXY -u HTTP_PROXY \
      curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
      --socks5-hostname "$SOCKS_IP:1080" "$1" 2>/dev/null || true)
    echo "${out:-000}"
  }
  for url in "https://example.com/" "https://api.anthropic.com/"; do
    code=$(socks_host_code "$url")
    if [[ $code != 000 ]]; then
      log "FAIL: the SOCKS5 listener resolved and proxied $url (HTTP $code)"
      exit 1
    fi
  done
  # Overlay-adjacent guesses: the mapping admits one address, not a subnet.
  base=${PROXY_OVERLAY_IP%.*}; last=${PROXY_OVERLAY_IP##*.}
  for adj in "$base.$(( (last + 1) % 256 ))" "$base.$(( (last + 254) % 256 ))"; do
    code=$(socks_code "https://$adj/")
    if [[ $code != 000 ]]; then
      log "FAIL: the SOCKS5 listener reached overlay-adjacent $adj (HTTP $code)"
      exit 1
    fi
  done
  code=$(socks_code "https://$PROXY_OVERLAY_IP/")
  if [[ $code == 000 ]]; then
    log "FAIL: the overlay address is not reachable through SOCKS5; the denials above are breakage"
    exit 1
  fi
  log "gate 1b passed (only the overlay answers through the proxy)"
}

# --- gate 2: the tunnel ------------------------------------------------------

gate_tunnel() {
  log "gate 2: tunnel status"
  local up=0 status
  for _ in $(seq 1 30); do
    status=$(kubectl -n "$AG" exec deploy/netbird-client -- \
      netbird status 2>&1 || true)
    if grep -qi 'Management: Connected' <<<"$status" && grep -qi 'Signal: Connected' <<<"$status"; then
      up=1; break
    fi
    sleep 5
  done
  if [[ $up != 1 ]]; then
    log "FAIL: the client's tunnel did not come up"
    kubectl -n "$AG" exec deploy/netbird-client -- \
      netbird status -d >&2 || true
    exit 1
  fi
  log "gate 2 passed"
}

# --- gate 3: the keyless call ------------------------------------------------

probe() { # probe MODEL -> globals code/body
  local model=$1
  code=$(in_agent curl -sS -o /tmp/.probe -w '%{http_code}' --max-time 60 \
    -X POST "$EP_URL/v1/messages" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    --data "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word pong.\"}]}" \
    2>/dev/null) || code=000
  body=$(in_agent cat /tmp/.probe 2>/dev/null || true)
}

gate_keyless() {
  log "gate 3: keyless call through $ENDPOINT ($MODE bridge)"
  keymode=""
  for i in $(seq 1 30); do
    probe "$ALLOWED"
    if [[ $code == 200 ]] && grep -q '"content"' <<<"$body"; then
      keymode=real; break
    fi
    # The deliberately fake upstream key: Anthropic's own 401 relayed through
    # the proxy proves tunnel, endpoint routing, policy authorization and
    # server-side key injection — everything NetBird owns — without a
    # billable completion.
    if [[ $code == 401 ]] && grep -qi 'authentication_error' <<<"$body"; then
      keymode=fake; break
    fi
    log "  attempt $i: HTTP $code (endpoint TLS or route may still be settling)"
    sleep 10
  done
  if [[ -z $keymode ]]; then
    log "FAIL: the keyless call neither completed nor returned the upstream 401"
    log "  last: HTTP $code: $(head -c 300 <<<"$body")"
    exit 1
  fi
  log "gate 3 passed ($keymode-key mode)"
}

# --- flag dispatch -----------------------------------------------------------

case ${1:-} in
  --isolation-only)
    check_drift; gate_isolation
    log "PASS (isolation only)"
    exit 0 ;;
  --post-disrupt)
    check_drift; gate_isolation; gate_tunnel; gate_keyless
    log "PASS (post-disruption)"
    exit 0 ;;
esac

check_drift
gate_isolation
gate_tunnel
gate_keyless

log "gate 3b: guardrail denial for $DENIED"
probe "$DENIED"
if [[ $code != 403 ]] || ! grep -qiE 'model_blocked|allowlist|not[ _-]?allowed' <<<"$body"; then
  log "FAIL: expected 403 model-not-allowed, got HTTP $code: $(head -c 300 <<<"$body")"
  exit 1
fi
log "gate 3b passed"

log "gate 3c: routing denial for $UNCLAIMED"
probe "$UNCLAIMED"
if [[ $code -lt 400 ]] || ! grep -qiE 'model_not_routable|no provider|not[ _-]?available' <<<"$body"; then
  log "FAIL: expected a model-not-available denial, got HTTP $code: $(head -c 300 <<<"$body")"
  exit 1
fi
log "gate 3c passed"

# --- gate 4: the payload -----------------------------------------------------

log "gate 4: headless Claude Code"
log "  versions: $(in_agent cat /etc/agent-versions | tr '\n' ' ')"
claude_out=$(in_agent claude -p 'Reply with the single word pong.' 2>&1) && claude_rc=0 || claude_rc=$?
if [[ $keymode == real ]]; then
  if [[ $claude_rc != 0 ]] || ! grep -qi 'pong' <<<"$claude_out"; then
    log "FAIL: Claude Code did not complete: $(head -c 300 <<<"$claude_out")"
    exit 1
  fi
else
  if [[ $claude_rc == 0 ]]; then
    log "FAIL: Claude Code completed against a fake upstream key"
    exit 1
  fi
  if ! grep -qiE '401|authentication' <<<"$claude_out"; then
    log "FAIL: Claude Code failed, but not with the relayed upstream 401: $(head -c 300 <<<"$claude_out")"
    exit 1
  fi
fi
log "gate 4 passed"

# --- gate 5: external denial -------------------------------------------------
#
# From this workstation with a scrubbed environment: no proxy variables, no
# overlay interface, the route to the LB asserted physical, the connection
# pinned to the LB address. An Anthropic 401 from out here would mean key
# injection served an unauthenticated caller — the vulnerability, not the
# proof; the correct outcome is the proxy's bare pre-identity 403.

log "gate 5: external denial from outside the overlay"
if ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -qE '^(wt|netbird)'; then
  log "FAIL: this workstation carries a NetBird/WireGuard interface; the external probe would not be external"
  exit 1
fi
route=$(ip route get "$LB_IP" 2>/dev/null | head -1)
if grep -qE 'dev (wt|netbird|tun)' <<<"$route"; then
  log "FAIL: the route to the load balancer rides a tunnel interface: $route"
  exit 1
fi
ext=$(env -i PATH="$PATH" HOME="$HOME" \
  curl -sk --max-time 20 -w '\nHTTPCODE:%{http_code}' \
  --resolve "$ENDPOINT:443:$LB_IP" \
  -X POST "https://$ENDPOINT/v1/messages" \
  -H 'content-type: application/json' \
  --data "{\"model\":\"$ALLOWED\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" || true)
ext_code=$(sed -n 's/.*HTTPCODE:\([0-9]*\)$/\1/p' <<<"$ext")
if [[ ${ext_code:-000} != 403 ]]; then
  log "FAIL: the endpoint answered an outside caller with HTTP ${ext_code:-000}, not the pre-identity 403"
  exit 1
fi
log "gate 5 passed"

# --- gateway health ----------------------------------------------------------

log "gateway health: certificate and dashboard"
s_client="echo | openssl s_client -servername $HOST -connect $HOST:443 2>/dev/null"
if ! curl -fsS -o /dev/null "https://$HOST/"; then
  log "FAIL: the certificate for $HOST is not trusted by the system store"
  exit 1
fi
if ! sh -c "$s_client | openssl x509 -noout -ext subjectAltName" | grep -qF "$HOST"; then
  log "FAIL: the certificate served for $HOST does not name it"
  exit 1
fi
if ! sh -c "$s_client | openssl x509 -noout -checkend 604800" >/dev/null; then
  log "FAIL: the certificate for $HOST expires within seven days and has not renewed"
  exit 1
fi
expiry=$(sh -c "$s_client | openssl x509 -noout -enddate" | cut -d= -f2)
log "  certificate expires $expiry"

page=$(curl -fsS "https://$HOST/")
unsub=""
for u in $(grep -oE '/_next/static/chunks/[A-Za-z0-9_.-]+\.js' <<<"$page" | sort -u | head -6); do
  if curl -fsS "https://$HOST$u" | grep -q '\$NETBIRD_'; then unsub=$u; break; fi
done
if [[ -n $unsub ]]; then
  log "FAIL: the dashboard is serving unsubstituted configuration in $unsub"
  exit 1
fi

for port in 8443 9090 9000; do
  if timeout 5 bash -c "</dev/tcp/$LB_IP/$port" 2>/dev/null; then
    log "FAIL: port $port answers on the load balancer; only 80 and 443 may be public"
    exit 1
  fi
done

# --- attribution and limits --------------------------------------------------

log "asserting access-log attribution"
logs=$(api GET "/agent-network/access-logs?page=1&page_size=100")
total=$(jq -r '.total_records // (.data|length)' <<<"$logs")
if [[ ${total:-0} -lt 3 ]]; then
  log "FAIL: expected at least the three probes in the access log, found ${total:-0}"
  exit 1
fi
bad_model=$(jq -r --arg m "$ALLOWED" \
  '[.data[] | select((.decision=="allow" or .status_code==200 or .status_code==401)
                     and .model != null and .model != $m)] | length' <<<"$logs")
if [[ $bad_model != 0 ]]; then
  log "FAIL: an allowed request named a model other than $ALLOWED"
  exit 1
fi
for reason in 'model_blocked|allowlist|not[ _-]?allowed' 'model_not_routable|no provider|not[ _-]?available'; do
  if ! jq -r '.data[].deny_reason // empty' <<<"$logs" | grep -qiE "$reason"; then
    log "FAIL: no denial with reason matching /$reason/ in the access log"
    exit 1
  fi
done
unattributed=$(jq -r '[.data[] | select((.user_id // "") == "")] | length' <<<"$logs")
if [[ $unattributed != 0 ]]; then
  log "FAIL: $unattributed access-log entries carry no caller identity"
  exit 1
fi
peer_id=$(cat "$STATE/agent-peer-id" 2>/dev/null || true)
[[ -n $peer_id ]] || { log "FAIL: no recorded agent peer id"; exit 1; }
foreign=$(jq -r --arg p "$peer_id" '[.data[] | select(.user_id != $p)] | length' <<<"$logs")
if [[ $foreign != 0 ]]; then
  log "FAIL: $foreign access-log entries are attributed to something other than the agent peer"
  exit 1
fi

log "asserting configured limits match desired state"
desired="$DIR/desired.json"
pol=$(api GET /agent-network/policies | jq -c '.[] | select(.name=="colors-agents-anthropic")')
[[ -n $pol ]] || { log "FAIL: the policy is missing"; exit 1; }
for check in \
  ".limits.budget_limit.group_cap_usd==$(jq .policy.budget_usd_per_day "$desired")" \
  ".limits.token_limit.group_cap==$(jq .policy.tokens_per_day "$desired")" \
  ".enabled==true"; do
  jq -e "$check" <<<"$pol" >/dev/null || { log "FAIL: policy check $check"; exit 1; }
done
rule=$(api GET /agent-network/budget-rules | jq -c '.[] | select(.name=="colors-global-ceiling")')
[[ -n $rule ]] || { log "FAIL: the global limit is missing"; exit 1; }
jq -e ".limits.budget_limit.group_cap_usd==$(jq .global.budget_usd_per_day "$desired")" \
  <<<"$rule" >/dev/null || { log "FAIL: global budget cap drifted"; exit 1; }
settings=$(api GET /agent-network/settings)
jq -e ".enable_log_collection==true and .access_log_retention_days==$(jq .log_retention_days "$desired")" \
  <<<"$settings" >/dev/null || { log "FAIL: log-collection settings drifted"; exit 1; }

# --- credential hygiene ------------------------------------------------------

log "asserting setup-key hygiene"
live_keys=$(api GET /setup-keys | jq -r \
  '[.[] | select(.name=="colors-agent" and (.revoked|not))] | length')
if [[ $live_keys != 0 ]]; then
  log "FAIL: $live_keys unrevoked colors-agent setup keys exist"
  exit 1
fi
profile=$(basename "$(dirname "$STATE")")
if [[ -d /dev/shm && -e "/dev/shm/agent-network-k8s-$profile-setup-key" ]]; then
  log "FAIL: the staged setup key file survived post-enroll"
  exit 1
fi
# The key must never have become a Kubernetes Secret — asserted by name
# across every namespace, not assumed from the code path.
if kubectl get secrets -A -o name 2>/dev/null | grep -qi 'setup'; then
  log "FAIL: a Secret with a setup-key-shaped name exists in the cluster"
  exit 1
fi

# --- disruption suite, proven once -------------------------------------------

if [[ ! -f $STATE/disrupt-tested ]]; then
  bash "$DIR/disrupt.sh"
  touch "$STATE/disrupt-tested"
fi

# Ephemeral converge diagnostics (never the durable record — that is the
# command output): what passed, when, against which cluster and endpoint.
{
  echo "passed-at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "cluster: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  echo "endpoint: $ENDPOINT"
  echo "bridge-mode: $MODE"
  echo "proxy-overlay: $PROXY_OVERLAY_IP"
  echo "gates: isolation-outer isolation-inner tunnel keyless denial-guardrail denial-routing payload external-403 attribution limits hygiene disruption"
} > "$STATE/proofs-summary"

log "PASS: isolation (outer and inner), tunnel, keyless path, both denials, payload, external denial, attribution, limits, hygiene"
