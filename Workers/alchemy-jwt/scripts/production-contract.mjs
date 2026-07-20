import { spawn } from "node:child_process";
import { createHash, timingSafeEqual } from "node:crypto";
import { constants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  open,
  readdir,
  realpath,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import {
  basename,
  dirname,
  join,
  relative,
  resolve,
  sep,
} from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { experimental_readRawConfig } from "wrangler";

export const PRODUCTION_WRANGLER_CONFIG_PATH = fileURLToPath(
  new URL("../wrangler.jsonc", import.meta.url),
);
export const PINNED_WRANGLER_PATH = fileURLToPath(
  new URL("../node_modules/wrangler/bin/wrangler.js", import.meta.url),
);
export const PINNED_WRANGLER_VERSION = "4.112.0";

const WORKER_NAME_PATTERN =
  /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u;
const CLOUDFLARE_ACCOUNT_ID_PATTERN = /^[0-9a-f]{32}$/u;
const MAX_CONFIGURATION_BYTES = 1_024 * 1_024;
const MAX_SNAPSHOT_FILE_BYTES = 8 * 1_024 * 1_024;
const PRINTABLE_API_TOKEN = /^[\u0021-\u007e]{1,4096}$/u;
const LEGACY_CLOUDFLARE_CREDENTIALS = new Set([
  "CLOUDFLARE_API_KEY",
  "CLOUDFLARE_API_USER_SERVICE_KEY",
  "CLOUDFLARE_EMAIL",
]);
const EXCLUDED_SNAPSHOT_ROOTS = new Set([
  ".git",
  ".wrangler",
  "coverage",
  "dist",
  "node_modules",
]);
const ENVIRONMENT_ALLOWLIST = new Set([
  "COMSPEC",
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "LOGNAME",
  "NO_COLOR",
  "PATH",
  "PATHEXT",
  "SHELL",
  "SYSTEMROOT",
  "TEMP",
  "TERM",
  "TMP",
  "TMPDIR",
  "USER",
  "WINDIR",
]);
const FORCED_ENVIRONMENT = {
  CI: "1",
  CLOUDFLARE_COMPLIANCE_REGION: "public",
  WRANGLER_API_ENVIRONMENT: "production",
  WRANGLER_LOG: "log",
  WRANGLER_LOG_SANITIZE: "true",
  WRANGLER_WRITE_LOGS: "false",
};

export class SafeProductionWranglerError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafeProductionWranglerError";
  }
}

function fail(message) {
  return new SafeProductionWranglerError(message);
}

function isPlainObject(value) {
  return (
    typeof value === "object" &&
    value !== null &&
    !Array.isArray(value) &&
    Object.getPrototypeOf(value) === Object.prototype
  );
}

function hasExactKeys(value, expectedKeys) {
  if (!isPlainObject(value)) {
    return false;
  }
  const actualKeys = Object.keys(value).sort();
  const sortedExpectedKeys = [...expectedKeys].sort();
  return (
    actualKeys.length === sortedExpectedKeys.length &&
    actualKeys.every(
      (key, index) => key === sortedExpectedKeys[index],
    )
  );
}

export function assertProductionObservabilityPolicy(config) {
  const observability = config?.observability;
  const logs = observability?.logs;
  const traces = observability?.traces;
  if (
    !hasExactKeys(observability, ["enabled", "logs", "traces"]) ||
    observability.enabled !== true ||
    !hasExactKeys(logs, [
      "enabled",
      "head_sampling_rate",
      "invocation_logs",
    ]) ||
    logs.enabled !== true ||
    logs.head_sampling_rate !== 1 ||
    logs.invocation_logs !== false ||
    !hasExactKeys(traces, ["enabled"]) ||
    traces.enabled !== false
  ) {
    throw fail("production Wrangler observability policy is invalid");
  }
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

function digest(bytes) {
  return createHash("sha256").update(bytes).digest();
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
      throw fail("production file changed while it was validated");
    }
    offset += bytesRead;
  }
  return bytes;
}

async function readStableRegularFile(path, maximumBytes) {
  let handle;
  try {
    handle = await open(
      path,
      constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
    );
    const before = await handle.stat();
    const pathBefore = await lstat(path);
    if (
      !before.isFile() ||
      !pathBefore.isFile() ||
      !sameFileIdentity(before, pathBefore) ||
      before.size < 0 ||
      before.size > maximumBytes
    ) {
      throw fail("production file is invalid");
    }

    const firstRead = await readFileAtPosition(handle, before.size);
    const secondRead = await readFileAtPosition(handle, before.size);
    const after = await handle.stat();
    const pathAfter = await lstat(path);
    if (
      !stableFileMetadata(before, after) ||
      !sameFileIdentity(after, pathAfter) ||
      firstRead.byteLength !== secondRead.byteLength ||
      !timingSafeEqual(firstRead, secondRead)
    ) {
      throw fail("production file changed while it was validated");
    }
    return { bytes: firstRead, stats: before };
  } catch (error) {
    if (error instanceof SafeProductionWranglerError) {
      throw error;
    }
    throw fail("production file could not be read safely");
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

async function writeProtectedFile(directory, name, bytes, mode = 0o600) {
  const path = join(directory, name);
  const handle = await open(
    path,
    constants.O_WRONLY |
      constants.O_CREAT |
      constants.O_EXCL |
      (constants.O_NOFOLLOW ?? 0),
    mode,
  );
  try {
    await handle.writeFile(bytes);
    await handle.sync();
    const stats = await handle.stat();
    if (
      !stats.isFile() ||
      (stats.mode & 0o777) !== mode ||
      stats.size !== bytes.byteLength
    ) {
      throw fail("protected production snapshot could not be created");
    }
  } finally {
    await handle.close().catch(() => undefined);
  }
  return path;
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
        throw fail("production Wrangler configuration is invalid");
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
      throw fail("production Wrangler configuration is invalid");
    }
    const next = skipJSONCTrivia(text, index);
    const context = stack.at(-1);
    if (text[next] === ":" && context?.type === "object") {
      let key;
      try {
        key = JSON.parse(text.slice(start, index));
      } catch {
        throw fail("production Wrangler configuration is invalid");
      }
      if (context.keys.has(key)) {
        throw fail("production Wrangler configuration is ambiguous");
      }
      context.keys.add(key);
    }
  }
}

function stripJSONC(text) {
  let result = "";
  let index = 0;
  let inString = false;
  let escaped = false;
  while (index < text.length) {
    const character = text[index];
    if (inString) {
      result += character;
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === "\"") {
        inString = false;
      }
      index += 1;
      continue;
    }
    if (character === "\"") {
      inString = true;
      result += character;
      index += 1;
      continue;
    }
    if (character === "/" && text[index + 1] === "/") {
      result += " ";
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
    if (character === "/" && text[index + 1] === "*") {
      const end = text.indexOf("*/", index + 2);
      if (end === -1) {
        throw fail("production Wrangler configuration is invalid");
      }
      result += " ";
      index = end + 2;
      continue;
    }
    if (character === ",") {
      const next = skipJSONCTrivia(text, index + 1);
      if (text[next] === "}" || text[next] === "]") {
        index += 1;
        continue;
      }
    }
    result += character;
    index += 1;
  }
  return result;
}

function parseExactConfiguration(bytes) {
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_CONFIGURATION_BYTES) {
    throw fail("production Wrangler configuration is invalid");
  }
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw fail("production Wrangler configuration is invalid");
  }
  rejectDuplicateJSONCProperties(text);
  try {
    return JSON.parse(stripJSONC(text));
  } catch (error) {
    if (error instanceof SafeProductionWranglerError) {
      throw error;
    }
    throw fail("production Wrangler configuration is invalid");
  }
}

export function isValidWorkerName(value) {
  return typeof value === "string" && WORKER_NAME_PATTERN.test(value);
}

export function productionWranglerEnvironment(parentEnvironment) {
  if (
    typeof parentEnvironment !== "object" ||
    parentEnvironment === null ||
    Array.isArray(parentEnvironment) ||
    typeof parentEnvironment.CLOUDFLARE_API_TOKEN !== "string" ||
    !PRINTABLE_API_TOKEN.test(
      parentEnvironment.CLOUDFLARE_API_TOKEN,
    )
  ) {
    throw fail(
      "CLOUDFLARE_API_TOKEN is required for production Wrangler commands",
    );
  }
  const childEnvironment = {};
  for (const [name, value] of Object.entries(parentEnvironment)) {
    const canonicalName = name.toUpperCase();
    if (
      (
        LEGACY_CLOUDFLARE_CREDENTIALS.has(canonicalName) ||
        (
          canonicalName === "CLOUDFLARE_API_TOKEN" &&
          name !== canonicalName
        )
      ) &&
      typeof value === "string" &&
      value !== ""
    ) {
      throw fail(
        "legacy or ambiguous Cloudflare credentials are not supported",
      );
    }
    if (
      ENVIRONMENT_ALLOWLIST.has(canonicalName) &&
      typeof value === "string"
    ) {
      childEnvironment[canonicalName] = value;
    }
  }
  return {
    ...childEnvironment,
    CLOUDFLARE_API_TOKEN: parentEnvironment.CLOUDFLARE_API_TOKEN,
    ...FORCED_ENVIRONMENT,
  };
}

export async function loadProductionWranglerContract({
  readWranglerConfiguration = (configPath) =>
    experimental_readRawConfig({ config: configPath }),
} = {}) {
  const configPath = resolve(PRODUCTION_WRANGLER_CONFIG_PATH);
  try {
    const before = await readStableRegularFile(
      configPath,
      MAX_CONFIGURATION_BYTES,
    );
    const exactConfig = parseExactConfiguration(before.bytes);
    const result = await readWranglerConfiguration(configPath);
    const after = await readStableRegularFile(
      configPath,
      MAX_CONFIGURATION_BYTES,
    );
    const beforeDigest = digest(before.bytes);
    const afterDigest = digest(after.bytes);
    const rawConfig = result?.rawConfig;
    const workerName = rawConfig?.name;
    const accountId = rawConfig?.account_id;
    if (
      !sameFileIdentity(before.stats, after.stats) ||
      !stableFileMetadata(before.stats, after.stats) ||
      beforeDigest.byteLength !== afterDigest.byteLength ||
      !timingSafeEqual(beforeDigest, afterDigest) ||
      result?.redirected !== false ||
      result?.deployConfigPath !== undefined ||
      resolve(result?.configPath ?? "") !== configPath ||
      resolve(result?.userConfigPath ?? "") !== configPath ||
      !isPlainObject(exactConfig) ||
      !isPlainObject(rawConfig) ||
      !isValidWorkerName(workerName) ||
      exactConfig.name !== workerName ||
      typeof accountId !== "string" ||
      !CLOUDFLARE_ACCOUNT_ID_PATTERN.test(accountId) ||
      exactConfig.account_id !== accountId
    ) {
      throw fail("production Wrangler configuration is invalid");
    }
    assertProductionObservabilityPolicy(exactConfig);
    assertProductionObservabilityPolicy(rawConfig);
    return {
      configPath,
      configBytes: Buffer.from(before.bytes),
      workerName,
      accountId,
      rawConfig,
    };
  } catch (error) {
    if (error instanceof SafeProductionWranglerError) {
      throw error;
    }
    throw fail("production Wrangler configuration could not be loaded safely");
  }
}

function isImplicitEnvironmentFile(name) {
  return (
    name === ".env" ||
    name.startsWith(".env.") ||
    name === ".dev.vars" ||
    name.startsWith(".dev.vars.")
  );
}

function isExcludedSnapshotPath(
  sourcePath,
  sourceRoot,
  configPath,
  temporaryDirectory,
  excludedPaths,
) {
  const exactPath = resolve(sourcePath);
  if (
    exactPath === resolve(configPath) ||
    exactPath === resolve(temporaryDirectory) ||
    exactPath.startsWith(`${resolve(temporaryDirectory)}${sep}`) ||
    excludedPaths.has(exactPath)
  ) {
    return true;
  }
  const relativePath = relative(sourceRoot, exactPath);
  const rootName = relativePath.split(sep, 1)[0];
  const name = basename(exactPath);
  return (
    EXCLUDED_SNAPSHOT_ROOTS.has(rootName) ||
    isImplicitEnvironmentFile(name) ||
    name.endsWith(".key") ||
    name.endsWith(".pem") ||
    name === "alchemy-jwt-secrets.json" ||
    name === "worker-startup.cpuprofile"
  );
}

async function copyProtectedDirectory({
  sourceDirectory,
  destinationDirectory,
  sourceRoot,
  configPath,
  temporaryDirectory,
  excludedPaths,
  sourceManifest,
}) {
  const before = await lstat(sourceDirectory);
  if (!before.isDirectory() || before.isSymbolicLink()) {
    throw fail("Worker source snapshot contains an unsupported entry");
  }
  await mkdir(destinationDirectory, { mode: 0o700 });
  await chmod(destinationDirectory, 0o700);
  const entries = await readdir(sourceDirectory, { withFileTypes: true });
  entries.sort((first, second) => first.name.localeCompare(second.name));
  for (const entry of entries) {
    const sourcePath = join(sourceDirectory, entry.name);
    if (
      isExcludedSnapshotPath(
        sourcePath,
        sourceRoot,
        configPath,
        temporaryDirectory,
        excludedPaths,
      )
    ) {
      continue;
    }
    const destinationPath = join(destinationDirectory, entry.name);
    const stats = await lstat(sourcePath);
    if (stats.isDirectory() && !stats.isSymbolicLink()) {
      await copyProtectedDirectory({
        sourceDirectory: sourcePath,
        destinationDirectory: destinationPath,
        sourceRoot,
        configPath,
        temporaryDirectory,
        excludedPaths,
        sourceManifest,
      });
      continue;
    }
    if (!stats.isFile() || stats.isSymbolicLink()) {
      throw fail("Worker source snapshot contains an unsupported entry");
    }
    const source = await readStableRegularFile(
      sourcePath,
      MAX_SNAPSHOT_FILE_BYTES,
    );
    await writeProtectedFile(
      destinationDirectory,
      entry.name,
      source.bytes,
      (source.stats.mode & 0o111) === 0 ? 0o600 : 0o700,
    );
    sourceManifest.set(relative(sourceRoot, sourcePath), {
      kind: "file",
      stats: source.stats,
      digest: digest(source.bytes),
    });
  }
  const after = await lstat(sourceDirectory);
  if (!stableFileMetadata(before, after)) {
    throw fail("Worker source changed while it was snapshotted");
  }
  sourceManifest.set(relative(sourceRoot, sourceDirectory), {
    kind: "directory",
    stats: after,
  });
}

function matchingDigest(first, second) {
  return (
    first.byteLength === second.byteLength &&
    timingSafeEqual(first, second)
  );
}

async function verifySourceDirectory({
  sourceDirectory,
  sourceRoot,
  configPath,
  temporaryDirectory,
  excludedPaths,
  sourceManifest,
  observedPaths,
}) {
  const before = await lstat(sourceDirectory);
  const directoryPath = relative(sourceRoot, sourceDirectory);
  const expectedDirectory = sourceManifest.get(directoryPath);
  if (
    !before.isDirectory() ||
    before.isSymbolicLink() ||
    expectedDirectory?.kind !== "directory" ||
    !stableFileMetadata(expectedDirectory.stats, before)
  ) {
    throw fail("Worker source changed while it was snapshotted");
  }
  observedPaths.add(directoryPath);

  const entries = await readdir(sourceDirectory, { withFileTypes: true });
  entries.sort((first, second) => first.name.localeCompare(second.name));
  for (const entry of entries) {
    const sourcePath = join(sourceDirectory, entry.name);
    if (
      isExcludedSnapshotPath(
        sourcePath,
        sourceRoot,
        configPath,
        temporaryDirectory,
        excludedPaths,
      )
    ) {
      continue;
    }
    const relativePath = relative(sourceRoot, sourcePath);
    const stats = await lstat(sourcePath);
    if (stats.isDirectory() && !stats.isSymbolicLink()) {
      await verifySourceDirectory({
        sourceDirectory: sourcePath,
        sourceRoot,
        configPath,
        temporaryDirectory,
        excludedPaths,
        sourceManifest,
        observedPaths,
      });
      continue;
    }
    if (!stats.isFile() || stats.isSymbolicLink()) {
      throw fail("Worker source changed while it was snapshotted");
    }
    const expectedFile = sourceManifest.get(relativePath);
    const source = await readStableRegularFile(
      sourcePath,
      MAX_SNAPSHOT_FILE_BYTES,
    );
    if (
      expectedFile?.kind !== "file" ||
      !stableFileMetadata(expectedFile.stats, source.stats) ||
      !matchingDigest(expectedFile.digest, digest(source.bytes))
    ) {
      throw fail("Worker source changed while it was snapshotted");
    }
    observedPaths.add(relativePath);
  }

  const after = await lstat(sourceDirectory);
  if (!stableFileMetadata(before, after)) {
    throw fail("Worker source changed while it was snapshotted");
  }
}

async function verifySourceTree({
  sourceRoot,
  configPath,
  temporaryDirectory,
  excludedPaths,
  sourceManifest,
}) {
  const observedPaths = new Set();
  await verifySourceDirectory({
    sourceDirectory: sourceRoot,
    sourceRoot,
    configPath,
    temporaryDirectory,
    excludedPaths,
    sourceManifest,
    observedPaths,
  });
  if (
    observedPaths.size !== sourceManifest.size ||
    [...sourceManifest.keys()].some((path) => !observedPaths.has(path))
  ) {
    throw fail("Worker source changed while it was snapshotted");
  }
}

async function captureProtectedTreeManifest(root) {
  const manifest = new Map();

  async function capture(directory) {
    const before = await lstat(directory);
    if (!before.isDirectory() || before.isSymbolicLink()) {
      throw fail("protected production snapshot contains an unsupported entry");
    }
    const directoryPath = relative(root, directory);
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((first, second) => first.name.localeCompare(second.name));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      const relativePath = relative(root, path);
      const stats = await lstat(path);
      if (stats.isDirectory() && !stats.isSymbolicLink()) {
        await capture(path);
        continue;
      }
      if (!stats.isFile() || stats.isSymbolicLink()) {
        throw fail(
          "protected production snapshot contains an unsupported entry",
        );
      }
      const source = await readStableRegularFile(
        path,
        MAX_SNAPSHOT_FILE_BYTES,
      );
      manifest.set(relativePath, {
        kind: "file",
        stats: source.stats,
        digest: digest(source.bytes),
      });
    }
    const after = await lstat(directory);
    if (!stableFileMetadata(before, after)) {
      throw fail("protected production snapshot changed");
    }
    manifest.set(directoryPath, {
      kind: "directory",
      stats: after,
    });
  }

  await capture(root);
  return manifest;
}

async function verifyProtectedTreeManifest(root, manifest) {
  const observedPaths = new Set();

  async function verify(directory) {
    const before = await lstat(directory);
    const directoryPath = relative(root, directory);
    const expectedDirectory = manifest.get(directoryPath);
    if (
      !before.isDirectory() ||
      before.isSymbolicLink() ||
      expectedDirectory?.kind !== "directory" ||
      !stableFileMetadata(expectedDirectory.stats, before)
    ) {
      throw fail("protected production snapshot changed");
    }
    observedPaths.add(directoryPath);
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((first, second) => first.name.localeCompare(second.name));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      const relativePath = relative(root, path);
      const stats = await lstat(path);
      if (stats.isDirectory() && !stats.isSymbolicLink()) {
        await verify(path);
        continue;
      }
      if (!stats.isFile() || stats.isSymbolicLink()) {
        throw fail("protected production snapshot changed");
      }
      const expectedFile = manifest.get(relativePath);
      const source = await readStableRegularFile(
        path,
        MAX_SNAPSHOT_FILE_BYTES,
      );
      if (
        expectedFile?.kind !== "file" ||
        !stableFileMetadata(expectedFile.stats, source.stats) ||
        !matchingDigest(expectedFile.digest, digest(source.bytes))
      ) {
        throw fail("protected production snapshot changed");
      }
      observedPaths.add(relativePath);
    }
    const after = await lstat(directory);
    if (!stableFileMetadata(before, after)) {
      throw fail("protected production snapshot changed");
    }
  }

  await verify(root);
  if (
    observedPaths.size !== manifest.size ||
    [...manifest.keys()].some((path) => !observedPaths.has(path))
  ) {
    throw fail("protected production snapshot changed");
  }
}

function resolveContainedPath(root, relativePath, description) {
  if (
    typeof relativePath !== "string" ||
    relativePath.length === 0 ||
    relativePath.includes("\0")
  ) {
    throw fail(`${description} is invalid`);
  }
  const exactRoot = resolve(root);
  const path = resolve(exactRoot, relativePath);
  if (path !== exactRoot && !path.startsWith(`${exactRoot}${sep}`)) {
    throw fail(`${description} escapes the Worker snapshot`);
  }
  return path;
}

async function copyRelativeSchemaReference({
  exactConfig,
  sourceRoot,
  workerDirectory,
}) {
  const schemaReference = exactConfig.$schema;
  if (
    typeof schemaReference !== "string" ||
    /^[a-z][a-z0-9+.-]*:/iu.test(schemaReference)
  ) {
    return;
  }
  const sourcePath = resolveContainedPath(
    sourceRoot,
    schemaReference,
    "Wrangler schema reference",
  );
  const destinationPath = resolveContainedPath(
    workerDirectory,
    schemaReference,
    "Wrangler schema reference",
  );
  try {
    const existing = await lstat(destinationPath);
    if (existing.isFile() && !existing.isSymbolicLink()) {
      return;
    }
    throw fail("Wrangler schema snapshot is invalid");
  } catch (error) {
    if (error instanceof SafeProductionWranglerError) {
      throw error;
    }
    if (error?.code !== "ENOENT") {
      throw fail("Wrangler schema reference could not be snapshotted");
    }
  }
  const source = await readStableRegularFile(
    sourcePath,
    MAX_SNAPSHOT_FILE_BYTES,
  );
  await mkdir(dirname(destinationPath), {
    recursive: true,
    mode: 0o700,
  });
  await chmod(dirname(destinationPath), 0o700);
  await writeProtectedFile(
    dirname(destinationPath),
    basename(destinationPath),
    source.bytes,
  );
}

async function verifyProductionSnapshot(snapshot, contract) {
  await verifyProtectedTreeManifest(
    snapshot.workerDirectory,
    snapshot.workerManifest,
  );
  const config = await readStableRegularFile(
    snapshot.configPath,
    MAX_CONFIGURATION_BYTES,
  );
  const expectedDigest = digest(contract.configBytes);
  const actualDigest = digest(config.bytes);
  if (
    expectedDigest.byteLength !== actualDigest.byteLength ||
    !timingSafeEqual(expectedDigest, actualDigest)
  ) {
    throw fail("protected Wrangler configuration snapshot changed");
  }
  const emptyEnvironment = await readStableRegularFile(
    snapshot.emptyEnvironmentPath,
    0,
  );
  if (emptyEnvironment.bytes.byteLength !== 0) {
    throw fail("protected Wrangler environment snapshot changed");
  }

  const exactConfig = parseExactConfiguration(config.bytes);
  if (
    !isPlainObject(exactConfig) ||
    exactConfig.name !== contract.workerName
  ) {
    throw fail("protected Wrangler configuration snapshot is invalid");
  }
  const mainPath = resolveContainedPath(
    snapshot.workerDirectory,
    exactConfig.main,
    "Wrangler main module",
  );
  await readStableRegularFile(mainPath, MAX_SNAPSHOT_FILE_BYTES);

  const schemaReference = exactConfig.$schema;
  if (
    typeof schemaReference === "string" &&
    !/^[a-z][a-z0-9+.-]*:/iu.test(schemaReference)
  ) {
    const schemaPath = resolveContainedPath(
      snapshot.workerDirectory,
      schemaReference,
      "Wrangler schema reference",
    );
    await readStableRegularFile(schemaPath, MAX_SNAPSHOT_FILE_BYTES);
  }
}

export async function createProtectedProductionSnapshot(
  contract,
  {
    temporaryRoot = tmpdir(),
    excludedPaths = [],
    snapshotHooks = {},
  } = {},
) {
  const sourceRoot = dirname(resolve(contract.configPath));
  const exactConfig = parseExactConfiguration(contract.configBytes);
  if (
    basename(contract.configPath) !== "wrangler.jsonc" ||
    !isPlainObject(exactConfig) ||
    exactConfig.name !== contract.workerName ||
    !isValidWorkerName(contract.workerName)
  ) {
    throw fail("production Wrangler contract is invalid");
  }
  if (
    !Array.isArray(excludedPaths) ||
    excludedPaths.some((path) =>
      typeof path !== "string" ||
      resolve(path) !== path
    )
  ) {
    throw fail("production snapshot exclusions are invalid");
  }
  if (
    !isPlainObject(snapshotHooks) ||
    (
      snapshotHooks.beforeSourceTreeVerification !== undefined &&
      typeof snapshotHooks.beforeSourceTreeVerification !== "function"
    ) ||
    Object.keys(snapshotHooks).some(
      (key) => key !== "beforeSourceTreeVerification",
    )
  ) {
    throw fail("production snapshot hooks are invalid");
  }
  const exactExcludedPaths = new Set(excludedPaths);

  const canonicalTemporaryRoot = await realpath(resolve(temporaryRoot));
  const temporaryDirectory = await mkdtemp(
    join(canonicalTemporaryRoot, "alchemy-jwt-rollout-"),
  );
  let snapshot;
  try {
    await chmod(temporaryDirectory, 0o700);
    const workerDirectory = join(temporaryDirectory, "worker");
    const sourceManifest = new Map();
    await copyProtectedDirectory({
      sourceDirectory: sourceRoot,
      destinationDirectory: workerDirectory,
      sourceRoot,
      configPath: contract.configPath,
      temporaryDirectory,
      excludedPaths: exactExcludedPaths,
      sourceManifest,
    });
    await snapshotHooks.beforeSourceTreeVerification?.({
      sourceRoot,
    });
    await verifySourceTree({
      sourceRoot,
      configPath: contract.configPath,
      temporaryDirectory,
      excludedPaths: exactExcludedPaths,
      sourceManifest,
    });
    const configPath = await writeProtectedFile(
      workerDirectory,
      "wrangler.jsonc",
      contract.configBytes,
    );
    await copyRelativeSchemaReference({
      exactConfig,
      sourceRoot,
      workerDirectory,
    });
    const emptyEnvironmentPath = await writeProtectedFile(
      temporaryDirectory,
      "empty.env",
      Buffer.alloc(0),
    );
    const workerManifest =
      await captureProtectedTreeManifest(workerDirectory);
    snapshot = {
      configPath,
      emptyEnvironmentPath,
      workerDirectory,
      workerManifest,
      verify: () => verifyProductionSnapshot(snapshot, contract),
      cleanup: () => rm(temporaryDirectory, {
        recursive: true,
        force: true,
      }),
    };
    await snapshot.verify();
    return snapshot;
  } catch (error) {
    await rm(temporaryDirectory, {
      recursive: true,
      force: true,
    }).catch(() => undefined);
    if (error instanceof SafeProductionWranglerError) {
      throw error;
    }
    throw fail("protected production snapshot could not be created");
  }
}

export function productionWranglerArguments({
  commandArguments,
  configPath,
  workerName,
  emptyEnvironmentPath,
  assumeYes = false,
}) {
  if (!isValidWorkerName(workerName)) {
    throw fail("production Worker name is invalid");
  }
  const exactConfigPath = resolve(configPath);
  const exactEnvironmentPath = resolve(emptyEnvironmentPath);
  const workerDirectory = dirname(exactConfigPath);
  const temporaryDirectory = dirname(workerDirectory);
  if (
    configPath !== exactConfigPath ||
    basename(exactConfigPath) !== "wrangler.jsonc" ||
    emptyEnvironmentPath !== exactEnvironmentPath ||
    basename(exactEnvironmentPath) !== "empty.env" ||
    dirname(exactEnvironmentPath) !== temporaryDirectory
  ) {
    throw fail("protected production snapshot paths are invalid");
  }
  if (
    !Array.isArray(commandArguments) ||
    commandArguments.some((argument) =>
      typeof argument !== "string" ||
      /^(?:-c|-e|-y|--(?:config|cwd|env|env-file|name|profile|yes))(?:=|$)/u
        .test(argument)
    )
  ) {
    throw fail("production Wrangler command contains a forbidden override");
  }
  const arguments_ = [
    PINNED_WRANGLER_PATH,
    ...commandArguments,
    `--config=${configPath}`,
    `--env-file=${emptyEnvironmentPath}`,
    "--env=",
    `--name=${workerName}`,
  ];
  if (assumeYes) {
    arguments_.push("--yes");
  }
  return arguments_;
}

export async function spawnPinnedProductionWrangler({
  arguments_,
  workingDirectory,
  parentEnvironment = process.env,
  spawnProcess = spawn,
  stdio = "inherit",
}) {
  if (
    !Array.isArray(arguments_) ||
    arguments_[0] !== PINNED_WRANGLER_PATH
  ) {
    throw fail("pinned Wrangler invocation is invalid");
  }
  const configArguments = arguments_.filter((argument) =>
    argument.startsWith("--config=")
  );
  if (
    typeof workingDirectory !== "string" ||
    resolve(workingDirectory) !== workingDirectory ||
    configArguments.length !== 1 ||
    dirname(configArguments[0].slice("--config=".length)) !==
      workingDirectory
  ) {
    throw fail("pinned Wrangler working directory is invalid");
  }
  const child = spawnProcess(process.execPath, arguments_, {
    cwd: workingDirectory,
    env: productionWranglerEnvironment(parentEnvironment),
    shell: false,
    stdio,
  });
  const exitCode = await new Promise((resolveExit, rejectExit) => {
    child.once("error", rejectExit);
    child.once("close", resolveExit);
  }).catch(() => {
    throw fail("Wrangler command could not be started");
  });
  if (exitCode !== 0) {
    throw fail("Wrangler command failed");
  }
}
