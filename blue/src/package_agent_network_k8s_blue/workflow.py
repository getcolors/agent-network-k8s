"""VKE Agent Network lifecycle DAG and package-specific remote-state advice,
the port of io.github.getcolors.agent-network-k8s.workflow."""

from __future__ import annotations

from blue import dry_run, progress, tofu
from blue.cli import par_name, read_pars
from blue.lifecycle import preflight
from blue.workflow import advice_add, workflow

from . import tools, validate

LIFECYCLE_EVENTS = ("create", "delete")

DEFAULTS = {"provider-compute": "vultr",
            "provider-dns": "cloudflare",
            "provider-backend": "local",
            "compute-prevent-destroy": True,
            "workdir": ".colors"}


async def start_step(opts: dict, env: dict | None = None) -> dict:
    return await preflight(
        opts, defaults=DEFAULTS, overlay=read_pars, env=env,
        validators=[
            lambda _o, e, _c: validate.env_errors(e),
            lambda o, _e, _c: validate.state_errors(o),
            lambda o, _e, c: (validate.secret_errors(o, str(c["event"]))
                              if c["real"] and c["event"] in LIFECYCLE_EVENTS else []),
            lambda o, _e, c: ([f"compute destruction is protected; set "
                               f"{par_name('compute-prevent-destroy')}=false to delete"]
                              if c["real"] and c["event"] == "delete"
                              and o.get("compute-prevent-destroy") else []),
        ])


def wire_fn(step: str, run_opts: dict):
    if run_opts.get("blue/event") == "delete":
        # In-cluster teardown first: the CSI volumes and the CCM-created load
        # balancer are Kubernetes-managed and invisible to the infrastructure
        # state, so destroying the cluster before removing them would orphan
        # them in the account. Local access material goes last — the
        # kubeconfig is needed by the teardown and dead only after the
        # destroy.
        return {
            "agent-network-k8s/start": (start_step, "agent-network-k8s/teardown"),
            "agent-network-k8s/teardown": (tools.teardown_step, "agent-network-k8s/dns"),
            "agent-network-k8s/dns": (tools.dns_step, "agent-network-k8s/infrastructure"),
            "agent-network-k8s/infrastructure": (tools.infrastructure_step, "agent-network-k8s/cleanup"),
            "agent-network-k8s/cleanup": (tools.cleanup_step,),
        }.get(step)
    # Create: the cluster first; then the workloads (the edge and the proxy
    # are applied but deliberately not awaited — they mount a TLS Secret
    # that does not exist yet); DNS once the load balancer has an address;
    # the certificate once DNS can answer DNS-01; then the control plane,
    # the two-pod application, and the gates.
    return {
        "agent-network-k8s/start": (start_step, "agent-network-k8s/infrastructure"),
        "agent-network-k8s/infrastructure": (tools.infrastructure_step, "agent-network-k8s/deploy"),
        "agent-network-k8s/deploy": (tools.deploy_step, "agent-network-k8s/dns"),
        "agent-network-k8s/dns": (tools.dns_step, "agent-network-k8s/certificate"),
        "agent-network-k8s/certificate": (tools.certificate_step, "agent-network-k8s/bootstrap"),
        "agent-network-k8s/bootstrap": (tools.bootstrap_step, "agent-network-k8s/agent"),
        "agent-network-k8s/agent": (tools.agent_step, "agent-network-k8s/acceptance"),
        "agent-network-k8s/acceptance": (tools.acceptance_step,),
    }.get(step)


def backend_advice(tool: str):
    return tofu.conventional_backend_advice(
        dir=lambda o, tool=tool: tools.tool_dir(o, tool),
        key=lambda o, tool=tool: f"{'' if o.get('profile') is None else o.get('profile')}/{tool}.tfstate")


side_effecting_steps = [
    "agent-network-k8s/infrastructure", "agent-network-k8s/deploy",
    "agent-network-k8s/dns", "agent-network-k8s/certificate",
    "agent-network-k8s/bootstrap", "agent-network-k8s/agent",
    "agent-network-k8s/acceptance", "agent-network-k8s/teardown",
    "agent-network-k8s/cleanup",
]


def create_workflow():
    wf = workflow(start="agent-network-k8s/start", wire_fn=wire_fn)
    wf = advice_add(wf, "agent-network-k8s/infrastructure", "before",
                    "io.github.getcolors.agent-network-k8s.workflow/backend",
                    backend_advice(tools.infrastructure_tool))
    wf = advice_add(wf, "agent-network-k8s/dns", "before",
                    "io.github.getcolors.agent-network-k8s.workflow/backend",
                    backend_advice(tools.dns_tool))
    wf = progress.advise(wf)
    wf = dry_run.advise(wf, side_effecting_steps)
    return wf


agent_network_k8s_workflow = create_workflow()
