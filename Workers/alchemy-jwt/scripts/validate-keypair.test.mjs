import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rename,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, before, test } from "node:test";

import {
  readBoundedRegularFile,
  SafePreflightError,
  validateKeypair,
} from "./validate-keypair.mjs";

const EXPECTED_KID = "tool-test-kid";
const temporaryDirectories = [];
let rsa2048;
let otherRsa2048;
let rsa3072;
let rsa2048Exponent3;

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
  rawSecrets,
  directory: suppliedDirectory,
} = {}) {
  const directory =
    suppliedDirectory ??
    await mkdtemp(join(tmpdir(), "alchemy-jwt-preflight-"));
  if (suppliedDirectory === undefined) {
    temporaryDirectories.push(directory);
  }
  const secretsFile = join(directory, "secrets.json");
  const publicKeyFile = join(directory, "public.pem");
  const secrets =
    rawSecrets ??
    JSON.stringify({ ALCHEMY_JWT_PRIVATE_KEY: privatePem });
  await writeFile(secretsFile, secrets, { mode: 0o600 });
  await chmod(secretsFile, secretsMode);
  await writeFile(publicKeyFile, publicPem, { mode: 0o644 });
  return { secretsFile, publicKeyFile, expectedKid: EXPECTED_KID };
}

test("accepts a matching RSA-2048 PKCS8/SPKI keypair", async () => {
  await assert.doesNotReject(validateKeypair(await writeFixture()));
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

test("rejects unsafe secrets-file permissions", async () => {
  await assert.rejects(
    validateKeypair(await writeFixture({ secretsMode: 0o644 })),
    /permissions must deny group and world access/u,
  );
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
  const outer = await mkdtemp(
    join(tmpdir(), "alchemy-jwt-preflight-ancestor-"),
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
  const outer = await mkdtemp(
    join(tmpdir(), "alchemy-jwt-preflight-sticky-"),
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
  await symlink(options.secretsFile, secretLink);
  await symlink(options.publicKeyFile, publicLink);

  await assert.rejects(
    validateKeypair({ ...options, secretsFile: secretLink }),
    /symlinks are not allowed/u,
  );
  await assert.rejects(
    validateKeypair({ ...options, publicKeyFile: publicLink }),
    /symlinks are not allowed/u,
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
    /must contain only ALCHEMY_JWT_PRIVATE_KEY/u,
  );
});

test("CLI failures never disclose supplied secret material", async () => {
  const sentinel = "never-print-this-private-key-sentinel";
  const options = await writeFixture({
    rawSecrets: JSON.stringify({
      ALCHEMY_JWT_PRIVATE_KEY: sentinel,
    }),
  });
  const result = spawnSync(
    process.execPath,
    [
      new URL("./validate-keypair.mjs", import.meta.url).pathname,
      "--secrets-file",
      options.secretsFile,
      "--public-key-file",
      options.publicKeyFile,
      "--expected-kid",
      EXPECTED_KID,
    ],
    { encoding: "utf8" },
  );

  assert.equal(result.status, 1);
  assert.doesNotMatch(result.stdout, new RegExp(sentinel, "u"));
  assert.doesNotMatch(result.stderr, new RegExp(sentinel, "u"));
  assert.match(result.stderr, /keypair-preflight: failed/u);
});
