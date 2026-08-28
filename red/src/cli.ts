// CLI entry: the same verbs as the green launcher, with the logic kept here
// where the test suite reaches it — the copied payload holds none of its own.

import { execCli, findUp, runCli } from "red/cli";
import type { Opts } from "red/workflow";
import * as tools from "./tools.ts";
import { agentNetworkK8sWorkflow } from "./workflow.ts";

export const lifecycleCommands = ["build", "create", "delete"];

export const usage =
  "Usage: red <build|create|delete> [-f|--file colors.yml] [--dry-run]\n" +
  "       red kubectl [-f|--file colors.yml] -- <kubectl args>\n" +
  "       red status  [-f|--file colors.yml]\n" +
  "\n" +
  "  build     render the work directory only — contact nothing\n" +
  "  create    provision and verify the Agent Network demo on VKE\n" +
  "  delete    remove the protected deployment\n" +
  "  kubectl   run kubectl against this deployment's cluster\n" +
  "  status    show cluster, certificate, endpoint and usage health";

// The nearest colors.yml at or above the working directory. Walking up means
// red can be run from any subdirectory of a project and still find the one
// desired state.
function defaultFile(): string {
  return findUp("colors.yml") ?? "colors.yml";
}

function fileArg(arg: string): boolean {
  return arg === "-f" || arg === "--file" || arg.startsWith("--file=");
}

export function defaultArgs(args: string[]): string[] {
  return args.some(fileArg) ? args : [...args, "-f", defaultFile()];
}

// The -f/--file value in args, or the default.
export function explicitFile(args: string[]): string {
  for (let i = 0; i < args.length; i += 1) {
    const arg = String(args[i]);
    if (arg.startsWith("--file=")) return arg.slice(7);
    if (arg === "-f" || arg === "--file") {
      const value = args[i + 1];
      if (value !== undefined) return value;
    }
  }
  return defaultFile();
}

// REPL-friendly entry point that returns the final outcome map.
export async function run(...args: string[]): Promise<Opts> {
  const command = args[0] ?? "";
  if (["help", "--help", "-h"].includes(command)) {
    return { "red/exit": 0, "red/err": usage };
  }
  if (command === "kubectl") {
    // `red kubectl [-f colors.yml] -- <kubectl args>`: everything after
    // the first `--` passes through untouched.
    const rest = args.slice(1);
    const split = rest.indexOf("--");
    const before = split < 0 ? rest : rest.slice(0, split);
    const passthrough = split < 0 ? [] : rest.slice(split + 1);
    return { "red/exit": await tools.kubectlMain(explicitFile(before), passthrough) };
  }
  if (command === "status") {
    return { "red/exit": await tools.statusMain(explicitFile(args.slice(1))) };
  }
  if (lifecycleCommands.includes(command)) {
    return runCli(agentNetworkK8sWorkflow, defaultArgs(args));
  }
  return { "red/exit": 2, "red/err": usage };
}

export async function exec(args: string[] = Bun.argv.slice(2)): Promise<never> {
  if (lifecycleCommands.includes(args[0] ?? "")) {
    return execCli(agentNetworkK8sWorkflow, defaultArgs(args));
  }
  const result = await run(...args);
  if (result["red/err"]) {
    ((result["red/exit"] ?? 0) === 0 ? console.log : console.error)(result["red/err"]);
  }
  return process.exit(result["red/exit"] ?? 0);
}
