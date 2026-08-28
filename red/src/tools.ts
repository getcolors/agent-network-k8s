// VKE infrastructure, Cloudflare DNS, and kubectl-driven deploy stages, the
// port of io.github.getcolors.agent-network-k8s.tools.

import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { stageDir } from "red/cli";
import { runInherit } from "red/process";
import { PRESERVE_JINJA_DELIMITERS, contentSpec, scaffold, type Spec, type Template } from "red/scaffold";
import * as tofu from "red/tofu";
import { runtime } from "red/runtime";
import type { Opts } from "red/workflow";
import { StepError, failed } from "red/workflow";
import * as validate from "./validate.ts";

export const infrastructureTool = "agent-network-k8s-infrastructure";
export const dnsTool = "agent-network-k8s-dns";
export const deployTool = "agent-network-k8s-deploy";
export const templateOpts = PRESERVE_JINJA_DELIMITERS;

const RESOURCES = join(import.meta.dir, "..", "resources");

export function toolDir(opts: Opts, tool: string): string {
  return stageDir(opts, tool, { defaultProfile: "agent-network-k8s" });
}

// The template tree this colour carries, keyed the way green names its
// classpath resources: "<path>/<file>" with dots as directories. The tree is
// a byte-for-byte copy of green's; parity diffs the copies.
export function template(path: string, file: string): Template {
  const name = `tools/${path.replaceAll(".", "/")}/${file}`;
  const source = join(RESOURCES, name);
  if (!existsSync(source)) throw new StepError(`template not found: ${name}`);
  return { name, content: readFileSync(source, "utf8") };
}

function spec(source: Template, target: string, data: Opts): Spec {
  return { template: source, target, data, opts: templateOpts };
}

const rawSpec = (target: string, content: string): Spec => contentSpec(target, content);

// The per-profile directory the stage directories live in. The kubeconfig,
// the launcher-side state files, and lego's account state all live here —
// generated, gitignored, and removed by delete.
export function profileDir(opts: Opts): string {
  return dirname(toolDir(opts, deployTool));
}

export function kubeconfigPath(opts: Opts): string {
  return join(profileDir(opts), "kubeconfig");
}

export function stateDir(opts: Opts): string {
  return join(profileDir(opts), "state");
}

export function legoDir(opts: Opts): string {
  return join(profileDir(opts), "lego");
}

export function registryEnvPath(opts: Opts): string {
  return join(stateDir(opts), "registry.env");
}

export function cidrs(opts: Opts, k: string): string[] {
  const v = opts[k];
  const xs = Array.isArray(v) ? v : String(v).split(/[,\s]+/);
  return xs.map((x) => String(x).trim()).filter((x) => x.length > 0);
}

// Provider and backend environment additions, omitting absent credentials.
export function credentialEnv(opts: Opts, ...slots: string[]): Record<string, string> | undefined {
  const mapping: Record<string, string> = Object.assign(
    {}, ...[...slots, "provider-backend"].map((slot) => validate.tofuEnv(opts, slot)));
  const env: Record<string, string> = {};
  for (const [k, envVar] of Object.entries(mapping)) {
    const v = String(opts[k] ?? "");
    if (v.length > 0) env[envVar] = v;
  }
  return Object.keys(env).length > 0 ? env : undefined;
}

export function backendCredentialEnv(opts: Opts): Record<string, string> | undefined {
  return credentialEnv(opts);
}

export function fallbackParams(opts: Opts): Opts {
  return { "lb-ip": "192.0.2.10", name: validate.computeName(opts) };
}

// ------------------------------------------------------------ file helpers

// Write `content` to `path` atomically with owner-only permissions: temp file
// beside the target, chmod, rename. A crash never leaves a half-written or
// world-readable credential.
export function writePrivate(path: string, content: string): void {
  const tmp = `${path}.tmp`;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(tmp, content);
  chmodSync(tmp, 0o600);
  renameSync(tmp, path);
}

// Single-quote a value for a sourced shell file: a generated credential is
// data, never syntax.
export function shQuote(s: unknown): string {
  return `'${String(s).replaceAll("'", "'\\''")}'`;
}

// ---------------------------------------------------------------- compute

export function infrastructureData(opts: Opts): Opts {
  return {
    ...opts,
    "compute-name": validate.computeName(opts),
    "registry-name": validate.registryName(opts),
  };
}

// Why the pinned VKE version cannot be created, or undefined. VKE retires old
// minors, so the pin is checked against the live supported list while failing
// is still free — a tofu apply that dies half-way leaves a cluster to clean
// up, this check leaves nothing.
export async function vkeVersionError(opts: Opts): Promise<string | undefined> {
  const { exit, out } = await runtime.exec(
    ["curl", "-fsS", "-H", `Authorization: Bearer ${opts["vultr-api-key"]}`,
     "https://api.vultr.com/v2/kubernetes/versions"]);
  if (exit !== 0) return undefined;
  const versions = (JSON.parse(out) as { versions?: string[] }).versions;
  if (Array.isArray(versions) && versions.length > 0 &&
      !versions.includes(String(opts["vultr-vke-version"]))) {
    return `vultr-vke-version ${opts["vultr-vke-version"]}` +
      ` is not offered by VKE; currently supported: ${versions.join(", ")}`;
  }
  return undefined;
}

export function outputParams(result: Opts): Opts | undefined {
  const outputs = result["tofu/outputs"] as Record<string, unknown> | undefined;
  return outputs?.params as Opts | undefined;
}

export function outputValue(result: Opts, k: string): unknown {
  return (result["tofu/outputs"] as Record<string, unknown> | undefined)?.[k];
}

// Write the kubeconfig and the registry credentials where the converge
// scripts read them: private files under the profile directory, never in a
// rendered template, never in a golden.
export function persistClusterAccess(opts: Opts, result: Opts): void {
  const kc = String(outputValue(result, "kubeconfig-b64") ?? "");
  if (kc.length > 0) {
    writePrivate(kubeconfigPath(opts), Buffer.from(kc, "base64").toString("utf8"));
  }
  const urn = String(outputValue(result, "registry-urn") ?? "");
  const user = String(outputValue(result, "registry-username") ?? "");
  const pass = String(outputValue(result, "registry-password") ?? "");
  if (urn.length > 0 && user.length > 0) {
    writePrivate(registryEnvPath(opts),
                 `REGISTRY_URN=${shQuote(urn)}\n` +
                 `REGISTRY_USER=${shQuote(user)}\n` +
                 `REGISTRY_PASS=${shQuote(pass)}\n`);
  }
}

export async function infrastructureStep(opts: Opts): Promise<Opts> {
  const dir = toolDir(opts, infrastructureTool);
  const specs = [spec(template("infrastructure", "main.tf"), `${dir}/main.tf`,
                      infrastructureData(opts))];
  const versionErr = opts["red/event"] === "create" && !opts["red/dry-run"]
    ? await vkeVersionError(opts)
    : undefined;
  if (versionErr) return { ...opts, "red/exit": 1, "red/err": versionErr };
  const result = await tofu.tofuWithSpec(opts, specs, {
    dir, env: credentialEnv(opts, "provider-compute"),
  });
  if (failed(result)) return result;
  if (opts["red/event"] === "build") return { ...result, ...fallbackParams(opts) };
  if (opts["red/event"] === "delete") return result;
  persistClusterAccess(opts, result);
  return { ...result, ...fallbackParams(opts), ...(outputParams(result) ?? {}) };
}

// -------------------------------------------------------------------- dns

// The base record and its wildcard, both unproxied: Cloudflare's proxy would
// terminate TLS in front of an edge whose certificate this deployment issues
// itself, and the wildcard is contract, not convenience — the agent-network
// endpoint is a label management mints beneath the base domain at bootstrap,
// and nothing knows that label before it exists.
export function dnsJson(opts: Opts): string {
  return tofu.constructsJson([
    tofu.construct("resource", "cloudflare_dns_record", "agent_network_k8s", {
      zone_id: "${data.cloudflare_zone.zone.id}",
      name: opts["agent-network-host"], content: opts["lb-ip"], type: "A",
      proxied: false, ttl: 60,
    }),
    tofu.construct("resource", "cloudflare_dns_record", "agent_network_k8s_wildcard", {
      zone_id: "${data.cloudflare_zone.zone.id}",
      name: `*.${opts["agent-network-host"]}`, content: opts["lb-ip"],
      type: "A", proxied: false, ttl: 60,
    }),
  ]);
}

export async function dnsStep(opts: Opts): Promise<Opts> {
  const dir = toolDir(opts, dnsTool);
  const data: Opts = {
    ...opts,
    "lb-ip": opts["lb-ip"] ?? fallbackParams(opts)["lb-ip"],
    "agent-network-zone": validate.zone(opts),
  };
  const specs = [spec(template("dns", "main.tf"), `${dir}/main.tf`, data),
                 rawSpec(`${dir}/record.tf.json`, dnsJson(data))];
  return tofu.tofuWithSpec(opts, specs, {
    dir, env: credentialEnv(opts, "provider-dns"),
  });
}

// ------------------------------------------------------------------ deploy

// Java's Double.toString, which is what Cheshire renders floats through and
// therefore what green's committed golden bytes carry. Integral numbers print
// as longs. JS's shortest-round-trip digits are the same digits Java chooses;
// only the layout differs.
function javaNumber(value: number): string {
  if (Number.isInteger(value)) return String(value);
  const negative = value < 0;
  const [mantissa, exponentPart] = Math.abs(value).toExponential().split("e");
  const exponent = Number(exponentPart);
  const digits = mantissa!.replace(".", "");
  let body: string;
  if (exponent >= -3 && exponent < 7) {
    if (exponent >= 0) {
      const intPart = digits.padEnd(exponent + 1, "0").slice(0, exponent + 1);
      const fracPart = digits.slice(exponent + 1);
      body = `${intPart}.${fracPart.length > 0 ? fracPart : "0"}`;
    } else {
      body = `0.${"0".repeat(-exponent - 1)}${digits}`;
    }
  } else {
    const rest = digits.slice(1);
    body = `${digits[0]}.${rest.length > 0 ? rest : "0"}E${exponent}`;
  }
  return negative ? `-${body}` : body;
}

// Cheshire's pretty printer, byte for byte: spaces around colons, arrays
// inline, nested objects newline-indented, floats in Java notation.
function pretty(value: unknown, indent = 0): string {
  if (Array.isArray(value)) {
    if (value.length === 0) return "[ ]";
    return `[ ${value.map((item) => pretty(item, indent)).join(", ")} ]`;
  }
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value);
    if (entries.length === 0) return "{ }";
    const pad = " ".repeat(indent + 2);
    return `{\n${entries
      .map(([key, nested]) => `${pad}${JSON.stringify(key)} : ${pretty(nested, indent + 2)}`)
      .join(",\n")}\n${" ".repeat(indent)}}`;
  }
  if (typeof value === "number") return javaNumber(value);
  return JSON.stringify(value ?? null);
}

// Non-secret run facts the scripts read as JSON — the k8s analog of the
// parent's Ansible inventory.
export function inventory(opts: Opts): string {
  return pretty({
    host: opts["agent-network-host"],
    profile: opts.profile,
    compute_name: validate.computeName(opts),
  });
}

// The control plane's desired state, one JSON document the bootstrap
// reconciles against. Everything in it is non-secret — the Anthropic key
// reaches the bootstrap as an environment variable resolved at run time and
// never lands in a rendered file.
export function desiredJson(opts: Opts): string {
  return pretty({
    host: opts["agent-network-host"],
    admin_email: opts["agent-network-admin-email"],
    admin_name: opts["agent-network-admin-name"],
    provider: {
      // The catalog id, from GET /api/agent-network/catalog/providers on the
      // pinned release — "anthropic" alone is a 422.
      provider_id: "anthropic_api",
      name: "Anthropic",
      upstream_url: "https://api.anthropic.com",
      models: validate.providerModels(opts).map((m) => ({
        id: String(m.id),
        input_per_1k: m["input-per-1k"],
        output_per_1k: m["output-per-1k"],
        ...(m["cache-read-per-1k"] != null
          ? { cache_read_per_1k: m["cache-read-per-1k"] } : {}),
        ...(m["cache-creation-per-1k"] != null
          ? { cache_creation_per_1k: m["cache-creation-per-1k"] } : {}),
      })),
    },
    allowed_models: validate.allowedModels(opts),
    policy: {
      budget_usd_per_day: opts["agent-network-policy-budget-usd-per-day"],
      tokens_per_day: opts["agent-network-policy-tokens-per-day"],
    },
    global: {
      budget_usd_per_day: opts["agent-network-global-budget-usd-per-day"],
      tokens_per_day: opts["agent-network-global-tokens-per-day"],
    },
    log_retention_days: opts["agent-network-log-retention-days"],
  });
}

// Template values for every deploy-stage file. Deliberately carries no
// operator secret: the Anthropic key, the Cloudflare token and the registry
// credentials reach the scripts through the process environment or private
// state files, so nothing in .colors/ or a golden ever holds one.
export function deployData(opts: Opts): Opts {
  return {
    ...opts,
    "allowed-model": validate.allowedModel(opts),
    "denied-claimed-model": validate.deniedClaimedModel(opts),
    // The escaped base domain for Traefik's HostSNIRegexp: only
    // endpoint subdomains ride the TCP passthrough, never the bare
    // base name (TCP routers outrank HTTP routers in Traefik).
    "host-regex": String(opts["agent-network-host"]).replaceAll(".", "\\."),
  };
}

// Rendered scripts and manifests, one entry per file: [subpath template-dir].
export const deployFiles: [string, string][] = [
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
];

export function deploySpecs(opts: Opts): Spec[] {
  const dir = toolDir(opts, deployTool);
  const data = deployData(opts);
  return [
    ...deployFiles.map(([subpath, tdir]) =>
      spec(template(tdir, basename(subpath)), `${dir}/${subpath}`, data)),
    rawSpec(`${dir}/desired.json`, desiredJson(data)),
    rawSpec(`${dir}/inventory.json`, inventory(data)),
  ];
}

// Why the profile's kubeconfig must not be used, or undefined: a bearer
// credential that is a symlink, not a regular file, group/world-readable, or
// owned by someone else is not this deployment's to wield. Called on every
// execution path that wields it — workflow scripts, status, and the kubectl
// verb.
export function kubeconfigError(opts: Opts): string | undefined {
  const path = kubeconfigPath(opts);
  if (!existsSync(path)) return undefined;
  const stat = lstatSync(path);
  if (stat.isSymbolicLink()) return `kubeconfig at ${path} is a symlink`;
  if (!stat.isFile()) return `kubeconfig at ${path} is not a regular file`;
  const uid = process.getuid?.() ?? -1;
  if (stat.uid !== uid) {
    return `kubeconfig at ${path} is owned by uid ${stat.uid}, not uid ${uid}`;
  }
  if ((stat.mode & 0o066) !== 0) {
    return `kubeconfig at ${path} is not owner-only; chmod 600 it`;
  }
  return undefined;
}

// Run one rendered deploy script with the caller's terminal attached. The
// scripts read run facts from their environment (paths only — secrets stay in
// the inherited COLORS_PAR_* variables and private state files, never argv).
export async function runScript(opts: Opts, script: string, ...args: string[]): Promise<Opts> {
  const err = kubeconfigError(opts);
  if (err) throw new StepError(err);
  const dir = toolDir(opts, deployTool);
  const argv = ["env",
                `KUBECONFIG=${kubeconfigPath(opts)}`,
                `STATE_DIR=${stateDir(opts)}`,
                `DEPLOY_DIR=${dir}`,
                `LEGO_DIR=${legoDir(opts)}`,
                "bash", `${dir}/${script}`,
                ...args];
  const { exit, err: runErr } = await runInherit(argv);
  if ((exit ?? 1) === 0) return { ...opts, "red/exit": 0 };
  return { ...opts, "red/exit": exit ?? 1,
           "red/err": runErr || `${script} exited ${exit}` };
}

// Scaffold the deploy tree, then on a real create run `script`. Build renders
// and stops; delete is handled by `teardownStep`, not here.
export async function scriptStep(opts: Opts, script: string, ...args: string[]): Promise<Opts> {
  const rendered: Opts = {
    ...scaffold({ ...opts, "red/event": "create" }, deploySpecs(opts)),
    "red/event": opts["red/event"],
  };
  if (opts["red/event"] !== "create") return { ...rendered, "red/exit": 0 };
  return runScript(rendered, script, ...args);
}

export function readStateFile(opts: Opts, name: string): string | undefined {
  const path = join(stateDir(opts), name);
  if (!existsSync(path)) return undefined;
  return readFileSync(path, "utf8").trim();
}

// Phase one of convergence: namespaces, create-once secrets, the in-cluster
// agent-image build, the gateway workloads, the proxy token, and the load
// balancer. Ends knowing the LB address, which the dns stage publishes.
export async function deployStep(opts: Opts): Promise<Opts> {
  const result = await scriptStep(opts, "converge.sh");
  if (failed(result)) return result;
  if (opts["red/event"] !== "create") return result;
  const ip = readStateFile(opts, "lb-ip");
  if (ip) return { ...result, "lb-ip": ip };
  return { ...result, "red/exit": 1,
           "red/err": "converge recorded no load-balancer address" };
}

// Issue or renew the wildcard pair (both SANs: the base name and *.base —
// a wildcard alone does not cover the bare base name) launcher-side via
// DNS-01, apply it as the TLS Secret, then wait for the edge and the proxy,
// whose readiness was deliberately not awaited before the Secret existed.
export async function certificateStep(opts: Opts): Promise<Opts> {
  return scriptStep(opts, "certificate.sh");
}

export async function bootstrapStep(opts: Opts): Promise<Opts> {
  return scriptStep(opts, "bootstrap.sh");
}

export async function agentStep(opts: Opts): Promise<Opts> {
  return scriptStep(opts, "agent.sh");
}

export async function acceptanceStep(opts: Opts): Promise<Opts> {
  const result = await scriptStep(opts, "smoke.sh");
  if (failed(result) || opts["red/event"] !== "create") return result;
  return { ...result,
           "agent-network-k8s/acceptance": {
             endpoint: readStateFile(opts, "endpoint"),
             isolation: "probed",
             "tunnel-only": "confirmed",
           } };
}

// Ordered in-cluster teardown before the infrastructure destroy: workloads,
// PVCs (waiting for the CSI volumes to leave the account), then the LB
// Service (waiting for the LB to leave the account). Skips cleanly when the
// cluster is already gone or was never created.
export async function teardownStep(opts: Opts): Promise<Opts> {
  const rendered: Opts = {
    ...scaffold({ ...opts, "red/event": "create" }, deploySpecs(opts)),
    "red/event": "delete",
  };
  if (!existsSync(kubeconfigPath(opts))) return { ...rendered, "red/exit": 0 };
  const r = await runScript(rendered, "teardown.sh");
  // A cluster that stopped answering must not block the destroy that
  // removes it: teardown is best-effort, the tofu destroy is the
  // authority.
  return { ...r, "red/exit": 0 };
}

// Remove the local per-profile access material after the infrastructure is
// gone: the kubeconfig is a dead bearer credential, the state files describe
// a cluster that no longer exists.
export async function cleanupStep(opts: Opts): Promise<Opts> {
  if (opts["red/event"] === "delete") {
    const kc = kubeconfigPath(opts);
    if (existsSync(kc)) unlinkSync(kc);
    for (const dir of [stateDir(opts), join(profileDir(opts), "proofs")]) {
      if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
    }
  }
  return { ...opts, "red/exit": 0 };
}

// ------------------------------------------------------------- kubectl verb

function readState(stateFile: string): Opts {
  const text = readFileSync(stateFile, "utf8");
  return { ...((Bun.YAML.parse(text) ?? {}) as Opts), "red/state-file": stateFile };
}

// The launcher's status verb: render nothing, run the already-rendered
// status script against the live cluster. Returns the exit code.
export async function statusMain(stateFile: string): Promise<number> {
  const opts = readState(stateFile);
  const dir = toolDir(opts, deployTool);
  const script = `${dir}/status.sh`;
  if (!existsSync(script)) {
    console.error(`no rendered status script at ${script}; run build first`);
    return 2;
  }
  const err = kubeconfigError(opts);
  if (err) {
    console.error(err);
    return 2;
  }
  const { exit } = await runInherit(
    ["env", `KUBECONFIG=${kubeconfigPath(opts)}`,
     `STATE_DIR=${stateDir(opts)}`,
     `DEPLOY_DIR=${dir}`,
     "bash", script]);
  return exit;
}

// The launcher's kubectl passthrough: run kubectl against this deployment's
// cluster with the profile's kubeconfig. Returns the exit code.
export async function kubectlMain(stateFile: string, args: string[]): Promise<number> {
  const opts = readState(stateFile);
  const kc = kubeconfigPath(opts);
  if (!existsSync(kc)) {
    console.error(`no kubeconfig at ${kc}; run create first`);
    return 2;
  }
  const err = kubeconfigError(opts);
  if (err) {
    console.error(err);
    return 2;
  }
  const { exit } = await runInherit(["env", `KUBECONFIG=${kc}`, "kubectl", ...args]);
  return exit;
}
