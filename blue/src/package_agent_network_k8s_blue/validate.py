"""Credential-free desired-state validation for the VKE Agent Network demo,
the port of io.github.getcolors.agent-network-k8s.validate. Depends only on
the SDK: like `k8s`, this package carries its own provider registry rather
than pinning ONCE for one lookup table.

Green renders its keys as Clojure keywords, so every message here carries the
same leading colon — the three colours must report identical errors for one
colors.yml.
"""

from __future__ import annotations

import re

from blue.cli import par_name

from . import utils

profile_par = par_name("profile")

providers = {
    "provider-compute": {
        "vultr": {"secrets": ["vultr-api-key"],
                  "tofu_env": {"vultr-api-key": "VULTR_API_KEY"}},
    },
    "provider-dns": {
        "cloudflare": {"secrets": ["cloudflare-api-token"], "tofu_env": {}},
    },
    "provider-backend": {
        "local": {"secrets": [], "tofu_env": {}},
        "s3": {"secrets": ["s3-access-key-id", "s3-secret-access-key"],
               "tofu_env": {"s3-access-key-id": "AWS_ACCESS_KEY_ID",
                            "s3-secret-access-key": "AWS_SECRET_ACCESS_KEY"}},
        "r2": {"secrets": ["r2-access-key-id", "r2-secret-access-key"],
               "tofu_env": {"r2-access-key-id": "AWS_ACCESS_KEY_ID",
                            "r2-secret-access-key": "AWS_SECRET_ACCESS_KEY"}},
    },
}

# Every key desired state must carry. There is no `vultr-name`: the Compute
# Name Standard's optional override applies, and a colors.yml that omits it is
# complete and names the cluster, node pool, load balancer and registry after
# the profile.
required = [
    "profile", "workdir", "provider-compute", "provider-dns", "provider-backend",
    "compute-prevent-destroy",
    "agent-network-host", "agent-network-letsencrypt-email",
    "agent-network-admin-email", "agent-network-admin-name",
    "agent-network-provider-models", "agent-network-allowed-models",
    "agent-network-policy-budget-usd-per-day", "agent-network-policy-tokens-per-day",
    "agent-network-global-budget-usd-per-day", "agent-network-global-tokens-per-day",
    "agent-network-log-retention-days", "agent-network-log-level",
    "agent-network-server-image", "agent-network-dashboard-image",
    "agent-network-proxy-image", "agent-network-traefik-image",
    "agent-network-client-image", "agent-network-kaniko-image",
    "agent-network-agent-base-image",
    "agent-network-claude-code-version", "agent-network-privoxy-version",
    "agent-network-gost-version", "agent-network-gost-sha256",
    "agent-network-lego-version",
    "vultr-region", "vultr-vke-version", "vultr-node-plan", "vultr-node-count",
    "vultr-registry-plan", "vultr-http-sources", "vke-pod-cidr",
]

image_keys = [
    "agent-network-server-image", "agent-network-dashboard-image",
    "agent-network-proxy-image", "agent-network-traefik-image",
    "agent-network-client-image", "agent-network-kaniko-image",
    "agent-network-agent-base-image",
]

_host_re = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
_email_re = re.compile(r"^[^@\s]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
# `tag@sha256:...` — the shape every image key here actually carries — pins
# both the human-readable version and the exact bytes.
_image_pinned_re = re.compile(r"^[^\s@]+(?::[^\s:@]+@sha256:[0-9a-f]{64}|:[^\s:@]+|@sha256:[0-9a-f]{64})$")
_cidr_re = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$")
_version_re = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
# A Debian package version: upstream plus revision, e.g. 3.0.34-1.
_deb_version_re = re.compile(r"^[0-9][0-9A-Za-z.+~:-]*$")
_sha256_re = re.compile(r"^[0-9a-f]{64}$")
# VKE versions are Kubernetes semver plus Vultr's build suffix: v1.35.2+1.
_vke_version_re = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$")
_model_id_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
# Vultr labels accept letters, digits, dashes, underscores and periods.
_vultr_name_re = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")


def missing(x) -> bool:
    return x is None or (isinstance(x, str) and not x.strip())


def placeholder(v) -> bool:
    """Absent, blank or REPLACE_ME all mean 'use the profile' (Compute Name
    Standard §2: presence is the only switch)."""
    return missing(v) or str(v).strip() == "REPLACE_ME"


def compute_name(opts: dict) -> str:
    """What this deployment calls its cluster. Every label — the node pool's,
    the registry's (lowercased, non-alphanumerics stripped: Vultr registry
    names accept nothing else) — derives from this and never from the raw
    override key or a second copy of the profile (§3)."""
    override = opts.get("vultr-name")
    if placeholder(override):
        return str(opts.get("profile"))
    return str(override).strip()


def registry_name(opts: dict) -> str:
    return utils.registry_name(compute_name(opts))


def zone(opts: dict) -> str:
    """The Cloudflare zone the host and its wildcard belong to."""
    return utils.registrable_domain(opts.get("agent-network-host"))


def provider_models(opts: dict) -> list[dict]:
    """The models the Anthropic provider claims, however YAML handed them
    over."""
    models = opts.get("agent-network-provider-models")
    return list(models) if isinstance(models, (list, tuple)) else []


def allowed_models(opts: dict) -> list[str]:
    models = opts.get("agent-network-allowed-models")
    return [str(m) for m in models] if isinstance(models, (list, tuple)) else []


def allowed_model(opts: dict) -> str | None:
    """The model every Claude Code knob is pinned to."""
    models = allowed_models(opts)
    return models[0] if models else None


def denied_claimed_model(opts: dict) -> str | None:
    """A model the provider claims but the guardrail does not allow — the
    guardrail-denial probe's negative case. Its existence is validated, so
    acceptance can rely on it."""
    allowed = set(allowed_models(opts))
    for m in provider_models(opts):
        if str(m.get("id")) not in allowed:
            return str(m.get("id"))
    return None


def pos_num(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0


def model_errors(opts: dict) -> list[str]:
    models = provider_models(opts)
    allowed = allowed_models(opts)
    claimed = {str(m.get("id")) for m in models}
    errors: list[str] = []
    if not (isinstance(opts.get("agent-network-provider-models"), (list, tuple)) and models):
        errors.append(":agent-network-provider-models must be a non-empty list")
    for m in models:
        if missing(m.get("id")) or not _model_id_re.fullmatch(str(m.get("id"))):
            errors.append(":agent-network-provider-models entries must carry a model id")
    for m in models:
        if not (pos_num(m.get("input-per-1k")) and pos_num(m.get("output-per-1k"))):
            errors.append(f"model {m.get('id')} must carry positive input-per-1k and output-per-1k prices")
    if not (isinstance(opts.get("agent-network-allowed-models"), (list, tuple)) and allowed):
        errors.append(":agent-network-allowed-models must be a non-empty list")
    for m in allowed:
        if m not in claimed:
            errors.append(f":agent-network-allowed-models entry {m} is not claimed by the provider")
    # The demo's guardrail-denial probe needs a model that routing accepts
    # and the allowlist rejects. Without one, gate 3b has no negative case
    # and the guardrail is configured but never demonstrated.
    if models and allowed and all(str(m.get("id")) in set(allowed) for m in models):
        errors.append(":agent-network-provider-models must claim at least one model outside :agent-network-allowed-models")
    return errors


def env_errors(env: dict) -> list[str]:
    if str(env.get(profile_par) or ""):
        return [f"{profile_par} is set; profile must come from colors.yml only"]
    return []


def _entry(opts: dict, slot: str) -> dict | None:
    return providers.get(slot, {}).get(str(opts.get(slot)))


def state_errors(opts: dict) -> list[str]:
    errors: list[str] = []
    for k in required:
        if missing(opts.get(k)):
            errors.append(f":{k} is required")
    if opts.get("provider-compute") != "vultr":
        errors.append(":provider-compute must be vultr")
    if opts.get("provider-dns") != "cloudflare":
        errors.append(":provider-dns must be cloudflare")
    if opts.get("provider-backend") not in ("local", "s3", "r2"):
        errors.append(":provider-backend must be local, s3, or r2")
    if not isinstance(opts.get("compute-prevent-destroy"), bool):
        errors.append(":compute-prevent-destroy must be true or false")
    if (not missing(opts.get("agent-network-host"))
            and not _host_re.fullmatch(str(opts.get("agent-network-host")))):
        errors.append(":agent-network-host must be a fully qualified hostname")
    for k in ("agent-network-letsencrypt-email", "agent-network-admin-email"):
        v = opts.get(k)
        if not missing(v) and not _email_re.fullmatch(str(v)):
            errors.append(f":{k} must be an email address")
    for k in image_keys:
        v = opts.get(k)
        if not missing(v) and not _image_pinned_re.fullmatch(str(v)):
            errors.append(f":{k} must carry an explicit image tag or digest")
    # This package owns its manifests rather than following the upstream
    # installer, so nothing tells it when a floating tag moved underneath it.
    for k in image_keys:
        v = str(opts.get(k))
        if (v.endswith(":latest") or v.endswith(":main")
                or ":latest@" in v or ":main@" in v):
            errors.append(f":{k} must not track a floating tag; pin the version")
    for k in ("agent-network-claude-code-version", "agent-network-lego-version"):
        v = opts.get(k)
        if not missing(v) and not _version_re.fullmatch(str(v)):
            errors.append(f":{k} must be an exact x.y.z version")
    if not (missing(opts.get("agent-network-privoxy-version"))
            or _deb_version_re.fullmatch(str(opts.get("agent-network-privoxy-version")))):
        errors.append(":agent-network-privoxy-version must be an exact Debian package version")
    if not (missing(opts.get("agent-network-gost-version"))
            or _version_re.fullmatch(str(opts.get("agent-network-gost-version")))):
        errors.append(":agent-network-gost-version must be an exact x.y.z version")
    if not (missing(opts.get("agent-network-gost-sha256"))
            or _sha256_re.fullmatch(str(opts.get("agent-network-gost-sha256")))):
        errors.append(":agent-network-gost-sha256 must be the 64-hex sha256 of the release tarball")
    if not (missing(opts.get("vultr-vke-version"))
            or _vke_version_re.fullmatch(str(opts.get("vultr-vke-version")))):
        errors.append(":vultr-vke-version must look like v1.35.2+1")
    node_count = opts.get("vultr-node-count")
    if not (missing(node_count)
            or (isinstance(node_count, int) and not isinstance(node_count, bool)
                and 1 <= node_count <= 16)):
        errors.append(":vultr-node-count must be an integer between 1 and 16")
    if not (missing(opts.get("vke-pod-cidr"))
            or _cidr_re.fullmatch(str(opts.get("vke-pod-cidr")))):
        errors.append(":vke-pod-cidr must be a CIDR block")
    if not (missing(opts.get("agent-network-log-level"))
            or str(opts.get("agent-network-log-level")) in ("error", "warn", "info", "debug")):
        errors.append(":agent-network-log-level must be error, warn, info, or debug")
    # 7-90 mirrors the dashboard's own retention range; usage metering is
    # unconditional and unaffected.
    retention = opts.get("agent-network-log-retention-days")
    if not (missing(retention)
            or (isinstance(retention, int) and not isinstance(retention, bool)
                and 7 <= retention <= 90)):
        errors.append(":agent-network-log-retention-days must be an integer between 7 and 90")
    for k in ("agent-network-policy-budget-usd-per-day",
              "agent-network-policy-tokens-per-day",
              "agent-network-global-budget-usd-per-day",
              "agent-network-global-tokens-per-day"):
        v = opts.get(k)
        if not missing(v) and not pos_num(v):
            errors.append(f":{k} must be a positive number")
    # The global rule is the backstop: a policy cap above it would never bind
    # and the desired state would be lying about which limit is the ceiling.
    if (pos_num(opts.get("agent-network-policy-budget-usd-per-day"))
            and pos_num(opts.get("agent-network-global-budget-usd-per-day"))
            and opts.get("agent-network-policy-budget-usd-per-day")
            > opts.get("agent-network-global-budget-usd-per-day")):
        errors.append(":agent-network-policy-budget-usd-per-day must not exceed the global budget")
    if (pos_num(opts.get("agent-network-policy-tokens-per-day"))
            and pos_num(opts.get("agent-network-global-tokens-per-day"))
            and opts.get("agent-network-policy-tokens-per-day")
            > opts.get("agent-network-global-tokens-per-day")):
        errors.append(":agent-network-policy-tokens-per-day must not exceed the global token cap")
    if any(not missing(v) for v in (opts.get("agent-network-provider-models"),
                                    opts.get("agent-network-allowed-models"))):
        errors.extend(model_errors(opts))
    srcs = opts.get("vultr-http-sources")
    if (not missing(srcs)
            and (not isinstance(srcs, (list, tuple)) or not srcs
                 or any(not _cidr_re.fullmatch(str(s)) for s in srcs))):
        errors.append(":vultr-http-sources must be a non-empty list of IPv4 CIDRs")
    # The override is validated against the provider's rules rather than
    # passed through unread (Compute Name Standard §2).
    if not (placeholder(opts.get("vultr-name"))
            or _vultr_name_re.fullmatch(str(opts.get("vultr-name")).strip())):
        errors.append(":vultr-name must be letters, digits, dot, dash or underscore")
    return errors


def backend_secrets(opts: dict) -> list[str]:
    entry = _entry(opts, "provider-backend")
    return entry["secrets"] if entry else []


# What talking to the providers needs, on any real event.
provider_secrets = ["vultr-api-key", "cloudflare-api-token"]

# What converging the cluster needs, and therefore only a create.
#
# One entry, deliberately. Everything else this deployment holds is generated
# in-cluster and supplied by nobody: the relay auth secret, the datastore
# encryption key, the session cookie key, the proxy access token, the local
# admin password, the durable automation token, and the agent's one-off setup
# key. The Anthropic key is the exception because it authenticates against an
# account this cluster does not own; it is handed to NetBird's encrypted store
# at converge time and the agent pod never sees it.
application_secrets = ["anthropic-api-key"]


def secret_errors(opts: dict, event: str) -> list[str]:
    """Credentials a real event needs. A delete tears down infrastructure with
    the provider credentials alone: this deployment is disposable by design,
    holds nothing worth a final archive, and demanding the Anthropic key to
    destroy a cluster would just be a lock on the exit."""
    keys = (provider_secrets
            + (application_secrets if event == "create" else [])
            + backend_secrets(opts))
    seen: list[str] = []
    for k in keys:
        if k not in seen:
            seen.append(k)
    return [f"required credential is not set: {par_name(k)}"
            for k in seen if missing(opts.get(k))]


def tofu_env(opts: dict, slot: str) -> dict[str, str]:
    if slot == "provider-compute":
        return {"vultr-api-key": "VULTR_API_KEY"}
    if slot == "provider-dns":
        return {"cloudflare-api-token": "CLOUDFLARE_API_TOKEN"}
    if slot == "provider-backend":
        entry = _entry(opts, "provider-backend")
        return entry["tofu_env"] if entry else {}
    return {}
