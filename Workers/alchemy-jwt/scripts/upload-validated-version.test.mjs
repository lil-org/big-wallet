import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
} from "node:crypto";
import { EventEmitter } from "node:events";
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  stat,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, before, test } from "node:test";

import {
  createProtectedProductionSnapshot,
  PINNED_WRANGLER_VERSION,
} from "./production-contract.mjs";
import {
  parseUploadArguments,
  parseVersionUploadOutput,
  runPinnedWrangler,
  SafeUploadError,
  safeUploadVersion,
  UploadInterruptedError,
  uploadMain,
} from "./upload-validated-version.mjs";

const EXPECTED_KID = "upload-test-kid";
const EXPECTED_WORKER_NAME = "upload-test-worker";
const UPLOADED_VERSION = "db7cd8d3-4425-4fe7-8c81-01bf963b6067";
const WRANGLER_OUTPUT_TIMESTAMP = "2026-07-20T00:00:00.000Z";
const REQUEST_PROOF_KEY =
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const REQUEST_PROOF_KEY_FINGERPRINT = createHash("sha256")
  .update(REQUEST_PROOF_KEY, "ascii")
  .digest("hex");
const PRODUCTION_OBSERVABILITY = {
  enabled: true,
  logs: {
    enabled: true,
    head_sampling_rate: 1,
    invocation_logs: false,
  },
  traces: {
    enabled: false,
  },
};
const temporaryDirectories = [];
let privatePem;
let publicPem;

function wranglerSession(overrides = {}) {
  return {
    type: "wrangler-session",
    version: 1,
    wrangler_version: PINNED_WRANGLER_VERSION,
    command_line_args: [
      "versions",
      "upload",
      "--strict",
      "--secrets-file",
      "/protected/secrets.json",
    ],
    log_file_path: "/protected/wrangler.log",
    timestamp: WRANGLER_OUTPUT_TIMESTAMP,
    ...overrides,
  };
}

function wranglerUpload(overrides = {}) {
  return {
    type: "version-upload",
    version: 1,
    worker_name: EXPECTED_WORKER_NAME,
    worker_tag: "worker-tag",
    version_id: UPLOADED_VERSION,
    preview_url: null,
    preview_alias_url: null,
    wrangler_environment: "",
    worker_name_overridden: false,
    timestamp: WRANGLER_OUTPUT_TIMESTAMP,
    ...overrides,
  };
}

function wranglerOutput(...entries) {
  return Buffer.from(
    `${entries.map((entry) => JSON.stringify(entry)).join("\n")}\n`,
  );
}

before(() => {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", {
    modulusLength: 2_048,
    publicExponent: 65_537,
  });
  privatePem = privateKey
    .export({ format: "pem", type: "pkcs8" })
    .toString();
  publicPem = publicKey
    .export({ format: "pem", type: "spki" })
    .toString();
});

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) =>
      rm(path, { recursive: true, force: true }),
    ),
  );
});

async function uploadOptions({
  configuredKid = EXPECTED_KID,
  wranglerConfig,
} = {}) {
  const directory = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-upload-test-"),
    ),
  );
  temporaryDirectories.push(directory);
  await chmod(directory, 0o700);
  const secretsFile = join(directory, "secrets.json");
  const publicKeyFile = join(directory, "public.pem");
  const appProofKeyFile = join(directory, "app-proof.key");
  const secretsBytes = Buffer.from(JSON.stringify({
    ALCHEMY_JWT_PRIVATE_KEY: privatePem,
    ALCHEMY_JWT_REQUEST_PROOF_KEY: REQUEST_PROOF_KEY,
  }));
  await writeFile(secretsFile, secretsBytes, { mode: 0o600 });
  await writeFile(publicKeyFile, publicPem, { mode: 0o644 });
  await writeFile(appProofKeyFile, `${REQUEST_PROOF_KEY}\n`, {
    mode: 0o600,
  });
  const wranglerConfigPath = join(directory, "wrangler.jsonc");
  const configBytes = Buffer.from(
    wranglerConfig ?? JSON.stringify({
      name: EXPECTED_WORKER_NAME,
      main: "src/index.ts",
      vars: {
        ALCHEMY_KEY_ID: configuredKid,
      },
      observability: PRODUCTION_OBSERVABILITY,
    }),
  );
  await writeFile(
    wranglerConfigPath,
    configBytes,
    { mode: 0o600 },
  );
  const sourceDirectory = join(directory, "src");
  const sourcePath = join(sourceDirectory, "index.ts");
  const sourceBytes = Buffer.from("export default {};\n");
  await mkdir(sourceDirectory);
  await writeFile(sourcePath, sourceBytes, { mode: 0o600 });
  return {
    secretsFile,
    publicKeyFile,
    appProofKeyFile,
    expectedKid: EXPECTED_KID,
    tag: "validated-upload-test",
    message: "Validated upload test",
    secretsBytes,
    configBytes,
    wranglerConfigPath,
    sourceBytes,
    sourcePath,
  };
}

function uploadDependencies(options, overrides = {}) {
  return {
    wranglerConfigPath: options.wranglerConfigPath,
    expectedRequestProofKeyFingerprint:
      REQUEST_PROOF_KEY_FINGERPRINT,
    uploadedVersionReader: async () => UPLOADED_VERSION,
    stdout: () => undefined,
    ...overrides,
  };
}

test("parses only the fixed validated-upload interface", () => {
  assert.deepEqual(
    parseUploadArguments([
      "--secrets-file", "/protected/secrets.json",
      "--public-key-file", "/protected/public.pem",
      "--app-proof-key-file", "/protected/app-proof.key",
      "--expected-kid", EXPECTED_KID,
      "--tag", "release-tag",
      "--message", "Release message",
    ]),
    {
      help: false,
      secretsFile: "/protected/secrets.json",
      publicKeyFile: "/protected/public.pem",
      appProofKeyFile: "/protected/app-proof.key",
      expectedKid: EXPECTED_KID,
      tag: "release-tag",
      message: "Release message",
    },
  );
  assert.throws(
    () => parseUploadArguments([
      "--secrets-file", "/protected/secrets.json",
      "--public-key-file", "/protected/public.pem",
      "--app-proof-key-file", "/protected/app-proof.key",
      "--expected-kid", EXPECTED_KID,
      "--tag", "release-tag",
      "--message", "Release message",
      "--keep-vars", "true",
    ]),
    /unknown command-line option/u,
  );
});

test("parses the pinned Wrangler session and one canonical upload", () => {
  const validSession = wranglerSession();
  const validUpload = wranglerUpload();
  assert.equal(
    parseVersionUploadOutput(
      wranglerOutput(validSession, validUpload),
      EXPECTED_WORKER_NAME,
    ),
    UPLOADED_VERSION,
  );
  for (const bytes of [
    Buffer.alloc(0),
    Buffer.from(
      `${JSON.stringify(validSession)}\n${JSON.stringify(validUpload)}`,
    ),
    wranglerOutput(validUpload),
    wranglerOutput(validSession),
    Buffer.from("{}\n"),
    Buffer.from("not-json\n"),
    wranglerOutput(validUpload, validSession),
    wranglerOutput(validSession, validSession),
    wranglerOutput(validUpload, validUpload),
    wranglerOutput(validSession, validUpload, validUpload),
    wranglerOutput(validSession, {
      type: "command-failed",
      version: 1,
      timestamp: WRANGLER_OUTPUT_TIMESTAMP,
    }),
    wranglerOutput(
      wranglerSession({ wrangler_version: "4.111.0" }),
      validUpload,
    ),
    wranglerOutput(
      wranglerSession({ command_line_args: ["versions", 1] }),
      validUpload,
    ),
    wranglerOutput(
      wranglerSession({
        command_line_args: ["deployments", "status", "--strict"],
      }),
      validUpload,
    ),
    wranglerOutput(
      wranglerSession({ log_file_path: "relative.log" }),
      validUpload,
    ),
    wranglerOutput(
      wranglerSession({ timestamp: "2026-07-20" }),
      validUpload,
    ),
    wranglerOutput(validSession, wranglerUpload({
      type: "deploy",
    })),
    wranglerOutput(validSession, wranglerUpload({
      version_id: UPLOADED_VERSION.toUpperCase(),
    })),
    wranglerOutput(validSession, wranglerUpload({
      timestamp: "not-a-timestamp",
    })),
  ]) {
    assert.throws(
      () => parseVersionUploadOutput(bytes, EXPECTED_WORKER_NAME),
      SafeUploadError,
    );
  }
});

test("uploads an immutable protected snapshot and cleans it up", async () => {
  const options = await uploadOptions();
  let snapshotPath;
  let emptyEnvironmentPath;
  let stagedConfigPath;
  let outputFilePath;

  await safeUploadVersion(options, uploadDependencies(options, {
    runner: async (invocation) => {
      snapshotPath = invocation.snapshotPath;
      emptyEnvironmentPath = invocation.emptyEnvironmentPath;
      stagedConfigPath = invocation.wranglerConfigPath;
      outputFilePath = invocation.outputFilePath;
      assert.notEqual(snapshotPath, options.secretsFile);
      assert.notEqual(stagedConfigPath, options.wranglerConfigPath);
      const fileStats = await stat(snapshotPath);
      const directoryStats = await stat(dirname(snapshotPath));
      assert.equal(fileStats.mode & 0o777, 0o600);
      assert.equal(directoryStats.mode & 0o777, 0o700);
      assert.equal(
        (await stat(emptyEnvironmentPath)).mode & 0o777,
        0o600,
      );
      assert.deepEqual(
        await readFile(emptyEnvironmentPath),
        Buffer.alloc(0),
      );
      assert.equal(
        (await stat(outputFilePath)).mode & 0o777,
        0o600,
      );
      assert.deepEqual(await readFile(outputFilePath), Buffer.alloc(0));

      await writeFile(
        options.secretsFile,
        Buffer.alloc(options.secretsBytes.byteLength, 0x78),
      );
      await writeFile(
        options.wranglerConfigPath,
        Buffer.from("{}"),
      );
      await writeFile(
        options.sourcePath,
        Buffer.from("throw new Error();\n"),
      );
      assert.deepEqual(
        await readFile(snapshotPath),
        options.secretsBytes,
      );
      assert.deepEqual(
        await readFile(stagedConfigPath),
        options.configBytes,
      );
      assert.deepEqual(
        await readFile(
          join(dirname(stagedConfigPath), "src", "index.ts"),
        ),
        options.sourceBytes,
      );
      await assert.rejects(
        access(join(dirname(stagedConfigPath), "app-proof.key")),
      );
      assert.equal(invocation.tag, options.tag);
      assert.equal(invocation.message, options.message);
      assert.equal(invocation.workerName, EXPECTED_WORKER_NAME);
      assert.equal(invocation.expectedKid, options.expectedKid);
    },
  }));

  await assert.rejects(access(snapshotPath));
  await assert.rejects(access(emptyEnvironmentPath));
  await assert.rejects(access(stagedConfigPath));
  await assert.rejects(access(outputFilePath));
});

test("validated upload emits only the parsed uploaded version after cleanup", async () => {
  const options = await uploadOptions();
  const output = [];
  let outputFilePath;
  const version = await safeUploadVersion(
    options,
    uploadDependencies(options, {
      uploadedVersionReader: undefined,
      stdout: (message) => output.push(message),
      runner: async (invocation) => {
        outputFilePath = invocation.outputFilePath;
        await writeFile(
          outputFilePath,
          wranglerOutput(
            wranglerSession(),
            wranglerUpload(),
          ),
        );
      },
    }),
  );
  assert.equal(version, UPLOADED_VERSION);
  assert.deepEqual(output, [
    `validated-upload: pass version=${UPLOADED_VERSION}\n`,
  ]);
  await assert.rejects(access(outputFilePath));
});

test("validated upload clears retained signing-bundle bytes", async () => {
  for (const failRunner of [false, true]) {
    const options = await uploadOptions();
    const retainedSecrets = Buffer.from("sensitive signing bundle");
    const operation = safeUploadVersion(
      options,
      uploadDependencies(options, {
        keypairPreparer: async () => ({
          secretsBytes: retainedSecrets,
        }),
        runner: async () => {
          if (failRunner) {
            throw new SafeUploadError("test runner failure");
          }
        },
      }),
    );
    if (failRunner) {
      await assert.rejects(operation, /test runner failure/u);
    } else {
      assert.equal(await operation, UPLOADED_VERSION);
    }
    assert.deepEqual(
      retainedSecrets,
      Buffer.alloc(retainedSecrets.byteLength),
    );
  }
});

test("missing Wrangler upload output fails closed and is cleaned", async () => {
  const options = await uploadOptions();
  let outputFilePath;
  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      uploadedVersionReader: undefined,
      runner: async (invocation) => {
        outputFilePath = invocation.outputFilePath;
      },
    })),
    /could not be read safely/u,
  );
  await assert.rejects(access(outputFilePath));
});

test("detects snapshot mutation before invoking Wrangler", async () => {
  const options = await uploadOptions();
  let runnerCalled = false;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      beforeSnapshotVerification: async (snapshotPath) => {
        await writeFile(
          snapshotPath,
          Buffer.alloc(options.secretsBytes.byteLength, 0x78),
        );
      },
      runner: async () => {
        runnerCalled = true;
      },
    })),
    /snapshot changed before upload/u,
  );
  assert.equal(runnerCalled, false);
});

test("concurrent Worker source changes block upload and clean snapshots", async () => {
  const mutations = {
    rewrite: async (options) => {
      await writeFile(options.sourcePath, "export default { changed: true };\n");
    },
    swap: async (options) => {
      const replacement = join(dirname(options.sourcePath), "replacement.ts");
      await writeFile(replacement, "export default { swapped: true };\n");
      await rename(replacement, options.sourcePath);
    },
    add: async (options) => {
      await writeFile(
        join(dirname(options.sourcePath), "added.ts"),
        "export const added = true;\n",
      );
    },
    remove: async (options) => {
      await unlink(options.sourcePath);
    },
    symlink: async (options) => {
      await unlink(options.sourcePath);
      await symlink(options.wranglerConfigPath, options.sourcePath);
    },
  };

  for (const mutate of Object.values(mutations)) {
    const options = await uploadOptions();
    let runnerCalled = false;
    let removedTemporaryDirectory;
    await assert.rejects(
      safeUploadVersion(options, uploadDependencies(options, {
        productionSnapshotFactory: (contract, snapshotOptions) =>
          createProtectedProductionSnapshot(contract, {
            ...snapshotOptions,
            snapshotHooks: {
              beforeSourceTreeVerification: () => mutate(options),
            },
          }),
        removeTemporaryDirectory: async (path) => {
          removedTemporaryDirectory = path;
          await rm(path, { recursive: true, force: true });
        },
        runner: async () => {
          runnerCalled = true;
        },
      })),
      SafeUploadError,
    );
    assert.equal(runnerCalled, false);
    await assert.rejects(access(removedTemporaryDirectory));
  }
});

test("cleans the protected snapshot after runner failure", async () => {
  const options = await uploadOptions();
  let snapshotPath;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      runner: async (invocation) => {
        snapshotPath = invocation.snapshotPath;
        throw new Error("runner sentinel");
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message === "validated Worker version upload failed" &&
      !error.message.includes(options.secretsFile) &&
      !error.message.includes("runner sentinel"),
  );
  await assert.rejects(access(snapshotPath));
});

test("fails closed and redacts a protected snapshot cleanup failure", async () => {
  const options = await uploadOptions();

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      runner: async () => undefined,
      removeTemporaryDirectory: async () => {
        throw new Error(`cleanup sentinel: ${options.secretsFile}`);
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message === "protected upload snapshot cleanup failed" &&
      !error.message.includes(options.secretsFile) &&
      !error.message.includes("cleanup sentinel"),
  );
});

test("reports cleanup failure without hiding the primary upload failure", async () => {
  const options = await uploadOptions();

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      runner: async () => {
        throw new SafeUploadError("Wrangler version upload failed");
      },
      removeTemporaryDirectory: async () => {
        throw new Error("cleanup sentinel");
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message ===
        "Wrangler version upload failed; protected upload snapshot cleanup also failed" &&
      !error.message.includes(options.secretsFile) &&
      !error.message.includes("cleanup sentinel"),
  );
});

test("rejects a mismatched configured kid before snapshot or upload", async () => {
  const configuredKid = "different-configured-kid";
  const options = await uploadOptions({ configuredKid });
  let snapshotCreated = false;
  let runnerCalled = false;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      beforeSnapshotVerification: async () => {
        snapshotCreated = true;
      },
      runner: async () => {
        runnerCalled = true;
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message ===
        "Wrangler key ID configuration does not match expected metadata" &&
      !error.message.includes(configuredKid) &&
      !error.message.includes(EXPECTED_KID) &&
      !error.message.includes(options.wranglerConfigPath),
  );
  assert.equal(snapshotCreated, false);
  assert.equal(runnerCalled, false);
});

test("validated upload requires the production observability policy", async () => {
  for (const observability of [
    undefined,
    true,
    {
      ...PRODUCTION_OBSERVABILITY,
      traces: { enabled: true },
    },
    {
      ...PRODUCTION_OBSERVABILITY,
      traces: { enabled: false, head_sampling_rate: 0 },
    },
  ]) {
    const options = await uploadOptions({
      wranglerConfig: JSON.stringify({
        name: EXPECTED_WORKER_NAME,
        main: "src/index.ts",
        vars: {
          ALCHEMY_KEY_ID: EXPECTED_KID,
        },
        observability,
      }),
    });
    let runnerCalled = false;
    await assert.rejects(
      safeUploadVersion(options, uploadDependencies(options, {
        runner: async () => {
          runnerCalled = true;
        },
      })),
      SafeUploadError,
    );
    assert.equal(runnerCalled, false);
  }
});

test("accepts comments and trailing commas supported by Wrangler JSONC", async () => {
  const options = await uploadOptions({
    wranglerConfig: [
      "{",
      "  // The pinned Wrangler parser owns JSONC semantics.",
      `  "name": "${EXPECTED_WORKER_NAME}",`,
      "  \"main\": \"src/index.ts\",",
      "  \"vars\": {",
      `    "ALCHEMY_KEY_ID": "${EXPECTED_KID}",`,
      "  },",
      "  \"observability\": {",
      "    \"enabled\": true,",
      "    \"logs\": {",
      "      \"enabled\": true,",
      "      \"head_sampling_rate\": 1,",
      "      \"invocation_logs\": false,",
      "    },",
      "    \"traces\": { \"enabled\": false },",
      "  },",
      "}",
    ].join("\n"),
  });
  let runnerCalled = false;

  await safeUploadVersion(options, uploadDependencies(options, {
    runner: async () => {
      runnerCalled = true;
    },
  }));
  assert.equal(runnerCalled, true);
});

test("rejects malformed Wrangler configuration without disclosing input", async () => {
  const configuredKid = "malformed-config-kid";
  const options = await uploadOptions({
    wranglerConfig:
      `{"vars":{"ALCHEMY_KEY_ID":"${configuredKid}"`,
  });
  let runnerCalled = false;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      runner: async () => {
        runnerCalled = true;
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message ===
        "Wrangler configuration could not be validated" &&
      !error.message.includes(configuredKid) &&
      !error.message.includes(EXPECTED_KID) &&
      !error.message.includes(options.wranglerConfigPath),
  );
  assert.equal(runnerCalled, false);
});

test("rejects duplicate Wrangler properties as ambiguous", async () => {
  const options = await uploadOptions({
    wranglerConfig: [
      "{",
      "  \"vars\": {",
      `    "ALCHEMY_KEY_ID": "${EXPECTED_KID}",`,
      `    "ALCHEMY_KEY_ID": "${EXPECTED_KID}"`,
      "  }",
      "}",
    ].join("\n"),
  });
  let runnerCalled = false;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      runner: async () => {
        runnerCalled = true;
      },
    })),
    (error) =>
      error instanceof SafeUploadError &&
      error.message === "Wrangler configuration is ambiguous" &&
      !error.message.includes(EXPECTED_KID) &&
      !error.message.includes(options.wranglerConfigPath),
  );
  assert.equal(runnerCalled, false);
});

function fakeChild(onKill) {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.kill = onKill;
  return child;
}

function pinnedRunnerOptions(overrides = {}) {
  return {
    snapshotPath: "/protected/snapshot.json",
    emptyEnvironmentPath: "/protected/empty.env",
    outputFilePath: "/protected/wrangler-output.ndjson",
    wranglerConfigPath: "/worker/wrangler.jsonc",
    workerName: EXPECTED_WORKER_NAME,
    expectedKid: EXPECTED_KID,
    tag: "test-tag",
    message: "Test upload",
    stdout: () => undefined,
    stderr: () => undefined,
    parentEnvironment: {
      CLOUDFLARE_API_TOKEN: "test-auth-token",
    },
    ...overrides,
  };
}

test("interrupting Wrangler terminates and settles the child", async () => {
  const controller = new AbortController();
  const killSignals = [];
  let spawnArguments;
  let child;

  const run = runPinnedWrangler(pinnedRunnerOptions({
    abortSignal: controller.signal,
    childTerminationGraceMilliseconds: 50,
    spawnProcess: (...arguments_) => {
      spawnArguments = arguments_;
      child = fakeChild((signal) => {
        killSignals.push(signal);
        queueMicrotask(() => child.emit("close", null, signal));
        return true;
      });
      return child;
    },
  }));
  controller.abort(new UploadInterruptedError("SIGTERM"));

  await assert.rejects(
    run,
    (error) =>
      error instanceof UploadInterruptedError &&
      error.signal === "SIGTERM",
  );
  assert.deepEqual(killSignals, ["SIGTERM"]);
  assert.deepEqual(
    spawnArguments[1].slice(1, 12),
    [
      "versions",
      "upload",
      "--config",
      "/worker/wrangler.jsonc",
      "--env-file",
      "/protected/empty.env",
      "--env=",
      "--name",
      EXPECTED_WORKER_NAME,
      "--var",
      `ALCHEMY_KEY_ID:${EXPECTED_KID}`,
    ],
  );
});

test("Wrangler spawn cannot inherit a named Worker environment", async () => {
  const parentEnvironment = {
    CLOUDFLARE_API_TOKEN: "test-auth-token",
    CLOUDFLARE_API_BASE_URL: "https://attacker.invalid",
    CLOUDFLARE_ENV: "unvalidated-environment",
    CF_API_BASE_URL: "https://attacker.invalid",
    cloudflare_api_base_url: "https://lowercase-attacker.invalid",
    HOME: "/test/home",
    https_proxy: "http://attacker.invalid",
    NODE_OPTIONS: "--require=/tmp/attacker.cjs",
    PATH: "/test/bin",
    WRANGLER_API_ENVIRONMENT: "staging",
    WRANGLER_CI_OVERRIDE_NAME: "wrong-worker",
    WRANGLER_LOG: "debug",
    WRANGLER_LOG_PATH: "/tmp/exposed-logs",
    WRANGLER_LOG_SANITIZE: "false",
    WRANGLER_OUTPUT_FILE_PATH: "/tmp/attacker-output.ndjson",
    WRANGLER_WRITE_LOGS: "true",
    wrangler_log_path: "/tmp/lowercase-exposed-logs",
    wrangler_log_sanitize: "false",
  };
  let spawnOptions;
  let spawnArguments;
  let child;

  await runPinnedWrangler(pinnedRunnerOptions({
    parentEnvironment,
    spawnProcess: (...arguments_) => {
      spawnArguments = arguments_;
      spawnOptions = arguments_[2];
      child = fakeChild(() => true);
      queueMicrotask(() => child.emit("close", 0));
      return child;
    },
  }));

  assert.ok(spawnArguments[1].includes("--env="));
  assert.ok(spawnArguments[1].includes("--env-file"));
  assert.ok(spawnArguments[1].includes("--name"));
  assert.notEqual(spawnOptions.env, parentEnvironment);
  assert.deepEqual(spawnOptions.env, {
    CI: "1",
    CLOUDFLARE_COMPLIANCE_REGION: "public",
    CLOUDFLARE_API_TOKEN: "test-auth-token",
    PATH: "/test/bin",
    WRANGLER_API_ENVIRONMENT: "production",
    WRANGLER_LOG: "log",
    WRANGLER_LOG_SANITIZE: "true",
    WRANGLER_OUTPUT_FILE_PATH: "/protected/wrangler-output.ndjson",
    WRANGLER_WRITE_LOGS: "false",
  });
  assert.equal(
    parentEnvironment.CLOUDFLARE_ENV,
    "unvalidated-environment",
  );
});

test("Wrangler upload requires one API token and rejects legacy auth", async () => {
  for (const parentEnvironment of [
    {},
    { CLOUDFLARE_API_TOKEN: "" },
    {
      CLOUDFLARE_API_TOKEN: "test-auth-token",
      CLOUDFLARE_API_KEY: "legacy-key",
      CLOUDFLARE_EMAIL: "legacy@example.com",
    },
    {
      CLOUDFLARE_API_TOKEN: "test-auth-token",
      cloudflare_api_token: "ambiguous-token",
    },
  ]) {
    let spawned = false;
    await assert.rejects(
      runPinnedWrangler(pinnedRunnerOptions({
        parentEnvironment,
        spawnProcess: () => {
          spawned = true;
          throw new Error("must not spawn");
        },
      })),
      /required|not supported/u,
    );
    assert.equal(spawned, false);
  }
});

test("upload metadata cannot be reinterpreted as Wrangler flags", async () => {
  let spawnArguments;
  let child;
  await runPinnedWrangler(pinnedRunnerOptions({
    tag: "--config=/tmp/attacker.jsonc",
    message: "--profile",
    spawnProcess: (...arguments_) => {
      spawnArguments = arguments_[1];
      child = fakeChild(() => true);
      queueMicrotask(() => child.emit("close", 0));
      return child;
    },
  }));

  assert.ok(spawnArguments.includes("--tag=--config=/tmp/attacker.jsonc"));
  assert.ok(spawnArguments.includes("--message=--profile"));
  assert.equal(spawnArguments.includes("/tmp/attacker.jsonc"), false);
  assert.equal(spawnArguments.includes("--profile"), false);
});

test("an interrupted child that does not settle is escalated to SIGKILL", async () => {
  const controller = new AbortController();
  const killSignals = [];
  let child;

  const run = runPinnedWrangler(pinnedRunnerOptions({
    abortSignal: controller.signal,
    childTerminationGraceMilliseconds: 0,
    spawnProcess: () => {
      child = fakeChild((signal) => {
        killSignals.push(signal);
        if (signal === "SIGKILL") {
          queueMicrotask(() =>
            child.emit("close", null, "SIGKILL"),
          );
        }
        return true;
      });
      return child;
    },
  }));
  controller.abort(new UploadInterruptedError("SIGINT"));

  await assert.rejects(run, UploadInterruptedError);
  assert.deepEqual(killSignals, ["SIGTERM", "SIGKILL"]);
});

test("failed Wrangler output redacts upload metadata", async () => {
  const output = [];
  const errors = [];
  const options = pinnedRunnerOptions({
    stdout: (message) => output.push(message),
    stderr: (message) => errors.push(message),
  });
  let child;

  const run = runPinnedWrangler({
    ...options,
    spawnProcess: () => {
      child = fakeChild(() => true);
      queueMicrotask(() => {
        child.stdout.emit(
          "data",
          `snapshot=${options.snapshotPath} kid=${options.expectedKid}\n`,
        );
        child.stderr.emit(
          "data",
          `config=${options.wranglerConfigPath} output=${options.outputFilePath}\n`,
        );
        child.emit("close", 1);
      });
      return child;
    },
  });

  await assert.rejects(run, SafeUploadError);
  assert.deepEqual(output, [
    "snapshot=<protected-secrets-file> kid=<expected-kid>\n",
  ]);
  assert.deepEqual(errors, [
    "config=<wrangler-config> output=<wrangler-output-file>\n",
  ]);
});

test("successful Wrangler output is suppressed until the UUID is parsed", async () => {
  const output = [];
  const errors = [];
  let child;
  await runPinnedWrangler(pinnedRunnerOptions({
    stdout: (message) => output.push(message),
    stderr: (message) => errors.push(message),
    spawnProcess: () => {
      child = fakeChild(() => true);
      queueMicrotask(() => {
        child.stdout.emit("data", "Wrangler success detail\n");
        child.stderr.emit("data", "Wrangler warning detail\n");
        child.emit("close", 0);
      });
      return child;
    },
  }));
  assert.deepEqual(output, []);
  assert.deepEqual(errors, []);
});

test("interruption cleans the protected snapshot after runner settlement", async () => {
  const options = await uploadOptions();
  const controller = new AbortController();
  let snapshotPath;
  let runnerSettled = false;

  await assert.rejects(
    safeUploadVersion(options, uploadDependencies(options, {
      abortSignal: controller.signal,
      runner: async (invocation) => {
        snapshotPath = invocation.snapshotPath;
        controller.abort(new UploadInterruptedError("SIGHUP"));
        await Promise.resolve();
        runnerSettled = true;
        throw controller.signal.reason;
      },
      removeTemporaryDirectory: async (path) => {
        assert.equal(runnerSettled, true);
        await rm(path, { recursive: true, force: true });
      },
    })),
    (error) =>
      error instanceof UploadInterruptedError &&
      error.signal === "SIGHUP",
  );
  await assert.rejects(access(snapshotPath));
});

test("uploadMain re-signals only after interruption and removes listeners", async () => {
  const signalEmitter = new EventEmitter();
  const output = [];
  const errors = [];
  const resignals = [];

  const result = await uploadMain([
    "--secrets-file", "/protected/secrets.json",
    "--public-key-file", "/protected/public.pem",
    "--app-proof-key-file", "/protected/app-proof.key",
    "--expected-kid", EXPECTED_KID,
    "--tag", "release-tag",
    "--message", "Release message",
  ], {
    stdout: (message) => output.push(message),
    stderr: (message) => errors.push(message),
    signalEmitter,
    resignal: (signal) => resignals.push(signal),
    uploader: async (_options, dependencies) => {
      dependencies.stdout("wrangler output\n");
      queueMicrotask(() => signalEmitter.emit("SIGINT"));
      await new Promise((resolve, reject) => {
        const onAbort = () => reject(
          dependencies.abortSignal.reason,
        );
        dependencies.abortSignal.addEventListener(
          "abort",
          onAbort,
          { once: true },
        );
      });
    },
  });

  assert.equal(result, 130);
  assert.deepEqual(output, ["wrangler output\n"]);
  assert.deepEqual(errors, []);
  assert.deepEqual(resignals, ["SIGINT"]);
  for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) {
    assert.equal(signalEmitter.listenerCount(signal), 0);
  }
});

test("uploadMain uses injected output for help and removes listeners", async () => {
  const signalEmitter = new EventEmitter();
  const output = [];
  const errors = [];

  const result = await uploadMain(["--help"], {
    stdout: (message) => output.push(message),
    stderr: (message) => errors.push(message),
    signalEmitter,
    resignal: () => assert.fail("help must not re-signal"),
  });

  assert.equal(result, 0);
  assert.equal(output.length, 1);
  assert.match(output[0], /^Usage:/u);
  assert.match(output[0], /\n$/u);
  assert.deepEqual(errors, []);
  for (const signal of ["SIGHUP", "SIGINT", "SIGTERM"]) {
    assert.equal(signalEmitter.listenerCount(signal), 0);
  }
});
