// Credential-free desired-state validation for the VKE Agent Network demo,
// the port of io.github.getcolors.agent-network-k8s.validate. Depends only on
// the SDK: like `k8s`, this package carries its own provider registry rather
// than pinning ONCE for one lookup table.
//
// Green renders its keys as Clojure keywords, so every message here carries
// the same leading colon — the three colours must report identical errors for
// one colors.yml.

import { parName } from "red/cli";
import type { Opts } from "red/workflow";
import * as utils from "./utils.ts";

export const profilePar = parName("profile");

interface ProviderEntry {
  secrets: string[];
  tofuEnv: Record<string, string>;
}

export const providers: Record<string, Record<string, ProviderEntry>> = {
  "provider-compute": {
    vultr: { secrets: ["vultr-api-key"],
             tofuEnv: { "vultr-api-key": "VULTR_API_KEY" } },
  },
  "provider-dns": {
    cloudflare: { secrets: ["cloudflare-api-token"], tofuEnv: {} },
  },
  "provider-backend": {
    local: { secrets: [], tofuEnv: {} },
    s3: { secrets: ["s3-access-key-id", "s3-secret-access-key"],
          tofuEnv: { "s3-access-key-id": "AWS_ACCESS_KEY_ID",
                     "s3-secret-access-key": "AWS_SECRET_ACCESS_KEY" } },
    r2: { secrets: ["r2-access-key-id", "r2-secret-access-key"],
          tofuEnv: { "r2-access-key-id": "AWS_ACCESS_KEY_ID",
                     "r2-secret-access-key": "AWS_SECRET_ACCESS_KEY" } },
  },
};

// Every key desired state must carry. There is no `vultr-name`: the Compute
// Name Standard's optional override applies, and a colors.yml that omits it is
// complete and names the cluster, node pool, load balancer and registry after
// the profile.
export const required = [
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
];

export const imageKeys = [
  "agent-network-server-image", "agent-network-dashboard-image",
  "agent-network-proxy-image", "agent-network-traefik-image",
  "agent-network-client-image", "agent-network-kaniko-image",
  "agent-network-agent-base-image",
];

const hostRe = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/;
const emailRe = /^[^@\s]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/;
// `tag@sha256:...` — the shape every image key here actually carries — pins
// both the human-readable version and the exact bytes.
const imagePinnedRe = /^[^\s@]+(?::[^\s:@]+@sha256:[0-9a-f]{64}|:[^\s:@]+|@sha256:[0-9a-f]{64})$/;
const cidrRe = /^(?:\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/;
const versionRe = /^[0-9]+\.[0-9]+\.[0-9]+$/;
// A Debian package version: upstream plus revision, e.g. 3.0.34-1.
const debVersionRe = /^[0-9][0-9A-Za-z.+~:-]*$/;
const sha256Re = /^[0-9a-f]{64}$/;
// VKE versions are Kubernetes semver plus Vultr's build suffix: v1.35.2+1.
const vkeVersionRe = /^v[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$/;
const modelIdRe = /^[A-Za-z0-9][A-Za-z0-9._:-]*$/;
// Vultr labels accept letters, digits, dashes, underscores and periods.
const vultrNameRe = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/;

export function missing(x: unknown): boolean {
  return x == null || (typeof x === "string" && x.trim().length === 0);
}

// Absent, blank or REPLACE_ME all mean 'use the profile' (Compute Name
// Standard §2: presence is the only switch).
export function placeholder(v: unknown): boolean {
  return missing(v) || String(v).trim() === "REPLACE_ME";
}

// What this deployment calls its cluster. Every label — the node pool's, the
// registry's (lowercased, non-alphanumerics stripped: Vultr registry names
// accept nothing else) — derives from this and never from the raw override
// key or a second copy of the profile (§3).
export function computeName(opts: Opts): string {
  const override = opts["vultr-name"];
  return placeholder(override) ? String(opts.profile) : String(override).trim();
}

export function registryName(opts: Opts): string {
  return utils.registryName(computeName(opts));
}

// The Cloudflare zone the host and its wildcard belong to.
export function zone(opts: Opts): string {
  return utils.registrableDomain(opts["agent-network-host"]);
}

export interface ProviderModel {
  id?: unknown;
  "input-per-1k"?: unknown;
  "output-per-1k"?: unknown;
  "cache-read-per-1k"?: unknown;
  "cache-creation-per-1k"?: unknown;
}

// The models the Anthropic provider claims, however YAML handed them over.
export function providerModels(opts: Opts): ProviderModel[] {
  const models = opts["agent-network-provider-models"];
  return Array.isArray(models) ? (models as ProviderModel[]) : [];
}

export function allowedModels(opts: Opts): string[] {
  const models = opts["agent-network-allowed-models"];
  return Array.isArray(models) ? models.map(String) : [];
}

// The model every Claude Code knob is pinned to.
export function allowedModel(opts: Opts): string | undefined {
  return allowedModels(opts)[0];
}

// A model the provider claims but the guardrail does not allow — the
// guardrail-denial probe's negative case. Its existence is validated, so
// acceptance can rely on it.
export function deniedClaimedModel(opts: Opts): string | undefined {
  const allowed = new Set(allowedModels(opts));
  return providerModels(opts)
    .map((m) => String(m.id))
    .find((id) => !allowed.has(id));
}

export function posNum(x: unknown): boolean {
  return typeof x === "number" && x > 0;
}

export function modelErrors(opts: Opts): string[] {
  const models = providerModels(opts);
  const allowed = allowedModels(opts);
  const claimed = new Set(models.map((m) => String(m.id)));
  const errors: string[] = [];
  if (!(Array.isArray(opts["agent-network-provider-models"]) && models.length > 0)) {
    errors.push(":agent-network-provider-models must be a non-empty list");
  }
  for (const m of models) {
    if (missing(m.id) || !modelIdRe.test(String(m.id))) {
      errors.push(":agent-network-provider-models entries must carry a model id");
    }
  }
  for (const m of models) {
    if (!(posNum(m["input-per-1k"]) && posNum(m["output-per-1k"]))) {
      errors.push(`model ${m.id} must carry positive input-per-1k and output-per-1k prices`);
    }
  }
  if (!(Array.isArray(opts["agent-network-allowed-models"]) && allowed.length > 0)) {
    errors.push(":agent-network-allowed-models must be a non-empty list");
  }
  for (const m of allowed) {
    if (!claimed.has(m)) {
      errors.push(`:agent-network-allowed-models entry ${m} is not claimed by the provider`);
    }
  }
  // The demo's guardrail-denial probe needs a model that routing accepts
  // and the allowlist rejects. Without one, gate 3b has no negative case
  // and the guardrail is configured but never demonstrated.
  const allowedSet = new Set(allowed);
  if (models.length > 0 && allowed.length > 0 &&
      models.every((m) => allowedSet.has(String(m.id)))) {
    errors.push(":agent-network-provider-models must claim at least one model outside :agent-network-allowed-models");
  }
  return errors;
}

export function envErrors(env: Record<string, string | undefined>): string[] {
  return String(env[profilePar] ?? "").length > 0
    ? [`${profilePar} is set; profile must come from colors.yml only`]
    : [];
}

function entry(opts: Opts, slot: string): ProviderEntry | undefined {
  return providers[slot]?.[String(opts[slot])];
}

export function stateErrors(opts: Opts): string[] {
  const errors: string[] = [];
  for (const k of required) {
    if (missing(opts[k])) errors.push(`:${k} is required`);
  }
  if (opts["provider-compute"] !== "vultr") {
    errors.push(":provider-compute must be vultr");
  }
  if (opts["provider-dns"] !== "cloudflare") {
    errors.push(":provider-dns must be cloudflare");
  }
  if (!["local", "s3", "r2"].includes(String(opts["provider-backend"]))) {
    errors.push(":provider-backend must be local, s3, or r2");
  }
  if (typeof opts["compute-prevent-destroy"] !== "boolean") {
    errors.push(":compute-prevent-destroy must be true or false");
  }
  if (!missing(opts["agent-network-host"]) &&
      !hostRe.test(String(opts["agent-network-host"]))) {
    errors.push(":agent-network-host must be a fully qualified hostname");
  }
  for (const k of ["agent-network-letsencrypt-email", "agent-network-admin-email"]) {
    const v = opts[k];
    if (!missing(v) && !emailRe.test(String(v))) {
      errors.push(`:${k} must be an email address`);
    }
  }
  for (const k of imageKeys) {
    const v = opts[k];
    if (!missing(v) && !imagePinnedRe.test(String(v))) {
      errors.push(`:${k} must carry an explicit image tag or digest`);
    }
  }
  // This package owns its manifests rather than following the upstream
  // installer, so nothing tells it when a floating tag moved underneath it.
  for (const k of imageKeys) {
    const v = String(opts[k]);
    if (v.endsWith(":latest") || v.endsWith(":main") ||
        v.includes(":latest@") || v.includes(":main@")) {
      errors.push(`:${k} must not track a floating tag; pin the version`);
    }
  }
  for (const k of ["agent-network-claude-code-version", "agent-network-lego-version"]) {
    const v = opts[k];
    if (!missing(v) && !versionRe.test(String(v))) {
      errors.push(`:${k} must be an exact x.y.z version`);
    }
  }
  if (!(missing(opts["agent-network-privoxy-version"]) ||
        debVersionRe.test(String(opts["agent-network-privoxy-version"])))) {
    errors.push(":agent-network-privoxy-version must be an exact Debian package version");
  }
  if (!(missing(opts["agent-network-gost-version"]) ||
        versionRe.test(String(opts["agent-network-gost-version"])))) {
    errors.push(":agent-network-gost-version must be an exact x.y.z version");
  }
  if (!(missing(opts["agent-network-gost-sha256"]) ||
        sha256Re.test(String(opts["agent-network-gost-sha256"])))) {
    errors.push(":agent-network-gost-sha256 must be the 64-hex sha256 of the release tarball");
  }
  if (!(missing(opts["vultr-vke-version"]) ||
        vkeVersionRe.test(String(opts["vultr-vke-version"])))) {
    errors.push(":vultr-vke-version must look like v1.35.2+1");
  }
  if (!(missing(opts["vultr-node-count"]) ||
        (Number.isInteger(opts["vultr-node-count"]) &&
         (opts["vultr-node-count"] as number) >= 1 &&
         (opts["vultr-node-count"] as number) <= 16))) {
    errors.push(":vultr-node-count must be an integer between 1 and 16");
  }
  if (!(missing(opts["vke-pod-cidr"]) || cidrRe.test(String(opts["vke-pod-cidr"])))) {
    errors.push(":vke-pod-cidr must be a CIDR block");
  }
  if (!(missing(opts["agent-network-log-level"]) ||
        ["error", "warn", "info", "debug"].includes(String(opts["agent-network-log-level"])))) {
    errors.push(":agent-network-log-level must be error, warn, info, or debug");
  }
  // 7-90 mirrors the dashboard's own retention range; usage metering is
  // unconditional and unaffected.
  if (!(missing(opts["agent-network-log-retention-days"]) ||
        (Number.isInteger(opts["agent-network-log-retention-days"]) &&
         (opts["agent-network-log-retention-days"] as number) >= 7 &&
         (opts["agent-network-log-retention-days"] as number) <= 90))) {
    errors.push(":agent-network-log-retention-days must be an integer between 7 and 90");
  }
  for (const k of ["agent-network-policy-budget-usd-per-day",
                   "agent-network-policy-tokens-per-day",
                   "agent-network-global-budget-usd-per-day",
                   "agent-network-global-tokens-per-day"]) {
    const v = opts[k];
    if (!missing(v) && !posNum(v)) {
      errors.push(`:${k} must be a positive number`);
    }
  }
  // The global rule is the backstop: a policy cap above it would never bind
  // and the desired state would be lying about which limit is the ceiling.
  if (posNum(opts["agent-network-policy-budget-usd-per-day"]) &&
      posNum(opts["agent-network-global-budget-usd-per-day"]) &&
      (opts["agent-network-policy-budget-usd-per-day"] as number) >
      (opts["agent-network-global-budget-usd-per-day"] as number)) {
    errors.push(":agent-network-policy-budget-usd-per-day must not exceed the global budget");
  }
  if (posNum(opts["agent-network-policy-tokens-per-day"]) &&
      posNum(opts["agent-network-global-tokens-per-day"]) &&
      (opts["agent-network-policy-tokens-per-day"] as number) >
      (opts["agent-network-global-tokens-per-day"] as number)) {
    errors.push(":agent-network-policy-tokens-per-day must not exceed the global token cap");
  }
  if ([opts["agent-network-provider-models"], opts["agent-network-allowed-models"]]
      .some((v) => !missing(v))) {
    errors.push(...modelErrors(opts));
  }
  const srcs = opts["vultr-http-sources"];
  if (!missing(srcs) &&
      (!Array.isArray(srcs) || srcs.length === 0 ||
       srcs.some((s) => !cidrRe.test(String(s))))) {
    errors.push(":vultr-http-sources must be a non-empty list of IPv4 CIDRs");
  }
  // The override is validated against the provider's rules rather than
  // passed through unread (Compute Name Standard §2).
  if (!(placeholder(opts["vultr-name"]) ||
        vultrNameRe.test(String(opts["vultr-name"]).trim()))) {
    errors.push(":vultr-name must be letters, digits, dot, dash or underscore");
  }
  return errors;
}

export function backendSecrets(opts: Opts): string[] {
  return entry(opts, "provider-backend")?.secrets ?? [];
}

// What talking to the providers needs, on any real event.
export const providerSecrets = ["vultr-api-key", "cloudflare-api-token"];

// What converging the cluster needs, and therefore only a create.
//
// One entry, deliberately. Everything else this deployment holds is generated
// in-cluster and supplied by nobody: the relay auth secret, the datastore
// encryption key, the session cookie key, the proxy access token, the local
// admin password, the durable automation token, and the agent's one-off setup
// key. The Anthropic key is the exception because it authenticates against an
// account this cluster does not own; it is handed to NetBird's encrypted store
// at converge time and the agent pod never sees it.
export const applicationSecrets = ["anthropic-api-key"];

// Credentials a real event needs. A delete tears down infrastructure with the
// provider credentials alone: this deployment is disposable by design, holds
// nothing worth a final archive, and demanding the Anthropic key to destroy a
// cluster would just be a lock on the exit.
export function secretErrors(opts: Opts, event: string): string[] {
  const keys = [...providerSecrets,
                ...(event === "create" ? applicationSecrets : []),
                ...backendSecrets(opts)];
  return [...new Set(keys)]
    .filter((k) => missing(opts[k]))
    .map((k) => `required credential is not set: ${parName(k)}`);
}

export function tofuEnv(opts: Opts, slot: string): Record<string, string> {
  switch (slot) {
    case "provider-compute": return { "vultr-api-key": "VULTR_API_KEY" };
    case "provider-dns": return { "cloudflare-api-token": "CLOUDFLARE_API_TOKEN" };
    case "provider-backend": return entry(opts, "provider-backend")?.tofuEnv ?? {};
    default: return {};
  }
}
