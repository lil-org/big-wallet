import assert from "node:assert/strict";
import { test } from "node:test";

import { PINNED_WRANGLER_PATH } from "./production-contract.mjs";
import {
  assertExpectedProductionDeployment,
  assertRemoteObservabilityPolicy,
  executeReleaseVerification,
  parseDeploymentStatus,
  parseReleaseVerificationArguments,
  releaseVerificationEnvironment,
  releaseVerificationMain,
  readRemoteScriptSettings,
  SafeReleaseVerificationError,
} from "./verify-release.mjs";

const VERSION = "db7cd8d3-4425-4fe7-8c81-01bf963b6067";
const OTHER_VERSION = "f1bc23fe-48a6-487b-b42f-f5f0fef1a1c9";
const ACCOUNT_ID = "e25f90fc073ea309b54b8b5144bf28e0";
const OPTIONS = {
  help: false,
  expectedKid: "expected-test-kid",
  expectedVersion: VERSION,
  appProofKeyFile: "/protected/app-proof.key",
};
const WORKER_DIRECTORY = "/protected/release/worker";

function deployment(versions = [{ version_id: VERSION, percentage: 100 }]) {
  return { id: "deployment-id", versions };
}

function settingsEnvelope(overrides = {}) {
  return {
    success: true,
    errors: [],
    result: {
      observability: {
        enabled: true,
        head_sampling_rate: 1,
        logs: {
          enabled: true,
          head_sampling_rate: 1,
          persist: true,
          invocation_logs: false,
        },
        traces: {
          enabled: false,
          persist: true,
          head_sampling_rate: 0.01,
        },
        ...overrides,
      },
    },
  };
}

function snapshot(onCleanup = () => undefined) {
  return {
    configPath: `${WORKER_DIRECTORY}/wrangler.jsonc`,
    emptyEnvironmentPath: "/protected/release/empty.env",
    workerDirectory: WORKER_DIRECTORY,
    verify: async () => undefined,
    cleanup: async () => onCleanup(),
  };
}

test("release verifier accepts only the three fixed attestation options", () => {
  assert.deepEqual(
    parseReleaseVerificationArguments([
      "--expected-kid",
      OPTIONS.expectedKid,
      "--expected-version",
      VERSION,
      "--app-proof-key-file",
      OPTIONS.appProofKeyFile,
    ]),
    OPTIONS,
  );
  for (const arguments_ of [
    [],
    ["--worker-name", "attacker"],
    ["--account-id", ACCOUNT_ID],
    ["--cloudflare-api-url", "https://attacker.invalid"],
    ["--catalog", "/tmp/catalog.json"],
    ["--version-override"],
    ["--expected-version", VERSION.toUpperCase()],
    [
      "--expected-kid",
      OPTIONS.expectedKid,
      "--expected-version",
      VERSION,
      "--app-proof-key-file",
      "relative.key",
    ],
  ]) {
    assert.throws(
      () => parseReleaseVerificationArguments(arguments_),
      SafeReleaseVerificationError,
    );
  }
});

test("release verifier requires exactly the pinned version at 100 percent", () => {
  const parsed = parseDeploymentStatus(
    Buffer.from(JSON.stringify(deployment())),
  );
  assert.doesNotThrow(() =>
    assertExpectedProductionDeployment(parsed, VERSION),
  );

  for (const invalid of [
    deployment([]),
    deployment([{ version_id: VERSION, percentage: 0 }]),
    deployment([{ version_id: VERSION, percentage: "100" }]),
    deployment([{ version_id: OTHER_VERSION, percentage: 100 }]),
    deployment([
      { version_id: VERSION, percentage: 50 },
      { version_id: OTHER_VERSION, percentage: 50 },
    ]),
    { versions: null },
  ]) {
    assert.throws(
      () => assertExpectedProductionDeployment(invalid, VERSION),
      SafeReleaseVerificationError,
    );
  }
  for (const invalid of [Buffer.alloc(0), Buffer.from("[]"), Buffer.from("{")]) {
    assert.throws(
      () => parseDeploymentStatus(invalid),
      SafeReleaseVerificationError,
    );
  }
});

test("release verifier accepts only one Cloudflare API token auth mode", () => {
  const environment = releaseVerificationEnvironment({
    CLOUDFLARE_API_TOKEN: "scoped-token",
    PATH: "/usr/bin",
  });
  assert.equal(environment.CLOUDFLARE_API_TOKEN, "scoped-token");
  assert.equal(environment.PATH, "/usr/bin");
  assert.equal(environment.CLOUDFLARE_API_KEY, undefined);
  assert.equal(environment.CLOUDFLARE_EMAIL, undefined);
  assert.equal(environment.CLOUDFLARE_API_USER_SERVICE_KEY, undefined);

  for (const parentEnvironment of [
    {},
    { CLOUDFLARE_API_TOKEN: "" },
    {
      CLOUDFLARE_API_TOKEN: "scoped-token",
      CLOUDFLARE_API_KEY: "legacy-key",
    },
    {
      CLOUDFLARE_API_TOKEN: "scoped-token",
      CLOUDFLARE_EMAIL: "owner@example.com",
    },
    {
      CLOUDFLARE_API_TOKEN: "scoped-token",
      CLOUDFLARE_API_USER_SERVICE_KEY: "legacy-service-key",
    },
  ]) {
    assert.throws(
      () => releaseVerificationEnvironment(parentEnvironment),
      SafeReleaseVerificationError,
    );
  }
});

test("remote settings require disabled traces and the intended log policy", () => {
  assert.doesNotThrow(() =>
    assertRemoteObservabilityPolicy(settingsEnvelope()),
  );
  for (const invalid of [
    settingsEnvelope({ traces: { enabled: true } }),
    settingsEnvelope({ traces: undefined }),
    settingsEnvelope({ traces: null }),
    settingsEnvelope({ logs: { enabled: false } }),
    settingsEnvelope({
      logs: {
        enabled: true,
        head_sampling_rate: 0.5,
        invocation_logs: false,
      },
    }),
    settingsEnvelope({
      logs: {
        enabled: true,
        head_sampling_rate: 1,
        invocation_logs: true,
      },
    }),
    settingsEnvelope({ enabled: false }),
    { success: false, errors: [], result: {} },
  ]) {
    assert.throws(
      () => assertRemoteObservabilityPolicy(invalid),
      SafeReleaseVerificationError,
    );
  }
});

test("remote settings use only the fixed read-only Cloudflare API request", async () => {
  let observedURL;
  let observedInit;
  const result = await readRemoteScriptSettings({
    accountId: ACCOUNT_ID,
    workerName: "big-wallet-alchemy-jwt",
    apiToken: "scoped-token",
    fetchImplementation: async (url, init) => {
      observedURL = new URL(url);
      observedInit = init;
      return new Response(JSON.stringify(settingsEnvelope()), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
  });
  assert.equal(
    observedURL.href,
    `https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/big-wallet-alchemy-jwt/script-settings`,
  );
  assert.equal(observedInit.method, "GET");
  assert.equal(observedInit.redirect, "error");
  assert.equal(observedInit.headers.Authorization, "Bearer scoped-token");
  assert.equal(result.result.observability.traces.enabled, false);

  await assert.rejects(
    readRemoteScriptSettings({
      accountId: ACCOUNT_ID,
      workerName: "big-wallet-alchemy-jwt",
      apiToken: "scoped-token",
      fetchImplementation: async () => new Response(null, { status: 403 }),
    }),
    (error) =>
      error instanceof SafeReleaseVerificationError &&
      error.message === "remote Worker settings request failed",
  );
});

test("release verification checks status and settings before live probes", async () => {
  const events = [];
  const result = await executeReleaseVerification(OPTIONS, {
    parentEnvironment: { CLOUDFLARE_API_TOKEN: "scoped-token" },
    contractLoader: async () => ({
      workerName: "big-wallet-alchemy-jwt",
      accountId: ACCOUNT_ID,
    }),
    snapshotFactory: async () => snapshot(() => events.push("cleanup")),
    deploymentStatusRunner: async ({
      arguments_,
      workingDirectory,
      parentEnvironment,
    }) => {
      events.push("status");
      assert.deepEqual(arguments_, [
        PINNED_WRANGLER_PATH,
        "deployments",
        "status",
        "--json",
        `--config=${WORKER_DIRECTORY}/wrangler.jsonc`,
        "--env-file=/protected/release/empty.env",
        "--env=",
        "--name=big-wallet-alchemy-jwt",
      ]);
      assert.equal(workingDirectory, WORKER_DIRECTORY);
      assert.equal(parentEnvironment.CLOUDFLARE_API_TOKEN, "scoped-token");
      return Buffer.from(JSON.stringify(deployment()));
    },
    scriptSettingsReader: async ({ accountId, workerName, apiToken }) => {
      events.push("settings");
      assert.equal(accountId, ACCOUNT_ID);
      assert.equal(workerName, "big-wallet-alchemy-jwt");
      assert.equal(apiToken, "scoped-token");
      return settingsEnvelope();
    },
    liveVerifier: async (options) => {
      events.push("live");
      assert.deepEqual(options, OPTIONS);
      return { probeCount: 9, canary: { ok: true } };
    },
  });
  assert.deepEqual(events, ["status", "cleanup", "settings", "live"]);
  assert.equal(result.live.canary.ok, true);
});

test("deployment mismatch blocks public probes", async () => {
  let liveCalled = false;
  await assert.rejects(
    executeReleaseVerification(OPTIONS, {
      parentEnvironment: { CLOUDFLARE_API_TOKEN: "scoped-token" },
      contractLoader: async () => ({
        workerName: "big-wallet-alchemy-jwt",
        accountId: ACCOUNT_ID,
      }),
      snapshotFactory: async () => snapshot(),
      deploymentStatusRunner: async () =>
        Buffer.from(JSON.stringify(deployment([
          { version_id: OTHER_VERSION, percentage: 100 },
        ]))),
      scriptSettingsReader: async () => {
        assert.fail("deployment mismatch must block settings verification");
      },
      liveVerifier: async () => {
        liveCalled = true;
      },
    }),
    SafeReleaseVerificationError,
  );
  assert.equal(liveCalled, false);
});

test("remote settings API failure blocks public probes", async () => {
  let liveCalled = false;
  await assert.rejects(
    executeReleaseVerification(OPTIONS, {
      parentEnvironment: { CLOUDFLARE_API_TOKEN: "scoped-token" },
      contractLoader: async () => ({
        workerName: "big-wallet-alchemy-jwt",
        accountId: ACCOUNT_ID,
      }),
      snapshotFactory: async () => snapshot(),
      deploymentStatusRunner: async () =>
        Buffer.from(JSON.stringify(deployment())),
      scriptSettingsReader: async () => {
        throw new SafeReleaseVerificationError(
          "remote Worker settings request failed",
        );
      },
      liveVerifier: async () => {
        liveCalled = true;
      },
    }),
    SafeReleaseVerificationError,
  );
  assert.equal(liveCalled, false);
});

test("release verifier reports success without printing the kid or key path", async () => {
  const output = [];
  assert.equal(
    await releaseVerificationMain([
      "--expected-kid",
      OPTIONS.expectedKid,
      "--expected-version",
      VERSION,
      "--app-proof-key-file",
      OPTIONS.appProofKeyFile,
    ], {
      stdout: (message) => output.push(message),
      executor: async () => ({
        live: { probeCount: 9, canary: { ok: true } },
      }),
    }),
    0,
  );
  assert.match(
    output.join(""),
    /traffic=100 traces=disabled probes=9 eth-mainnet=ok/u,
  );
  assert.doesNotMatch(output.join(""), /expected-test-kid|app-proof\.key/u);
});
