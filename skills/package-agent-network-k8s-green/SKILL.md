---
name: package-agent-network-k8s-green
description: Provision and manage a NetBird Agent Network demo on Vultr Kubernetes Engine from declarative desired state — a keyless, policy-gated LLM endpoint and a two-pod application, the NetBird client in netstack/SOCKS5 mode plus a network-isolated agent pod running headless Claude Code. Use when asked to deploy, converge, inspect or delete an Agent Network on Kubernetes, a keyless LLM gateway demo on VKE, or an isolated AI-agent sandbox with identity-based model access and NetworkPolicy-enforced egress.
---

# NetBird Agent Network on Vultr Kubernetes Engine

A Green workflow that turns one `colors.yml` into a running Agent Network
demo on a managed Kubernetes cluster: OpenTofu for the VKE cluster and the
deployment-owned container registry plus two Cloudflare records (the base
name and its wildcard); kubectl for the gateway (Traefik behind a TCP-mode
Vultr Load Balancer, the combined `netbird-server` with its datastore on a
CSI volume, the dashboard in agent-network-only mode, the NetBird reverse
proxy in private mode), a launcher-side control-plane bootstrap, an
in-cluster kaniko build of the agent image, and the **two-pod application**:
the NetBird client in netstack/SOCKS5 mode — userspace WireGuard, no TUN, no
capabilities — and the isolated agent running headless Claude Code.

The demo's claim: the agent pod has **no network egress but the SOCKS5
listener** — default-deny NetworkPolicy with a single allow, in a
`restricted` Pod Security namespace, with no ServiceAccount token and no DNS
— and its only road to an LLM is the keyless agent-network endpoint over the
WireGuard tunnel, where every request carries the peer's identity, passes
the model allowlist and the budget caps, and is metered. Convergence proves
the claim from both sides: raw probes around the proxy AND CONNECT probes
through it (NetworkPolicy cannot constrain what a CONNECT names, so the
"only the overlay is dialable" property is probed on every converge, never
assumed).

## Verbs

```sh
./green build              # render .colors/<profile>/ — no provider calls, no credentials
./green create --dry-run   # walk the workflow, skip every side effect
./green create             # converge for real
./green delete             # guarded; needs a one-run override
./green status             # cluster, certificate, endpoint, tunnel, usage
./green kubectl -- get pods -A   # kubectl with this deployment's kubeconfig
```

Exit code 2 is validation or usage failure and lists every problem at once.
The launcher walks up from the working directory to find `colors.yml`.

## Before you converge

- The hostname and its wildcard must be free in the Cloudflare zone. The DNS
  stage creates both and never adopts a foreign record.
- Five credentials must be set in `.envrc.private`; see
  `references/configuration.md`. Never export `COLORS_PAR_PROFILE`.
- A deliberately fake `COLORS_PAR_ANTHROPIC_API_KEY` is a supported mode: the
  acceptance gates then expect Anthropic's own 401 relayed through the proxy,
  which proves everything NetBird owns with nothing billable. A real key
  upgrades the same gates to require completions; swapping is an
  `.envrc.private` edit and a re-converge.
- `vultr-vke-version` is checked against VKE's live supported list before
  anything is created; the error names the versions on offer.

## What create does

infrastructure (VKE + registry) → deploy (namespaces, create-once secrets,
kaniko build, gateway, proxy token, LB) → dns (base + wildcard, unproxied) →
certificate (lego DNS-01, both SANs, launcher-side; then the edge and proxy
readiness deliberately deferred until the Secret exists) → bootstrap
(headless: setup-PAT exchange, endpoint minted by the settings POST,
provider claiming two models, guardrail allowing one, per-group caps on the
agents peer group, account-wide ceiling) → agent (the two pods; one-off
setup key streamed over exec stdin into memory-backed storage, revoked after
enrollment) → acceptance (isolation outer and inner, tunnel, keyless call,
both denial classes, external pre-identity 403, attribution, limits read
back, credential hygiene, and — once — a bounded disruption suite including
a node drain).

## Recovery

Disposable by design: no backups. Recovery is a guarded `delete`
(`COLORS_PAR_COMPUTE_PREVENT_DESTROY=false` for one run) followed by
`create`, which regenerates the endpoint hostname and every peer identity;
anything that memorized the old endpoint breaks. The dashboard admin
password: `./green kubectl -- -n agent-network-gateway get secret
an-admin-password -o jsonpath='{.data.value}' | base64 -d`.
