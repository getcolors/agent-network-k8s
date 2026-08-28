# Configuration reference

Every key in `colors.yml`. Non-secret values only: credentials are
`COLORS_PAR_*` environment variables in a gitignored `.envrc.private`.

Keys are kebab-case. A key's `COLORS_PAR_` name is its upper-snake form —
`agent-network-host` overlays from `COLORS_PAR_AGENT_NETWORK_HOST`. **Never
export `COLORS_PAR_PROFILE`**: the profile keys remote state, and overlaying
it would point one deployment at another's. The package refuses to run when
it is set.

## Core

| Key | Meaning |
|---|---|
| `profile` | This deployment's identity. Keys remote state as `<profile>/<stage>.tfstate` and names the cluster, node pool, load balancer and registry (Compute Name Standard; the registry name is the profile reduced to lowercase alphanumerics, the only characters Vultr accepts there). |
| `workdir` | Where generated output lands. Conventionally `.colors`. The kubeconfig, launcher-side state files and lego's account state live under `<workdir>/<profile>/`. |
| `provider-compute` | Must be `vultr`. |
| `provider-dns` | Must be `cloudflare`. |
| `provider-backend` | `local`, `s3` or `r2`. |
| `compute-prevent-destroy` | Keep `true` in committed state. Destruction needs `COLORS_PAR_COMPUTE_PREVENT_DESTROY=false` for one run. |

## Agent Network

| Key | Meaning |
|---|---|
| `agent-network-host` | Public hostname for the whole demo: dashboard, REST API, management/signal gRPC, relay WebSocket, embedded IdP, and the base the generated agent-network endpoint hangs one label beneath. The DNS stage creates it **and** `*.<host>` — the wildcard is contract, because the endpoint label is minted at bootstrap and nothing knows it earlier. |
| `agent-network-letsencrypt-email` | Contact address for lego's DNS-01 order — one certificate carrying both SANs (the base name and the wildcard; a wildcard alone does not cover the bare base name). Nothing in this deployment runs ACME per-name: the pinned reverse-proxy build's responder is defective. |
| `agent-network-admin-email` | Owner of the local admin account, minted headlessly by `POST /api/setup`. Its password is generated in-cluster, create-once: the `an-admin-password` Secret in `agent-network-gateway`. |
| `agent-network-admin-name` | Display name for that account. |
| `agent-network-provider-models` | The models the Anthropic provider claims, each with `id` and per-1k prices (`input-per-1k`, `output-per-1k`, optional `cache-read-per-1k`, `cache-creation-per-1k`). Must claim at least one model outside the allowlist so the guardrail denial is demonstrable. |
| `agent-network-allowed-models` | The guardrail's model allowlist; a non-empty subset of the claimed models. Every Claude Code model knob in the agent pod is pinned to the first entry. |
| `agent-network-policy-budget-usd-per-day` | Per-group USD cap on the agents policy, over an epoch-aligned one-day window. Must not exceed the global budget. |
| `agent-network-policy-tokens-per-day` | Per-group token cap on the agents policy. Must not exceed the global token cap. |
| `agent-network-global-budget-usd-per-day` | Account-wide USD ceiling (a global limit rule), the backstop across every policy and provider. |
| `agent-network-global-tokens-per-day` | Account-wide token ceiling. |
| `agent-network-log-retention-days` | Access-log retention, 7–90. Usage metering is unconditional and unaffected. |
| `agent-network-log-level` | `error`, `warn`, `info` or `debug`. |

There are no subnet keys and no STUN key: pod addressing belongs to VKE's
Calico (see `vke-pod-cidr`), STUN is fixed at 3478 and never public — both
peers live on the pod network and ICE connects on direct host candidates,
with the in-cluster relay as fallback. The public surface is TCP 80/443 on
the load balancer, nothing else.

## Images and versions

An explicit tag or `@sha256:` digest is **required** — a bare
`repository/name` means `:latest` by implication and is refused, as are
`:latest` and `:main` (with or without a digest). This package owns its
manifests rather than running upstream's installer, so nothing warns you
when a floating tag moves; pin tag@digest and bump deliberately.

| Key | Meaning |
|---|---|
| `agent-network-server-image` | The combined `netbird-server` (management, signal, relay, STUN, embedded IdP). |
| `agent-network-dashboard-image` | The dashboard, run in agent-network-only mode. |
| `agent-network-proxy-image` | The NetBird reverse proxy, private mode. |
| `agent-network-traefik-image` | The edge. |
| `agent-network-client-image` | The stock NetBird client image the SOCKS5 pod runs in netstack mode. Same release train as the server and proxy — move them together. |
| `agent-network-kaniko-image` | The in-cluster builder (the debug variant: its init container needs a shell to receive the streamed context). |
| `agent-network-agent-base-image` | The Node base the agent image builds FROM, by digest. |
| `agent-network-claude-code-version` | Exact `x.y.z`; installed via `npm ci` from the committed integrity-hashed `package-lock.json`. Bumping the version requires regenerating that lockfile in the package repository — `npm ci` fails loudly on a mismatch, by design. |
| `agent-network-privoxy-version` | Exact Debian package version of the HTTP→SOCKS5 bridge (Claude Code speaks HTTP proxies only). |
| `agent-network-gost-version` | Exact `x.y.z` of the fallback bridge (local forward to the overlay address when the pinned SOCKS5 build will not serve hostname CONNECTs). |
| `agent-network-gost-sha256` | sha256 of gost's release tarball; the build refuses a mismatch. |
| `agent-network-lego-version` | The DNS-01 client, checksum-verified from its release, run launcher-side. |

## Vultr

| Key | Meaning |
|---|---|
| `vultr-region` | Region for the cluster and the registry. |
| `vultr-vke-version` | VKE control-plane version, `v<semver>+<build>`. Checked against the live supported list before anything is created. |
| `vultr-node-plan` | Plan for every node in the pool. |
| `vultr-node-count` | Node count (1–16). Two carries the demo comfortably. |
| `vultr-registry-plan` | Vultr Container Registry plan (e.g. `start_up`). |
| `vultr-http-sources` | CIDRs admitted to the load balancer's 80/443. |
| `vke-pod-cidr` | The pod CIDR VKE's Calico allocates from (conventionally `10.244.0.0/16`). Carried into the server's trusted-proxy range and the reverse proxy's PROXY-protocol trust; converge re-validates it against live pod addresses and fails loudly on mismatch. |
| `vultr-name` | Optional Compute Name Standard override. Omit it: the profile names everything. |

## Credentials (`.envrc.private`)

| Variable | Meaning |
|---|---|
| `COLORS_PAR_VULTR_API_KEY` | Cluster, registry, load balancer. |
| `COLORS_PAR_CLOUDFLARE_API_TOKEN` | The two DNS records and lego's DNS-01 TXT records — one record-edit scope covers both. Never enters the cluster. |
| `COLORS_PAR_R2_ACCESS_KEY_ID` / `COLORS_PAR_R2_SECRET_ACCESS_KEY` | Remote state, when `provider-backend: r2`. |
| `COLORS_PAR_ANTHROPIC_API_KEY` | Held server-side in NetBird's encrypted store after convergence; the agent pod never sees it. A deliberately fake value is a supported mode (the gates then expect the relayed upstream 401). |

Everything else is generated in-cluster and supplied by nobody: the relay
auth secret, the datastore encryption key, the session cookie key, the
dashboard admin password (create-once Secrets), the proxy access token, the
durable automation token (cluster Secrets, pipe-only capture), and the
agent's one-off setup key (streamed over exec stdin into memory-backed
storage, revoked after enrollment, never a Kubernetes Secret).
