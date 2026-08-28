#!/usr/bin/env bash
# Phase one of convergence, kubectl against the VKE cluster: namespaces and
# Pod Security levels, create-once cluster secrets, the rendered server
# configuration, the registry credentials, the in-cluster kaniko build of the
# agent image (consumed by digest only), the gateway workloads, the proxy
# token (create-once), and the load balancer.
#
# Deliberately NOT here: waiting for Traefik or the reverse proxy — both
# mount the wildcard TLS Secret the certificate stage creates later, so
# awaiting them now would deadlock (they are applied, and awaited after the
# certificate exists). Every manifest passes a server-side dry run before the
# real apply, so an admission rejection names the manifest instead of
# surfacing as a half-applied stack.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
MAN="$DIR/manifests"
STATE=${STATE_DIR:?}
GW=agent-network-gateway
AG=agent-network-agent
BLD=agent-network-build
umask 077
mkdir -p "$STATE"

log() { echo "agent-network-k8s-converge: $*" >&2; }

# Registry credentials arrive as a private state file written by the
# infrastructure stage — never argv, never a rendered template.
# shellcheck disable=SC1091
source "$STATE/registry.env"
: "${REGISTRY_URN:?no registry URN; did the infrastructure stage run?}"
REGISTRY_HOST=${REGISTRY_URN%%/*}
REGISTRY_PATH=${REGISTRY_URN#*/}

# A freshly created VKE cluster answers its API minutes after the resource
# exists, and nodes join later still; both are awaited, bounded, so a first
# converge does not fail on provider latency.
log "waiting for the cluster API server"
ok=0
for _ in $(seq 1 90); do
  kubectl version --request-timeout=10s >/dev/null 2>&1 && { ok=1; break; }
  sleep 10
done
[[ $ok == 1 ]] || { log "FATAL: the API server never answered"; exit 1; }
log "waiting for a Ready node"
ok=0
for _ in $(seq 1 90); do
  if kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | grep -q .; then ok=1; break; fi
  sleep 10
done
[[ $ok == 1 ]] || { log "FATAL: no node became Ready"; exit 1; }

apply() { # apply FILE — server-side dry run first, then the real thing
  kubectl apply --dry-run=server -f "$1" >/dev/null \
    || { log "admission rejected $1"; exit 1; }
  kubectl apply -f "$1"
}

# --- namespaces --------------------------------------------------------------

apply "$MAN/namespaces.yaml"

# --- create-once cluster secrets --------------------------------------------
#
# Create-once is what keeps the deployment alive: a regenerated datastore
# encryption key orphans the peer database, a regenerated session cookie key
# logs the admin out, a regenerated relay secret breaks relayed peers while
# every pod stays green. A converge finding them present touches nothing —
# the idempotency the parent package proved the hard way.

gen_secret() { # gen_secret NAME BYTES FILTER — FILTER strips what the consumer rejects
  if ! kubectl -n "$GW" get secret "$1" >/dev/null 2>&1; then
    log "generating create-once secret $1"
    openssl rand -base64 "$2" | tr -d "$3" \
      | kubectl -n "$GW" create secret generic "$1" --from-file=value=/dev/stdin >/dev/null
  fi
}
# The datastore and cookie keys must remain STRICT base64 — the server's
# field encryptor rejects unpadded input ("illegal base64 data") — so only
# newlines are stripped there; the relay secret is a plain shared string and
# drops padding like the parent's.
gen_secret an-relay-auth 32 '\n='
gen_secret an-session-cookie 32 '\n'
gen_secret an-datastore-key 32 '\n'
gen_secret an-admin-password 24 '\n='

read_secret() { kubectl -n "$GW" get secret "$1" -o jsonpath='{.data.value}' | base64 -d; }

# --- the server configuration -----------------------------------------------
#
# Substitution happens here rather than in the rendered template so the
# secrets never enter .colors/. The final document is itself a Secret; a
# changed one restarts the server, an unchanged one restarts nothing.

tmpdir=$(mktemp -d /dev/shm/an-k8s.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
sed -e "s|__RELAY_AUTH_SECRET__|$(read_secret an-relay-auth)|" \
    -e "s|__SESSION_COOKIE_ENCRYPTION_KEY__|$(read_secret an-session-cookie)|" \
    -e "s|__DATASTORE_ENCRYPTION_KEY__|$(read_secret an-datastore-key)|" \
    "$DIR/netbird-config.yaml" > "$tmpdir/config.yaml"

new_sum=$(sha256sum "$tmpdir/config.yaml" | awk '{print $1}')
old_sum=$(kubectl -n "$GW" get secret netbird-server-config \
            -o jsonpath='{.data.config\.yaml}' 2>/dev/null | base64 -d | sha256sum | awk '{print $1}' || true)
if [[ "$new_sum" != "$old_sum" ]]; then
  log "server configuration changed; applying"
  kubectl -n "$GW" create secret generic netbird-server-config \
    --from-file=config.yaml="$tmpdir/config.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$GW" rollout restart statefulset/netbird-server 2>/dev/null || true
fi

# --- registry credentials, namespace-scoped copies ---------------------------
#
# One broad Vultr credential — the provider offers no scoped tokens — copied
# into exactly the two namespaces that need it: kaniko's push and the
# kubelet's pull. Application pods run without ServiceAccount tokens, so no
# in-pod principal can read either copy.

auth=$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASS" | base64 -w0)
printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
  "$REGISTRY_HOST" "$REGISTRY_USER" "$REGISTRY_PASS" "$auth" > "$tmpdir/dockerconfig.json"
for pair in "$BLD:registry-push" "$AG:registry-pull"; do
  ns=${pair%%:*}; name=${pair#*:}
  kubectl -n "$ns" create secret generic "$name" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$tmpdir/dockerconfig.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

# --- the gateway core --------------------------------------------------------

kubectl -n "$GW" create configmap traefik-dynamic \
  --from-file=dynamic.yaml="$DIR/traefik-dynamic.yaml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

apply "$MAN/networkpolicies.yaml"
apply "$MAN/traefik.yaml"
apply "$MAN/netbird-server.yaml"
apply "$MAN/dashboard.yaml"

log "waiting for the NetBird server (readiness = OIDC discovery, probed by the kubelet)"
kubectl -n "$GW" rollout status statefulset/netbird-server --timeout=900s
kubectl -n "$GW" rollout status deployment/dashboard --timeout=600s

# --- pod CIDR sanity ---------------------------------------------------------
#
# NB_PROXY_TRUSTED_PROXIES and the server's trustedHTTPProxies carry the pod
# CIDR from desired state; a VKE that allocated pods elsewhere would make
# both silently wrong.

ip_to_int() { # dotted quad -> integer
  local IFS=.
  # shellcheck disable=SC2086
  set -- $1
  echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}
in_cidr() { # in_cidr IP CIDR
  local ip=$1 base=${2%/*} mask=${2#*/}
  [[ $(( $(ip_to_int "$ip") >> (32 - mask) )) -eq $(( $(ip_to_int "$base") >> (32 - mask) )) ]]
}
server_ip=$(kubectl -n "$GW" get pod -l app=netbird-server -o jsonpath='{.items[0].status.podIP}')
if ! in_cidr "$server_ip" "<{ vke-pod-cidr }>"; then
  log "FATAL: pod address $server_ip is outside vke-pod-cidr <{ vke-pod-cidr }>; fix colors.yml"
  exit 1
fi

# --- the proxy access token, create-once -------------------------------------
#
# Preserved untouched while the Secret exists: a healthy converge never
# rotates a credential the running proxy depends on. Delete-by-name-before-
# create runs only on a fresh mint, so a crash between create and persist
# leaves an orphan the next run closes rather than an undiscoverable live
# token. The value travels a pipe-only path into the Secret.

if ! kubectl -n "$GW" get secret proxy-token >/dev/null 2>&1; then
  log "minting the proxy access token"
  admin() { kubectl -n "$GW" exec netbird-server-0 -- \
    /go/bin/netbird-server admin "$@" --config /etc/netbird/config.yaml; }
  for id in $(admin token list 2>/dev/null \
              | awk '$2=="colors-proxy" && $NF=="no" {print $1}'); do
    admin token revoke "$id" >/dev/null 2>&1 || true
  done
  token=$(admin token create --name colors-proxy 2>/dev/null \
          | grep '^Token:' | awk '{print $2}')
  [[ -n $token ]] || { log "FATAL: no proxy token minted"; exit 1; }
  printf '%s' "$token" \
    | kubectl -n "$GW" create secret generic proxy-token --from-file=token=/dev/stdin >/dev/null
  unset token
fi

# --- the reverse proxy (applied, not awaited) --------------------------------

traefik_internal=$(kubectl -n "$GW" get svc traefik-internal -o jsonpath='{.spec.clusterIP}')
sed "s|__TRAEFIK_INTERNAL_IP__|$traefik_internal|" "$MAN/proxy.yaml" > "$tmpdir/proxy.yaml"
apply "$tmpdir/proxy.yaml"

# --- the agent image ---------------------------------------------------------
#
# Deterministic context (sorted names, zeroed mtimes) so the context sha is a
# statement about content; the Job is named by that sha, so an unchanged
# context is an already-completed Job. The deploy consumes only the digest
# read back from the registry — tags are never trusted.

( cd "$DIR/agent-image" && tar --sort=name --mtime=@0 --owner=0 --group=0 -czf "$tmpdir/context.tgz" . )
ctx_sha=$(sha256sum "$tmpdir/context.tgz" | awk '{print $1}')
ctx8=${ctx_sha:0:8}
image_dest="$REGISTRY_URN/agent:ctx-$ctx8"

manifest_digest() {
  curl -fsSI -u "$REGISTRY_USER:$REGISTRY_PASS" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://$REGISTRY_HOST/v2/$REGISTRY_PATH/agent/manifests/ctx-$ctx8" 2>/dev/null \
    | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:" {print $2}'
}

digest=$(manifest_digest || true)
if [[ -z $digest ]]; then
  log "building the agent image in-cluster (context ctx-$ctx8)"
  sed -e "s|__CONTEXT_SHA__|$ctx_sha|" -e "s|__CONTEXT_SHA8__|$ctx8|" \
      -e "s|__IMAGE_DEST__|$image_dest|" "$MAN/build-job.yaml" > "$tmpdir/build-job.yaml"
  kubectl -n "$BLD" delete job "agent-image-build-$ctx8" --ignore-not-found >/dev/null
  apply "$tmpdir/build-job.yaml"

  log "waiting for the build pod's init container"
  pod=""
  for _ in $(seq 1 60); do
    pod=$(kubectl -n "$BLD" get pod -l "job-name=agent-image-build-$ctx8" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n $pod ]] && state=$(kubectl -n "$BLD" get pod "$pod" \
      -o jsonpath='{.status.initContainerStatuses[0].state.running}' 2>/dev/null || true) || state=""
    [[ -n ${state:-} ]] && break
    sleep 5
  done
  [[ -n ${state:-} ]] || { log "FATAL: the build pod's init container never ran"; exit 1; }

  log "streaming the build context"
  kubectl -n "$BLD" exec -i "$pod" -c wait-context -- sh -c 'cat > /workspace/context.tgz' \
    < "$tmpdir/context.tgz"
  kubectl -n "$BLD" exec "$pod" -c wait-context -- touch /workspace/.ready

  log "waiting for kaniko"
  if ! kubectl -n "$BLD" wait --for=condition=complete "job/agent-image-build-$ctx8" --timeout=1800s; then
    log "FATAL: the build failed; last log lines:"
    kubectl -n "$BLD" logs "job/agent-image-build-$ctx8" --tail=50 >&2 || true
    exit 1
  fi
  digest=$(manifest_digest)
  [[ -n $digest ]] || { log "FATAL: the pushed image has no readable digest"; exit 1; }
fi
printf '%s' "$digest" > "$STATE/agent-image-digest"
printf '%s' "$ctx_sha" > "$STATE/agent-image-ctx"
log "agent image: $REGISTRY_URN/agent@$digest"

# --- the load balancer -------------------------------------------------------

log "waiting for the load balancer address"
lb=""
for _ in $(seq 1 120); do
  lb=$(kubectl -n "$GW" get svc traefik \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n $lb ]] && break
  sleep 10
done
[[ -n $lb ]] || { log "FATAL: the load balancer never received an address"; exit 1; }
printf '%s' "$lb" > "$STATE/lb-ip"
log "load balancer: $lb"
log "converge phase one complete"
