// The port of green's tools-test, validate-test and workflow-test: the three
// colours assert the same behaviour over the same fixture.

import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { scaffold } from "red/scaffold";
import type { Opts } from "red/workflow";
import * as tools from "../src/tools.ts";
import * as validate from "../src/validate.ts";
import { sideEffectingSteps, startStep, wireFn } from "../src/workflow.ts";

const fixturePath = join(import.meta.dir, "..", "..", "test", "fixtures", "colors.yml");

function fixture(): Opts {
  return {
    ...(Bun.YAML.parse(readFileSync(fixturePath, "utf8")) as Opts),
    "red/state-file": fixturePath,
  };
}

// ------------------------------------------------------------------- tools

describe("dns records", () => {
  test("base and wildcard, both unproxied, both at the LB", () => {
    const doc = JSON.parse(tools.dnsJson({ ...fixture(), "lb-ip": "203.0.113.9" }));
    const records = doc.resource.cloudflare_dns_record;
    const base = records.agent_network_k8s;
    const wild = records.agent_network_k8s_wildcard;
    expect(base.name).toBe("agent-network-k8s.example.com");
    expect(wild.name).toBe("*.agent-network-k8s.example.com");
    expect(base.content).toBe("203.0.113.9");
    expect(wild.content).toBe("203.0.113.9");
    expect(base.proxied).toBe(false);
    expect(wild.proxied).toBe(false);
  });
});

describe("desired document", () => {
  const doc = JSON.parse(tools.desiredJson(fixture()));
  test("the catalog provider id, not the bare name (422 otherwise)", () => {
    expect(doc.provider.provider_id).toBe("anthropic_api");
  });
  test("two claimed models, one allowed — both denial classes derivable", () => {
    expect(doc.provider.models.length).toBe(2);
    expect(doc.allowed_models).toEqual(["claude-haiku-4-5-20251001"]);
  });
  test("caps and retention travel", () => {
    expect(doc.policy.budget_usd_per_day).toBe(2);
    expect(doc.global.tokens_per_day).toBe(5000000);
    expect(doc.log_retention_days).toBe(7);
  });
  test("no secret has any business here", () => {
    expect(tools.desiredJson(fixture())).not.toContain("api_key");
  });
});

describe("deploy rendering", () => {
  const opts = { ...fixture(), workdir: join(tmpdir(), `an-k8s-test-${Date.now()}-${Math.random()}`) };
  const specs = tools.deploySpecs(opts);
  const rendered = scaffold({ ...opts, "red/event": "create" }, specs);
  const written = rendered["red.scaffold/written"] as string[];
  const slurpTarget = (suffix: string) =>
    readFileSync(written.find((p) => p.endsWith(suffix))!, "utf8");

  test("every deploy file renders", () => {
    expect(written.length).toBe(tools.deployFiles.length + 2);
  });
  test("the host reaches the scripts and manifests", () => {
    expect(slurpTarget("bootstrap.sh")).toContain("agent-network-k8s.example.com");
    expect(slurpTarget("manifests/proxy.yaml")).toContain("NB_PROXY_DOMAIN");
    expect(slurpTarget("traefik-dynamic.yaml")).toContain("HostSNIRegexp");
  });
  test("the passthrough matches subdomains only, never the bare base name", () => {
    const dyn = slurpTarget("traefik-dynamic.yaml");
    expect(dyn).toContain("HostSNIRegexp(`^[a-z0-9-]+\\.agent-network-k8s\\.example\\.com$`)");
    // No router may carry the catch-all rule (the comment may name it).
    expect(/rule:.*HostSNI\(`\*`\)/.test(dyn)).toBe(false);
  });
  test("every model knob is pinned in both agent variants", () => {
    for (const variant of ["manifests/agent-primary.yaml", "manifests/agent-fallback.yaml"]) {
      const content = slurpTarget(variant);
      for (const knob of ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                          "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                          "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"]) {
        expect(content).toContain(knob);
      }
      expect(content).toContain("claude-haiku-4-5-20251001");
    }
  });
  test("the agent pod mounts no ServiceAccount token and no DNS path", () => {
    expect(slurpTarget("manifests/agent-primary.yaml"))
      .toContain("automountServiceAccountToken: false");
  });
  test("the client entry is state-aware: reconnect without a key", () => {
    const entry = slurpTarget("socks-entry.sh");
    expect(entry).toContain("reconnecting without a key");
    expect(entry).toContain("--setup-key-file");
  });
  test("the one-off key never becomes a Kubernetes Secret", () => {
    const bootstrap = slurpTarget("bootstrap.sh");
    expect(bootstrap).toContain("/dev/shm");
    expect(/create secret.*setup/.test(bootstrap)).toBe(false);
  });
});

describe("per-profile paths", () => {
  const opts = fixture();
  test("kubeconfig and state live under the profile directory", () => {
    expect(tools.kubeconfigPath(opts).endsWith("agent-network-k8s-fixture/kubeconfig")).toBe(true);
    expect(tools.stateDir(opts).endsWith("agent-network-k8s-fixture/state")).toBe(true);
  });
});

describe("cidr splitting", () => {
  test("lists pass through, strings split", () => {
    expect(tools.cidrs({ "vultr-http-sources": ["1.2.3.0/24", "5.6.7.0/24"] }, "vultr-http-sources"))
      .toEqual(["1.2.3.0/24", "5.6.7.0/24"]);
    expect(tools.cidrs({ "vultr-http-sources": "1.2.3.0/24" }, "vultr-http-sources"))
      .toEqual(["1.2.3.0/24"]);
  });
});

// ---------------------------------------------------------------- validate

describe("validate", () => {
  test("fixture is valid", () => {
    expect(validate.stateErrors(fixture())).toEqual([]);
  });
  test("required keys are enforced", () => {
    for (const k of validate.required) {
      const opts = fixture();
      delete opts[k];
      const errors = validate.stateErrors(opts);
      expect(errors.some((e) => e.includes(`:${k}`))).toBe(true);
    }
  });
  test("env guard", () => {
    expect(validate.envErrors({})).toEqual([]);
    expect(validate.envErrors({ COLORS_PAR_PROFILE: "other" }).length).toBeGreaterThan(0);
  });
  test("a floating tag is refused", () => {
    for (const bad of ["netbirdio/netbird:latest", "netbirdio/netbird:main",
                       "netbirdio/netbird:latest@sha256:66f408b0c423e9c3376deea7bc0da78024d32494dd0f957344993015b74c4451"]) {
      expect(validate.stateErrors({ ...fixture(), "agent-network-client-image": bad }).length)
        .toBeGreaterThan(0);
    }
  });
  test("a bare repository means :latest by implication and is refused", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-client-image": "netbirdio/netbird" }).length)
      .toBeGreaterThan(0);
  });
  test("the allowlist must be claimed", () => {
    expect(validate.modelErrors({ ...fixture(), "agent-network-allowed-models": ["not-claimed"] }).length)
      .toBeGreaterThan(0);
  });
  test("at least one claimed model must sit outside the allowlist", () => {
    expect(validate.modelErrors({
      ...fixture(),
      "agent-network-allowed-models": ["claude-haiku-4-5-20251001", "claude-sonnet-4-5-20250929"],
    }).length).toBeGreaterThan(0);
  });
  test("the denial probe's negative case is derivable", () => {
    expect(validate.deniedClaimedModel(fixture())).toBe("claude-sonnet-4-5-20250929");
    expect(validate.allowedModel(fixture())).toBe("claude-haiku-4-5-20251001");
  });
  test("budget ceilings", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-policy-budget-usd-per-day": 50 }).length)
      .toBeGreaterThan(0);
    expect(validate.stateErrors({ ...fixture(), "agent-network-policy-tokens-per-day": 99999999 }).length)
      .toBeGreaterThan(0);
  });
  test("vke version shape", () => {
    expect(validate.stateErrors({ ...fixture(), "vultr-vke-version": "v1.34.0+3" })).toEqual([]);
    for (const bad of ["1.35.2+1", "v1.35.2", "v1.35+1", "latest"]) {
      expect(validate.stateErrors({ ...fixture(), "vultr-vke-version": bad }).length)
        .toBeGreaterThan(0);
    }
  });
  test("the compute name defaults to the profile (Compute Name Standard)", () => {
    expect(validate.computeName(fixture())).toBe("agent-network-k8s-fixture");
    expect(validate.computeName({ ...fixture(), "vultr-name": "custom" })).toBe("custom");
    expect(validate.computeName({ ...fixture(), "vultr-name": "REPLACE_ME" }))
      .toBe("agent-network-k8s-fixture");
  });
  test("the registry name is the compute name reduced to what Vultr accepts", () => {
    expect(validate.registryName(fixture())).toBe("agentnetworkk8sfixture");
  });
  test("zone derivation", () => {
    expect(validate.zone(fixture())).toBe("example.com");
  });
  test("create needs the providers, the backend and the Anthropic key", () => {
    const errors = validate.secretErrors({ ...fixture(), "provider-backend": "r2" }, "create");
    for (const v of ["COLORS_PAR_VULTR_API_KEY", "COLORS_PAR_CLOUDFLARE_API_TOKEN",
                     "COLORS_PAR_ANTHROPIC_API_KEY", "COLORS_PAR_R2_ACCESS_KEY_ID"]) {
      expect(errors.some((e) => e.includes(v))).toBe(true);
    }
  });
  test("delete never demands the Anthropic key", () => {
    const errors = validate.secretErrors(fixture(), "delete");
    expect(errors.some((e) => e.includes("ANTHROPIC"))).toBe(false);
  });
  test("gost pin shape", () => {
    expect(validate.stateErrors({ ...fixture(), "agent-network-gost-sha256": "abc" }).length)
      .toBeGreaterThan(0);
    expect(validate.stateErrors({ ...fixture(), "agent-network-gost-version": "3.2" }).length)
      .toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------- workflow

function chain(event: string): string[] {
  const steps: string[] = [];
  let step = "agent-network-k8s/start";
  for (;;) {
    const decl = wireFn(step, { "red/event": event });
    const next = decl?.[1];
    if (!next) return steps;
    steps.push(next);
    step = next;
  }
}

describe("workflow", () => {
  test("create ordering: cluster → workloads → dns → certificate → bootstrap → agent → gates", () => {
    expect(chain("create")).toEqual([
      "agent-network-k8s/infrastructure", "agent-network-k8s/deploy",
      "agent-network-k8s/dns", "agent-network-k8s/certificate",
      "agent-network-k8s/bootstrap", "agent-network-k8s/agent",
      "agent-network-k8s/acceptance",
    ]);
  });
  test("delete ordering: in-cluster teardown precedes the infrastructure destroy", () => {
    expect(chain("delete")).toEqual([
      "agent-network-k8s/teardown", "agent-network-k8s/dns",
      "agent-network-k8s/infrastructure", "agent-network-k8s/cleanup",
    ]);
  });
  test("every side-effecting step is dry-runnable", () => {
    const wired = new Set([...chain("create"), ...chain("delete")]);
    for (const step of wired) {
      expect(sideEffectingSteps).toContain(step);
    }
  });
  test("a valid fixture passes", async () => {
    const out = await startStep({ ...fixture(), "red/event": "build" }, {});
    expect(out["red/exit"]).toBe(0);
  });
  test("missing desired state aggregates every error at exit 2", async () => {
    const opts: Opts = { ...fixture(), "red/event": "build" };
    delete opts["agent-network-host"];
    delete opts["vultr-vke-version"];
    const out = await startStep(opts, {});
    expect(out["red/exit"]).toBe(2);
    expect(String(out["red/err"])).toContain(":agent-network-host");
    expect(String(out["red/err"])).toContain(":vultr-vke-version");
  });
  test("the profile guard refuses the overlay", async () => {
    const out = await startStep({ ...fixture(), "red/event": "build" },
                                { COLORS_PAR_PROFILE: "other" });
    expect(out["red/exit"]).toBe(2);
  });
  test("a real delete is refused while the guard stands", async () => {
    const out = await startStep({
      ...fixture(),
      "red/event": "delete",
      "vultr-api-key": "x",
      "cloudflare-api-token": "x",
    }, {});
    expect(out["red/exit"]).toBe(2);
    expect(String(out["red/err"])).toContain("COLORS_PAR_COMPUTE_PREVENT_DESTROY");
  });
});
