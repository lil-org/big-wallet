import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { EventEmitter } from "node:events";
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, before, test } from "node:test";

import {
  parseUploadArguments,
  runPinnedWrangler,
  SafeUploadError,
  safeUploadVersion,
  UploadInterruptedError,
  uploadMain,
} from "./upload-validated-version.mjs";

const EXPECTED_KID = "upload-test-kid";
const EXPECTED_WORKER_NAME = "upload-test-worker";
const temporaryDirectories = [];
let privatePem;
let publicPem;

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
  const directory = await mkdtemp(
    join(tmpdir(), "alchemy-jwt-upload-test-"),
  );
  temporaryDirectories.push(directory);
  await chmod(directory, 0o700);
  const secretsFile = join(directory, "secrets.json");
  const publicKeyFile = join(directory, "public.pem");
  const secretsBytes = Buffer.from(JSON.stringify({
    ALCHEMY_JWT_PRIVATE_KEY: privatePem,
  }));
  await writeFile(secretsFile, secretsBytes, { mode: 0o600 });
  await writeFile(publicKeyFile, publicPem, { mode: 0o644 });
  const wranglerConfigPath = join(directory, "wrangler.jsonc");
  const configBytes = Buffer.from(
    wranglerConfig ?? JSON.stringify({
      name: EXPECTED_WORKER_NAME,
      main: "src/index.ts",
      vars: {
        ALCHEMY_KEY_ID: configuredKid,
      },
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
    ...overrides,
  };
}

test("parses only the fixed validated-upload interface", () => {
  assert.deepEqual(
    parseUploadArguments([
      "--secrets-file", "/protected/secrets.json",
      "--public-key-file", "/protected/public.pem",
      "--expected-kid", EXPECTED_KID,
      "--tag", "release-tag",
      "--message", "Release message",
    ]),
    {
      help: false,
      secretsFile: "/protected/secrets.json",
      publicKeyFile: "/protected/public.pem",
      expectedKid: EXPECTED_KID,
      tag: "release-tag",
      message: "Release message",
    },
  );
  assert.throws(
    () => parseUploadArguments([
      "--secrets-file", "/protected/secrets.json",
      "--public-key-file", "/protected/public.pem",
      "--expected-kid", EXPECTED_KID,
      "--tag", "release-tag",
      "--message", "Release message",
      "--keep-vars", "true",
    ]),
    /unknown command-line option/u,
  );
});

test("uploads an immutable protected snapshot and cleans it up", async () => {
  const options = await uploadOptions();
  let snapshotPath;
  let emptyEnvironmentPath;
  let stagedConfigPath;

  await safeUploadVersion(options, uploadDependencies(options, {
    runner: async (invocation) => {
      snapshotPath = invocation.snapshotPath;
      emptyEnvironmentPath = invocation.emptyEnvironmentPath;
      stagedConfigPath = invocation.wranglerConfigPath;
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
      assert.equal(invocation.tag, options.tag);
      assert.equal(invocation.message, options.message);
      assert.equal(invocation.workerName, EXPECTED_WORKER_NAME);
      assert.equal(invocation.expectedKid, options.expectedKid);
    },
  }));

  await assert.rejects(access(snapshotPath));
  await assert.rejects(access(emptyEnvironmentPath));
  await assert.rejects(access(stagedConfigPath));
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
    wranglerConfigPath: "/worker/wrangler.jsonc",
    workerName: EXPECTED_WORKER_NAME,
    expectedKid: EXPECTED_KID,
    tag: "test-tag",
    message: "Test upload",
    stdout: () => undefined,
    stderr: () => undefined,
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
    HOME: "/test/home",
    PATH: "/test/bin",
    WRANGLER_API_ENVIRONMENT: "production",
    WRANGLER_LOG: "log",
    WRANGLER_LOG_SANITIZE: "true",
    WRANGLER_WRITE_LOGS: "false",
  });
  assert.equal(
    parentEnvironment.CLOUDFLARE_ENV,
    "unvalidated-environment",
  );
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

test("Wrangler output redacts upload metadata", async () => {
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
          `config=${options.wranglerConfigPath}\n`,
        );
        child.emit("close", 0);
      });
      return child;
    },
  });

  await run;
  assert.deepEqual(output, [
    "snapshot=<protected-secrets-file> kid=<expected-kid>\n",
  ]);
  assert.deepEqual(errors, ["config=<wrangler-config>\n"]);
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
