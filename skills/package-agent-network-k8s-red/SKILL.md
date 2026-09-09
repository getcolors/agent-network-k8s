---
name: package-agent-network-k8s-red
description: Deploy, converge, inspect, or delete a NetBird Agent Network demo on Vultr Kubernetes Engine. Use for a keyless LLM gateway or an isolated AI agent on managed Kubernetes, with model allowlists, budget limits, and NetworkPolicy checks.
---

# NetBird Agent Network on managed Kubernetes

This Red package configures a NetBird gateway and a two-pod application.
The NetBird client runs in netstack/SOCKS5 mode without TUN or capabilities.
The isolated agent runs Claude Code. Its NetworkPolicy permits only the SOCKS5
listener, with no DNS or ServiceAccount token. Acceptance tests direct egress
and connections through SOCKS5, and verifies tunnel identity, model restrictions,
budget limits, and access-log attribution.

Use one `colors.yml` for non-secret desired state. The hostname and its wildcard
must be free in the Cloudflare zone. Read [configuration](references/configuration.md)
for application settings and credentials. Never export `COLORS_PAR_PROFILE`.

```sh
./red build
./red create --dry-run
./red create
./red delete
./red status
./red kubectl -- get pods -A
```

`build` renders without credentials or provider calls. `create --dry-run` skips
side effects. Exit code 2 reports validation or usage failures. The launcher
finds `colors.yml` by walking up from the current directory.

## Compute dependency and state

The pinned `colors-compute` library owns managed compute, provider validation,
version preflight, remote state, kubeconfig handling, and provider cleanup checks.
A compatible provider addition requires only a library pin update in this package.
Managed control planes use their provider API, with no SSH keys or VM fan-out.

The library stores compute at `<profile>/compute/managed-kubernetes.tfstate`
and ownership at `<profile>/compute/coordination.json`. The package stores registry
state at `<profile>/agent-network-k8s-registry.tfstate`. Use R2 or S3.
R2 requires `COLORS_PAR_R2_ACCESS_KEY_ID` and `COLORS_PAR_R2_SECRET_ACCESS_KEY`.
S3 uses the ambient AWS credential chain.

Existing combined `agent-network-k8s-infrastructure.tfstate` must be explicitly
split and reviewed before using the new lifecycle. Execution refuses that legacy
state. It also refuses unreadable ownership and an active operation lock.

## Convergence and deletion

Create converges managed compute, then the application registry. It deploys
namespaces, persistent secrets, the kaniko image build, the gateway, and the
load balancer. DNS precedes the wildcard certificate, which covers the base name
and wildcard. Bootstrap configures identities, model allowlists, and budgets.
The agent enrolls using a one-off key streamed into memory-backed storage;
the key is revoked after enrollment. Acceptance checks isolation and includes
a bounded disruption suite with a node drain.

The package creates a deployment-owned Vultr Container Registry.

Delete reloads managed access and withdraws Kubernetes workloads, volumes, and
the load-balancer Service. Provider checks must confirm cleanup before registry
and compute destruction. Failed commands or uncertain cleanup stop deletion.
Keep `compute-prevent-destroy: true` in committed desired state. An intended
delete uses `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false` for that run.

There are no backups. Delete followed by create regenerates peer identities and
the endpoint hostname. A deliberately fake `COLORS_PAR_ANTHROPIC_API_KEY` is
supported; acceptance then requires the relayed upstream 401. A real key requires
successful completions. Application secrets otherwise remain in cluster Secrets
or NetBird's encrypted store, never in rendered templates or the agent pod.
