"""The port of green's workflow-test."""

from package_agent_network_k8s_blue.workflow import (side_effecting_steps,
                                                     start_step, wire_fn)


def chain(event):
    steps = []
    step = "agent-network-k8s/start"
    while True:
        decl = wire_fn(step, {"blue/event": event})
        if not decl or len(decl) < 2:
            return steps
        steps.append(decl[1])
        step = decl[1]


def test_create_ordering():
    # cluster → workloads → dns → certificate → bootstrap → agent → gates
    assert chain("create") == [
        "agent-network-k8s/infrastructure", "agent-network-k8s/deploy",
        "agent-network-k8s/dns", "agent-network-k8s/certificate",
        "agent-network-k8s/bootstrap", "agent-network-k8s/agent",
        "agent-network-k8s/acceptance",
    ]


def test_delete_ordering():
    # In-cluster teardown precedes the infrastructure destroy; local access
    # material goes last.
    assert chain("delete") == [
        "agent-network-k8s/teardown", "agent-network-k8s/dns",
        "agent-network-k8s/infrastructure", "agent-network-k8s/cleanup",
    ]


def test_every_side_effecting_step_is_dry_runnable():
    wired = set(chain("create")) | set(chain("delete"))
    for step in wired:
        assert step in side_effecting_steps, step


async def test_start_validates(fixture):
    # A valid fixture passes.
    out = await start_step({**fixture, "blue/event": "build"}, {})
    assert out["blue/exit"] == 0
    # Missing desired state aggregates every error at exit 2.
    opts = {k: v for k, v in fixture.items()
            if k not in ("agent-network-host", "vultr-vke-version")}
    out = await start_step({**opts, "blue/event": "build"}, {})
    assert out["blue/exit"] == 2
    assert ":agent-network-host" in str(out.get("blue/err"))
    assert ":vultr-vke-version" in str(out.get("blue/err"))
    # The profile guard refuses the overlay.
    out = await start_step({**fixture, "blue/event": "build"},
                           {"COLORS_PAR_PROFILE": "other"})
    assert out["blue/exit"] == 2
    # A real delete is refused while the guard stands.
    out = await start_step({**fixture, "blue/event": "delete",
                            "vultr-api-key": "x", "cloudflare-api-token": "x"}, {})
    assert out["blue/exit"] == 2
    assert "COLORS_PAR_COMPUTE_PREVENT_DESTROY" in str(out.get("blue/err"))
