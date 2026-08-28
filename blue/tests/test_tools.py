"""The port of green's tools-test: the three colours assert the same
behaviour over the same fixture."""

import json
import re
import tempfile
import time
from pathlib import Path

from blue.scaffold import scaffold

from package_agent_network_k8s_blue import tools


def test_dns_records(fixture):
    doc = json.loads(tools.dns_json({**fixture, "lb-ip": "203.0.113.9"}))
    records = doc["resource"]["cloudflare_dns_record"]
    base = records["agent_network_k8s"]
    wild = records["agent_network_k8s_wildcard"]
    assert base["name"] == "agent-network-k8s.example.com"
    assert wild["name"] == "*.agent-network-k8s.example.com"
    assert base["content"] == wild["content"] == "203.0.113.9"
    assert base["proxied"] is False and wild["proxied"] is False


def test_desired_document(fixture):
    doc = json.loads(tools.desired_json(fixture))
    # The catalog provider id, not the bare name (422 otherwise).
    assert doc["provider"]["provider_id"] == "anthropic_api"
    # Two claimed models, one allowed — both denial classes derivable.
    assert len(doc["provider"]["models"]) == 2
    assert doc["allowed_models"] == ["claude-haiku-4-5-20251001"]
    # Caps and retention travel.
    assert doc["policy"]["budget_usd_per_day"] == 2
    assert doc["global"]["tokens_per_day"] == 5000000
    assert doc["log_retention_days"] == 7
    # No secret has any business here.
    assert "api_key" not in tools.desired_json(fixture)


def test_deploy_rendering(fixture):
    opts = {**fixture,
            "workdir": f"{tempfile.gettempdir()}/an-k8s-test-{time.time_ns()}"}
    specs = tools.deploy_specs(opts)
    rendered = scaffold({**opts, "blue/event": "create"}, specs)
    written = rendered["blue.scaffold/written"]

    def slurp_target(suffix):
        return Path(next(p for p in written if p.endswith(suffix))).read_text()

    # Every deploy file renders.
    assert len(written) == len(tools.deploy_files) + 2
    # The host reaches the scripts and manifests.
    assert "agent-network-k8s.example.com" in slurp_target("bootstrap.sh")
    assert "NB_PROXY_DOMAIN" in slurp_target("manifests/proxy.yaml")
    dyn = slurp_target("traefik-dynamic.yaml")
    # The passthrough matches subdomains only, never the bare base name.
    assert "HostSNIRegexp(`^[a-z0-9-]+\\.agent-network-k8s\\.example\\.com$`)" in dyn
    # No router may carry the catch-all rule (the comment may name it).
    assert not re.search(r"rule:.*HostSNI\(`\*`\)", dyn)
    # Every model knob is pinned in both agent variants.
    for variant in ("manifests/agent-primary.yaml", "manifests/agent-fallback.yaml"):
        content = slurp_target(variant)
        for knob in ("ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                     "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                     "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"):
            assert knob in content, f"{variant} {knob}"
        assert "claude-haiku-4-5-20251001" in content
    # The agent pod mounts no ServiceAccount token.
    assert "automountServiceAccountToken: false" in slurp_target("manifests/agent-primary.yaml")
    # The client entry is state-aware: reconnect without a key.
    entry = slurp_target("socks-entry.sh")
    assert "reconnecting without a key" in entry
    assert "--setup-key-file" in entry
    # The one-off key never becomes a Kubernetes Secret.
    bootstrap = slurp_target("bootstrap.sh")
    assert "/dev/shm" in bootstrap
    assert not re.search(r"create secret.*setup", bootstrap)


def test_per_profile_paths(fixture):
    assert tools.kubeconfig_path(fixture).endswith("agent-network-k8s-fixture/kubeconfig")
    assert tools.state_dir(fixture).endswith("agent-network-k8s-fixture/state")


def test_cidr_splitting():
    assert tools.cidrs({"vultr-http-sources": ["1.2.3.0/24", "5.6.7.0/24"]},
                       "vultr-http-sources") == ["1.2.3.0/24", "5.6.7.0/24"]
    assert tools.cidrs({"vultr-http-sources": "1.2.3.0/24"},
                       "vultr-http-sources") == ["1.2.3.0/24"]
