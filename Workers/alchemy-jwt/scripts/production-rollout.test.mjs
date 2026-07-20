import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, test } from "node:test";

import {
  assertProductionObservabilityPolicy,
  createProtectedProductionSnapshot,
  isValidWorkerName,
  loadProductionWranglerContract,
  PINNED_WRANGLER_PATH,
  PINNED_WRANGLER_VERSION,
  productionWranglerArguments,
  productionWranglerEnvironment,
  PRODUCTION_WRANGLER_CONFIG_PATH,
  SafeProductionWranglerError,
  spawnPinnedProductionWrangler,
} from "./production-contract.mjs";
import {
  assertCurrentDeployment,
  executeRollout,
  parseRolloutArguments,
  rolloutMain,
  SafeRolloutError,
} from "./production-rollout.mjs";

const FIRST_VERSION = "db7cd8d3-4425-4fe7-8c81-01bf963b6067";
const SECOND_VERSION = "f1bc23fe-48a6-487b-b42f-f5f0fef1a1c9";
const THIRD_VERSION = "6ac1816b-1a72-4715-9d96-08f8f85467bb";
const SNAPSHOT_WORKER_DIRECTORY = "/protected/rollout/worker";
const SNAPSHOT_CONFIG_PATH =
  `${SNAPSHOT_WORKER_DIRECTORY}/wrangler.jsonc`;
const SNAPSHOT_ENVIRONMENT_PATH = "/protected/rollout/empty.env";
const temporaryDirectories = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) =>
      rm(path, { recursive: true, force: true }),
    ),
  );
});

function fixedSnapshot(cleanup = async () => undefined) {
  return {
    configPath: SNAPSHOT_CONFIG_PATH,
    emptyEnvironmentPath: SNAPSHOT_ENVIRONMENT_PATH,
    workerDirectory: SNAPSHOT_WORKER_DIRECTORY,
    verify: async () => undefined,
    cleanup,
  };
}

async function sourceFixture() {
  const sourceDirectory = await mkdtemp(
    join(tmpdir(), "alchemy-jwt-rollout-source-"),
  );
  temporaryDirectories.push(sourceDirectory);
  await mkdir(join(sourceDirectory, "src"));
  await mkdir(
    join(sourceDirectory, "node_modules", "wrangler"),
    { recursive: true },
  );
  await writeFile(
    join(sourceDirectory, "src", "index.ts"),
    "export default {};\n",
  );
  await writeFile(
    join(
      sourceDirectory,
      "node_modules",
      "wrangler",
      "config-schema.json",
    ),
    "{}\n",
  );
  const configPath = join(sourceDirectory, "wrangler.jsonc");
  const configBytes = Buffer.from(JSON.stringify({
    $schema: "./node_modules/wrangler/config-schema.json",
    name: "original-worker",
    main: "src/index.ts",
  }));
  await writeFile(configPath, configBytes);
  return { sourceDirectory, configPath, configBytes };
}

test("Worker names follow the production 1-63 character contract", () => {
  for (const name of ["a", "worker-1", `a${"b".repeat(62)}`]) {
    assert.equal(isValidWorkerName(name), true);
  }
  for (const name of [
    "",
    "-worker",
    "worker-",
    "Worker",
    "worker_name",
    `a${"b".repeat(63)}`,
  ]) {
    assert.equal(isValidWorkerName(name), false);
  }
});

test("production configuration derives the checked-in Worker name", async () => {
  const contract = await loadProductionWranglerContract();
  assert.equal(contract.workerName, "big-wallet-alchemy-jwt");
  assert.equal(contract.accountId, "e25f90fc073ea309b54b8b5144bf28e0");
  assert.match(contract.configPath, /\/wrangler\.jsonc$/u);
  assert.deepEqual(
    contract.configBytes,
    await readFile(PRODUCTION_WRANGLER_CONFIG_PATH),
  );
});

test("production observability requires explicit trace disablement", () => {
  const valid = {
    observability: {
      enabled: true,
      logs: {
        enabled: true,
        head_sampling_rate: 1,
        invocation_logs: false,
      },
      traces: { enabled: false },
    },
  };
  assert.doesNotThrow(() => assertProductionObservabilityPolicy(valid));

  for (const observability of [
    undefined,
    true,
    {
      enabled: true,
      logs: valid.observability.logs,
    },
    {
      enabled: true,
      logs: valid.observability.logs,
      traces: { enabled: true },
    },
    {
      enabled: true,
      logs: valid.observability.logs,
      traces: { enabled: false, head_sampling_rate: 0 },
    },
    {
      enabled: true,
      logs: {
        ...valid.observability.logs,
        invocation_logs: true,
      },
      traces: { enabled: false },
    },
  ]) {
    assert.throws(
      () => assertProductionObservabilityPolicy({ observability }),
      SafeProductionWranglerError,
    );
  }
});

test(
  "environment-altered Wrangler config cannot replace the checked-in name",
  async () => {
    await assert.rejects(
      loadProductionWranglerContract({
        readWranglerConfiguration: async (configPath) => ({
          redirected: false,
          configPath,
          userConfigPath: configPath,
          rawConfig: { name: "attacker-worker" },
        }),
      }),
      SafeProductionWranglerError,
    );
  },
);

test("rollout parser exposes only the fixed production commands", () => {
  assert.deepEqual(parseRolloutArguments(["deployments-list"]), {
    command: "deployments-list",
  });
  assert.deepEqual(parseRolloutArguments(["settings-check"]), {
    command: "settings-check",
  });
  assert.deepEqual(parseRolloutArguments(["versions-list"]), {
    command: "versions-list",
  });
  assert.deepEqual(
    parseRolloutArguments([
      "deploy",
      `${FIRST_VERSION}@10`,
      `${SECOND_VERSION}@90`,
      "--require-current",
      `${THIRD_VERSION}@100`,
      "--message",
      "Canary rollout",
    ]),
    {
      command: "deploy",
      versions: [`${FIRST_VERSION}@10`, `${SECOND_VERSION}@90`],
      requiredCurrentVersions: [`${THIRD_VERSION}@100`],
      message: "Canary rollout",
    },
  );

  for (const arguments_ of [
    ["deployments-list", "--config", "/tmp/attacker.jsonc"],
    ["settings-check", "--account-id", "attacker"],
    ["versions-list", "--env", "attacker"],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--profile",
      "attacker",
    ],
    [
      "deploy",
      `${FIRST_VERSION.toUpperCase()}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "bad",
    ],
  ]) {
    assert.throws(
      () => parseRolloutArguments(arguments_),
      SafeRolloutError,
    );
  }
});

test("the upload-output contract tracks the installed Wrangler version", async () => {
  const packageJSON = JSON.parse(
    await readFile(
      new URL("../package.json", import.meta.url),
      "utf8",
    ),
  );
  assert.equal(
    packageJSON.devDependencies.wrangler,
    PINNED_WRANGLER_VERSION,
  );
});

test("rollout usage documents at most two version specifications", async () => {
  const output = [];
  assert.equal(
    await rolloutMain(["--help"], {
      stdout: (message) => output.push(message),
    }),
    0,
  );
  assert.match(
    output.join(""),
    /deploy TARGET\.\.\. --require-current CURRENT\.\.\. --message/u,
  );
});

test("the production invocation rejects configuration overrides", () => {
  assert.throws(
    () => productionWranglerArguments({
      commandArguments: ["versions", "list"],
      configPath: "/tmp/attacker.jsonc",
      workerName: "big-wallet-alchemy-jwt",
      emptyEnvironmentPath: "/protected/empty.env",
    }),
    SafeProductionWranglerError,
  );
  assert.throws(
    () => productionWranglerArguments({
      commandArguments: ["versions", "list", "--profile=attacker"],
      configPath: SNAPSHOT_CONFIG_PATH,
      workerName: "big-wallet-alchemy-jwt",
      emptyEnvironmentPath: SNAPSHOT_ENVIRONMENT_PATH,
    }),
    SafeProductionWranglerError,
  );
});

test("deploy validation rejects ambiguous or unsafe traffic splits", () => {
  for (const arguments_ of [
    [
      "deploy",
      `${FIRST_VERSION}@99`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "bad total",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@50`,
      `${FIRST_VERSION}@50`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "duplicate",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100.0`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "decimal",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@101`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "too high",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@40`,
      `${SECOND_VERSION}@30`,
      `${THIRD_VERSION}@30`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "too many versions",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "line\nbreak",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "   ",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "ok",
      "extra",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--message",
      "missing precondition",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      "--message",
      "empty precondition",
    ],
    [
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--require-current",
      `${THIRD_VERSION}@100`,
      "--message",
      "duplicate precondition",
    ],
  ]) {
    assert.throws(
      () => parseRolloutArguments(arguments_),
      SafeRolloutError,
    );
  }
});

test("current deployment preconditions require exact version traffic", () => {
  assert.doesNotThrow(() =>
    assertCurrentDeployment(
      {
        versions: [
          { version_id: SECOND_VERSION, percentage: 0 },
          { version_id: FIRST_VERSION, percentage: 100 },
        ],
      },
      [`${FIRST_VERSION}@100`, `${SECOND_VERSION}@0`],
    )
  );

  for (const deployment of [
    null,
    [],
    {},
    { versions: [] },
    {
      versions: [
        { version_id: FIRST_VERSION, percentage: 50 },
        { version_id: SECOND_VERSION, percentage: 50 },
      ],
    },
    {
      versions: [
        { version_id: FIRST_VERSION, percentage: 100 },
      ],
    },
    {
      versions: [
        { version_id: FIRST_VERSION, percentage: 100 },
        { version_id: THIRD_VERSION, percentage: 0 },
      ],
    },
    {
      versions: [
        { version_id: FIRST_VERSION, percentage: "100" },
        { version_id: SECOND_VERSION, percentage: 0 },
      ],
    },
    {
      versions: [
        { version_id: FIRST_VERSION, percentage: 100 },
        { version_id: FIRST_VERSION, percentage: 0 },
      ],
    },
  ]) {
    assert.throws(
      () =>
        assertCurrentDeployment(
          deployment,
          [`${FIRST_VERSION}@100`, `${SECOND_VERSION}@0`],
        ),
      SafeRolloutError,
    );
  }
});

test("deployment drift and malformed status block the mutation runner", async () => {
  const options = parseRolloutArguments([
    "deploy",
    `${SECOND_VERSION}@100`,
    "--require-current",
    `${FIRST_VERSION}@100`,
    `${SECOND_VERSION}@0`,
    "--message",
    "Promote validated candidate",
  ]);
  const invalidStatusResults = [
    Buffer.from("{"),
    Buffer.from("[]"),
    Buffer.alloc((1024 * 1024) + 1, 0x20),
    Buffer.from(JSON.stringify({
      versions: [{ version_id: FIRST_VERSION, percentage: 100 }],
    })),
    Buffer.from(JSON.stringify({
      versions: [
        { version_id: FIRST_VERSION, percentage: 50 },
        { version_id: SECOND_VERSION, percentage: 50 },
      ],
    })),
    Buffer.from(JSON.stringify({
      versions: [
        { version_id: FIRST_VERSION, percentage: 100 },
        { version_id: SECOND_VERSION, percentage: "0" },
      ],
    })),
  ];

  for (const statusResult of invalidStatusResults) {
    let mutationCalls = 0;
    let cleanupCalls = 0;
    await assert.rejects(
      executeRollout(options, {
        contractLoader: async () => ({
          configPath: PRODUCTION_WRANGLER_CONFIG_PATH,
          workerName: "big-wallet-alchemy-jwt",
        }),
        snapshotFactory: async () => fixedSnapshot(async () => {
          cleanupCalls += 1;
        }),
        deploymentStatusRunner: async () => statusResult,
        runner: async () => {
          mutationCalls += 1;
        },
      }),
    );
    assert.equal(mutationCalls, 0);
    assert.equal(cleanupCalls, 1);
  }

  let mutationCalls = 0;
  let cleanupCalls = 0;
  await assert.rejects(
    executeRollout(options, {
      contractLoader: async () => ({
        configPath: PRODUCTION_WRANGLER_CONFIG_PATH,
        workerName: "big-wallet-alchemy-jwt",
      }),
      snapshotFactory: async () => fixedSnapshot(async () => {
        cleanupCalls += 1;
      }),
      deploymentStatusRunner: async () => {
        throw new Error("status unavailable");
      },
      runner: async () => {
        mutationCalls += 1;
      },
    }),
  );
  assert.equal(mutationCalls, 0);
  assert.equal(cleanupCalls, 1);
});

test("deploy checks exact status immediately before mutation", async () => {
  const events = [];
  const statusInvocations = [];
  const mutationInvocations = [];
  const snapshot = fixedSnapshot(async () => {
    events.push("cleanup");
  });
  snapshot.verify = async () => {
    events.push("verify");
  };

  await executeRollout(
    parseRolloutArguments([
      "deploy",
      `${SECOND_VERSION}@100`,
      "--require-current",
      `${FIRST_VERSION}@100`,
      `${SECOND_VERSION}@0`,
      "--message",
      "Promote validated candidate",
    ]),
    {
      contractLoader: async () => ({
        configPath: PRODUCTION_WRANGLER_CONFIG_PATH,
        workerName: "big-wallet-alchemy-jwt",
      }),
      snapshotFactory: async () => snapshot,
      deploymentStatusRunner: async (invocation) => {
        events.push("status");
        statusInvocations.push(invocation);
        return Buffer.from(JSON.stringify({
          versions: [
            { version_id: SECOND_VERSION, percentage: 0 },
            { version_id: FIRST_VERSION, percentage: 100 },
          ],
        }));
      },
      runner: async (invocation) => {
        events.push("deploy");
        mutationInvocations.push(invocation);
      },
    },
  );

  assert.deepEqual(events, [
    "verify",
    "status",
    "verify",
    "deploy",
    "cleanup",
  ]);
  assert.deepEqual(statusInvocations, [{
    arguments_: [
      PINNED_WRANGLER_PATH,
      "deployments",
      "status",
      "--json",
      `--config=${SNAPSHOT_CONFIG_PATH}`,
      `--env-file=${SNAPSHOT_ENVIRONMENT_PATH}`,
      "--env=",
      "--name=big-wallet-alchemy-jwt",
    ],
    workingDirectory: SNAPSHOT_WORKER_DIRECTORY,
  }]);
  assert.deepEqual(mutationInvocations, [{
    arguments_: [
      PINNED_WRANGLER_PATH,
      "versions",
      "deploy",
      `${SECOND_VERSION}@100`,
      "--message=Promote validated candidate",
      `--config=${SNAPSHOT_CONFIG_PATH}`,
      `--env-file=${SNAPSHOT_ENVIRONMENT_PATH}`,
      "--env=",
      "--name=big-wallet-alchemy-jwt",
      "--yes",
    ],
    workingDirectory: SNAPSHOT_WORKER_DIRECTORY,
  }]);
});

test("rollout injects the protected snapshot and cleans it", async () => {
  const invocations = [];
  let cleaned = 0;
  await executeRollout(
    parseRolloutArguments([
      "deploy",
      `${FIRST_VERSION}@100`,
      "--require-current",
      `${SECOND_VERSION}@100`,
      "--message",
      "--config",
    ]),
    {
      contractLoader: async () => ({
        configPath: PRODUCTION_WRANGLER_CONFIG_PATH,
        workerName: "big-wallet-alchemy-jwt",
      }),
      snapshotFactory: async () => fixedSnapshot(
        async () => {
          cleaned += 1;
        },
      ),
      deploymentStatusRunner: async () => Buffer.from(JSON.stringify({
        versions: [{
          version_id: SECOND_VERSION,
          percentage: 100,
        }],
      })),
      runner: async (invocation) => invocations.push(invocation),
    },
  );

  assert.equal(cleaned, 1);
  assert.deepEqual(invocations, [{
    arguments_: [
      PINNED_WRANGLER_PATH,
      "versions",
      "deploy",
      `${FIRST_VERSION}@100`,
      "--message=--config",
      `--config=${SNAPSHOT_CONFIG_PATH}`,
      `--env-file=${SNAPSHOT_ENVIRONMENT_PATH}`,
      "--env=",
      "--name=big-wallet-alchemy-jwt",
      "--yes",
    ],
    workingDirectory: SNAPSHOT_WORKER_DIRECTORY,
  }]);
});

test("rollout list commands emit only their fixed Wrangler vectors", async () => {
  const invocations = [];
  let deploymentStatusCalls = 0;
  const dependencies = {
    contractLoader: async () => ({
      configPath: PRODUCTION_WRANGLER_CONFIG_PATH,
      workerName: "big-wallet-alchemy-jwt",
    }),
    snapshotFactory: async () => fixedSnapshot(),
    runner: async (invocation) => invocations.push(invocation.arguments_),
    deploymentStatusRunner: async () => {
      deploymentStatusCalls += 1;
      throw new Error("list commands must not read deployment status");
    },
  };

  await executeRollout(
    parseRolloutArguments(["deployments-list"]),
    dependencies,
  );
  await executeRollout(
    parseRolloutArguments(["versions-list"]),
    dependencies,
  );

  const fixedTail = [
    `--config=${SNAPSHOT_CONFIG_PATH}`,
    `--env-file=${SNAPSHOT_ENVIRONMENT_PATH}`,
    "--env=",
    "--name=big-wallet-alchemy-jwt",
  ];
  assert.deepEqual(invocations, [
    [PINNED_WRANGLER_PATH, "deployments", "list", ...fixedTail],
    [PINNED_WRANGLER_PATH, "versions", "list", ...fixedTail],
  ]);
  assert.equal(deploymentStatusCalls, 0);
});

test("settings check uses only the fixed Worker and account", async () => {
  const calls = [];
  const result = await executeRollout(
    parseRolloutArguments(["settings-check"]),
    {
      contractLoader: async () => ({
        accountId: "e25f90fc073ea309b54b8b5144bf28e0",
        workerName: "big-wallet-alchemy-jwt",
      }),
      snapshotFactory: async () => {
        throw new Error("settings check must not create a rollout snapshot");
      },
      runner: async () => {
        throw new Error("settings check must not invoke Wrangler");
      },
      scriptSettingsReader: async (options) => {
        calls.push(options);
        return {};
      },
      parentEnvironment: {
        CLOUDFLARE_API_TOKEN: "scoped-token",
      },
    },
  );

  assert.deepEqual(calls, [{
    accountId: "e25f90fc073ea309b54b8b5144bf28e0",
    workerName: "big-wallet-alchemy-jwt",
    apiToken: "scoped-token",
  }]);
  assert.deepEqual(result, { settingsChecked: true });
});

test("post-validation config mutation or swap cannot change invocation", async () => {
  for (const mutation of ["rewrite", "swap"]) {
    const fixture = await sourceFixture();
    const replacementBytes = Buffer.from(JSON.stringify({
      name: "attacker-worker",
      account_id: "attacker-account",
      main: "src/index.ts",
    }));
    let snapshotConfigPath;
    await executeRollout(
      parseRolloutArguments(["versions-list"]),
      {
        contractLoader: async () => {
          if (mutation === "rewrite") {
            await writeFile(fixture.configPath, replacementBytes);
          } else {
            const replacementPath = join(
              fixture.sourceDirectory,
              "replacement.jsonc",
            );
            await writeFile(replacementPath, replacementBytes);
            await rename(replacementPath, fixture.configPath);
          }
          return {
            configPath: fixture.configPath,
            configBytes: fixture.configBytes,
            workerName: "original-worker",
            rawConfig: {
              name: "original-worker",
              main: "src/index.ts",
            },
          };
        },
        snapshotFactory: (contract) =>
          createProtectedProductionSnapshot(contract),
        runner: async ({ arguments_, workingDirectory }) => {
          const configArgument = arguments_.find((argument) =>
            argument.startsWith("--config=")
          );
          assert.ok(configArgument);
          snapshotConfigPath = configArgument.slice("--config=".length);
          assert.equal(dirname(snapshotConfigPath), workingDirectory);
          assert.deepEqual(
            await readFile(snapshotConfigPath),
            fixture.configBytes,
          );
          assert.deepEqual(
            await readFile(fixture.configPath),
            replacementBytes,
          );
          assert.equal(
            await readFile(
              join(workingDirectory, "src", "index.ts"),
              "utf8",
            ),
            "export default {};\n",
          );
          assert.equal(
            await readFile(
              join(
                workingDirectory,
                "node_modules",
                "wrangler",
                "config-schema.json",
              ),
              "utf8",
            ),
            "{}\n",
          );
        },
      },
    );
    await assert.rejects(access(snapshotConfigPath));
  }
});

test("rollout revalidates the protected config immediately before spawn", async () => {
  const fixture = await sourceFixture();
  let snapshotConfigPath;
  let runnerCalled = false;
  await assert.rejects(
    executeRollout(
      parseRolloutArguments(["versions-list"]),
      {
        contractLoader: async () => ({
          configPath: fixture.configPath,
          configBytes: fixture.configBytes,
          workerName: "original-worker",
          rawConfig: {
            name: "original-worker",
            main: "src/index.ts",
          },
        }),
        snapshotFactory: async (contract) => {
          const snapshot = await createProtectedProductionSnapshot(contract);
          snapshotConfigPath = snapshot.configPath;
          await writeFile(
            snapshot.configPath,
            Buffer.from("{\"name\":\"attacker-worker\"}"),
          );
          return snapshot;
        },
        runner: async () => {
          runnerCalled = true;
        },
      },
    ),
    SafeProductionWranglerError,
  );
  assert.equal(runnerCalled, false);
  await assert.rejects(access(snapshotConfigPath));
});

test("rollout detects snapshot mutation after the status precondition", async () => {
  const fixture = await sourceFixture();
  let snapshotConfigPath;
  let runnerCalled = false;
  await assert.rejects(
    executeRollout(
      parseRolloutArguments([
        "deploy",
        `${SECOND_VERSION}@100`,
        "--require-current",
        `${FIRST_VERSION}@100`,
        `${SECOND_VERSION}@0`,
        "--message",
        "Promote validated candidate",
      ]),
      {
        contractLoader: async () => ({
          configPath: fixture.configPath,
          configBytes: fixture.configBytes,
          workerName: "original-worker",
          rawConfig: {
            name: "original-worker",
            main: "src/index.ts",
          },
        }),
        snapshotFactory: async (contract) => {
          const snapshot =
            await createProtectedProductionSnapshot(contract);
          snapshotConfigPath = snapshot.configPath;
          return snapshot;
        },
        deploymentStatusRunner: async () => {
          await writeFile(
            snapshotConfigPath,
            Buffer.from("{\"name\":\"attacker-worker\"}"),
          );
          return Buffer.from(JSON.stringify({
            versions: [
              { version_id: FIRST_VERSION, percentage: 100 },
              { version_id: SECOND_VERSION, percentage: 0 },
            ],
          }));
        },
        runner: async () => {
          runnerCalled = true;
        },
      },
    ),
    SafeProductionWranglerError,
  );
  assert.equal(runnerCalled, false);
  await assert.rejects(access(snapshotConfigPath));
});

test("the pinned runner strips redirecting environment inputs", async () => {
  let spawnOptions;
  let child;
  await spawnPinnedProductionWrangler({
    arguments_: productionWranglerArguments({
      commandArguments: ["versions", "list"],
      configPath: SNAPSHOT_CONFIG_PATH,
      workerName: "big-wallet-alchemy-jwt",
      emptyEnvironmentPath: SNAPSHOT_ENVIRONMENT_PATH,
    }),
    workingDirectory: SNAPSHOT_WORKER_DIRECTORY,
    parentEnvironment: {
      CLOUDFLARE_API_TOKEN: "token",
      CLOUDFLARE_API_BASE_URL: "https://attacker.invalid",
      CLOUDFLARE_ACCOUNT_ID: "attacker-account",
      CLOUDFLARE_ENV: "attacker",
      CLOUDFLARE_PROFILE: "attacker-profile",
      HTTPS_PROXY: "https://attacker.invalid",
      NODE_OPTIONS: "--require=/tmp/attacker.cjs",
      PATH: "/safe/bin",
      WRANGLER_API_ENVIRONMENT: "staging",
      WRANGLER_CI_OVERRIDE_NAME: "attacker",
      WRANGLER_CWD: "/tmp/attacker",
      WRANGLER_LOG_PATH: "/tmp/leak",
    },
    spawnProcess: (_executable, _arguments, options) => {
      spawnOptions = options;
      child = new EventEmitter();
      queueMicrotask(() => child.emit("close", 0));
      return child;
    },
  });

  assert.deepEqual(spawnOptions.env, productionWranglerEnvironment({
    CLOUDFLARE_API_TOKEN: "token",
    CLOUDFLARE_API_BASE_URL: "https://attacker.invalid",
    CLOUDFLARE_ACCOUNT_ID: "attacker-account",
    CLOUDFLARE_ENV: "attacker",
    CLOUDFLARE_PROFILE: "attacker-profile",
    HTTPS_PROXY: "https://attacker.invalid",
    NODE_OPTIONS: "--require=/tmp/attacker.cjs",
    PATH: "/safe/bin",
    WRANGLER_API_ENVIRONMENT: "staging",
    WRANGLER_CI_OVERRIDE_NAME: "attacker",
    WRANGLER_CWD: "/tmp/attacker",
    WRANGLER_LOG_PATH: "/tmp/leak",
  }));
  assert.deepEqual(spawnOptions.env, {
    CI: "1",
    CLOUDFLARE_COMPLIANCE_REGION: "public",
    CLOUDFLARE_API_TOKEN: "token",
    PATH: "/safe/bin",
    WRANGLER_API_ENVIRONMENT: "production",
    WRANGLER_LOG: "log",
    WRANGLER_LOG_SANITIZE: "true",
    WRANGLER_WRITE_LOGS: "false",
  });
});
