#!/usr/bin/env bash
# The wildcard certificate, launcher-side: lego (pinned, checksum-verified)
# orders ONE certificate carrying BOTH SANs — the base name and *.base,
# because a wildcard alone does not cover the bare base hostname and Traefik
# terminates the base name from this same pair. DNS-01 against Cloudflare:
# the token already required for the DNS stage covers the TXT records, and it
# never enters the cluster. Per-name ACME never runs anywhere: the pinned
# reverse-proxy build's responder is defective (see proxy.yaml).
#
# Renewal is a re-converge (`create` renews under 30 days left); the `status`
# verb and the acceptance suite both surface expiry, and this deployment
# deliberately owns no external alerting.
set -euo pipefail

DIR=${DEPLOY_DIR:?}
STATE=${STATE_DIR:?}
LEGO=${LEGO_DIR:?}
GW=agent-network-gateway
HOST="agent-network-k8s.example.com"
EMAIL="admin@example.com"
V="5.4.0"
umask 077
mkdir -p "$LEGO/bin"

log() { echo "agent-network-k8s-certificate: $*" >&2; }

# --- lego, installed once and checksum-verified ------------------------------

BIN="$LEGO/bin/lego"
if ! [[ -x $BIN ]] || ! "$BIN" --version 2>/dev/null | grep -q " $V "; then
  log "installing lego $V"
  curl -fsSL -o "$LEGO/bin/lego.tgz" \
    "https://github.com/go-acme/lego/releases/download/v${V}/lego_v${V}_linux_amd64.tar.gz"
  curl -fsSL "https://github.com/go-acme/lego/releases/download/v${V}/lego_${V}_checksums.txt" \
    | grep "lego_v${V}_linux_amd64.tar.gz" | sed "s#  .*#  $LEGO/bin/lego.tgz#" | sha256sum -c -
  tar -xzf "$LEGO/bin/lego.tgz" -C "$LEGO/bin" lego
  chmod 0755 "$BIN"
  rm -f "$LEGO/bin/lego.tgz"
fi

# --- issue or renew ----------------------------------------------------------

export LEGO_PATH="$LEGO"
export CLOUDFLARE_DNS_API_TOKEN="${COLORS_PAR_CLOUDFLARE_API_TOKEN:?COLORS_PAR_CLOUDFLARE_API_TOKEN is not set}"
crt="$LEGO_PATH/certificates/$HOST.crt"
key="$LEGO_PATH/certificates/$HOST.key"
common=(--dns cloudflare --dns.resolvers 1.1.1.1:53 --dns.propagation.disable-rns)

if [[ ! -s $crt ]]; then
  log "issuing the certificate for $HOST and *.$HOST"
  "$BIN" run -a -m "$EMAIL" -d "$HOST" -d "*.$HOST" "${common[@]}" >&2
elif ! openssl x509 -noout -checkend 2592000 -in "$crt" >/dev/null 2>&1; then
  log "renewing (under 30 days left)"
  "$BIN" renew -m "$EMAIL" -d "$HOST" -d "*.$HOST" "${common[@]}" >&2
fi
unset CLOUDFLARE_DNS_API_TOKEN

# Both SANs verified on the issued certificate before anything consumes it.
sans=$(openssl x509 -noout -ext subjectAltName -in "$crt")
for name in "DNS:$HOST" "DNS:*.$HOST"; do
  grep -qF "$name" <<<"$sans" \
    || { log "FATAL: the certificate does not carry $name"; exit 1; }
done
expiry=$(openssl x509 -noout -enddate -in "$crt" | cut -d= -f2)
log "certificate valid for $HOST and *.$HOST, expires $expiry"

# --- the TLS Secret ----------------------------------------------------------

new_sum=$(cat "$crt" "$key" | sha256sum | awk '{print $1}')
old_sum=$(kubectl -n "$GW" get secret wildcard-tls \
            -o go-template='{{index .data "tls.crt"}}{{index .data "tls.key"}}' 2>/dev/null \
          | base64 -d 2>/dev/null | sha256sum | awk '{print $1}' || true)
if [[ "$new_sum" != "$old_sum" ]]; then
  log "applying the wildcard TLS Secret"
  kubectl -n "$GW" create secret tls wildcard-tls --cert="$crt" --key="$key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Traefik's file provider does not watch the mounted Secret's certificates;
  # a changed pair needs a restart. The reverse proxy file-watches, but a
  # restart is harmless and makes the two paths identical.
  kubectl -n "$GW" rollout restart deployment/traefik >/dev/null
  kubectl -n "$GW" rollout restart deployment/reverse-proxy >/dev/null 2>&1 || true
fi

# --- the readiness deliberately deferred from the deploy stage ---------------

log "waiting for the edge and the proxy (both mount the Secret that now exists)"
kubectl -n "$GW" rollout status deployment/traefik --timeout=300s
kubectl -n "$GW" rollout status deployment/reverse-proxy --timeout=900s
log "certificate stage complete"
