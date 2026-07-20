#!/usr/bin/env node

import {
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
  isAbsolute,
  parse,
  resolve,
  sep,
} from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const MAX_SECRETS_FILE_BYTES = 32 * 1_024;
const MAX_PUBLIC_KEY_FILE_BYTES = 16 * 1_024;
const PRIVATE_KEY_FIELD = "ALCHEMY_JWT_PRIVATE_KEY";
const PRINTABLE_KEY_ID = /^[\u0021-\u007e]{1,256}$/u;

export class SafePreflightError extends Error {
  constructor(message) {
    super(message);
    this.name = "SafePreflightError";
  }
}

function fail(message) {
  return new SafePreflightError(message);
}

function usage() {
  return [
    "Usage: node scripts/validate-keypair.mjs [options]",
    "",
    "Required options:",
    "  --secrets-file PATH     Absolute path to mode-0600 Wrangler JSON secrets",
    "  --public-key-file PATH  Absolute path to Alchemy's SPKI public key PEM",
    "  --expected-kid KID      Alchemy key ID to place in the test JWT header",
    "",
    "The command never prints key material, the kid, the JWT, or its signature.",
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
    expectedKid: undefined,
  };
  const fields = new Map([
    ["--secrets-file", "secretsFile"],
    ["--public-key-file", "publicKeyFile"],
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
    parsed.expectedKid === undefined
  ) {
    throw fail("all three keypair options are required");
  }
  if (
    !isAbsolute(parsed.secretsFile) ||
    !isAbsolute(parsed.publicKeyFile)
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
      (before.mode & 0o077) !== 0
    ) {
      throw fail(
        "secrets file permissions must deny group and world access",
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
  const originalStats = await lstat(path);
  if (originalStats.isSymbolicLink()) {
    throw fail("key input symlinks are not allowed");
  }

  const canonicalPath = await realpath(path);
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
    Object.keys(parsed).length !== 1 ||
    Object.keys(parsed)[0] !== PRIVATE_KEY_FIELD ||
    typeof parsed[PRIVATE_KEY_FIELD] !== "string"
  ) {
    throw fail(`secrets file must contain only ${PRIVATE_KEY_FIELD}`);
  }
  return parsed[PRIVATE_KEY_FIELD];
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
  expectedKid,
}) {
  if (
    !isAbsolute(secretsFile) ||
    !isAbsolute(publicKeyFile) ||
    !PRINTABLE_KEY_ID.test(expectedKid)
  ) {
    throw fail("keypair inputs are invalid");
  }

  const [secretsBytes, publicKeyBytes] = await Promise.all([
    readBoundedRegularFile(secretsFile, MAX_SECRETS_FILE_BYTES, {
      requirePrivatePermissions: true,
    }),
    readBoundedRegularFile(publicKeyFile, MAX_PUBLIC_KEY_FILE_BYTES),
  ]);
  const privateKey = parsePrivateKey(parseSecretsFile(secretsBytes));
  const publicKey = parsePublicKey(publicKeyBytes);
  requireRsa2048(privateKey);
  requireRsa2048(publicKey);

  const derivedPublicDer = createPublicKey(privateKey).export({
    format: "der",
    type: "spki",
  });
  const suppliedPublicDer = publicKey.export({
    format: "der",
    type: "spki",
  });
  if (
    derivedPublicDer.byteLength !== suppliedPublicDer.byteLength ||
    !timingSafeEqual(derivedPublicDer, suppliedPublicDer)
  ) {
    throw fail("private and public keys do not match");
  }

  const signingInput = [
    base64UrlJson({ alg: "RS256", typ: "JWT", kid: expectedKid }),
    base64UrlJson({ iat: 1_800_000_000, exp: 1_800_086_400 }),
  ].join(".");
  const signature = sign("RSA-SHA256", Buffer.from(signingInput), privateKey);
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

  return { secretsBytes };
}

export async function validateKeypair(options) {
  await prepareValidatedKeypair(options);
}

export async function keypairMain(
  arguments_,
  {
    stdout = (message) => console.log(message),
    stderr = (message) => console.error(message),
  } = {},
) {
  try {
    const options = parseKeypairArguments(arguments_);
    if (options.help) {
      stdout(usage());
      return 0;
    }
    await validateKeypair(options);
    stdout("keypair-preflight: pass rsa=2048 formats=pkcs8/spki");
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
