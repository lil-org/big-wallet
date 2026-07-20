#!/usr/bin/env node

import { spawn } from "node:child_process";
import { isAbsolute, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  fetchBoundedWithTimeout,
  SafeValidationError,
  verifyReleaseLiveContract,
} from "./live-validate.mjs";
import {
  createProtectedProductionSnapshot,
  loadProductionWranglerContract,
  PINNED_WRANGLER_PATH,
  productionWranglerArguments,
  productionWranglerEnvironment,
  SafeProductionWranglerError,
} from "./production-contract.mjs";

const MAX_WRANGLER_OUTPUT_BYTES = 1024 * 1024;
const MAX_SCRIPT_SETTINGS_BYTES = 256 * 1024;
const SCRIPT_SETTINGS_TIMEOUT_MS = 15_000;
const CLOUDFLARE_API_ORIGIN = "https://api.cloudflare.com";
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const PRINTABLE_KEY_ID = /^[\u0021-\u007e]{1,256}$/u;
const WORKER_NAME_PATTERN =
  /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u;
const PRINTABLE_API_TOKEN = /^[\u0021-\u007e]{1,4096}$/u;
const STATUS_COMMAND = ["deployments", "status", "--json"];
const LEGACY_CLOUDFLARE_CREDENTIALS = [
  "CLOUDFLARE_API_KEY",
  "CLOUDFLARE_API_USER_SERVICE_KEY",
  "CLOUDFLARE_EMAIL",
];

export class SafeReleaseVerificationError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafeReleaseVerificationError";
  }
}

function fail(message) {
  return new SafeReleaseVerificationError(message);
}

function usage() {
  return [
    "Usage: npm run verify:release -- [options]",
    "",
    "Required options:",
    "  --expected-kid KID",
    "  --expected-version UUID",
    "  --app-proof-key-file PATH",
    "",
    "The command reads fixed deployment status and Worker settings endpoints,",
    "then validates the fixed public issuer endpoint.",
    "It cannot upload, deploy, change secrets, or override Worker routing.",
  ].join("\n");
}

export function parseReleaseVerificationArguments(arguments_) {
  if (arguments_.length === 1 && arguments_[0] === "--help") {
    return { help: true };
  }
  const parsed = {
    help: false,
    expectedKid: undefined,
    expectedVersion: undefined,
    appProofKeyFile: undefined,
  };
  const fields = new Map([
    ["--expected-kid", "expectedKid"],
    ["--expected-version", "expectedVersion"],
    ["--app-proof-key-file", "appProofKeyFile"],
  ]);
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    const field = fields.get(argument);
    if (field === undefined) {
      throw fail("unknown release verification option");
    }
    if (parsed[field] !== undefined) {
      throw fail(`duplicate option ${argument}`);
    }
    const value = arguments_[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw fail(`missing value for ${argument}`);
    }
    parsed[field] = value;
    index += 1;
  }
  if (
    parsed.expectedKid === undefined ||
    parsed.expectedVersion === undefined ||
    parsed.appProofKeyFile === undefined
  ) {
    throw fail("all release verification options are required");
  }
  if (!PRINTABLE_KEY_ID.test(parsed.expectedKid)) {
    throw fail("expected release kid is invalid");
  }
  if (!CANONICAL_UUID.test(parsed.expectedVersion)) {
    throw fail("expected release version must be a canonical lowercase UUID");
  }
  if (
    !isAbsolute(parsed.appProofKeyFile) ||
    resolve(parsed.appProofKeyFile) !== parsed.appProofKeyFile
  ) {
    throw fail("app proof key path must be canonical and absolute");
  }
  return parsed;
}

function isPlainObject(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

export function parseDeploymentStatus(bytes) {
  if (
    !(bytes instanceof Uint8Array) ||
    bytes.byteLength === 0 ||
    bytes.byteLength > MAX_WRANGLER_OUTPUT_BYTES
  ) {
    throw fail("deployment status output is invalid");
  }
  let parsed;
  try {
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    parsed = JSON.parse(text);
  } catch {
    throw fail("deployment status output is invalid");
  }
  if (!isPlainObject(parsed)) {
    throw fail("deployment status output is invalid");
  }
  return parsed;
}

export function assertExpectedProductionDeployment(
  deployment,
  expectedVersion,
) {
  if (
    !CANONICAL_UUID.test(expectedVersion) ||
    !isPlainObject(deployment) ||
    !Array.isArray(deployment.versions) ||
    deployment.versions.length !== 1
  ) {
    throw fail("production deployment does not match the pinned version");
  }
  const active = deployment.versions[0];
  if (
    !isPlainObject(active) ||
    active.version_id !== expectedVersion ||
    active.percentage !== 100
  ) {
    throw fail("production deployment does not match the pinned version");
  }
}

export function assertRemoteObservabilityPolicy(settingsEnvelope) {
  const result = settingsEnvelope?.result;
  const observability = result?.observability;
  const logs = observability?.logs;
  const traces = observability?.traces;
  if (
    !isPlainObject(settingsEnvelope) ||
    settingsEnvelope.success !== true ||
    !Array.isArray(settingsEnvelope.errors) ||
    settingsEnvelope.errors.length !== 0 ||
    !isPlainObject(result) ||
    !isPlainObject(observability) ||
    observability.enabled !== true ||
    !isPlainObject(logs) ||
    logs.enabled !== true ||
    logs.head_sampling_rate !== 1 ||
    logs.invocation_logs !== false ||
    !isPlainObject(traces) ||
    traces.enabled !== false
  ) {
    throw fail("remote Worker observability policy is invalid");
  }
}

export async function readRemoteScriptSettings({
  accountId,
  workerName,
  apiToken,
  fetchImplementation = fetch,
}) {
  if (
    !/^[0-9a-f]{32}$/u.test(accountId) ||
    !WORKER_NAME_PATTERN.test(workerName) ||
    !PRINTABLE_API_TOKEN.test(apiToken)
  ) {
    throw fail("remote Worker settings request is invalid");
  }
  const url = new URL(
    `/client/v4/accounts/${accountId}/workers/scripts/${workerName}/script-settings`,
    CLOUDFLARE_API_ORIGIN,
  );
  try {
    const { response, bytes } = await fetchBoundedWithTimeout(
      url,
      {
        method: "GET",
        redirect: "error",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${apiToken}`,
        },
      },
      SCRIPT_SETTINGS_TIMEOUT_MS,
      MAX_SCRIPT_SETTINGS_BYTES,
      "Worker settings verification",
      { fetchImplementation, readNonSuccessBody: false },
    );
    if (response.status !== 200) {
      throw fail("remote Worker settings request failed");
    }
    let envelope;
    try {
      envelope = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      );
    } catch {
      throw fail("remote Worker settings response is invalid");
    }
    assertRemoteObservabilityPolicy(envelope);
    return envelope;
  } catch (error) {
    if (error instanceof SafeReleaseVerificationError) {
      throw error;
    }
    throw fail("remote Worker settings request failed");
  }
}

async function collectBoundedOutput(stream, description) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of stream) {
    totalBytes += chunk.byteLength;
    if (totalBytes > MAX_WRANGLER_OUTPUT_BYTES) {
      throw fail(`${description} exceeded the safe size limit`);
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, totalBytes);
}

export function releaseVerificationEnvironment(parentEnvironment) {
  const apiToken = parentEnvironment.CLOUDFLARE_API_TOKEN;
  if (
    typeof apiToken !== "string" ||
    !PRINTABLE_API_TOKEN.test(apiToken)
  ) {
    throw fail("CLOUDFLARE_API_TOKEN is required for release verification");
  }
  for (const name of LEGACY_CLOUDFLARE_CREDENTIALS) {
    if (
      typeof parentEnvironment[name] === "string" &&
      parentEnvironment[name] !== ""
    ) {
      throw fail("legacy Cloudflare credentials are not supported");
    }
  }
  const childEnvironment = productionWranglerEnvironment(parentEnvironment);
  for (const name of LEGACY_CLOUDFLARE_CREDENTIALS) {
    delete childEnvironment[name];
  }
  childEnvironment.CLOUDFLARE_API_TOKEN = apiToken;
  return childEnvironment;
}

export async function runPinnedDeploymentStatus({
  arguments_,
  workingDirectory,
  parentEnvironment = process.env,
  spawnProcess = spawn,
}) {
  if (
    !Array.isArray(arguments_) ||
    arguments_.length !== 8 ||
    arguments_[0] !== PINNED_WRANGLER_PATH ||
    !STATUS_COMMAND.every(
      (argument, index) => arguments_[index + 1] === argument,
    ) ||
    typeof workingDirectory !== "string" ||
    resolve(workingDirectory) !== workingDirectory ||
    arguments_[4] !== `--config=${workingDirectory}/wrangler.jsonc` ||
    arguments_[5] !==
      `--env-file=${resolve(workingDirectory, "..", "empty.env")}` ||
    arguments_[6] !== "--env=" ||
    !arguments_[7].startsWith("--name=") ||
    !WORKER_NAME_PATTERN.test(arguments_[7].slice("--name=".length))
  ) {
    throw fail("release verification Wrangler command is invalid");
  }

  const child = spawnProcess(process.execPath, arguments_, {
    cwd: workingDirectory,
    env: releaseVerificationEnvironment(parentEnvironment),
    shell: false,
    stdio: ["ignore", "pipe", "pipe"],
  });
  if (child.stdout === null || child.stderr === null) {
    throw fail("release verification Wrangler command could not be captured");
  }

  try {
    const exitCodePromise = new Promise((resolveExit, rejectExit) => {
      child.once("error", rejectExit);
      child.once("close", resolveExit);
    });
    const [stdout, , exitCode] = await Promise.all([
      collectBoundedOutput(child.stdout, "Wrangler standard output"),
      collectBoundedOutput(child.stderr, "Wrangler standard error"),
      exitCodePromise,
    ]);
    if (exitCode !== 0) {
      throw fail("release verification deployment-status command failed");
    }
    return stdout;
  } catch (error) {
    child.kill();
    if (error instanceof SafeReleaseVerificationError) {
      throw error;
    }
    throw fail("release verification deployment-status command failed");
  }
}

export async function executeReleaseVerification(
  options,
  {
    contractLoader = loadProductionWranglerContract,
    snapshotFactory = createProtectedProductionSnapshot,
    deploymentStatusRunner = runPinnedDeploymentStatus,
    scriptSettingsReader = readRemoteScriptSettings,
    liveVerifier = verifyReleaseLiveContract,
    parentEnvironment = process.env,
  } = {},
) {
  const contract = await contractLoader();
  const childEnvironment = releaseVerificationEnvironment(
    parentEnvironment,
  );
  const snapshot = await snapshotFactory(contract);
  let statusBytes;
  try {
    const arguments_ = productionWranglerArguments({
      commandArguments: STATUS_COMMAND,
      configPath: snapshot.configPath,
      workerName: contract.workerName,
      emptyEnvironmentPath: snapshot.emptyEnvironmentPath,
    });
    await snapshot.verify();
    statusBytes = await deploymentStatusRunner({
      arguments_,
      workingDirectory: snapshot.workerDirectory,
      parentEnvironment: childEnvironment,
    });
  } finally {
    await snapshot.cleanup();
  }

  const deployment = parseDeploymentStatus(statusBytes);
  assertExpectedProductionDeployment(
    deployment,
    options.expectedVersion,
  );
  const settings = await scriptSettingsReader({
    accountId: contract.accountId,
    workerName: contract.workerName,
    apiToken: childEnvironment.CLOUDFLARE_API_TOKEN,
  });
  const live = await liveVerifier(options);
  return { deployment, settings, live };
}

export async function releaseVerificationMain(
  arguments_,
  {
    stdout = (message) => process.stdout.write(message),
    stderr = (message) => process.stderr.write(message),
    executor = executeReleaseVerification,
  } = {},
) {
  try {
    const options = parseReleaseVerificationArguments(arguments_);
    if (options.help) {
      stdout(`${usage()}\n`);
      return 0;
    }
    const result = await executor(options);
    stdout(
      `release-verification: pass version=${options.expectedVersion} traffic=100 traces=disabled probes=${result.live.probeCount} eth-mainnet=ok\n`,
    );
    return 0;
  } catch (error) {
    const message =
      error instanceof SafeReleaseVerificationError ||
      error instanceof SafeProductionWranglerError ||
      error instanceof SafeValidationError
        ? error.message
        : "release verification failed";
    stderr(`release-verification: failed: ${message}\n`);
    return 1;
  }
}

const isDirectExecution =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectExecution) {
  process.exitCode = await releaseVerificationMain(process.argv.slice(2));
}
