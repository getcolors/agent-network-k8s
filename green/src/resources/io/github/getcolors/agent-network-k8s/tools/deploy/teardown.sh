#!/usr/bin/env bash
# Delete Kubernetes-owned resources before destroying their control plane.
# Any failed command or unverified provider cleanup blocks compute destruction.
set -euo pipefail

GW=agent-network-gateway
AG=agent-network-agent
BLD=agent-network-build

log() { echo "agent-network-k8s-teardown: $*" >&2; }

if ! kubectl version --request-timeout=15s >/dev/null 2>&1; then
  log "cluster access failed; refusing compute destruction"
  exit 1
fi

bash "$(dirname "$0")/managed-cleanup.sh" check-credentials

# Captured BEFORE anything is deleted: the CSI volume handles and the LB
# address are what the Vultr API is asked to confirm absent afterwards —
# Kubernetes objects disappearing proves nothing about the paid resources
# behind them.
# Retain the original resource identities across retries after Kubernetes
# objects disappear. The provider must confirm these same identities absent.
[[ -n ${STATE_DIR:-} && ! -L $STATE_DIR ]] || { log "cleanup state directory unavailable"; exit 1; }
(umask 077; mkdir -p -- "$STATE_DIR")
snapshot="$STATE_DIR/compute-cleanup.json"
[[ ! -L $snapshot ]] || { log "invalid cleanup snapshot"; exit 1; }
volumes=$(kubectl get pv -o json | jq -ce 'if (.items | type) == "array" then [.items[].spec.csi.volumeHandle | select(. != null)] else error("invalid volumes") end')
service=$(kubectl -n "$GW" get svc traefik --ignore-not-found -o json)
[[ -n $service ]] || service='{}'
lb_ip=$(jq -r '.status.loadBalancer.ingress[0].ip // ""' <<<"$service")
if [[ ! -e $snapshot ]]; then
  temporary=$(umask 077; mktemp "$STATE_DIR/.compute-cleanup.XXXXXX")
  jq -n --argjson volumes "$volumes" --arg lb_ip "$lb_ip" '{volumes:$volumes,lb_ip:$lb_ip}' > "$temporary"
  mv "$temporary" "$snapshot"
fi
jq -e 'type == "object" and (.volumes | type) == "array" and all(.volumes[]; type == "string") and (.lb_ip | type) == "string"' "$snapshot" >/dev/null
# A retry must not silently omit resources created since its snapshot.
jq -e --argjson current "$volumes" --arg current_ip "$lb_ip"   '($current - .volumes | length) == 0 and ($current_ip == "" or $current_ip == .lb_ip)'   "$snapshot" >/dev/null || { log "compute resources changed during cleanup; refusing destruction"; exit 1; }
volume_ids=$(jq -r '.volumes[]' "$snapshot")
lb_ip=$(jq -r '.lb_ip' "$snapshot")

log "deleting application and build namespaces"
kubectl delete namespace "$AG" "$BLD" --ignore-not-found --timeout=300s

log "deleting gateway workloads"
kubectl -n "$GW" delete statefulset --all --ignore-not-found --timeout=300s
kubectl -n "$GW" delete deployment --all --ignore-not-found --timeout=300s

log "deleting PVCs and waiting for the CSI volumes to leave"
kubectl -n "$GW" delete pvc --all --ignore-not-found --timeout=300s
for _ in $(seq 1 60); do
  pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
  [[ ${pvs:-0} -eq 0 ]] && break
  sleep 10
done
pvs=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
[[ ${pvs:-0} -eq 0 ]] || { log "PersistentVolumes remain; refusing compute destruction"; exit 1; }

log "deleting the load balancer Service and waiting for the LB to leave"
kubectl -n "$GW" delete service traefik --ignore-not-found --timeout=120s

log "deleting the gateway namespace"
kubectl delete namespace "$GW" --ignore-not-found --timeout=300s

bash "$(dirname "$0")/managed-cleanup.sh" "$snapshot"

log "teardown complete"
