"""The port of green's validate-test."""

from package_agent_network_k8s_blue import validate


def test_fixture_is_valid(fixture):
    assert validate.state_errors(fixture) == []


def test_required_keys_are_enforced(fixture):
    for k in validate.required:
        opts = {key: value for key, value in fixture.items() if key != k}
        errors = validate.state_errors(opts)
        assert any(f":{k}" in e for e in errors), f"{k} missing must be reported"


def test_env_guard():
    assert validate.env_errors({}) == []
    assert validate.env_errors({"COLORS_PAR_PROFILE": "other"})


def test_image_pins(fixture):
    # A floating tag is refused.
    for bad in ("netbirdio/netbird:latest", "netbirdio/netbird:main",
                "netbirdio/netbird:latest@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451"):
        assert validate.state_errors({**fixture, "agent-network-client-image": bad}), bad
    # A bare repository means :latest by implication and is refused.
    assert validate.state_errors({**fixture, "agent-network-client-image": "netbirdio/netbird"})


def test_model_shape(fixture):
    # The allowlist must be claimed.
    assert validate.model_errors({**fixture, "agent-network-allowed-models": ["not-claimed"]})
    # At least one claimed model must sit outside the allowlist.
    assert validate.model_errors(
        {**fixture,
         "agent-network-allowed-models": ["claude-haiku-4-5-20251001",
                                          "claude-sonnet-4-5-20250929"]})
    # The denial probe's negative case is derivable.
    assert validate.denied_claimed_model(fixture) == "claude-sonnet-4-5-20250929"
    assert validate.allowed_model(fixture) == "claude-haiku-4-5-20251001"


def test_budget_ceilings(fixture):
    assert validate.state_errors({**fixture, "agent-network-policy-budget-usd-per-day": 50})
    assert validate.state_errors({**fixture, "agent-network-policy-tokens-per-day": 99999999})


def test_vke_version_shape(fixture):
    assert validate.state_errors({**fixture, "vultr-vke-version": "v1.34.0+3"}) == []
    for bad in ("1.35.2+1", "v1.35.2", "v1.35+1", "latest"):
        assert validate.state_errors({**fixture, "vultr-vke-version": bad}), bad


def test_naming(fixture):
    # The compute name defaults to the profile (Compute Name Standard).
    assert validate.compute_name(fixture) == "agent-network-k8s-fixture"
    assert validate.compute_name({**fixture, "vultr-name": "custom"}) == "custom"
    assert validate.compute_name({**fixture, "vultr-name": "REPLACE_ME"}) == "agent-network-k8s-fixture"
    # The registry name is the compute name reduced to what Vultr accepts.
    assert validate.registry_name(fixture) == "agentnetworkk8sfixture"


def test_zone_derivation(fixture):
    assert validate.zone(fixture) == "example.com"


def test_secret_requirements(fixture):
    # Create needs the providers, the backend and the Anthropic key.
    errors = validate.secret_errors({**fixture, "provider-backend": "r2"}, "create")
    for v in ("COLORS_PAR_VULTR_API_KEY", "COLORS_PAR_CLOUDFLARE_API_TOKEN",
              "COLORS_PAR_ANTHROPIC_API_KEY", "COLORS_PAR_R2_ACCESS_KEY_ID"):
        assert any(v in e for e in errors), v
    # Delete never demands the Anthropic key.
    errors = validate.secret_errors(fixture, "delete")
    assert not any("ANTHROPIC" in e for e in errors)


def test_gost_pin_shape(fixture):
    assert validate.state_errors({**fixture, "agent-network-gost-sha256": "abc"})
    assert validate.state_errors({**fixture, "agent-network-gost-version": "3.2"})
