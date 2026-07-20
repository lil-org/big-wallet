import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
} from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, before, test } from "node:test";

import {
  keypairMain,
  parseRequestProofKeyFile,
  readBoundedRegularFile,
  readExpectedRequestProofKeyFingerprint,
  SafePreflightError,
  validateKeypair as validateKeypairWithDependencies,
} from "./validate-keypair.mjs";

const EXPECTED_KID = "tool-test-kid";
const REQUEST_PROOF_KEY =
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const OTHER_REQUEST_PROOF_KEY =
  "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8";
const REQUEST_PROOF_KEY_FINGERPRINT = createHash("sha256")
  .update(REQUEST_PROOF_KEY, "ascii")
  .digest("hex");
const OTHER_REQUEST_PROOF_KEY_FINGERPRINT = createHash("sha256")
  .update(OTHER_REQUEST_PROOF_KEY, "ascii")
  .digest("hex");
const temporaryDirectories = [];
let rsa2048;
let otherRsa2048;
let rsa3072;
let rsa2048Exponent3;

function validateKeypair(options) {
  return validateKeypairWithDependencies(options, {
    expectedRequestProofKeyFingerprint:
      REQUEST_PROOF_KEY_FINGERPRINT,
  });
}

function generateFixture(modulusLength, publicExponent = 65_537) {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", {
    modulusLength,
    publicExponent,
  });
  return {
    pkcs8: privateKey.export({ format: "pem", type: "pkcs8" }).toString(),
    pkcs1: privateKey.export({ format: "pem", type: "pkcs1" }).toString(),
    spki: publicKey.export({ format: "pem", type: "spki" }).toString(),
  };
}

before(() => {
  rsa2048 = generateFixture(2_048);
  otherRsa2048 = generateFixture(2_048);
  rsa3072 = generateFixture(3_072);
  rsa2048Exponent3 = generateFixture(2_048, 3);
});

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) =>
      rm(path, { recursive: true, force: true }),
    ),
  );
});

async function writeFixture({
  privatePem = rsa2048.pkcs8,
  publicPem = rsa2048.spki,
  secretsMode = 0o600,
  appProofKey = `${REQUEST_PROOF_KEY}\n`,
  appProofKeyMode = 0o600,
  rawSecrets,
  directory: suppliedDirectory,
} = {}) {
  const directory =
    suppliedDirectory ??
    await realpath(
      await mkdtemp(join(tmpdir(), "alchemy-jwt-preflight-")),
    );
  if (suppliedDirectory === undefined) {
    temporaryDirectories.push(directory);
  }
  const secretsFile = join(directory, "secrets.json");
  const publicKeyFile = join(directory, "public.pem");
  const appProofKeyFile = join(directory, "app-proof.key");
  const secrets =
    rawSecrets ??
    JSON.stringify({
      ALCHEMY_JWT_PRIVATE_KEY: privatePem,
      ALCHEMY_JWT_REQUEST_PROOF_KEY: REQUEST_PROOF_KEY,
    });
  await writeFile(secretsFile, secrets, { mode: 0o600 });
  await chmod(secretsFile, secretsMode);
  await writeFile(publicKeyFile, publicPem, { mode: 0o644 });
  await writeFile(appProofKeyFile, appProofKey, { mode: 0o600 });
  await chmod(appProofKeyFile, appProofKeyMode);
  return {
    secretsFile,
    publicKeyFile,
    appProofKeyFile,
    expectedKid: EXPECTED_KID,
  };
}

test("accepts matching RSA and Worker/app request-proof keys", async () => {
  await assert.doesNotReject(validateKeypair(await writeFixture()));
  await assert.doesNotReject(
    validateKeypair(
      await writeFixture({ appProofKey: REQUEST_PROOF_KEY }),
    ),
  );
});

test("strict proof-key parser rejects alternate raw encodings", () => {
  const canonicalBytes = Buffer.from(REQUEST_PROOF_KEY, "ascii");
  assert.deepEqual(
    parseRequestProofKeyFile(
      canonicalBytes,
      REQUEST_PROOF_KEY_FINGERPRINT,
    ),
    Buffer.from(REQUEST_PROOF_KEY, "base64url"),
  );
  assert.deepEqual(
    parseRequestProofKeyFile(
      Buffer.concat([canonicalBytes, Buffer.from("\n", "ascii")]),
      REQUEST_PROOF_KEY_FINGERPRINT,
    ),
    Buffer.from(REQUEST_PROOF_KEY, "base64url"),
  );

  for (const appProofKeyBytes of [
    Buffer.concat([
      Buffer.from([0xef, 0xbb, 0xbf]),
      canonicalBytes,
    ]),
    Buffer.concat([canonicalBytes, Buffer.from("\r\n", "ascii")]),
    Buffer.concat([canonicalBytes, Buffer.from("=", "ascii")]),
    Buffer.concat([canonicalBytes, Buffer.from("\n\n", "ascii")]),
    Buffer.concat([canonicalBytes.subarray(0, 42), Buffer.from([0xff])]),
  ]) {
    assert.throws(
      () => parseRequestProofKeyFile(
        appProofKeyBytes,
        REQUEST_PROOF_KEY_FINGERPRINT,
      ),
      /app proof key file is invalid/u,
    );
  }
});

test("fingerprint file parser requires exact lowercase SHA-256 text", async () => {
  const directory = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-fingerprint-test-"),
    ),
  );
  temporaryDirectories.push(directory);
  const fingerprintPath = join(directory, "proof-key.sha256");
  await writeFile(
    fingerprintPath,
    `${REQUEST_PROOF_KEY_FINGERPRINT}\n`,
    { mode: 0o644 },
  );
  assert.equal(
    await readExpectedRequestProofKeyFingerprint(fingerprintPath),
    REQUEST_PROOF_KEY_FINGERPRINT,
  );

  for (const malformed of [
    REQUEST_PROOF_KEY_FINGERPRINT.toUpperCase(),
    `\ufeff${REQUEST_PROOF_KEY_FINGERPRINT}`,
    `${REQUEST_PROOF_KEY_FINGERPRINT}\r\n`,
  ]) {
    await writeFile(fingerprintPath, malformed, { mode: 0o644 });
    await assert.rejects(
      readExpectedRequestProofKeyFingerprint(fingerprintPath),
      /(fingerprint file|key input file size) is invalid/u,
    );
  }
});

test("rejects a valid proof key that does not match the pinned fingerprint", async () => {
  const options = await writeFixture();
  await assert.rejects(
    validateKeypairWithDependencies(options, {
      expectedRequestProofKeyFingerprint:
        OTHER_REQUEST_PROOF_KEY_FINGERPRINT,
    }),
    /does not match the pinned fingerprint/u,
  );
});

test("rejects a mismatched app request-proof key", async () => {
  await assert.rejects(
    validateKeypairWithDependencies(
      await writeFixture({ appProofKey: OTHER_REQUEST_PROOF_KEY }),
      {
        expectedRequestProofKeyFingerprint:
          OTHER_REQUEST_PROOF_KEY_FINGERPRINT,
      },
    ),
    /Worker and app request-proof keys do not match/u,
  );
});

test("rejects malformed request-proof keys", async () => {
  await assert.rejects(
    validateKeypair(
      await writeFixture({
        rawSecrets: JSON.stringify({
          ALCHEMY_JWT_PRIVATE_KEY: rsa2048.pkcs8,
          ALCHEMY_JWT_REQUEST_PROOF_KEY: `${REQUEST_PROOF_KEY}=`,
        }),
      }),
    ),
    /request-proof secret must be a canonical 32-byte base64url key/u,
  );
  for (const appProofKey of [
    `${REQUEST_PROOF_KEY}\n\n`,
    `${REQUEST_PROOF_KEY}\r\n`,
    `${REQUEST_PROOF_KEY} `,
    `${REQUEST_PROOF_KEY}=`,
  ]) {
    await assert.rejects(
      validateKeypair(await writeFixture({ appProofKey })),
      /(app proof key file|key input file size) is invalid/u,
    );
  }
});

test("rejects a mismatched public key", async () => {
  await assert.rejects(
    validateKeypair(
      await writeFixture({ publicPem: otherRsa2048.spki }),
    ),
    (error) =>
      error instanceof SafePreflightError &&
      error.message === "private and public keys do not match",
  );
});

test("rejects PKCS1 private key input", async () => {
  await assert.rejects(
    validateKeypair(await writeFixture({ privatePem: rsa2048.pkcs1 })),
    /private key must be unencrypted PKCS8 PEM/u,
  );
});

test("rejects concatenated private and public PEM envelopes", async () => {
  await assert.rejects(
    validateKeypair(
      await writeFixture({
        privatePem: rsa2048.pkcs8 + otherRsa2048.pkcs8,
      }),
    ),
    /private key must be unencrypted PKCS8 PEM/u,
  );
  await assert.rejects(
    validateKeypair(
      await writeFixture({
        publicPem: rsa2048.spki + otherRsa2048.spki,
      }),
    ),
    /public key must be SPKI PEM/u,
  );
});

test("rejects non-RSA-2048 keys", async () => {
  await assert.rejects(
    validateKeypair(
      await writeFixture({
        privatePem: rsa3072.pkcs8,
        publicPem: rsa3072.spki,
      }),
    ),
    /keypair must use RSA-2048/u,
  );
});

test("rejects RSA-2048 keys with a non-65537 public exponent", async () => {
  await assert.rejects(
    validateKeypair(
      await writeFixture({
        privatePem: rsa2048Exponent3.pkcs8,
        publicPem: rsa2048Exponent3.spki,
      }),
    ),
    /public exponent 65537/u,
  );
});

test("requires exact mode 0600 for the secrets file", async () => {
  for (const secretsMode of [0o400, 0o644, 0o700]) {
    await assert.rejects(
      validateKeypair(await writeFixture({ secretsMode })),
      /permissions must be exactly 0600/u,
    );
  }
});

test("requires mode 0600 for the external app proof key", async () => {
  for (const appProofKeyMode of [0o400, 0o644, 0o700]) {
    await assert.rejects(
      validateKeypair(
        await writeFixture({ appProofKeyMode }),
      ),
      /permissions must be exactly 0600/u,
    );
  }
});

test("requires an owner-only secrets directory", async () => {
  const options = await writeFixture();
  await chmod(temporaryDirectories.at(-1), 0o755);

  await assert.rejects(
    validateKeypair(options),
    /secrets directory permissions must deny group and world access/u,
  );
});

test("rejects a non-sticky writable ancestor", async () => {
  const outer = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-preflight-ancestor-"),
    ),
  );
  temporaryDirectories.push(outer);
  const writableAncestor = join(outer, "writable");
  const protectedDirectory = join(writableAncestor, "protected");
  await mkdir(writableAncestor, { mode: 0o700 });
  await mkdir(protectedDirectory, { mode: 0o700 });
  const options = await writeFixture({
    directory: protectedDirectory,
  });
  await chmod(writableAncestor, 0o777);

  await assert.rejects(
    validateKeypair(options),
    /directory permissions are unsafe/u,
  );
});

test("accepts a trusted sticky writable ancestor", async () => {
  const outer = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-preflight-sticky-"),
    ),
  );
  temporaryDirectories.push(outer);
  const stickyAncestor = join(outer, "sticky");
  const protectedDirectory = join(stickyAncestor, "protected");
  await mkdir(stickyAncestor, { mode: 0o700 });
  await mkdir(protectedDirectory, { mode: 0o700 });
  const options = await writeFixture({
    directory: protectedDirectory,
  });
  await chmod(stickyAncestor, 0o1777);

  await assert.doesNotReject(validateKeypair(options));
});

test("rejects final-component key input symlinks", async () => {
  const options = await writeFixture();
  const directory = temporaryDirectories.at(-1);
  const secretLink = join(directory, "secret-link.json");
  const publicLink = join(directory, "public-link.pem");
  const appProofLink = join(directory, "app-proof-link.key");
  await symlink(options.secretsFile, secretLink);
  await symlink(options.publicKeyFile, publicLink);
  await symlink(options.appProofKeyFile, appProofLink);

  await assert.rejects(
    validateKeypair({ ...options, secretsFile: secretLink }),
    /symlinks are not allowed/u,
  );
  await assert.rejects(
    validateKeypair({ ...options, publicKeyFile: publicLink }),
    /symlinks are not allowed/u,
  );
  await assert.rejects(
    validateKeypair({ ...options, appProofKeyFile: appProofLink }),
    /symlinks are not allowed/u,
  );
});

test("rejects symlinked ancestors and noncanonical key paths", async () => {
  const outer = await realpath(
    await mkdtemp(join(tmpdir(), "alchemy-jwt-preflight-path-")),
  );
  temporaryDirectories.push(outer);
  const realParent = join(outer, "real-parent");
  const protectedDirectory = join(realParent, "protected");
  await mkdir(realParent, { mode: 0o700 });
  await mkdir(protectedDirectory, { mode: 0o700 });
  const options = await writeFixture({
    directory: protectedDirectory,
  });
  const linkedParent = join(outer, "linked-parent");
  await symlink(realParent, linkedParent);

  await assert.rejects(
    validateKeypair({
      ...options,
      appProofKeyFile: join(
        linkedParent,
        "protected",
        "app-proof.key",
      ),
    }),
    /must not contain symlinked components/u,
  );
  await assert.rejects(
    validateKeypair({
      ...options,
      appProofKeyFile:
        `${protectedDirectory}/./app-proof.key`,
    }),
    /path must be canonical and absolute/u,
  );
});

test("detects pathname replacement while reading", async () => {
  const options = await writeFixture();
  const originalBytes = await readFile(options.secretsFile);
  const replacedPath = `${options.secretsFile}.replaced`;

  await assert.rejects(
    readBoundedRegularFile(
      options.secretsFile,
      32 * 1_024,
      {
        requirePrivatePermissions: true,
        afterFirstRead: async () => {
          await rename(options.secretsFile, replacedPath);
          await writeFile(options.secretsFile, originalBytes, {
            mode: 0o600,
          });
        },
      },
    ),
    /changed while it was being validated/u,
  );
});

test("detects same-inode content mutation while reading", async () => {
  const options = await writeFixture();
  const originalBytes = await readFile(options.secretsFile);
  const replacementBytes = Buffer.alloc(
    originalBytes.byteLength,
    0x78,
  );

  await assert.rejects(
    readBoundedRegularFile(
      options.secretsFile,
      32 * 1_024,
      {
        requirePrivatePermissions: true,
        afterFirstRead: async () => {
          await writeFile(options.secretsFile, replacementBytes);
        },
      },
    ),
    /changed while it was being validated/u,
  );
});

test("rejects missing and unreadable key inputs without disclosing paths", async () => {
  const missing = await writeFixture();
  const missingPath = join(
    temporaryDirectories.at(-1),
    "missing-private-bundle.json",
  );
  await assert.rejects(
    validateKeypair({ ...missing, secretsFile: missingPath }),
    (error) =>
      error instanceof SafePreflightError &&
      error.message === "key input file could not be read safely" &&
      !error.message.includes(missingPath),
  );

  const unreadable = await writeFixture();
  await chmod(unreadable.secretsFile, 0o000);
  await assert.rejects(
    validateKeypair(unreadable),
    (error) =>
      error instanceof SafePreflightError &&
      error.message === "key input file could not be read safely" &&
      !error.message.includes(unreadable.secretsFile),
  );
});

test("rejects malformed and incorrectly shaped secret bundles", async () => {
  await assert.rejects(
    validateKeypair(await writeFixture({ rawSecrets: "{" })),
    /valid UTF-8 JSON/u,
  );
  await assert.rejects(
    validateKeypair(await writeFixture({ rawSecrets: "{}" })),
    /must contain exactly the signing and request-proof keys/u,
  );
});

test("CLI failures never disclose supplied secret material", async () => {
  const sentinel = "never-print-this-private-key-sentinel";
  const options = await writeFixture({
    rawSecrets: JSON.stringify({
      ALCHEMY_JWT_PRIVATE_KEY: sentinel,
      ALCHEMY_JWT_REQUEST_PROOF_KEY: REQUEST_PROOF_KEY,
    }),
  });
  const output = [];
  const errors = [];
  const exitCode = await keypairMain(
    [
      "--secrets-file",
      options.secretsFile,
      "--public-key-file",
      options.publicKeyFile,
      "--app-proof-key-file",
      options.appProofKeyFile,
      "--expected-kid",
      EXPECTED_KID,
    ],
    {
      expectedRequestProofKeyFingerprint:
        REQUEST_PROOF_KEY_FINGERPRINT,
      stdout: (message) => output.push(message),
      stderr: (message) => errors.push(message),
    },
  );

  assert.equal(exitCode, 1);
  assert.doesNotMatch(output.join("\n"), new RegExp(sentinel, "u"));
  assert.doesNotMatch(errors.join("\n"), new RegExp(sentinel, "u"));
  assert.match(errors.join("\n"), /keypair-preflight: failed/u);
});
