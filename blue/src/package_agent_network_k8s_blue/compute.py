"""Managed compute adapter; application registry and manifests stay in the package."""
import json
from pathlib import Path
from colors_compute.managed import managed_kubernetes, plan_managed_kubernetes, read_managed_kubernetes


def request(opts):
    return {'legacy_state_keys': [opts['profile'] + '/agent-network-k8s-infrastructure.tfstate']}


def attach(opts, result):
    if result.get('status') not in ('planned', 'ready', 'present', 'destroyed'):
        return {**opts, 'blue/exit': 1, 'blue/err': '\n'.join(result.get('errors', [])) or 'managed compute lifecycle refused'}
    params = result.get('params', {})
    return {**opts, 'blue/exit': 0, 'colors-compute/managed': params,
            **({'name': params['name'], 'cluster-id': params['cluster_id'], 'endpoint': params['endpoint']} if params else {})}


async def infrastructure_step(opts):
    planning = opts.get('blue/event') == 'build' or opts.get('blue/dry-run')
    try:
        result = plan_managed_kubernetes(opts, request(opts)) if planning else await managed_kubernetes(opts, request(opts))
        if planning:
            directory = Path(opts['workdir']) / opts['profile'] / 'compute' / 'managed-kubernetes'
            directory.mkdir(parents=True, exist_ok=True)
            for name, value in result['documents'].items():
                (directory / name).write_text(json.dumps(value, sort_keys=True, indent=2) + '\n')
        return attach(opts, result)
    except Exception:
        return {**opts, 'blue/exit': 1, 'blue/err': 'invalid managed compute requirements'}


async def load_step(opts):
    if opts.get('blue/event') == 'build' or opts.get('blue/dry-run'):
        return opts
    result = await read_managed_kubernetes(opts, request(opts))
    if result.get('status') == 'destroyed':
        return {**opts, 'blue/exit': 0, 'managed/already-destroyed': True}
    return attach(opts, result)
