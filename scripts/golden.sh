#!/usr/bin/env bash
set -euo pipefail

# agent-network-k8s is a single colour, so there is no parity harness. This is
# the regression net in its place: render the fixture and diff against
# committed output — twice, once per state backend, like `k8s`. The two trees
# differ only in the tofu stages' backend.tf.json, and rendering both proves
# the backend never leaks anywhere else.
#
#   ./scripts/golden.sh            check
#   ./scripts/golden.sh --accept   regenerate after an intended change — read
#                                  the diff first

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

accept=0
[[ ${1:-} == --accept ]] && accept=1

status=0
for backend in local r2; do
  fixture="$tmp/$backend/colors.yml"
  mkdir -p "$tmp/$backend"
  sed "s#WORKDIR#$tmp/$backend/work#" "$root/test/fixtures/colors.yml" > "$fixture"
  (cd "$root/green" \
   && AGENT_NETWORK_K8S_LIB_ROOT="$root" COLORS_PAR_PROVIDER_BACKEND="$backend" \
      ./green build -f "$fixture" >/dev/null)

  profile=$(sed -n 's/^profile: //p' "$fixture")
  actual="$tmp/$backend/work/$profile"
  golden="$root/test/resources/golden/$backend/$profile"

  # No rendered artefact may carry a real secret into a committed golden.
  # Checked before --accept copies anything.
  if grep -rEq 'BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY|github_pat_|ghp_|gho_|ghu_|ghs_|ghr_|sk-ant-api' "$actual"; then
    echo "golden: a credential-shaped value was rendered for $backend" >&2; exit 1
  fi

  deploy="$actual/agent-network-k8s-deploy"

  # The operator secrets must reach the scripts as environment lookups
  # resolved at run time, never as values templated into generated output.
  for pair in "bootstrap.sh:COLORS_PAR_ANTHROPIC_API_KEY" \
              "certificate.sh:COLORS_PAR_CLOUDFLARE_API_TOKEN"; do
    f=${pair%%:*}; var=${pair#*:}
    if ! grep -q "$var" "$deploy/$f"; then
      echo "golden: $f no longer reads $var from the environment" >&2; exit 1
    fi
  done

  # The cluster-generated secrets are substituted at converge time. If a real
  # value ever reaches the rendered config, the next `bb golden:accept` would
  # commit this deployment's store encryption key to git.
  for ph in __RELAY_AUTH_SECRET__ __SESSION_COOKIE_ENCRYPTION_KEY__ __DATASTORE_ENCRYPTION_KEY__; do
    if ! grep -q "$ph" "$deploy/netbird-config.yaml"; then
      echo "golden: netbird-config.yaml no longer renders $ph as a placeholder" >&2; exit 1
    fi
  done

  # Run facts stay placeholders until the converge scripts substitute them —
  # a literal address or digest here would mean a run-time fact was templated
  # and the goldens stopped being workstation-independent.
  for pair in "manifests/proxy.yaml:__TRAEFIK_INTERNAL_IP__" \
              "manifests/netbird-client.yaml:__PROXY_OVERLAY_IP__" \
              "manifests/agent-primary.yaml:__AGENT_IMAGE__" \
              "manifests/agent-fallback.yaml:__AGENT_IMAGE__" \
              "manifests/build-job.yaml:__CONTEXT_SHA__"; do
    f=${pair%%:*}; ph=${pair#*:}
    if ! grep -q "$ph" "$deploy/$f"; then
      echo "golden: $f no longer renders $ph as a placeholder" >&2; exit 1
    fi
  done

  # The forbidden matrix is template-visible: the agent's egress must remain
  # exactly one rule to the SOCKS5 pod, and the agent namespace restricted.
  if ! grep -q 'pod-security.kubernetes.io/enforce: restricted' "$deploy/manifests/namespaces.yaml"; then
    echo "golden: the agent namespace is no longer restricted" >&2; exit 1
  fi

  if [[ $accept == 1 ]]; then
    rm -rf "$golden"; mkdir -p "$(dirname "$golden")"; cp -a "$actual" "$golden"; continue
  fi
  [[ -d "$golden" ]] || { echo "golden missing for $backend; inspect build then run bb golden:accept" >&2; exit 1; }
  diff -ru "$golden" "$actual" || status=1
done

exit "$status"
