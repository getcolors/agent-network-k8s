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

log "teardown complete"
