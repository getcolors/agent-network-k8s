"""CLI entry: the same verbs as the green launcher, with the logic kept here
where the test suite reaches it — the copied payload holds none of its own."""

from __future__ import annotations

import asyncio
import sys

from blue.cli import find_up, run_cli

from . import tools
from .workflow import agent_network_k8s_workflow

USAGE = ("Usage: blue <build|create|delete> "
         "[-f|--file colors.yml] [--dry-run]\n"
         "       blue kubectl [-f|--file colors.yml] -- <kubectl args>\n"
         "       blue status  [-f|--file colors.yml]\n"
         "\n"
         "  build     render the work directory only — contact nothing\n"
         "  create    provision and verify the Agent Network demo on VKE\n"
         "  delete    remove the protected deployment\n"
         "  kubectl   run kubectl against this deployment's cluster\n"
         "  status    show cluster, certificate, endpoint and usage health")

LIFECYCLE = ("build", "create", "delete")


def _find() -> str:
    return find_up("colors.yml") or "colors.yml"


def default_args(args: list[str]) -> list[str]:
    if any(a in ("-f", "--file") or str(a).startswith("--file=") for a in args):
        return args
    return [*args, "-f", _find()]


def explicit_file(args: list[str]) -> str:
    """The -f/--file value in args, or the default."""
    for i, arg in enumerate(args):
        text = str(arg)
        if text.startswith("--file="):
            return text[7:]
        if text in ("-f", "--file") and i + 1 < len(args):
            return args[i + 1]
    return _find()


async def run(*args):
    """REPL-friendly entry point that returns the final outcome map."""
    args = list(args)
    command = args[0] if args else None
    if command in ("help", "--help", "-h"):
        return {"blue/exit": 0, "blue/err": USAGE}
    if command == "kubectl":
        # `blue kubectl [-f colors.yml] -- <kubectl args>`: everything after
        # the first `--` passes through untouched.
        rest = args[1:]
        split = rest.index("--") if "--" in rest else -1
        before = rest if split < 0 else rest[:split]
        passthrough = [] if split < 0 else rest[split + 1:]
        return {"blue/exit": tools.kubectl_main(explicit_file(before), passthrough)}
    if command == "status":
        return {"blue/exit": tools.status_main(explicit_file(args[1:]))}
    if command in LIFECYCLE:
        return await run_cli(agent_network_k8s_workflow, default_args(args))
    return {"blue/exit": 2, "blue/err": USAGE}


def exec(args: list[str] | None = None) -> None:
    result = asyncio.run(run(*(sys.argv[1:] if args is None else args)))
    if result.get("blue/err"):
        stream = sys.stdout if (result.get("blue/exit") or 0) == 0 else sys.stderr
        print(result["blue/err"], file=stream)
        if result.get("blue/trace"):
            print(result["blue/trace"], file=stream)
    raise SystemExit(result.get("blue/exit") or 0)
