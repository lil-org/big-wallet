#!/usr/bin/env node

import {
  createHash,
  timingSafeEqual,
} from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  lstat,
  mkdtemp,
  open,
  realpath,
  rm,
} from "node:fs/promises";
import {
  constants as osConstants,
  tmpdir,
} from "node:os";
import {
  basename,
  dirname,
  join,
  resolve,
  sep,
} from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import { experimental_readRawConfig } from "wrangler";

import {
  prepareValidatedKeypair,
  readBoundedRegularFile,
  SafePreflightError,
} from "./validate-keypair.mjs";
import {
  assertProductionObservabilityPolicy,
  createProtectedProductionSnapshot,
  isValidWorkerName,
  PINNED_WRANGLER_PATH,
  PINNED_WRANGLER_VERSION,
  productionWranglerEnvironment,
  PRODUCTION_WRANGLER_CONFIG_PATH,
} from "./production-contract.mjs";

const MAX_SECRETS_FILE_BYTES = 32 * 1_024;
const MAX_WRANGLER_CONFIG_BYTES = 1_024 * 1_024;
const MAX_WRANGLER_OUTPUT_FILE_BYTES = 64 * 1_024;
const MAX_CAPTURED_OUTPUT_BYTES = 2 * 1_024 * 1_024;
const CHILD_TERMINATION_GRACE_MILLISECONDS = 2_000;
const PRINTABLE_KEY_ID = /^[\u0021-\u007e]{1,256}$/u;
const PRINTABLE_TAG = /^[\u0021-\u007e]{1,128}$/u;
const PRINTABLE_MESSAGE = /^[\u0020-\u007e]{1,512}$/u;
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const HANDLED_SIGNALS = [
  "SIGHUP",
  "SIGINT",
  "SIGTERM",
];

export class SafeUploadError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafeUploadError";
  }
}

export class UploadInterruptedError extends Error {
  constructor(signal) {
    super("validated Worker version upload interrupted");
    this.name = "UploadInterruptedError";
    this.signal = signal;
  }
}

function fail(message) {
  return new SafeUploadError(message);
}

function usage() {
  return [
    "Usage: node scripts/upload-validated-version.mjs [options]",
    "",
    "Required options:",
    "  --secrets-file PATH",
    "  --public-key-file PATH",
    "  --app-proof-key-file PATH",
    "  --expected-kid KID",
    "  --tag TAG",
    "  --message MESSAGE",
    "",
    "The command validates and snapshots the signing bundle before invoking",
    "the pinned local Wrangler with versions upload --strict.",
  ].join("\n");
}

export function parseUploadArguments(arguments_) {
  if (arguments_.length === 1 && arguments_[0] === "--help") {
    return { help: true };
  }

  const parsed = {
    help: false,
    secretsFile: undefined,
    publicKeyFile: undefined,
    appProofKeyFile: undefined,
    expectedKid: undefined,
    tag: undefined,
    message: undefined,
  };
  const fields = new Map([
    ["--secrets-file", "secretsFile"],
    ["--public-key-file", "publicKeyFile"],
    ["--app-proof-key-file", "appProofKeyFile"],
    ["--expected-kid", "expectedKid"],
    ["--tag", "tag"],
    ["--message", "message"],
  ]);

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    const field = fields.get(argument);
    if (field === undefined) {
      throw fail("unknown command-line option");
    }
    const value = arguments_[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw fail(`missing value for ${argument}`);
    }
    if (parsed[field] !== undefined) {
      throw fail(`duplicate option ${argument}`);
    }
    parsed[field] = value;
    index += 1;
  }

  if (
    parsed.secretsFile === undefined ||
    parsed.publicKeyFile === undefined ||
    parsed.appProofKeyFile === undefined ||
    parsed.expectedKid === undefined ||
    parsed.tag === undefined ||
    parsed.message === undefined
  ) {
    throw fail("all upload options are required");
  }
  if (
    !PRINTABLE_KEY_ID.test(parsed.expectedKid) ||
    !PRINTABLE_TAG.test(parsed.tag) ||
    !PRINTABLE_MESSAGE.test(parsed.message)
  ) {
    throw fail("upload metadata is invalid");
  }
  return parsed;
}

function digest(bytes) {
  return createHash("sha256").update(bytes).digest();
}

function sameFileIdentity(first, second) {
  return first.dev === second.dev && first.ino === second.ino;
}

function stableFileMetadata(first, second) {
  return (
    sameFileIdentity(first, second) &&
    first.mode === second.mode &&
    first.size === second.size &&
    first.mtimeMs === second.mtimeMs &&
    first.ctimeMs === second.ctimeMs
  );
}

async function readFileAtPosition(handle, size) {
  const bytes = Buffer.allocUnsafe(size);
  let offset = 0;
  while (offset < size) {
    const { bytesRead } = await handle.read(
      bytes,
      offset,
      size - offset,
      offset,
    );
    if (bytesRead <= 0) {
      throw fail("Wrangler configuration changed while it was validated");
    }
    offset += bytesRead;
  }
  return bytes;
}

async function readStableWranglerConfigurationBytes(configPath) {
  let handle;
  try {
    const noFollow = constants.O_NOFOLLOW ?? 0;
    handle = await open(
      configPath,
      constants.O_RDONLY | noFollow,
    );
    const before = await handle.stat();
    const pathBefore = await lstat(configPath);
    if (
      !before.isFile() ||
      !pathBefore.isFile() ||
      !sameFileIdentity(before, pathBefore) ||
      before.size <= 0 ||
      before.size > MAX_WRANGLER_CONFIG_BYTES
    ) {
      throw fail("Wrangler configuration is invalid");
    }

    const firstRead = await readFileAtPosition(handle, before.size);
    const secondRead = await readFileAtPosition(handle, before.size);
    const after = await handle.stat();
    const pathAfter = await lstat(configPath);
    if (
      !stableFileMetadata(before, after) ||
      !sameFileIdentity(after, pathAfter) ||
      firstRead.byteLength !== secondRead.byteLength ||
      !timingSafeEqual(firstRead, secondRead)
    ) {
      throw fail("Wrangler configuration changed while it was validated");
    }
    return firstRead;
  } catch (error) {
    if (error instanceof SafeUploadError) {
      throw error;
    }
    throw fail("Wrangler configuration could not be read safely");
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function isPlainObject(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

function skipJSONCTrivia(text, start) {
  let index = start;
  while (index < text.length) {
    if (/\s/u.test(text[index])) {
      index += 1;
      continue;
    }
    if (text[index] !== "/") {
      return index;
    }
    if (text[index + 1] === "/") {
      index += 2;
      while (
        index < text.length &&
        text[index] !== "\n" &&
        text[index] !== "\r"
      ) {
        index += 1;
      }
      continue;
    }
    if (text[index + 1] === "*") {
      const end = text.indexOf("*/", index + 2);
      if (end === -1) {
        throw fail("Wrangler configuration is invalid");
      }
      index = end + 2;
      continue;
    }
    return index;
  }
  return index;
}

function rejectDuplicateJSONCProperties(text) {
  const stack = [];
  let index = 0;

  while (index < text.length) {
    index = skipJSONCTrivia(text, index);
    if (index >= text.length) {
      return;
    }

    const character = text[index];
    if (character === "{") {
      stack.push({ type: "object", keys: new Set() });
      index += 1;
      continue;
    }
    if (character === "[") {
      stack.push({ type: "array" });
      index += 1;
      continue;
    }
    if (character === "}" || character === "]") {
      stack.pop();
      index += 1;
      continue;
    }
    if (character !== "\"") {
      index += 1;
      continue;
    }

    const start = index;
    index += 1;
    let escaped = false;
    while (index < text.length) {
      const current = text[index];
      index += 1;
      if (escaped) {
        escaped = false;
      } else if (current === "\\") {
        escaped = true;
      } else if (current === "\"") {
        break;
      }
    }
    if (text[index - 1] !== "\"") {
      throw fail("Wrangler configuration is invalid");
    }

    const next = skipJSONCTrivia(text, index);
    const context = stack.at(-1);
    if (
      text[next] === ":" &&
      context?.type === "object"
    ) {
      let key;
      try {
        key = JSON.parse(text.slice(start, index));
      } catch {
        throw fail("Wrangler configuration is invalid");
      }
      if (context.keys.has(key)) {
        throw fail("Wrangler configuration is ambiguous");
      }
      context.keys.add(key);
    }
  }
}

function readPinnedWranglerConfiguration(configPath) {
  return experimental_readRawConfig({ config: configPath });
}

async function requireMatchingWranglerKeyID(
  expectedKid,
  configPath,
  readWranglerConfiguration,
) {
  try {
    const beforeBytes =
      await readStableWranglerConfigurationBytes(configPath);
    const text = new TextDecoder("utf-8", {
      fatal: true,
    }).decode(beforeBytes);
    rejectDuplicateJSONCProperties(text);

    const result = await readWranglerConfiguration(configPath);
    const afterBytes =
      await readStableWranglerConfigurationBytes(configPath);
    const beforeDigest = digest(beforeBytes);
    const afterDigest = digest(afterBytes);
    if (
      beforeDigest.byteLength !== afterDigest.byteLength ||
      !timingSafeEqual(beforeDigest, afterDigest)
    ) {
      throw fail("Wrangler configuration changed while it was validated");
    }

    const exactConfigPath = resolve(configPath);
    const rawConfig = result?.rawConfig;
    const variables = rawConfig?.vars;
    const configuredKid = variables?.ALCHEMY_KEY_ID;
    const workerName = rawConfig?.name;
    if (
      result?.redirected !== false ||
      result?.deployConfigPath !== undefined ||
      resolve(result?.configPath ?? "") !== exactConfigPath ||
      resolve(result?.userConfigPath ?? "") !== exactConfigPath ||
      !isPlainObject(rawConfig) ||
      !isPlainObject(variables) ||
      !Object.hasOwn(variables, "ALCHEMY_KEY_ID") ||
      typeof configuredKid !== "string" ||
      !PRINTABLE_KEY_ID.test(configuredKid) ||
      configuredKid !== expectedKid ||
      typeof workerName !== "string" ||
      !isValidWorkerName(workerName)
    ) {
      throw fail(
        "Wrangler key ID configuration does not match expected metadata",
      );
    }
    assertProductionObservabilityPolicy(rawConfig);
    return {
      configBytes: beforeBytes,
      workerName,
    };
  } catch (error) {
    if (error instanceof SafeUploadError) {
      throw error;
    }
    throw fail("Wrangler configuration could not be validated");
  }
}

function interruptionFromAbortSignal(abortSignal) {
  if (!abortSignal?.aborted) {
    return undefined;
  }
  return abortSignal.reason instanceof UploadInterruptedError
    ? abortSignal.reason
    : new UploadInterruptedError("SIGTERM");
}

function throwIfInterrupted(abortSignal) {
  const interruption = interruptionFromAbortSignal(abortSignal);
  if (interruption !== undefined) {
    throw interruption;
  }
}

async function writeProtectedFile(directory, name, bytes) {
  const path = join(directory, name);
  const noFollow = constants.O_NOFOLLOW ?? 0;
  const handle = await open(
    path,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      noFollow,
    0o600,
  );
  try {
    await handle.writeFile(bytes);
    await handle.sync();
    const stats = await handle.stat();
    const effectiveUserID = process.geteuid?.() ?? process.getuid?.();
    if (
      !stats.isFile() ||
      stats.uid !== effectiveUserID ||
      (stats.mode & 0o777) !== 0o600 ||
      stats.size !== bytes.byteLength
    ) {
      throw fail("protected upload snapshot could not be created");
    }
  } finally {
    await handle.close().catch(() => undefined);
  }
  return path;
}

async function verifyProtectedSnapshot(path, expectedDigest) {
  const bytes = await readBoundedRegularFile(
    path,
    MAX_SECRETS_FILE_BYTES,
    { requirePrivatePermissions: true },
  );
  const actualDigest = digest(bytes);
  if (
    actualDigest.byteLength !== expectedDigest.byteLength ||
    !timingSafeEqual(actualDigest, expectedDigest)
  ) {
    throw fail("protected upload snapshot changed before upload");
  }
}

function redactUploadOutput(
  text,
  {
    snapshotPath,
    emptyEnvironmentPath,
    wranglerConfigPath,
    outputFilePath,
    expectedKid,
  },
) {
  return text
    .replaceAll(snapshotPath, "<protected-secrets-file>")
    .replaceAll(emptyEnvironmentPath, "<empty-environment-file>")
    .replaceAll(wranglerConfigPath, "<wrangler-config>")
    .replaceAll(outputFilePath, "<wrangler-output-file>")
    .replaceAll(expectedKid, "<expected-kid>");
}

function isCanonicalTimestamp(value) {
  const milliseconds = Date.parse(value);
  return (
    Number.isFinite(milliseconds) &&
    new Date(milliseconds).toISOString() === value
  );
}

export function parseVersionUploadOutput(bytes, expectedWorkerName) {
  if (
    !(bytes instanceof Uint8Array) ||
    bytes.byteLength === 0 ||
    bytes.byteLength > MAX_WRANGLER_OUTPUT_FILE_BYTES ||
    !isValidWorkerName(expectedWorkerName)
  ) {
    throw fail("Wrangler version upload result is invalid");
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw fail("Wrangler version upload result is invalid");
  }
  if (!text.endsWith("\n")) {
    throw fail("Wrangler version upload result is invalid");
  }
  const lines = text.slice(0, -1).split("\n");
  if (lines.length !== 2 || lines.some((line) => line === "")) {
    throw fail("Wrangler version upload result is invalid");
  }
  let session;
  let upload;
  try {
    session = JSON.parse(lines[0]);
    upload = JSON.parse(lines[1]);
  } catch {
    throw fail("Wrangler version upload result is invalid");
  }
  if (
    !isPlainObject(session) ||
    session.type !== "wrangler-session" ||
    session.version !== 1 ||
    session.wrangler_version !== PINNED_WRANGLER_VERSION ||
    !Array.isArray(session.command_line_args) ||
    session.command_line_args.length === 0 ||
    session.command_line_args.length > 64 ||
    session.command_line_args[0] !== "versions" ||
    session.command_line_args[1] !== "upload" ||
    !session.command_line_args.includes("--strict") ||
    session.command_line_args.some(
      (argument) =>
        typeof argument !== "string" ||
        argument.length === 0 ||
        argument.length > 4_096,
    ) ||
    typeof session.log_file_path !== "string" ||
    session.log_file_path.length === 0 ||
    session.log_file_path.length > 4_096 ||
    resolve(session.log_file_path) !== session.log_file_path ||
    typeof session.timestamp !== "string" ||
    !isCanonicalTimestamp(session.timestamp) ||
    !isPlainObject(upload) ||
    upload.type !== "version-upload" ||
    upload.version !== 1 ||
    upload.worker_name !== expectedWorkerName ||
    typeof upload.version_id !== "string" ||
    !CANONICAL_UUID.test(upload.version_id) ||
    typeof upload.timestamp !== "string" ||
    !isCanonicalTimestamp(upload.timestamp)
  ) {
    throw fail("Wrangler version upload result is invalid");
  }
  return upload.version_id;
}

export async function readUploadedVersionID(
  outputFilePath,
  expectedWorkerName,
) {
  try {
    const bytes = await readBoundedRegularFile(
      outputFilePath,
      MAX_WRANGLER_OUTPUT_FILE_BYTES,
      { requirePrivatePermissions: true },
    );
    return parseVersionUploadOutput(bytes, expectedWorkerName);
  } catch (error) {
    if (error instanceof SafeUploadError) {
      throw error;
    }
    throw fail("Wrangler version upload result could not be read safely");
  }
}

export async function runPinnedWrangler({
  snapshotPath,
  emptyEnvironmentPath,
  wranglerConfigPath,
  outputFilePath,
  workerName,
  expectedKid,
  tag,
  message,
  stdout,
  stderr,
  abortSignal,
  spawnProcess = spawn,
  childTerminationGraceMilliseconds =
    CHILD_TERMINATION_GRACE_MILLISECONDS,
  parentEnvironment = process.env,
  setTimeoutFunction = setTimeout,
  clearTimeoutFunction = clearTimeout,
}) {
  throwIfInterrupted(abortSignal);
  const temporaryDirectory = dirname(snapshotPath);
  if (
    resolve(outputFilePath) !== outputFilePath ||
    dirname(outputFilePath) !== temporaryDirectory ||
    basename(outputFilePath) !== "wrangler-output.ndjson" ||
    dirname(emptyEnvironmentPath) !== temporaryDirectory
  ) {
    throw fail("protected Wrangler output path is invalid");
  }
  const childEnvironment = productionWranglerEnvironment(
    parentEnvironment,
  );
  childEnvironment.WRANGLER_OUTPUT_FILE_PATH = outputFilePath;
  const child = spawnProcess(
    process.execPath,
    [
      PINNED_WRANGLER_PATH,
      "versions",
      "upload",
      "--config",
      wranglerConfigPath,
      "--env-file",
      emptyEnvironmentPath,
      "--env=",
      "--name",
      workerName,
      "--var",
      `ALCHEMY_KEY_ID:${expectedKid}`,
      `--tag=${tag}`,
      `--message=${message}`,
      "--strict",
      "--secrets-file",
      snapshotPath,
    ],
    {
      cwd: dirname(wranglerConfigPath),
      env: childEnvironment,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  const captured = { stdout: "", stderr: "", exceeded: false };
  let childError;
  let childClosed = false;
  let forceKillTimer;
  let terminationRequested = false;

  function requestTermination(signal) {
    if (terminationRequested || childClosed) {
      return;
    }
    terminationRequested = true;
    try {
      child.kill(signal);
    } catch {
      // The close event remains the source of truth for child settlement.
    }
    forceKillTimer = setTimeoutFunction(() => {
      if (!childClosed) {
        try {
          child.kill("SIGKILL");
        } catch {
          // Await close so cleanup never races a child that may hold the file.
        }
      }
    }, Math.max(0, childTerminationGraceMilliseconds));
    forceKillTimer.unref?.();
  }

  function capture(field, chunk) {
    if (captured.exceeded) {
      return;
    }
    const next = captured[field] + chunk.toString("utf8");
    if (next.length > MAX_CAPTURED_OUTPUT_BYTES) {
      captured.exceeded = true;
      captured[field] = next.slice(0, MAX_CAPTURED_OUTPUT_BYTES);
      requestTermination("SIGTERM");
      return;
    }
    captured[field] = next;
  }
  child.stdout.on("data", (chunk) => capture("stdout", chunk));
  child.stderr.on("data", (chunk) => capture("stderr", chunk));
  child.stdout.on("error", (error) => {
    childError ??= error;
    requestTermination("SIGTERM");
  });
  child.stderr.on("error", (error) => {
    childError ??= error;
    requestTermination("SIGTERM");
  });

  const closePromise = new Promise((resolveExit) => {
    child.once("error", (error) => {
      childError = error;
    });
    child.once("close", (code) => {
      childClosed = true;
      resolveExit(code);
    });
  });

  const onAbort = () => {
    requestTermination("SIGTERM");
  };
  abortSignal?.addEventListener("abort", onAbort, { once: true });
  if (abortSignal?.aborted) {
    onAbort();
  }

  let exitCode;
  try {
    exitCode = await closePromise;
  } finally {
    abortSignal?.removeEventListener("abort", onAbort);
    if (forceKillTimer !== undefined) {
      clearTimeoutFunction(forceKillTimer);
    }
  }

  const interruption = interruptionFromAbortSignal(abortSignal);
  const failed =
    captured.exceeded ||
    childError !== undefined ||
    exitCode !== 0;
  if (!captured.exceeded && failed && interruption === undefined) {
    const redactions = {
      snapshotPath,
      emptyEnvironmentPath,
      wranglerConfigPath,
      outputFilePath,
      expectedKid,
    };
    const safeStdout = redactUploadOutput(
      captured.stdout,
      redactions,
    );
    const safeStderr = redactUploadOutput(
      captured.stderr,
      redactions,
    );
    if (safeStdout !== "") {
      stdout(safeStdout);
    }
    if (safeStderr !== "") {
      stderr(safeStderr);
    }
  }
  if (interruption !== undefined) {
    throw interruption;
  }
  if (failed) {
    throw fail("Wrangler version upload failed");
  }
}

export async function safeUploadVersion(
  options,
  {
    temporaryRoot = tmpdir(),
    runner = runPinnedWrangler,
    wranglerConfigPath = PRODUCTION_WRANGLER_CONFIG_PATH,
    readWranglerConfiguration = readPinnedWranglerConfiguration,
    beforeSnapshotVerification,
    removeTemporaryDirectory = (path) => rm(path, {
      recursive: true,
      force: true,
    }),
    stdout = (message) => process.stdout.write(message),
    stderr = (message) => process.stderr.write(message),
    uploadedVersionReader = readUploadedVersionID,
    productionSnapshotFactory = createProtectedProductionSnapshot,
    abortSignal,
    expectedRequestProofKeyFingerprint,
    keypairPreparer = prepareValidatedKeypair,
  } = {},
) {
  let secretsBytes;
  try {
    throwIfInterrupted(abortSignal);
    await requireMatchingWranglerKeyID(
      options.expectedKid,
      wranglerConfigPath,
      readWranglerConfiguration,
    );
    throwIfInterrupted(abortSignal);
    ({ secretsBytes } = await keypairPreparer(options, {
      expectedRequestProofKeyFingerprint,
    }));
    throwIfInterrupted(abortSignal);
    const expectedDigest = digest(secretsBytes);
    const canonicalTemporaryRoot = await realpath(
      resolve(temporaryRoot),
    );
    const temporaryDirectory = await mkdtemp(
      join(canonicalTemporaryRoot, "alchemy-jwt-upload-"),
    );

    let operationError;
    let uploadedVersionID;
    try {
      throwIfInterrupted(abortSignal);
      await chmod(temporaryDirectory, 0o700);
      const {
        configBytes,
        workerName,
      } = await requireMatchingWranglerKeyID(
        options.expectedKid,
        wranglerConfigPath,
        readWranglerConfiguration,
      );
      throwIfInterrupted(abortSignal);
      const productionSnapshot = await productionSnapshotFactory(
        {
          configPath: wranglerConfigPath,
          configBytes,
          workerName,
        },
        {
          temporaryRoot: temporaryDirectory,
          excludedPaths: [
            options.secretsFile,
            options.publicKeyFile,
            options.appProofKeyFile,
          ],
        },
      );
      const protectedDirectory = dirname(
        productionSnapshot.emptyEnvironmentPath,
      );
      if (
        resolve(protectedDirectory) !== protectedDirectory ||
        !protectedDirectory.startsWith(`${temporaryDirectory}${sep}`) ||
        dirname(productionSnapshot.workerDirectory) !== protectedDirectory ||
        dirname(productionSnapshot.configPath) !==
          productionSnapshot.workerDirectory
      ) {
        throw fail("protected Worker snapshot paths are invalid");
      }
      const snapshotPath = await writeProtectedFile(
        protectedDirectory,
        "wrangler-secrets.json",
        secretsBytes,
      );
      await beforeSnapshotVerification?.(snapshotPath);
      await verifyProtectedSnapshot(snapshotPath, expectedDigest);
      throwIfInterrupted(abortSignal);
      const stagedConfiguration =
        await requireMatchingWranglerKeyID(
          options.expectedKid,
          productionSnapshot.configPath,
          readWranglerConfiguration,
        );
      const originalConfigDigest = digest(configBytes);
      const stagedConfigDigest = digest(
        stagedConfiguration.configBytes,
      );
      if (
        stagedConfiguration.workerName !== workerName ||
        originalConfigDigest.byteLength !==
          stagedConfigDigest.byteLength ||
        !timingSafeEqual(
          originalConfigDigest,
          stagedConfigDigest,
        )
      ) {
        throw fail("Worker source snapshot changed before upload");
      }
      const currentConfiguration =
        await requireMatchingWranglerKeyID(
          options.expectedKid,
          wranglerConfigPath,
          readWranglerConfiguration,
        );
      const currentConfigDigest = digest(
        currentConfiguration.configBytes,
      );
      if (
        currentConfiguration.workerName !== workerName ||
        currentConfigDigest.byteLength !== originalConfigDigest.byteLength ||
        !timingSafeEqual(currentConfigDigest, originalConfigDigest)
      ) {
        throw fail("Worker source snapshot changed before upload");
      }
      const outputFilePath = await writeProtectedFile(
        protectedDirectory,
        "wrangler-output.ndjson",
        Buffer.alloc(0),
      );
      throwIfInterrupted(abortSignal);
      await productionSnapshot.verify();
      await runner({
        snapshotPath,
        emptyEnvironmentPath: productionSnapshot.emptyEnvironmentPath,
        wranglerConfigPath: productionSnapshot.configPath,
        outputFilePath,
        workerName,
        expectedKid: options.expectedKid,
        tag: options.tag,
        message: options.message,
        stdout,
        stderr,
        abortSignal,
      });
      throwIfInterrupted(abortSignal);
      uploadedVersionID = await uploadedVersionReader(
        outputFilePath,
        workerName,
      );
    } catch (error) {
      operationError =
        error instanceof SafeUploadError ||
        error instanceof SafePreflightError ||
        error instanceof UploadInterruptedError
          ? error
          : fail("validated Worker version upload failed");
    }

    try {
      await removeTemporaryDirectory(temporaryDirectory);
    } catch {
      const prefix = operationError?.message;
      throw fail(
        prefix === undefined
          ? "protected upload snapshot cleanup failed"
          : `${prefix}; protected upload snapshot cleanup also failed`,
      );
    }

    if (operationError !== undefined) {
      throw operationError;
    }
    if (!CANONICAL_UUID.test(uploadedVersionID)) {
      throw fail("Wrangler version upload result is invalid");
    }
    stdout(`validated-upload: pass version=${uploadedVersionID}\n`);
    return uploadedVersionID;
  } finally {
    secretsBytes?.fill(0);
  }
}

function installSignalHandlers(signalEmitter, abortController) {
  let receivedSignal;
  const listeners = new Map();
  try {
    for (const signal of HANDLED_SIGNALS) {
      const listener = () => {
        if (receivedSignal === undefined) {
          receivedSignal = signal;
          abortController.abort(
            new UploadInterruptedError(signal),
          );
        }
      };
      listeners.set(signal, listener);
      signalEmitter.on(signal, listener);
    }
  } catch (error) {
    for (const [signal, listener] of listeners) {
      signalEmitter.removeListener(signal, listener);
    }
    throw error;
  }

  let disposed = false;
  return {
    receivedSignal: () => receivedSignal,
    dispose: () => {
      if (disposed) {
        return;
      }
      disposed = true;
      for (const [signal, listener] of listeners) {
        signalEmitter.removeListener(signal, listener);
      }
    },
  };
}

function signalExitCode(signal) {
  const number = osConstants.signals?.[signal];
  return Number.isInteger(number) ? 128 + number : 1;
}

export async function uploadMain(
  arguments_,
  {
    stdout = (message) => process.stdout.write(message),
    stderr = (message) => process.stderr.write(message),
    uploader = safeUploadVersion,
    signalEmitter = process,
    resignal = (signal) => process.kill(process.pid, signal),
  } = {},
) {
  const abortController = new AbortController();
  const signalHandlers = installSignalHandlers(
    signalEmitter,
    abortController,
  );
  let exitCode = 0;
  try {
    const options = parseUploadArguments(arguments_);
    if (options.help) {
      stdout(`${usage()}\n`);
    } else {
      await uploader(options, {
        stdout,
        stderr,
        abortSignal: abortController.signal,
      });
    }
  } catch (error) {
    if (
      !(error instanceof UploadInterruptedError) &&
      signalHandlers.receivedSignal() === undefined
    ) {
      const message =
        error instanceof SafeUploadError ||
        error instanceof SafePreflightError
          ? error.message
          : "unexpected validated upload failure";
      stderr(`validated-upload: failed: ${message}\n`);
    }
    exitCode = 1;
  } finally {
    signalHandlers.dispose();
  }

  const receivedSignal = signalHandlers.receivedSignal();
  if (receivedSignal !== undefined) {
    const conventionalExitCode = signalExitCode(receivedSignal);
    try {
      resignal(receivedSignal);
    } catch {
      // Fall back to the conventional 128 + signal exit status.
    }
    return conventionalExitCode;
  }
  return exitCode;
}

const isDirectExecution =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectExecution) {
  process.exitCode = await uploadMain(process.argv.slice(2));
}
