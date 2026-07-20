#!/usr/bin/env node

import {
  createHash,
  createPrivateKey,
  createPublicKey,
  sign,
  timingSafeEqual,
  verify,
} from "node:crypto";
import { constants } from "node:fs";
import {
  lstat,
  open,
  realpath,
} from "node:fs/promises";
import {
  dirname,
  isAbsolute,
  parse,
  resolve,
  sep,
} from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const MAX_SECRETS_FILE_BYTES = 32 * 1_024;
const MAX_PUBLIC_KEY_FILE_BYTES = 16 * 1_024;
const MAX_APP_PROOF_KEY_FILE_BYTES = 44;
const MAX_PROOF_KEY_FINGERPRINT_FILE_BYTES = 65;
const PRIVATE_KEY_FIELD = "ALCHEMY_JWT_PRIVATE_KEY";
const REQUEST_PROOF_KEY_FIELD = "ALCHEMY_JWT_REQUEST_PROOF_KEY";
const CANONICAL_PROOF_KEY = /^[A-Za-z0-9_-]{43}$/u;
const CANONICAL_PROOF_KEY_FINGERPRINT = /^[0-9a-f]{64}$/u;
const PRINTABLE_KEY_ID = /^[\u0021-\u007e]{1,256}$/u;
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
export const REQUEST_PROOF_KEY_FINGERPRINT_PATH = resolve(
  scriptDirectory,
  "../../../Scripts/alchemy_jwt_request_proof_key.sha256",
);

export class SafePreflightError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafePreflightError";
  }
}

function fail(message) {
  return new SafePreflightError(message);
}

function strictASCII(bytes, pattern, description) {
  if (!(bytes instanceof Uint8Array)) {
    throw fail(`${description} is invalid`);
  }
  for (const byte of bytes) {
    if (byte > 0x7f) {
      throw fail(`${description} is invalid`);
    }
  }
  const value = Buffer.from(
    bytes.buffer,
    bytes.byteOffset,
    bytes.byteLength,
  ).toString("ascii");
  if (!pattern.test(value)) {
    throw fail(`${description} is invalid`);
  }
  return value;
}

function parseFingerprintBytes(bytes) {
  if (
    !(bytes instanceof Uint8Array) ||
    (
      bytes.byteLength !== 64 &&
      !(
        bytes.byteLength === 65 &&
        bytes[64] === 0x0a
      )
    )
  ) {
    throw fail("request-proof key fingerprint file is invalid");
  }
  return strictASCII(
    bytes.subarray(0, 64),
    CANONICAL_PROOF_KEY_FINGERPRINT,
    "request-proof key fingerprint file",
  );
}

function requireExpectedFingerprint(value) {
  if (
    typeof value !== "string" ||
    !CANONICAL_PROOF_KEY_FINGERPRINT.test(value)
  ) {
    throw fail("expected request-proof key fingerprint is invalid");
  }
  return value;
}

export async function readExpectedRequestProofKeyFingerprint(
  path = REQUEST_PROOF_KEY_FINGERPRINT_PATH,
) {
  return parseFingerprintBytes(
    await readBoundedRegularFile(
      path,
      MAX_PROOF_KEY_FINGERPRINT_FILE_BYTES,
    ),
  );
}

export function parseRequestProofKeyFile(
  bytes,
  expectedFingerprint,
) {
  if (
    !(bytes instanceof Uint8Array) ||
    (
      bytes.byteLength !== 43 &&
      !(
        bytes.byteLength === 44 &&
        bytes[43] === 0x0a
      )
    )
  ) {
    throw fail("app proof key file is invalid");
  }
  const encoded = strictASCII(
    bytes.subarray(0, 43),
    CANONICAL_PROOF_KEY,
    "app proof key file",
  );
  const key = parseProofKey(encoded, "app proof key");
  const expectedDigest = Buffer.from(
    requireExpectedFingerprint(expectedFingerprint),
    "hex",
  );
  const actualDigest = createHash("sha256")
    .update(encoded, "ascii")
    .digest();
  if (
    actualDigest.byteLength !== expectedDigest.byteLength ||
    !timingSafeEqual(actualDigest, expectedDigest)
  ) {
    key.fill(0);
    throw fail("app proof key does not match the pinned fingerprint");
  }
  return key;
}

export async function readValidatedRequestProofKeyFile(
  path,
  {
    expectedFingerprint,
  } = {},
) {
  const pinnedFingerprint =
    expectedFingerprint === undefined
      ? await readExpectedRequestProofKeyFingerprint()
      : requireExpectedFingerprint(expectedFingerprint);
  return parseRequestProofKeyFile(
    await readBoundedRegularFile(
      path,
      MAX_APP_PROOF_KEY_FILE_BYTES,
      { requirePrivatePermissions: true },
    ),
    pinnedFingerprint,
  );
}

function usage() {
  return [
    "Usage: node scripts/validate-keypair.mjs [options]",
    "",
    "Required options:",
    "  --secrets-file PATH     Absolute path to mode-0600 Wrangler JSON secrets",
    "  --public-key-file PATH  Absolute path to Alchemy's SPKI public key PEM",
    "  --app-proof-key-file PATH",
    "                         Absolute path to the app's mode-0600 proof key",
    "  --expected-kid KID      Alchemy key ID to place in the test JWT header",
    "",
    "The command never prints key material, the kid, the JWT, or signatures.",
  ].join("\n");
}

export function parseKeypairArguments(arguments_) {
  if (arguments_.length === 1 && arguments_[0] === "--help") {
    return { help: true };
  }

  const parsed = {
    help: false,
    secretsFile: undefined,
    publicKeyFile: undefined,
    appProofKeyFile: undefined,
    expectedKid: undefined,
  };
  const fields = new Map([
    ["--secrets-file", "secretsFile"],
    ["--public-key-file", "publicKeyFile"],
    ["--app-proof-key-file", "appProofKeyFile"],
    ["--expected-kid", "expectedKid"],
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
    parsed.expectedKid === undefined
  ) {
    throw fail("all four key and proof options are required");
  }
  if (
    !isAbsolute(parsed.secretsFile) ||
    !isAbsolute(parsed.publicKeyFile) ||
    !isAbsolute(parsed.appProofKeyFile)
  ) {
    throw fail("key files must use absolute paths");
  }
  if (!PRINTABLE_KEY_ID.test(parsed.expectedKid)) {
    throw fail("expected kid is invalid");
  }
  return parsed;
}

export async function readBoundedRegularFile(
  path,
  maximumBytes,
  {
    requirePrivatePermissions = false,
    afterFirstRead,
  } = {},
) {
  let handle;
  try {
    const canonicalPath = await canonicalKeyInputPath(path, {
      requirePrivatePermissions,
    });
    const noFollow = constants.O_NOFOLLOW ?? 0;
    handle = await open(
      canonicalPath,
      constants.O_RDONLY | noFollow,
    );
    const before = await handle.stat();
    const pathBefore = await lstat(canonicalPath);
    if (!before.isFile() || !pathBefore.isFile()) {
      throw fail("key input must be a regular file");
    }
    if (!sameFileIdentity(before, pathBefore)) {
      throw fail("key input changed while it was being validated");
    }
    if (before.size <= 0 || before.size > maximumBytes) {
      throw fail("key input file size is invalid");
    }
    const effectiveUserID = requireEffectiveUserID();
    if (before.uid !== effectiveUserID) {
      throw fail("key input ownership is invalid");
    }
    if (
      requirePrivatePermissions &&
      (before.mode & 0o777) !== 0o600
    ) {
      throw fail(
        "private key input permissions must be exactly 0600",
      );
    }

    const firstRead = await readFileAtPosition(
      handle,
      before.size,
    );
    await afterFirstRead?.({
      canonicalPath,
      stats: before,
    });
    const secondRead = await readFileAtPosition(
      handle,
      before.size,
    );
    const after = await handle.stat();
    const pathAfter = await lstat(canonicalPath);
    if (
      !stableFileMetadata(before, after) ||
      !sameFileIdentity(after, pathAfter) ||
      firstRead.byteLength !== secondRead.byteLength ||
      !timingSafeEqual(firstRead, secondRead)
    ) {
      throw fail("key input changed while it was being validated");
    }
    return firstRead;
  } catch (error) {
    if (error instanceof SafePreflightError) {
      throw error;
    }
    throw fail("key input file could not be read safely");
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function requireEffectiveUserID() {
  const effectiveUserID = process.geteuid?.() ?? process.getuid?.();
  if (!Number.isSafeInteger(effectiveUserID) || effectiveUserID < 0) {
    throw fail("key input ownership could not be validated");
  }
  return effectiveUserID;
}

function sameFileIdentity(first, second) {
  return first.dev === second.dev && first.ino === second.ino;
}

function stableFileMetadata(first, second) {
  return sameFileIdentity(first, second) &&
    first.uid === second.uid &&
    first.mode === second.mode &&
    first.size === second.size &&
    first.mtimeMs === second.mtimeMs &&
    first.ctimeMs === second.ctimeMs;
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
      throw fail("key input changed while it was being validated");
    }
    offset += bytesRead;
  }
  return bytes;
}

async function canonicalKeyInputPath(
  path,
  { requirePrivatePermissions },
) {
  if (!isAbsolute(path) || resolve(path) !== path) {
    throw fail("key input path must be canonical and absolute");
  }
  const originalStats = await lstat(path);
  if (originalStats.isSymbolicLink()) {
    throw fail("key input symlinks are not allowed");
  }

  const canonicalPath = await realpath(path);
  if (canonicalPath !== path) {
    throw fail(
      "key input path must not contain symlinked components",
    );
  }
  await validateCanonicalPath(
    canonicalPath,
    requirePrivatePermissions,
  );
  return canonicalPath;
}

async function validateCanonicalPath(
  canonicalPath,
  requirePrivatePermissions,
) {
  const effectiveUserID = requireEffectiveUserID();
  const root = parse(canonicalPath).root;
  const relativeParts = canonicalPath
    .slice(root.length)
    .split(sep)
    .filter(Boolean);
  if (relativeParts.length < 2) {
    throw fail("key input path is invalid");
  }

  const directoryPaths = [root];
  let current = root;
  for (const part of relativeParts.slice(0, -1)) {
    current = resolve(current, part);
    directoryPaths.push(current);
  }

  const directoryStats = [];
  for (const directoryPath of directoryPaths) {
    const stats = await lstat(directoryPath);
    if (stats.isSymbolicLink() || !stats.isDirectory()) {
      throw fail("key input directory chain is invalid");
    }
    if (stats.uid !== 0 && stats.uid !== effectiveUserID) {
      throw fail("key input directory ownership is invalid");
    }
    directoryStats.push(stats);
  }

  const fileStats = await lstat(canonicalPath);
  if (fileStats.isSymbolicLink() || !fileStats.isFile()) {
    throw fail("key input must be a regular file");
  }
  if (fileStats.uid !== effectiveUserID) {
    throw fail("key input ownership is invalid");
  }

  for (let index = 0; index < directoryStats.length; index += 1) {
    const stats = directoryStats[index];
    const isWritableByOthers = (stats.mode & 0o022) !== 0;
    if (!isWritableByOthers) {
      continue;
    }

    const isSticky = (stats.mode & 0o1000) !== 0;
    const nextStats =
      directoryStats[index + 1] ?? fileStats;
    const nextOwnerIsTrusted =
      nextStats.uid === 0 || nextStats.uid === effectiveUserID;
    if (!isSticky || !nextOwnerIsTrusted) {
      throw fail("key input directory permissions are unsafe");
    }
  }

  if (requirePrivatePermissions) {
    const parentStats = directoryStats.at(-1);
    if (
      parentStats === undefined ||
      parentStats.uid !== effectiveUserID ||
      (parentStats.mode & 0o077) !== 0
    ) {
      throw fail(
        "secrets directory permissions must deny group and world access",
      );
    }
  }
}

function parseSecretsFile(bytes) {
  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw fail("secrets file must be valid UTF-8 JSON");
  }
  if (
    typeof parsed !== "object" ||
    parsed === null ||
    Array.isArray(parsed) ||
    Object.getPrototypeOf(parsed) !== Object.prototype ||
    Object.keys(parsed).length !== 2 ||
    !Object.hasOwn(parsed, PRIVATE_KEY_FIELD) ||
    !Object.hasOwn(parsed, REQUEST_PROOF_KEY_FIELD) ||
    typeof parsed[PRIVATE_KEY_FIELD] !== "string" ||
    typeof parsed[REQUEST_PROOF_KEY_FIELD] !== "string"
  ) {
    throw fail(
      "secrets file must contain exactly the signing and request-proof keys",
    );
  }
  return {
    privateKeyPem: parsed[PRIVATE_KEY_FIELD],
    requestProofKey: parseProofKey(
      parsed[REQUEST_PROOF_KEY_FIELD],
      "request-proof secret",
    ),
  };
}

function parseProofKey(encoded, description) {
  if (
    typeof encoded !== "string" ||
    !CANONICAL_PROOF_KEY.test(encoded)
  ) {
    throw fail(`${description} must be a canonical 32-byte base64url key`);
  }
  const bytes = Buffer.from(encoded, "base64url");
  if (
    bytes.byteLength !== 32 ||
    bytes.toString("base64url") !== encoded
  ) {
    throw fail(`${description} must be a canonical 32-byte base64url key`);
  }
  return bytes;
}

function requireSinglePemEnvelope(
  pem,
  beginMarker,
  endMarker,
  errorMessage,
) {
  const trimmed = pem.trim();
  if (
    !trimmed.startsWith(beginMarker) ||
    !trimmed.endsWith(endMarker)
  ) {
    throw fail(errorMessage);
  }

  const encoded = trimmed
    .slice(beginMarker.length, -endMarker.length)
    .replace(/\s/gu, "");
  if (
    encoded.length === 0 ||
    encoded.length > 8_192 ||
    !/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded)
  ) {
    throw fail(errorMessage);
  }
  return trimmed;
}

function parsePrivateKey(pem) {
  const errorMessage = "private key must be unencrypted PKCS8 PEM";
  const strictPem = requireSinglePemEnvelope(
    pem,
    "-----BEGIN PRIVATE KEY-----",
    "-----END PRIVATE KEY-----",
    errorMessage,
  );
  try {
    return createPrivateKey({
      key: strictPem,
      format: "pem",
      type: "pkcs8",
    });
  } catch {
    throw fail(errorMessage);
  }
}

function parsePublicKey(bytes) {
  let pem;
  try {
    pem = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw fail("public key must be UTF-8 SPKI PEM");
  }
  const errorMessage = "public key must be SPKI PEM";
  const strictPem = requireSinglePemEnvelope(
    pem,
    "-----BEGIN PUBLIC KEY-----",
    "-----END PUBLIC KEY-----",
    errorMessage,
  );
  try {
    return createPublicKey({
      key: strictPem,
      format: "pem",
      type: "spki",
    });
  } catch {
    throw fail(errorMessage);
  }
}

function requireRsa2048(key) {
  const details = key.asymmetricKeyDetails;
  if (
    key.asymmetricKeyType !== "rsa" ||
    details?.modulusLength !== 2_048 ||
    details.publicExponent !== 65_537n
  ) {
    throw fail("keypair must use RSA-2048 with public exponent 65537");
  }
}

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

export async function prepareValidatedKeypair({
  secretsFile,
  publicKeyFile,
  appProofKeyFile,
  expectedKid,
}, {
  expectedRequestProofKeyFingerprint,
} = {}) {
  if (
    typeof secretsFile !== "string" ||
    !isAbsolute(secretsFile) ||
    typeof publicKeyFile !== "string" ||
    !isAbsolute(publicKeyFile) ||
    typeof appProofKeyFile !== "string" ||
    !isAbsolute(appProofKeyFile) ||
    typeof expectedKid !== "string" ||
    !PRINTABLE_KEY_ID.test(expectedKid)
  ) {
    throw fail("keypair inputs are invalid");
  }

  let secretsBytes;
  let publicKeyBytes;
  let appProofKey;
  let requestProofKey;
  let derivedPublicDer;
  let suppliedPublicDer;
  let signature;
  let succeeded = false;
  try {
    secretsBytes = await readBoundedRegularFile(
      secretsFile,
      MAX_SECRETS_FILE_BYTES,
      {
        requirePrivatePermissions: true,
      },
    );
    publicKeyBytes = await readBoundedRegularFile(
      publicKeyFile,
      MAX_PUBLIC_KEY_FILE_BYTES,
    );
    appProofKey = await readValidatedRequestProofKeyFile(
      appProofKeyFile,
      {
        expectedFingerprint: expectedRequestProofKeyFingerprint,
      },
    );
    const parsedSecrets = parseSecretsFile(secretsBytes);
    const { privateKeyPem } = parsedSecrets;
    requestProofKey = parsedSecrets.requestProofKey;
    const privateKey = parsePrivateKey(privateKeyPem);
    const publicKey = parsePublicKey(publicKeyBytes);
    requireRsa2048(privateKey);
    requireRsa2048(publicKey);

    derivedPublicDer = createPublicKey(privateKey).export({
      format: "der",
      type: "spki",
    });
    suppliedPublicDer = publicKey.export({
      format: "der",
      type: "spki",
    });
    if (
      derivedPublicDer.byteLength !== suppliedPublicDer.byteLength ||
      !timingSafeEqual(derivedPublicDer, suppliedPublicDer)
    ) {
      throw fail("private and public keys do not match");
    }
    if (
      requestProofKey.byteLength !== appProofKey.byteLength ||
      !timingSafeEqual(requestProofKey, appProofKey)
    ) {
      throw fail("Worker and app request-proof keys do not match");
    }

    const signingInput = [
      base64UrlJson({ alg: "RS256", typ: "JWT", kid: expectedKid }),
      base64UrlJson({ iat: 1_800_000_000, exp: 1_800_021_600 }),
    ].join(".");
    signature = sign(
      "RSA-SHA256",
      Buffer.from(signingInput),
      privateKey,
    );
    if (
      signature.byteLength !== 256 ||
      !verify(
        "RSA-SHA256",
        Buffer.from(signingInput),
        publicKey,
        signature,
      )
    ) {
      throw fail("keypair signing verification failed");
    }

    succeeded = true;
    return { secretsBytes };
  } finally {
    if (!succeeded) {
      secretsBytes?.fill(0);
    }
    publicKeyBytes?.fill(0);
    appProofKey?.fill(0);
    requestProofKey?.fill(0);
    derivedPublicDer?.fill(0);
    suppliedPublicDer?.fill(0);
    signature?.fill(0);
  }
}

export async function validateKeypair(options, dependencies) {
  const { secretsBytes } = await prepareValidatedKeypair(
    options,
    dependencies,
  );
  secretsBytes.fill(0);
}

export async function keypairMain(
  arguments_,
  {
    stdout = (message) => console.log(message),
    stderr = (message) => console.error(message),
    expectedRequestProofKeyFingerprint,
  } = {},
) {
  try {
    const options = parseKeypairArguments(arguments_);
    if (options.help) {
      stdout(usage());
      return 0;
    }
    await validateKeypair(options, {
      expectedRequestProofKeyFingerprint,
    });
    stdout(
      "keypair-preflight: pass rsa=2048 formats=pkcs8/spki proof-key=matched",
    );
    return 0;
  } catch (error) {
    const message =
      error instanceof SafePreflightError
        ? error.message
        : "unexpected preflight failure";
    stderr(`keypair-preflight: failed: ${message}`);
    return 1;
  }
}

const isDirectExecution =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectExecution) {
  process.exitCode = await keypairMain(process.argv.slice(2));
}
