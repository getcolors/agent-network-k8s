#!/usr/bin/env bash
# The disruption suite, bounded and run once (smoke.sh records the proof):
# both application pods bounced, both stateful gateway components restarted,
# and one node drain — each followed by the post-disruption gates (outer and
# inner isolation, tunnel, keyless path). The k8s analog of the parent's
# docker-restart and reboot proofs: Calico reconciles policy continuously,
# but the claim is probed anyway.
#
# The drain runs under an unconditional trap that uncordons the exact node
# and asserts every node Ready even when a gate fails mid-suite, so a failed
# run can never leave the two-node cluster silently half-capacity.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
STATE=${STATE_DIR:?}
AG=agent-network-agent
GW=agent-network-gateway

log() { echo "agent-network-k8s-disrupt: $*" >&2; }

regate() { bash "$DIR/smoke.sh" --post-disrupt; }

log "1/5: deleting the agent pod (reschedule)"
kubectl -n "$AG" delete pod -l app=agent --wait=true
kubectl -n "$AG" rollout status deployment/agent --timeout=600s
regate

log "2/5: deleting the SOCKS5 pod (state volume re-attach, no new key)"
kubectl -n "$AG" delete pod -l app=netbird-client --wait=true
kubectl -n "$AG" rollout status deployment/netbird-client --timeout=900s
regate

# A restarted reverse proxy re-registers as a NEW embedded proxy peer with a
# fresh overlay address (observed live: the old mapping goes stale the
# moment the pod bounces). TUN-mode peers would receive the updated DNS zone
# automatically; this deployment's static mapping is reconciled instead —
# agent.sh re-reads the network map and rolls the client — and the regates
# then prove the healed path. The same reconcile covers a server restart.
reconcile() { bash "$DIR/agent.sh"; }

log "3/5: restarting the reverse proxy"
kubectl -n "$GW" rollout restart deployment/reverse-proxy
kubectl -n "$GW" rollout status deployment/reverse-proxy --timeout=600s
reconcile
regate

log "4/5: restarting the NetBird server"
kubectl -n "$GW" rollout restart statefulset/netbird-server
kubectl -n "$GW" rollout status statefulset/netbird-server --timeout=900s
reconcile
regate

log "5/5: draining the node hosting the agent"
node=$(kubectl -n "$AG" get pod -l app=agent -o jsonpath='{.items[0].spec.nodeName}')
cleanup() {
  log "uncordoning $node and asserting every node Ready"
  kubectl uncordon "$node" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    notready=$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}')
    [[ -z $notready ]] && return 0
    sleep 10
  done
  log "WARNING: nodes not Ready after uncordon: $notready"
  return 1
}
trap cleanup EXIT
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=900s
log "waiting for the application to reschedule"
kubectl -n "$AG" rollout status deployment/netbird-client --timeout=900s
kubectl -n "$AG" rollout status deployment/agent --timeout=900s
# The drain evicts the reverse proxy along with everything else on the node,
# and an evicted proxy is a new registration with a new overlay address —
# the same churn 3/5 proves, healed the same way before the regate.
kubectl -n "$GW" rollout status deployment/reverse-proxy --timeout=900s
kubectl -n "$GW" rollout status statefulset/netbird-server --timeout=900s
reconcile
kubectl uncordon "$node"
trap - EXIT
cleanup
regate

log "disruption suite passed"
