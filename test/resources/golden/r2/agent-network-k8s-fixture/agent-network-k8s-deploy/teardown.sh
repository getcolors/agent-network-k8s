#!/usr/bin/env bash
# Ordered in-cluster teardown before the infrastructure destroy. The CSI
# volumes and the CCM-created load balancer are Kubernetes-managed and
# invisible to the infrastructure state; destroying the cluster first would
# orphan them in the account. Order: workloads → PVCs (waiting for the
# volumes to leave) → the LB Service (waiting for the LB to leave) →
# namespaces. Best-effort throughout: a cluster that stopped answering must
# not block the destroy that removes it.
set -uo pipefail

GW=agent-network-gateway
AG=agent-network-agent
BLD=agent-network-build

log() { echo "agent-network-k8s-teardown: $*" >&2; }

if ! kubectl version --request-timeout=15s >/dev/null 2>&1; then
  log "cluster does not answer; leaving teardown to the infrastructure destroy"
  exit 0
fi

# Captured BEFORE anything is deleted: the CSI volume handles and the LB
# address are what the Vultr API is asked to confirm absent afterwards —
# Kubernetes objects disappearing proves nothing about the paid resources
# behind them.
volume_ids=$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null | grep . || true)
lb_ip=$(kubectl -n "$GW" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

log "deleting application and build namespaces"
kubectl delete namespace "$AG" "$BLD" --ignore-not-found --timeout=300s || true

log "deleting gateway workloads"
kubectl -n "$GW" delete statefulset --all --ignore-not-found --timeout=300s || true
kubectl -n "$GW" delete deployment --all --ignore-not-found --timeout=300s || true

log "deleting PVCs and waiting for the CSI volumes to leave"
kubectl -n "$GW" delete pvc --all --ignore-not-found --timeout=300s || true
for _ in $(seq 1 60); do
  pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  [[ ${pvs:-0} -eq 0 ]] && break
  sleep 10
done
pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
[[ ${pvs:-0} -eq 0 ]] || log "WARNING: $pvs PersistentVolumes remain; check for orphaned block volumes after the destroy"

log "deleting the load balancer Service and waiting for the LB to leave"
kubectl -n "$GW" delete service traefik --ignore-not-found --timeout=120s || true
for _ in $(seq 1 30); do
  kubectl -n "$GW" get service traefik >/dev/null 2>&1 || break
  sleep 10
done

log "deleting the gateway namespace"
kubectl delete namespace "$GW" --ignore-not-found --timeout=300s || true

# The provider is the authority on what still bills. Best-effort (the tofu
# destroy that follows removes the cluster either way), but leftovers are
# surfaced loudly rather than assumed gone.
vultr_api() { curl -fsS -H "Authorization: Bearer ${COLORS_PAR_VULTR_API_KEY:-}" "https://api.vultr.com/v2$1" 2>/dev/null; }
if [[ -n ${COLORS_PAR_VULTR_API_KEY:-} ]]; then
  if [[ -n ${volume_ids:-} ]]; then
    for _ in $(seq 1 30); do
      live=$(vultr_api "/blocks?per_page=500" | jq -r '.blocks[].id' 2>/dev/null || true)
      leftover=$(comm -12 <(sort <<<"$volume_ids") <(sort <<<"$live") | grep . || true)
      [[ -z $leftover ]] && break
      sleep 10
    done
    [[ -z ${leftover:-} ]] || log "WARNING: block volumes still in the account: $leftover — delete them manually"
  fi
  if [[ -n ${lb_ip:-} ]]; then
    for _ in $(seq 1 30); do
      vultr_api "/load-balancers?per_page=500" | jq -e --arg ip "$lb_ip" \
        '.load_balancers[] | select(.ipv4==$ip)' >/dev/null 2>&1 || { lb_ip=""; break; }
      sleep 10
    done
    [[ -z $lb_ip ]] || log "WARNING: the load balancer at $lb_ip is still in the account — delete it manually"
  fi
fi

log "teardown complete"
