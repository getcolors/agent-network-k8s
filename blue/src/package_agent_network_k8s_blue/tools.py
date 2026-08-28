"""VKE infrastructure, Cloudflare DNS, and kubectl-driven deploy stages, the
port of io.github.getcolors.agent-network-k8s.tools."""

from __future__ import annotations

import base64
import json
import math
import os
import shutil
import stat as stat_module
import sys
from decimal import Decimal
from pathlib import Path

from blue import tofu
from blue.cli import load_yaml, stage_dir
from blue.process import run_inherit
from blue.runtime import runtime
from blue.scaffold import PRESERVE_JINJA_DELIMITERS, content_spec, scaffold
from blue.workflow import StepError, failed

from . import validate

infrastructure_tool = "agent-network-k8s-infrastructure"
dns_tool = "agent-network-k8s-dns"
deploy_tool = "agent-network-k8s-deploy"

ROOT = Path(__file__).parent / "resources"
template_opts = PRESERVE_JINJA_DELIMITERS


def tool_dir(opts: dict, tool: str) -> str:
    return stage_dir(opts, tool, default_profile="agent-network-k8s")


def template(path: str, file: str) -> dict:
    name = f"tools/{path.replace('.', '/')}/{file}"
    source = ROOT / name
    if not source.is_file():
        raise StepError(f"template not found: {name}")
    return {"name": name, "content": source.read_text()}


def spec(source: dict, target: str, data: dict) -> dict:
    return {"template": source, "target": target, "data": data, "opts": template_opts}


def raw_spec(target: str, content: str) -> dict:
    return content_spec(target, content)


def profile_dir(opts: dict) -> str:
    """The per-profile directory the stage directories live in. The kubeconfig,
    the launcher-side state files, and lego's account state all live here —
    generated, gitignored, and removed by delete."""
    return str(Path(tool_dir(opts, deploy_tool)).parent)


def kubeconfig_path(opts: dict) -> str:
    return str(Path(profile_dir(opts)) / "kubeconfig")


def state_dir(opts: dict) -> str:
    return str(Path(profile_dir(opts)) / "state")


def lego_dir(opts: dict) -> str:
    return str(Path(profile_dir(opts)) / "lego")


def registry_env_path(opts: dict) -> str:
    return str(Path(state_dir(opts)) / "registry.env")


def cidrs(opts: dict, k: str) -> list[str]:
    import re
    v = opts.get(k)
    xs = v if isinstance(v, (list, tuple)) else re.split(r"[,\s]+", str(v))
    return [s for s in (str(x).strip() for x in xs) if s]


def credential_env(opts: dict, *slots: str) -> dict[str, str] | None:
    """Provider and backend environment additions, omitting absent
    credentials."""
    mapping: dict[str, str] = {}
    for slot in [*slots, "provider-backend"]:
        mapping.update(validate.tofu_env(opts, slot))
    env = {env_var: str(opts.get(k))
           for k, env_var in mapping.items()
           if str(opts.get(k) or "")}
    return env or None


def backend_credential_env(opts: dict) -> dict[str, str] | None:
    return credential_env(opts)


def fallback_params(opts: dict) -> dict:
    return {"lb-ip": "192.0.2.10", "name": validate.compute_name(opts)}


# ------------------------------------------------------------ file helpers


def write_private(path: str, content: str) -> None:
    """Write `content` to `path` atomically with owner-only permissions: temp
    file beside the target, chmod, rename. A crash never leaves a half-written
    or world-readable credential."""
    tmp = f"{path}.tmp"
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(tmp, "w") as handle:
        handle.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def sh_quote(s) -> str:
    """Single-quote a value for a sourced shell file: a generated credential is
    data, never syntax."""
    return "'" + str(s).replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- compute


def infrastructure_data(opts: dict) -> dict:
    return {**opts,
            "compute-name": validate.compute_name(opts),
            "registry-name": validate.registry_name(opts)}


async def vke_version_error(opts: dict) -> str | None:
    """Why the pinned VKE version cannot be created, or None. VKE retires old
    minors, so the pin is checked against the live supported list while failing
    is still free — a tofu apply that dies half-way leaves a cluster to clean
    up, this check leaves nothing."""
    result = await runtime.exec(
        ["curl", "-fsS", "-H", f"Authorization: Bearer {opts.get('vultr-api-key')}",
         "https://api.vultr.com/v2/kubernetes/versions"])
    if result.exit != 0:
        return None
    versions = (json.loads(result.out) or {}).get("versions")
    if versions and str(opts.get("vultr-vke-version")) not in versions:
        return (f"vultr-vke-version {opts.get('vultr-vke-version')}"
                f" is not offered by VKE; currently supported: {', '.join(versions)}")
    return None


def output_params(result: dict) -> dict | None:
    outputs = result.get("tofu/outputs") or {}
    return outputs.get("params")


def output_value(result: dict, k: str):
    return (result.get("tofu/outputs") or {}).get(k)


def persist_cluster_access(opts: dict, result: dict) -> None:
    """Write the kubeconfig and the registry credentials where the converge
    scripts read them: private files under the profile directory, never in a
    rendered template, never in a golden."""
    kc = str(output_value(result, "kubeconfig-b64") or "")
    if kc:
        write_private(kubeconfig_path(opts),
                      base64.b64decode(kc).decode("utf-8"))
    urn = str(output_value(result, "registry-urn") or "")
    user = str(output_value(result, "registry-username") or "")
    password = str(output_value(result, "registry-password") or "")
    if urn and user:
        write_private(registry_env_path(opts),
                      f"REGISTRY_URN={sh_quote(urn)}\n"
                      f"REGISTRY_USER={sh_quote(user)}\n"
                      f"REGISTRY_PASS={sh_quote(password)}\n")


async def infrastructure_step(opts: dict) -> dict:
    dir = tool_dir(opts, infrastructure_tool)
    specs = [spec(template("infrastructure", "main.tf"), f"{dir}/main.tf",
                  infrastructure_data(opts))]
    version_err = None
    if opts.get("blue/event") == "create" and not opts.get("blue/dry-run"):
        version_err = await vke_version_error(opts)
    if version_err:
        return {**opts, "blue/exit": 1, "blue/err": version_err}
    result = await tofu.tofu_with_spec(opts, specs, dir=dir,
                                       env=credential_env(opts, "provider-compute"))
    if failed(result):
        return result
    if opts.get("blue/event") == "build":
        return {**result, **fallback_params(opts)}
    if opts.get("blue/event") == "delete":
        return result
    persist_cluster_access(opts, result)
    return {**result, **fallback_params(opts), **(output_params(result) or {})}


# -------------------------------------------------------------------- dns


def dns_json(opts: dict) -> str:
    """The base record and its wildcard, both unproxied: Cloudflare's proxy
    would terminate TLS in front of an edge whose certificate this deployment
    issues itself, and the wildcard is contract, not convenience — the
    agent-network endpoint is a label management mints beneath the base domain
    at bootstrap, and nothing knows that label before it exists."""
    return tofu.constructs_json([
        tofu.construct("resource", "cloudflare_dns_record", "agent_network_k8s", {
            "zone_id": "${data.cloudflare_zone.zone.id}",
            "name": opts.get("agent-network-host"), "content": opts.get("lb-ip"),
            "type": "A", "proxied": False, "ttl": 60,
        }),
        tofu.construct("resource", "cloudflare_dns_record", "agent_network_k8s_wildcard", {
            "zone_id": "${data.cloudflare_zone.zone.id}",
            "name": f"*.{opts.get('agent-network-host')}",
            "content": opts.get("lb-ip"),
            "type": "A", "proxied": False, "ttl": 60,
        }),
    ])


async def dns_step(opts: dict) -> dict:
    dir = tool_dir(opts, dns_tool)
    data = {**opts,
            "lb-ip": opts.get("lb-ip") or fallback_params(opts)["lb-ip"],
            "agent-network-zone": validate.zone(opts)}
    specs = [spec(template("dns", "main.tf"), f"{dir}/main.tf", data),
             raw_spec(f"{dir}/record.tf.json", dns_json(data))]
    return await tofu.tofu_with_spec(opts, specs, dir=dir,
                                     env=credential_env(opts, "provider-dns"))


# ------------------------------------------------------------------ deploy


def _java_double(x: float) -> str:
    """Java's Double.toString, which is what Green's cheshire JSON emits for
    floats: decimal between 1e-3 and 1e7, `d.dddE±e` scientific outside it.
    Python's own repr disagrees exactly where scientific notation starts
    (0.0001 -> "1.0E-4"), and the goldens carry the Java form."""
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    negative = math.copysign(1.0, x) < 0
    magnitude = abs(x)
    if magnitude == 0.0:
        return "-0.0" if negative else "0.0"
    _sign, digits, exponent = Decimal(repr(magnitude)).as_tuple()
    digit_str = "".join(map(str, digits)).rstrip("0") or "0"
    dec_exp = exponent + len(digits) - 1
    if -3 <= dec_exp < 7:
        if dec_exp >= 0:
            whole = digit_str[:dec_exp + 1].ljust(dec_exp + 1, "0")
            frac = digit_str[dec_exp + 1:] or "0"
        else:
            whole = "0"
            frac = "0" * (-dec_exp - 1) + digit_str
        rendered = f"{whole}.{frac}"
    else:
        mantissa = digit_str[0] + "." + (digit_str[1:] or "0")
        rendered = f"{mantissa}E{dec_exp}"
    return ("-" if negative else "") + rendered


def _pretty(value, indent=0):
    """Cheshire's pretty JSON, byte for byte — Green's artifact contract."""
    if isinstance(value, (list, tuple)):
        if not value:
            return "[ ]"
        return "[ " + ", ".join(_pretty(item, indent) for item in value) + " ]"
    if isinstance(value, dict):
        if not value:
            return "{ }"
        pad = " " * (indent + 2)
        body = ",\n".join(f"{pad}{json.dumps(str(k))} : {_pretty(v, indent + 2)}"
                          for k, v in value.items())
        return "{\n" + body + "\n" + " " * indent + "}"
    if isinstance(value, float) and not isinstance(value, bool):
        return _java_double(value)
    return json.dumps(value)


def inventory(opts: dict) -> str:
    """Non-secret run facts the scripts read as JSON — the k8s analog of the
    parent's Ansible inventory."""
    return _pretty({
        "host": opts.get("agent-network-host"),
        "profile": opts.get("profile"),
        "compute_name": validate.compute_name(opts),
    })


def desired_json(opts: dict) -> str:
    """The control plane's desired state, one JSON document the bootstrap
    reconciles against. Everything in it is non-secret — the Anthropic key
    reaches the bootstrap as an environment variable resolved at run time and
    never lands in a rendered file."""
    models = []
    for m in validate.provider_models(opts):
        model = {"id": str(m.get("id")),
                 "input_per_1k": m.get("input-per-1k"),
                 "output_per_1k": m.get("output-per-1k")}
        if m.get("cache-read-per-1k") is not None:
            model["cache_read_per_1k"] = m.get("cache-read-per-1k")
        if m.get("cache-creation-per-1k") is not None:
            model["cache_creation_per_1k"] = m.get("cache-creation-per-1k")
        models.append(model)
    return _pretty({
        "host": opts.get("agent-network-host"),
        "admin_email": opts.get("agent-network-admin-email"),
        "admin_name": opts.get("agent-network-admin-name"),
        "provider": {
            # The catalog id, from GET /api/agent-network/catalog/providers on
            # the pinned release — "anthropic" alone is a 422.
            "provider_id": "anthropic_api",
            "name": "Anthropic",
            "upstream_url": "https://api.anthropic.com",
            "models": models,
        },
        "allowed_models": validate.allowed_models(opts),
        "policy": {
            "budget_usd_per_day": opts.get("agent-network-policy-budget-usd-per-day"),
            "tokens_per_day": opts.get("agent-network-policy-tokens-per-day"),
        },
        "global": {
            "budget_usd_per_day": opts.get("agent-network-global-budget-usd-per-day"),
            "tokens_per_day": opts.get("agent-network-global-tokens-per-day"),
        },
        "log_retention_days": opts.get("agent-network-log-retention-days"),
    })


def deploy_data(opts: dict) -> dict:
    """Template values for every deploy-stage file. Deliberately carries no
    operator secret: the Anthropic key, the Cloudflare token and the registry
    credentials reach the scripts through the process environment or private
    state files, so nothing in .colors/ or a golden ever holds one."""
    return {**opts,
            "allowed-model": validate.allowed_model(opts),
            "denied-claimed-model": validate.denied_claimed_model(opts),
            # The escaped base domain for Traefik's HostSNIRegexp: only
            # endpoint subdomains ride the TCP passthrough, never the bare
            # base name (TCP routers outrank HTTP routers in Traefik).
            "host-regex": str(opts.get("agent-network-host")).replace(".", "\\.")}


# Rendered scripts and manifests, one entry per file: [subpath template-dir].
deploy_files = [
    ["converge.sh", "deploy"],
    ["certificate.sh", "deploy"],
    ["bootstrap.sh", "deploy"],
    ["agent.sh", "deploy"],
    ["smoke.sh", "deploy"],
    ["disrupt.sh", "deploy"],
    ["status.sh", "deploy"],
    ["teardown.sh", "deploy"],
    ["netbird-config.yaml", "deploy"],
    ["traefik-dynamic.yaml", "deploy"],
    ["manifests/namespaces.yaml", "deploy.manifests"],
    ["manifests/traefik.yaml", "deploy.manifests"],
    ["manifests/netbird-server.yaml", "deploy.manifests"],
    ["manifests/dashboard.yaml", "deploy.manifests"],
    ["manifests/proxy.yaml", "deploy.manifests"],
    ["manifests/netbird-client.yaml", "deploy.manifests"],
    ["manifests/agent-primary.yaml", "deploy.manifests"],
    ["manifests/agent-fallback.yaml", "deploy.manifests"],
    ["manifests/networkpolicies.yaml", "deploy.manifests"],
    ["manifests/build-job.yaml", "deploy.manifests"],
    ["agent-image/Dockerfile", "deploy.agent-image"],
    ["agent-image/package.json", "deploy.agent-image"],
    ["agent-image/package-lock.json", "deploy.agent-image"],
    ["agent-image/bridge-entry.sh", "deploy.agent-image"],
    ["agent-image/privoxy.config", "deploy.agent-image"],
    ["socks-entry.sh", "deploy"],
]


def deploy_specs(opts: dict) -> list[dict]:
    dir = tool_dir(opts, deploy_tool)
    data = deploy_data(opts)
    return ([spec(template(tdir, Path(subpath).name), f"{dir}/{subpath}", data)
             for subpath, tdir in deploy_files]
            + [raw_spec(f"{dir}/desired.json", desired_json(data)),
               raw_spec(f"{dir}/inventory.json", inventory(data))])


def kubeconfig_error(opts: dict) -> str | None:
    """Why the profile's kubeconfig must not be used, or None: a bearer
    credential that is a symlink, not a regular file, group/world-readable, or
    owned by someone else is not this deployment's to wield. Called on every
    execution path that wields it — workflow scripts, status, and the kubectl
    verb."""
    path = Path(kubeconfig_path(opts))
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink():
        return f"kubeconfig at {path} is a symlink"
    info = path.lstat()
    if not stat_module.S_ISREG(info.st_mode):
        return f"kubeconfig at {path} is not a regular file"
    uid = os.getuid()
    if info.st_uid != uid:
        return f"kubeconfig at {path} is owned by uid {info.st_uid}, not uid {uid}"
    if info.st_mode & 0o066:
        return f"kubeconfig at {path} is not owner-only; chmod 600 it"
    return None


def run_script(opts: dict, script: str, *args: str) -> dict:
    """Run one rendered deploy script with the caller's terminal attached. The
    scripts read run facts from their environment (paths only — secrets stay in
    the inherited COLORS_PAR_* variables and private state files, never
    argv)."""
    err = kubeconfig_error(opts)
    if err:
        raise StepError(err)
    dir = tool_dir(opts, deploy_tool)
    argv = ["env",
            f"KUBECONFIG={kubeconfig_path(opts)}",
            f"STATE_DIR={state_dir(opts)}",
            f"DEPLOY_DIR={dir}",
            f"LEGO_DIR={lego_dir(opts)}",
            "bash", f"{dir}/{script}",
            *args]
    result = run_inherit(argv)
    exit_code = result.exit if result.exit is not None else 1
    if exit_code == 0:
        return {**opts, "blue/exit": 0}
    return {**opts, "blue/exit": exit_code,
            "blue/err": result.err or f"{script} exited {exit_code}"}


def script_step(opts: dict, script: str, *args: str) -> dict:
    """Scaffold the deploy tree, then on a real create run `script`. Build
    renders and stops; delete is handled by `teardown_step`, not here."""
    rendered = {**scaffold({**opts, "blue/event": "create"}, deploy_specs(opts)),
                "blue/event": opts.get("blue/event")}
    if opts.get("blue/event") != "create":
        return {**rendered, "blue/exit": 0}
    return run_script(rendered, script, *args)


def read_state_file(opts: dict, name: str) -> str | None:
    path = Path(state_dir(opts)) / name
    if not path.exists():
        return None
    return path.read_text().strip()


async def deploy_step(opts: dict) -> dict:
    """Phase one of convergence: namespaces, create-once secrets, the
    in-cluster agent-image build, the gateway workloads, the proxy token, and
    the load balancer. Ends knowing the LB address, which the dns stage
    publishes."""
    result = script_step(opts, "converge.sh")
    if failed(result):
        return result
    if opts.get("blue/event") != "create":
        return result
    ip = read_state_file(opts, "lb-ip")
    if ip:
        return {**result, "lb-ip": ip}
    return {**result, "blue/exit": 1,
            "blue/err": "converge recorded no load-balancer address"}


async def certificate_step(opts: dict) -> dict:
    """Issue or renew the wildcard pair (both SANs: the base name and *.base —
    a wildcard alone does not cover the bare base name) launcher-side via
    DNS-01, apply it as the TLS Secret, then wait for the edge and the proxy,
    whose readiness was deliberately not awaited before the Secret existed."""
    return script_step(opts, "certificate.sh")


async def bootstrap_step(opts: dict) -> dict:
    return script_step(opts, "bootstrap.sh")


async def agent_step(opts: dict) -> dict:
    return script_step(opts, "agent.sh")


async def acceptance_step(opts: dict) -> dict:
    result = script_step(opts, "smoke.sh")
    if failed(result) or opts.get("blue/event") != "create":
        return result
    return {**result,
            "agent-network-k8s/acceptance": {
                "endpoint": read_state_file(opts, "endpoint"),
                "isolation": "probed",
                "tunnel-only": "confirmed",
            }}


async def teardown_step(opts: dict) -> dict:
    """Ordered in-cluster teardown before the infrastructure destroy:
    workloads, PVCs (waiting for the CSI volumes to leave the account), then
    the LB Service (waiting for the LB to leave the account). Skips cleanly
    when the cluster is already gone or was never created."""
    rendered = {**scaffold({**opts, "blue/event": "create"}, deploy_specs(opts)),
                "blue/event": "delete"}
    if not Path(kubeconfig_path(opts)).exists():
        return {**rendered, "blue/exit": 0}
    result = run_script(rendered, "teardown.sh")
    # A cluster that stopped answering must not block the destroy that
    # removes it: teardown is best-effort, the tofu destroy is the
    # authority.
    return {**result, "blue/exit": 0}


async def cleanup_step(opts: dict) -> dict:
    """Remove the local per-profile access material after the infrastructure
    is gone: the kubeconfig is a dead bearer credential, the state files
    describe a cluster that no longer exists."""
    if opts.get("blue/event") == "delete":
        kc = Path(kubeconfig_path(opts))
        if kc.exists():
            kc.unlink()
        for dir in (Path(state_dir(opts)), Path(profile_dir(opts)) / "proofs"):
            if dir.exists():
                shutil.rmtree(dir, ignore_errors=True)
    return {**opts, "blue/exit": 0}


# ------------------------------------------------------------- kubectl verb


def _read_state(state_file: str) -> dict:
    with open(state_file) as handle:
        state = load_yaml(handle.read()) or {}
    return {**state, "blue/state-file": state_file}


def status_main(state_file: str) -> int:
    """The launcher's status verb: render nothing, run the already-rendered
    status script against the live cluster. Returns the exit code."""
    opts = _read_state(state_file)
    dir = tool_dir(opts, deploy_tool)
    script = Path(dir) / "status.sh"
    if not script.exists():
        print(f"no rendered status script at {script}; run build first",
              file=sys.stderr)
        return 2
    err = kubeconfig_error(opts)
    if err:
        print(err, file=sys.stderr)
        return 2
    result = run_inherit(
        ["env", f"KUBECONFIG={kubeconfig_path(opts)}",
         f"STATE_DIR={state_dir(opts)}",
         f"DEPLOY_DIR={dir}",
         "bash", str(script)])
    return result.exit


def kubectl_main(state_file: str, args: list[str]) -> int:
    """The launcher's kubectl passthrough: run kubectl against this
    deployment's cluster with the profile's kubeconfig. Returns the exit
    code."""
    opts = _read_state(state_file)
    kc = kubeconfig_path(opts)
    if not Path(kc).exists():
        print(f"no kubeconfig at {kc}; run create first", file=sys.stderr)
        return 2
    err = kubeconfig_error(opts)
    if err:
        print(err, file=sys.stderr)
        return 2
    result = run_inherit(["env", f"KUBECONFIG={kc}", "kubectl", *args])
    return result.exit
