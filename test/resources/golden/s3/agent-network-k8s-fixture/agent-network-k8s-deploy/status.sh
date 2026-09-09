#!/usr/bin/env bash
# What an operator runs to see whether this deployment is well. Deliberately
# local and queryable rather than an alerting integration: this package ships
# no monitoring stack, and pretending otherwise would be the same class of
# error as trusting an exit code.
set -uo pipefail

STATE=${STATE_DIR:?}
GW=agent-network-gateway
AG=agent-network-agent
HOST="agent-network-k8s.example.com"

echo "== pods"
kubectl get pods -n "$GW" -o wide 2>/dev/null
kubectl get pods -n "$AG" -o wide 2>/dev/null

echo; echo "== certificate"
cert=$(echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null \
       | openssl x509 2>/dev/null)
exp=$(openssl x509 -noout -enddate 2>/dev/null <<<"$cert" | cut -d= -f2)
echo "$HOST expires ${exp:-unknown}"
if [[ -n $cert ]] && ! openssl x509 -noout -checkend 2592000 <<<"$cert" >/dev/null 2>&1; then
  echo "  WARNING: under 30 days remain — run ./green create to renew"
fi

echo; echo "== endpoint"
ep=$(cat "$STATE/endpoint" 2>/dev/null)
echo "  ${ep:-not bootstrapped} (bridge mode: $(cat "$STATE/bridge-mode" 2>/dev/null || echo unknown))"

echo; echo "== tunnel"
kubectl -n "$AG" exec deploy/netbird-client -- \
  netbird status 2>/dev/null | sed -n '1,8p' \
  || echo "  client pod is not running"

echo; echo "== usage (access log)"
pat=$(kubectl -n "$GW" get secret an-pat -o jsonpath='{.data.value}' 2>/dev/null | base64 -d)
if [[ -n ${pat:-} ]]; then
  curl -fsS -H "Authorization: Token $pat" \
    "https://$HOST/api/agent-network/access-logs?page=1&page_size=1" 2>/dev/null \
    | jq -r '"  \(.total_records // 0) requests in the access log"' \
    || echo "  management unreachable"
else
  echo "  no automation credential"
fi

echo; echo "== dashboard"
echo "  https://$HOST/  (admin: admin@example.com;"
echo "  password: kubectl -n $GW get secret an-admin-password -o jsonpath='{.data.value}' | base64 -d)"
