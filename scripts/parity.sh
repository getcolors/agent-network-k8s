#!/usr/bin/env bash
set -euo pipefail

# One desired state, three colours, byte for byte. golden.sh is green's
# regression net against the committed goldens; this is the net across colours:
# each backend variant is rendered by green, red, and blue into separate work
# directories and the trees must be identical — and the template trees each
# colour carries must be identical too, because the copies are the mechanism
# (red/resources and blue's embedded resources are copies of green's tree, not
# references to it).
#
# Two variants, because the goldens have a second axis: the same fixture is
# rendered under the local state backend and again under r2, the way golden.sh
# produces its trees — COLORS_PAR_PROVIDER_BACKEND overlaid on the one
# fixture. Parity means every backend.tf.json agrees in every colour.
#
# Renders resolve each colour's package from this working tree (the
# AGENT_NETWORK_K8S_LIB_ROOT overrides name the repository root), while green,
# red, and blue stay on their pins — a change that lands here passes parity
# before it is pushed or pinned anywhere.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

build_variant() {
  local variant=$1; shift
  local state="$tmp/$variant/colors.yml"
  mkdir -p "$tmp/$variant"
  for colour in green red blue; do
    sed "s#WORKDIR#$tmp/$variant/$colour#" "$root/test/fixtures/colors.yml" > "$state"
    case $colour in
      green) (cd "$root/green" && env AGENT_NETWORK_K8S_LIB_ROOT="$root" "$@" \
                ./green build -f "$state" >/dev/null) ;;
      red)   (cd "$root/red" && env AGENT_NETWORK_K8S_LIB_ROOT="$root" "$@" \
                ./red build -f "$state" >/dev/null) ;;
      blue)  (cd "$root/blue" && env "$@" \
                uv run python -m package_agent_network_k8s_blue build -f "$state" >/dev/null) ;;
    esac
  done
  diff -r "$tmp/$variant/green" "$tmp/$variant/red"
  diff -r "$tmp/$variant/green" "$tmp/$variant/blue"
}

build_variant local COLORS_PAR_PROVIDER_BACKEND=local
build_variant r2 COLORS_PAR_PROVIDER_BACKEND=r2

diff -r "$root/green/src/resources/io/github/getcolors/agent-network-k8s" "$root/red/resources"
diff -r "$root/green/src/resources/io/github/getcolors/agent-network-k8s" "$root/blue/src/package_agent_network_k8s_blue/resources"

echo "green, red, and blue Agent Network K8s artifacts are byte-identical"
