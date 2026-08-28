#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
launcher="$root/skills/package-agent-network-k8s-green/green"
grep -q 'io.github.getcolors.agent-network-k8s.workflow/workflow' "$launcher"
grep -q 'def \^:private agent-network-k8s-sha' "$launcher"
[[ -L "$root/green/green" ]] && [[ $(readlink "$root/green/green") == ../skills/package-agent-network-k8s-green/green ]]
[[ -L "$root/red/red" ]] && [[ $(readlink "$root/red/red") == ../skills/package-agent-network-k8s-red/red ]]
[[ -L "$root/blue/blue" ]] && [[ $(readlink "$root/blue/blue") == ../skills/package-agent-network-k8s-blue/blue ]]
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp "$launcher" "$tmp/green"; chmod +x "$tmp/green"
sed "s#WORKDIR#.colors#" "$root/test/fixtures/colors.yml" > "$tmp/colors.yml"
(cd "$tmp" && AGENT_NETWORK_K8S_LIB_ROOT="$root" ./green build >/dev/null)
[[ -f "$tmp/.colors/agent-network-k8s-fixture/agent-network-k8s-infrastructure/main.tf" ]]
[[ -f "$tmp/.colors/agent-network-k8s-fixture/agent-network-k8s-deploy/converge.sh" ]]
[[ -f "$tmp/.colors/agent-network-k8s-fixture/agent-network-k8s-deploy/manifests/networkpolicies.yaml" ]]
# The launcher walks up for colors.yml, so any subdirectory works.
mkdir -p "$tmp/nested/path"
(cd "$tmp/nested/path" && AGENT_NETWORK_K8S_LIB_ROOT="$root" ../../green build >/dev/null)
# The profile guard is the whole reason COLORS_PAR_PROFILE is refused: an
# overlay would point one deployment at another's state.
out=$(cd "$tmp" && AGENT_NETWORK_K8S_LIB_ROOT="$root" COLORS_PAR_PROFILE=wrong ./green build 2>&1 || true)
grep -q COLORS_PAR_PROFILE <<<"$out"
[[ ! -d "$tmp/.colors/wrong" ]]
# The red and blue payloads: same copied-out build through the working-tree
# override, and — while unpinned — the same actionable refusal standalone.
for colour in red blue; do
  payload="$root/skills/package-agent-network-k8s-$colour/$colour"
  cp "$payload" "$tmp/$colour"; chmod +x "$tmp/$colour"
  rm -rf "$tmp/.colors"
  (cd "$tmp" && AGENT_NETWORK_K8S_LIB_ROOT="$root" "./$colour" build >/dev/null)
  [[ -f "$tmp/.colors/agent-network-k8s-fixture/agent-network-k8s-deploy/converge.sh" ]]
  if grep -qE '"package-agent-network-k8s-red": null,|^# dependencies = \[\]$' "$payload"; then
    mkdir -p "$tmp/bare-$colour"; cp "$payload" "$tmp/bare-$colour/$colour"; chmod +x "$tmp/bare-$colour/$colour"
    out=$( (cd "$tmp/bare-$colour" && "./$colour" build 2>&1) || true )
    grep -q 'AGENT_NETWORK_K8S_LIB_ROOT' <<<"$out"
  fi
done
echo 'launcher: all checks passed'
