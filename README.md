# agent-network-k8s

A [Colors Package Skill](https://www.getcolors.ai/) for a
[NetBird Agent Network](https://docs.netbird.io/agent-network) demo on
**Vultr Kubernetes Engine**: a keyless, policy-gated LLM endpoint and a
**two-pod application** — the NetBird client in netstack/SOCKS5 mode
(userspace WireGuard: no TUN device, no capabilities, `restricted` Pod
Security) and a network-isolated agent pod running headless Claude Code
whose only egress, enforced by a default-deny NetworkPolicy and probed from
both sides on every converge, is that SOCKS5 listener.

One `colors.yml` describes the whole deployment. OpenTofu provisions the VKE
cluster, a deployment-owned container registry, and two unproxied Cloudflare
records (the base hostname and its wildcard — the agent-network endpoint is
a label minted beneath it at bootstrap). kubectl converges the gateway:
Traefik behind a TCP-mode Vultr Load Balancer (the only public surface, TCP
80/443), the combined `netbird-server` on a CSI volume, the dashboard in
agent-network-only mode, and the NetBird reverse proxy in private mode
serving endpoint TLS from a wildcard certificate issued launcher-side via
DNS-01. A headless bootstrap reconciles the control plane by stable name:
admin account, endpoint, an Anthropic provider claiming two models, a
guardrail allowing one, per-group budget and token caps on the agents peer
group, and an account-wide ceiling. The agent image is built in-cluster by
kaniko and consumed by digest.

The demo's product is a provable claim: the agent holds no API key, no
ServiceAccount token, no DNS, and no route anywhere but the tunnel — and
every request it makes arrives at the provider with its peer identity
attached, allowlisted, capped, and attributed in the access log. Acceptance
proves the negative space too: raw probes around the SOCKS5 pod, CONNECT
probes through it, denial probes for the blocked and the unroutable model,
an outside-the-overlay probe that must draw the bare pre-identity 403, and a
bounded disruption suite (pod deletes, component restarts, a node drain)
after which the whole claim is re-probed.

## Use

```sh
npx skills add getcolors/agent-network-k8s@package-agent-network-k8s-green
./green build              # render .colors/<profile>/ — no credentials needed
./green create --dry-run   # walk the workflow, skip every side effect
./green create             # converge for real
./green status             # cluster, certificate, endpoint, tunnel, usage
./green kubectl -- get pods -A
./green delete             # guarded; needs a one-run override
```

Credentials live in a gitignored `.envrc.private` as `COLORS_PAR_*`
variables; see
[`skills/package-agent-network-k8s-green/references/configuration.md`](skills/package-agent-network-k8s-green/references/configuration.md).
A deliberately fake `COLORS_PAR_ANTHROPIC_API_KEY` is a supported mode: the
acceptance gates then expect Anthropic's own 401 relayed through the proxy,
proving everything NetBird owns with nothing billable.

## Recovery

Disposable by design: no backups. Recovery is a guarded `delete` followed by
`create`, which regenerates the endpoint hostname and every peer identity —
anything that memorized the old endpoint breaks, and that is the documented
contract. The dashboard admin password is generated in-cluster:
`./green kubectl -- -n agent-network-gateway get secret an-admin-password -o jsonpath='{.data.value}' | base64 -d`.

## Relation to `agent-network`

The single-node parent (Docker Compose, kernel-TUN agent, one Vultr
instance) verified the control-plane contract this package reuses verbatim —
endpoint minting by the settings POST, the setup-PAT exchange, one-off key
discipline, fake-key mode, the defective per-name ACME on the pinned 0.77.1
build. This package changes the substrate and the isolation mechanism, not
the claim.
