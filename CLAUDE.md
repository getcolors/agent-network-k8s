# CLAUDE.md

## Repository

`agent-network-k8s` is a green-only Package Skill for the
[NetBird Agent Network](https://docs.netbird.io/agent-network) demo — keyless,
identity-gated LLM access — re-architected from one host onto **Vultr
Kubernetes Engine**. OpenTofu manages the VKE cluster, a deployment-owned
Vultr Container Registry, and two unproxied Cloudflare `A` records: the base
name and its **wildcard**. kubectl (no Ansible, no SSH — the nodes are
managed and every operation goes through the generated kubeconfig) converges
the gateway — Traefik behind a TCP-mode Vultr Load Balancer, the combined
`netbird-server` with its datastore on a CSI volume, the dashboard in
agent-network-only mode, the NetBird reverse proxy in private mode — then a
launcher-side bootstrap reconciles the control plane and starts the
**two-pod application**: the NetBird client in netstack/SOCKS5 mode
(userspace WireGuard — no TUN, no capabilities, `restricted` Pod Security)
and the isolated agent running headless Claude Code. The first consumer is
`../agent-network-k8s-vultr`.

The sibling `../agent-network` package is the architectural parent: same
control-plane contract, same release train, same fake-key doctrine, opposite
substrate (that one is Docker Compose on a single instance with a kernel-TUN
agent; this one is Kubernetes with an unprivileged SOCKS5 leg). Read its
CLAUDE.md for the findings this package inherits; everything below is where
the two deliberately differ.

## The demo's claim, and where it is enforced

The agent pod can reach exactly one address, and the LLM only through it:

- **Isolation is two boundaries, and the second is probed through the
  first.** The agent pod sits behind a default-deny NetworkPolicy whose
  single egress rule is the SOCKS5 pod on TCP 1080 — no kube-dns (the bridge
  targets a ClusterIP rendered at converge; the pod never resolves
  anything), no metadata, no API server, `automountServiceAccountToken:
  false`, `restricted` PSA. But NetworkPolicy cannot constrain what a
  CONNECT names, so acceptance also probes **through** the SOCKS5 listener —
  public addresses, the metadata endpoint, the API server, every gateway
  service must be refused, and only the reverse proxy's overlay address may
  answer. That netstack property is asserted on every converge, never
  assumed, and paired with control probes that must succeed so breakage
  cannot masquerade as isolation.
- **The metered path is the tunnel, supplied statically.** Netstack mode has
  no NetBird DNS ("peers by IP address only"), so what management's
  synthesized zone would serve TUN-mode peers is rendered into the pods
  instead: the endpoint hostname maps to the proxy peer's **overlay**
  address, the connection traverses WireGuard, and `ValidateTunnelPeer`
  enforcement is untouched. The mapping is reconciled against the live API
  on every converge and acceptance run; drift rolls the pod. This is not the
  parent's forbidden gateway-address bypass — the tunnel is still the only
  road.
- **Claude Code cannot speak SOCKS5** (it crashes on socks proxy URLs), so a
  localhost bridge rides in the agent pod: privoxy (primary — hostname
  passed through for remote resolution) or gost (fallback — local forward to
  the overlay address, TLS end-to-end past it), selected by a scripted gate
  in `agent.sh` against the live listener. Both are identity-preserving; the
  bridge is plumbing, never a boundary.
- **A caller without a tunnel has no identity.** The wildcard passthrough
  still exposes 443 publicly, so acceptance probes the endpoint from a
  scrubbed environment and requires the bare pre-identity **403** — an
  upstream 401 from outside would mean key injection served an
  unauthenticated caller, which is the vulnerability, not the proof.

## Kubernetes translations worth knowing

- **Traefik's routing is the file provider only** — no CRDs, no discovery.
  The TCP passthrough matches **endpoint subdomains only**
  (`HostSNIRegexp`), never `HostSNI(*)`: Traefik evaluates matching TCP
  routers before HTTP routers, so a catch-all would swallow the dashboard
  and API. TLS for the base name terminates from the wildcard Secret — one
  lego DNS-01 order carries **both SANs** (a wildcard alone does not cover
  the bare base name); nothing anywhere runs per-name ACME (defective on
  the pinned 0.77.1 build; see the parent).
- **The reverse proxy binds pod port 8443** (non-root cannot bind 443); the
  Service maps 443 onto it. `NB_PROXY_TRUSTED_PROXIES` is the pod CIDR, made
  meaningful by the ingress policy admitting only Traefik pods to that port.
- **The whole traffic matrix lives in `networkpolicies.yaml`** and is pinned
  by the goldens; smoke.sh derives its forbidden-probe list from the same
  table. The reverse proxy's upstream egress is an honest CIDR-bounded
  allowance (vanilla Calico has no FQDN policies) with cluster, private,
  CGN and link-local space carved out.
- **The agent image is built in-cluster by kaniko** (the agent pod has no
  egress; VKE nodes have no host docker) from a deterministic streamed
  context — the Job is named by the context sha, an unchanged context is an
  already-complete Job, and the deploy consumes only the digest read back
  from the registry. Claude Code installs via `npm ci` from the committed
  integrity-hashed lockfile (`agent-image/package-lock.json`; regenerate it
  when bumping `agent-network-claude-code-version`).
- **Create-once discipline is cluster Secrets**: relay auth, datastore
  encryption key, session cookie key, admin password — generated if absent,
  never regenerated (a new datastore key orphans the peer database while
  health stays green). The proxy token and the automation PAT are
  pipe-only-captured cluster Secrets, preserved while healthy. The one-off
  setup key is **never a Kubernetes Secret** (etcd would keep a durable
  copy): it streams over `kubectl exec` stdin into a memory-backed volume,
  and the client entrypoint is state-aware — enrolled state reconnects with
  no key; only an empty state volume waits for one, bounded.
- **Ordering**: deploy applies Traefik and the proxy but does NOT await them
  (they mount the TLS Secret the certificate stage creates later);
  certificate issues, applies, restarts, then awaits both. Delete tears down
  in-cluster first — workloads, PVCs (waiting for the CSI volumes to
  leave), the LB Service (waiting for the LB to leave) — because both are
  Kubernetes-managed and invisible to the infrastructure state.
- **Acceptance's disruption suite** (run once, recorded in the profile
  state) bounces both application pods, the proxy and the server, and drains
  the application node under an unconditional uncordon trap.

## Commands

```sh
cd green && bb test           # validation, tools, workflow
cd green && bb golden         # two backends (local, r2), byte for byte
cd green && bb golden:accept  # after an intended change — read the diff first
./scripts/golden.sh           # same, from the repository root
./scripts/launcher.sh         # launcher self-checks
cd green && bb pin            # stamp the payload after a push
cd green && ./green build     # render; contacts nothing
cd green && ./green create --dry-run
```

Never run a real create/delete without explicit authorization. Never edit or
read `.colors/`, and never read `.envrc.private`.

## Coupling

The package pins only the Green SDK, in `green/deps.edn` — like `k8s`, its
Vultr templates and provider table are its own; there is no ONCE pin.
Working-tree overrides: `AGENT_NETWORK_K8S_LIB_ROOT` (this repository's
root), `GREEN_LIB_ROOT`. `green/green` is a symlink to the skill payload; in
a deployment it is a **copy** that must be refreshed after
`npx skills update -p`. After committing and pushing package code, run
`bb pin` (in `green/`), commit the launcher stamp, and push again. Do not
invent or hand-edit any pin.

## Documentation

`index.html` is this repository's landing page and carries two analytics
tags: GA4 measurement ID `G-4VKP1WY4QJ`, whose explicit `page_title` must
exactly equal the decoded HTML `<title>` and stay distinct and stable, and
the self-hosted Rybbit snippet with site ID `9fb9c41a6d49`. Never add one
tag without the other.

## Git

Work on the current branch. Do not commit or push unless explicitly asked.
