import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtemp,
  realpath,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  afterEach,
  test,
} from "node:test";

import {
  SafeValidationError,
  assertBrokerHeaders,
  assertGenericUnauthorizedBody,
  createRequestProof,
  createSignedBrokerRequest,
  loadEvmTargets,
  parseArguments,
  parseBrokerURL,
  probeHttpRedirect,
  readAppProofKey,
  readBoundedNetworkCatalog,
  runBrokerContractProbes,
  validateOptionalDryRunProofKey,
  validateIssuancePayload,
  validateRpcMatrix,
  validateRpcTarget,
  verifyReleaseLiveContract,
} from "./live-validate.mjs";

const VERSION = "db7cd8d3-4425-4fe7-8c81-01bf963b6067";
const KID = "expected-test-kid";
const REQUEST_PROOF_KEY =
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const REQUEST_PROOF_KEY_FINGERPRINT = createHash("sha256")
  .update(REQUEST_PROOF_KEY, "ascii")
  .digest("hex");
const temporaryDirectories = [];
const TARGET = {
  kind: "evm",
  host: "eth-mainnet.g.alchemy.com",
  url: "https://eth-mainnet.g.alchemy.com/v2",
};

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) =>
      rm(path, { recursive: true, force: true }),
    ),
  );
});

function rpcResponse(result = "0x1") {
  return new Response(
    JSON.stringify({ jsonrpc: "2.0", id: 1, result }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

function brokerResponse(status, body = "{}", extraHeaders = {}) {
  return new Response(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "Strict-Transport-Security": "max-age=31536000",
      "X-Alchemy-JWT-Worker-Version": VERSION,
      "X-Content-Type-Options": "nosniff",
      ...extraHeaders,
    },
  });
}

function nonSuccessResponseWithUnreadableBody(status, onCancel) {
  let pulls = 0;
  const body = new ReadableStream({
    pull(controller) {
      pulls += 1;
      if (pulls === 1) {
        controller.enqueue(new Uint8Array([0x7b]));
      } else {
        controller.error(new Error("non-success body must not be read"));
      }
    },
    cancel() {
      onCancel();
      throw new Error("cancellation failure must not override status");
    },
  });
  return new Response(body, { status });
}

function jwtPayload(kid = KID, ttlSeconds = 21_600) {
  const issuedAt = 1_800_000_000;
  const expiresAt = issuedAt + ttlSeconds;
  const token = [
    Buffer.from(
      JSON.stringify({ alg: "RS256", typ: "JWT", kid }),
    ).toString("base64url"),
    Buffer.from(JSON.stringify({ iat: issuedAt, exp: expiresAt })).toString(
      "base64url",
    ),
    Buffer.alloc(256, 1).toString("base64url"),
  ].join(".");
  return { token, issuedAt, expiresAt };
}

test("live CLI parses exact version attestation and bounded retry options", () => {
  const defaults = parseArguments([]);
  assert.equal(defaults.workerName, "alchemy-jwt-proxy");
  const options = parseArguments([
    "--expected-kid",
    KID,
    "--expected-version",
    VERSION,
    "--app-proof-key-file",
    "/protected/app-proof.key",
    "--version-override",
    "--rpc-attempts",
    "5",
  ]);
  assert.equal(options.expectedKid, KID);
  assert.equal(options.expectedVersion, VERSION);
  assert.equal(options.appProofKeyFile, "/protected/app-proof.key");
  assert.equal(options.versionOverride, true);
  assert.equal(options.rpcAttempts, 5);
  assert.throws(
    () => parseArguments(["--rpc-attempts", "6"]),
    SafeValidationError,
  );
  assert.throws(
    () => parseArguments(["--expected-ttl", "43200"]),
    SafeValidationError,
  );
  assert.throws(
    () => parseArguments(["--app-proof-key-file", "relative.key"]),
    SafeValidationError,
  );
  assert.equal(
    parseArguments(["--worker-name", "validated-worker"]).workerName,
    "validated-worker",
  );
  for (const invalidWorkerName of [
    "-worker",
    "worker-",
    "worker_name",
    "Worker",
    `a${"b".repeat(63)}`,
  ]) {
    assert.throws(
      () => parseArguments(["--worker-name", invalidWorkerName]),
      SafeValidationError,
    );
  }
});

test("request proof matches the cross-language golden vector", () => {
  const key = Buffer.from(
    "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
    "base64url",
  );
  const body = Buffer.from(
    '{"timestamp":1784558400,"nonce":"AAECAwQFBgcICQoLDA0ODw"}',
    "utf8",
  );
  assert.equal(
    createRequestProof(body, key),
    "ctfhJTYThhT35Q05ptrHCn16ylcrBkNb5c5unj1u1Jk",
  );
  assert.deepEqual(
    createSignedBrokerRequest(key, {
      timestamp: 1_784_558_400,
      nonce: "AAECAwQFBgcICQoLDA0ODw",
    }),
    {
      body,
      proof: "ctfhJTYThhT35Q05ptrHCn16ylcrBkNb5c5unj1u1Jk",
    },
  );
});

test("network catalog reads are bounded and require a stable regular file", async () => {
  const directory = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-live-catalog-"),
    ),
  );
  temporaryDirectories.push(directory);

  const maximumBytes = 2 * 1_024 * 1_024;
  const validPath = join(directory, "valid-catalog.json");
  const validJSON = Buffer.from(
    JSON.stringify([{ alchemyNetwork: "eth-mainnet" }]),
    "utf8",
  );
  await writeFile(
    validPath,
    Buffer.concat([
      validJSON,
      Buffer.alloc(maximumBytes - validJSON.byteLength, 0x20),
    ]),
  );
  assert.deepEqual(
    await loadEvmTargets(validPath, 1),
    [{
      kind: "evm",
      host: "eth-mainnet.g.alchemy.com",
      url: "https://eth-mainnet.g.alchemy.com/v2",
    }],
  );

  const oversizedPath = join(directory, "oversized-catalog.json");
  await writeFile(oversizedPath, Buffer.alloc(maximumBytes + 1, 0x20));
  await assert.rejects(
    loadEvmTargets(oversizedPath, 1),
    /Network catalog could not be read safely/u,
  );
  await assert.rejects(
    loadEvmTargets(directory, 1),
    /Network catalog could not be read safely/u,
  );

  const rewrittenPath = join(directory, "rewritten-catalog.json");
  await writeFile(rewrittenPath, validJSON);
  await assert.rejects(
    readBoundedNetworkCatalog(rewrittenPath, {
      afterFirstRead: async () => {
        await writeFile(
          rewrittenPath,
          JSON.stringify([{ alchemyNetwork: "eth-sepolia" }]),
        );
      },
    }),
    /Network catalog could not be read safely/u,
  );

  const swappedPath = join(directory, "swapped-catalog.json");
  const replacementPath = join(directory, "replacement-catalog.json");
  await writeFile(swappedPath, validJSON);
  await writeFile(replacementPath, validJSON);
  await assert.rejects(
    readBoundedNetworkCatalog(swappedPath, {
      afterFirstRead: async () => {
        await rename(replacementPath, swappedPath);
      },
    }),
    /Network catalog could not be read safely/u,
  );
});

test("live proof-key loading uses strict raw bytes and pinned fingerprint", async () => {
  const directory = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-live-proof-key-"),
    ),
  );
  temporaryDirectories.push(directory);
  const path = join(directory, "app-proof.key");
  await writeFile(path, `${REQUEST_PROOF_KEY}\n`, { mode: 0o600 });
  const key = await readAppProofKey(path, {
    expectedFingerprint: REQUEST_PROOF_KEY_FINGERPRINT,
  });
  assert.deepEqual(key, Buffer.from(REQUEST_PROOF_KEY, "base64url"));
  key.fill(0);

  await writeFile(
    path,
    Buffer.concat([
      Buffer.from([0xef, 0xbb, 0xbf]),
      Buffer.from(REQUEST_PROOF_KEY, "ascii"),
    ]),
    { mode: 0o600 },
  );
  await assert.rejects(
    readAppProofKey(path, {
      expectedFingerprint: REQUEST_PROOF_KEY_FINGERPRINT,
    }),
    /could not be validated/u,
  );
});

test("dry-run validates and clears a supplied proof key", async () => {
  const directory = await realpath(
    await mkdtemp(
      join(tmpdir(), "alchemy-jwt-dry-run-proof-key-"),
    ),
  );
  temporaryDirectories.push(directory);
  const path = join(directory, "app-proof.key");
  await writeFile(path, REQUEST_PROOF_KEY, { mode: 0o600 });

  assert.equal(
    await validateOptionalDryRunProofKey(
      { appProofKeyFile: path },
      { expectedFingerprint: REQUEST_PROOF_KEY_FINGERPRINT },
    ),
    true,
  );
  assert.equal(
    await validateOptionalDryRunProofKey({}),
    false,
  );

  await assert.rejects(
    validateOptionalDryRunProofKey(
      { appProofKeyFile: join(directory, "missing.key") },
      { expectedFingerprint: REQUEST_PROOF_KEY_FINGERPRINT },
    ),
    /could not be validated/u,
  );
  await assert.rejects(
    validateOptionalDryRunProofKey(
      { appProofKeyFile: path },
      { expectedFingerprint: "0".repeat(64) },
    ),
    /could not be validated/u,
  );

  await writeFile(path, `${REQUEST_PROOF_KEY}=`, { mode: 0o600 });
  await assert.rejects(
    validateOptionalDryRunProofKey(
      { appProofKeyFile: path },
      { expectedFingerprint: REQUEST_PROOF_KEY_FINGERPRINT },
    ),
    /could not be validated/u,
  );

  const injectedKey = Buffer.alloc(32, 0xa5);
  assert.equal(
    await validateOptionalDryRunProofKey(
      { appProofKeyFile: "/protected/app-proof.key" },
      {
        readProofKey: async () => injectedKey,
      },
    ),
    true,
  );
  assert.deepEqual(injectedKey, Buffer.alloc(32));
});

test("unauthorized proof probes require the exact generic body", () => {
  assert.doesNotThrow(() =>
    assertGenericUnauthorizedBody(
      Buffer.from('{"error":"Unauthorized"}', "utf8"),
      "test probe",
    ),
  );
  for (const body of [
    '{"error":"Missing proof"}',
    '{"error":"Unauthorized"}\n',
    '{ "error": "Unauthorized" }',
    "",
  ]) {
    assert.throws(
      () => assertGenericUnauthorizedBody(
        Buffer.from(body, "utf8"),
        "test probe",
      ),
      SafeValidationError,
    );
  }
});

test("live contract sends signed stale, future, and malformed nonce probes", async () => {
  const key = Buffer.from(REQUEST_PROOF_KEY, "base64url");
  const nowSeconds = 1_800_000_000;
  const observed = [];
  const statuses = [405, 404, 401, 401, 401, 401, 401, 401, 401];
  const probeCount = await runBrokerContractProbes(
    new URL("https://api.lil.org/v1/alchemy/jwt"),
    {
      expectedVersion: VERSION,
      timeoutMs: 1_000,
      versionOverride: false,
      workerName: "alchemy-jwt-proxy",
    },
    key,
    {
      nowSeconds,
      fetchImplementation: async (url, init) => {
        const index = observed.length;
        const body = init.body === undefined
          ? Buffer.alloc(0)
          : Buffer.from(init.body);
        observed.push({ url: new URL(url), init, body });
        const status = statuses[index];
        const responseBody = status === 401
          ? '{"error":"Unauthorized"}'
          : "{}";
        return brokerResponse(
          status,
          responseBody,
          status === 405 ? { Allow: "POST" } : {},
        );
      },
    },
  );

  assert.equal(probeCount, 9);
  assert.equal(observed.length, 9);
  const [stale, future, malformedNonce] = observed.slice(6);
  for (const probe of [stale, future, malformedNonce]) {
    assert.equal(
      probe.init.headers["X-Lil-Alchemy-Proof"],
      createRequestProof(probe.body, key),
    );
  }
  const staleBody = JSON.parse(stale.body.toString("utf8"));
  assert.equal(staleBody.timestamp, nowSeconds - 600);
  assert.match(staleBody.nonce, /^[A-Za-z0-9_-]{22}$/u);
  assert.equal(Buffer.from(staleBody.nonce, "base64url").byteLength, 16);
  assert.equal(
    JSON.parse(future.body.toString("utf8")).timestamp,
    nowSeconds + 600,
  );
  assert.deepEqual(JSON.parse(malformedNonce.body.toString("utf8")), {
    timestamp: nowSeconds,
    nonce: "invalid",
  });
  key.fill(0);
});

test("release live verification delays and clears the proof key before RPC", async () => {
  const key = Buffer.alloc(32, 0xa5);
  const events = [];
  const result = await verifyReleaseLiveContract(
    {
      expectedKid: KID,
      expectedVersion: VERSION,
      appProofKeyFile: "/protected/app-proof.key",
    },
    {
      nowImplementation: () => 1_800_000_000_000,
      probeHttpRedirectImplementation: async () => {
        events.push("redirect");
      },
      waitForExpectedVersionImplementation: async () => {
        events.push("version");
        return 1;
      },
      readProofKey: async () => {
        events.push("read-key");
        return key;
      },
      runBrokerContractProbesImplementation: async () => {
        events.push("probes");
        assert.deepEqual(key, Buffer.alloc(32, 0xa5));
        return 9;
      },
      acquireTokenImplementation: async () => {
        events.push("issuance");
        assert.deepEqual(key, Buffer.alloc(32, 0xa5));
        return "secret-token";
      },
      validateRpcTargetImplementation: async (target, token) => {
        events.push("canary");
        assert.deepEqual(key, Buffer.alloc(32));
        assert.deepEqual(target, TARGET);
        assert.equal(token, "secret-token");
        return {
          host: target.host,
          status: 200,
          result: "ok",
          ok: true,
          retryable: false,
          attempts: 1,
          classification: "ok",
        };
      },
    },
  );
  assert.deepEqual(events, [
    "redirect",
    "version",
    "read-key",
    "probes",
    "issuance",
    "canary",
  ]);
  assert.equal(result.probeCount, 9);
  assert.deepEqual(key, Buffer.alloc(32));
});

test("broker URL is pinned to the exact production HTTPS origin and path", () => {
  assert.equal(
    parseBrokerURL("https://api.lil.org/v1/alchemy/jwt").href,
    "https://api.lil.org/v1/alchemy/jwt",
  );
  for (const url of [
    "http://api.lil.org/v1/alchemy/jwt",
    "https://other.lil.org/v1/alchemy/jwt",
    "https://api.lil.org:444/v1/alchemy/jwt",
    "https://user@api.lil.org/v1/alchemy/jwt",
    "https://api.lil.org/v1/alchemy/jwt?x=1",
    "https://api.lil.org/v1/alchemy/jwt?",
    "https://api.lil.org/v1/alchemy/jwt#",
    "https://api.lil.org:443/v1/alchemy/jwt",
    "HTTPS://api.lil.org/v1/alchemy/jwt",
    "https://API.LIL.ORG/v1/alchemy/jwt",
    " https://api.lil.org/v1/alchemy/jwt",
    "https://api.lil.org/v1/alchemy/../alchemy/jwt",
  ]) {
    assert.throws(() => parseBrokerURL(url), SafeValidationError);
  }
});

test("HTTP redirect probe requires path and query preservation", async () => {
  const brokerURL = new URL("https://api.lil.org/v1/alchemy/jwt");
  const observedURLs = [];
  await assert.doesNotReject(
    probeHttpRedirect(
      brokerURL,
      1_000,
      async (url) => {
        const requestURL = new URL(url);
        observedURLs.push(requestURL.href);
        requestURL.protocol = "https:";
        return new Response("", {
          status: 308,
          headers: { Location: requestURL.href },
        });
      },
    ),
  );
  assert.deepEqual(observedURLs, [
    "http://api.lil.org/v1/alchemy/jwt",
    "http://api.lil.org/v1/alchemy/jwt?alchemy-jwt-redirect-probe=1",
  ]);

  await assert.rejects(
    probeHttpRedirect(
      brokerURL,
      1_000,
      async (url) => {
        const requestURL = new URL(url);
        requestURL.protocol = "https:";
        requestURL.search = "";
        return new Response("", {
          status: 308,
          headers: { Location: requestURL.href },
        });
      },
    ),
    SafeValidationError,
  );
});

test("broker headers require exact HSTS and Worker version", () => {
  const response = new Response("{}", {
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "Strict-Transport-Security": "max-age=31536000",
      "X-Alchemy-JWT-Worker-Version": VERSION,
      "X-Content-Type-Options": "nosniff",
    },
  });
  assert.doesNotThrow(() =>
    assertBrokerHeaders(response, "test", VERSION),
  );
  assert.throws(
    () => assertBrokerHeaders(response, "test", VERSION.replace("d", "e")),
    SafeValidationError,
  );

  const capitalizedMediaType = new Response("{}", {
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "Application/JSON; Charset=UTF-8",
      "Strict-Transport-Security": "max-age=31536000",
      "X-Alchemy-JWT-Worker-Version": VERSION,
      "X-Content-Type-Options": "nosniff",
    },
  });
  assert.doesNotThrow(() =>
    assertBrokerHeaders(capitalizedMediaType, "test", VERSION),
  );
});

test("broker headers require the exact JSON response media type", () => {
  for (const contentType of [
    undefined,
    "application/json",
    "application/jsonp",
    "application/json-seq",
    "application/json; charset=utf-8; unexpected=true",
  ]) {
    const headers = new Headers({
      "Cache-Control": "no-store",
      "Strict-Transport-Security": "max-age=31536000",
      "X-Alchemy-JWT-Worker-Version": VERSION,
      "X-Content-Type-Options": "nosniff",
    });
    if (contentType !== undefined) {
      headers.set("Content-Type", contentType);
    }
    const response = new Response("{}", { headers });
    assert.throws(
      () => assertBrokerHeaders(response, "test", VERSION),
      SafeValidationError,
    );
  }
});

test("issuance validation requires the exact expected kid", () => {
  const payload = jwtPayload();
  assert.equal(
    validateIssuancePayload(payload, payload.issuedAt, KID),
    payload.token,
  );
  assert.throws(
    () =>
      validateIssuancePayload(
        payload,
        payload.issuedAt,
        "wrong-kid",
      ),
    SafeValidationError,
  );
  const shortPayload = jwtPayload(KID, 43_200);
  assert.throws(
    () =>
      validateIssuancePayload(
        shortPayload,
        shortPayload.issuedAt,
        KID,
      ),
    SafeValidationError,
  );
});

test("RPC retries only transient failures and then succeeds", async () => {
  const responses = [
    new Response("", { status: 503 }),
    new Response("", { status: 429 }),
    rpcResponse(),
  ];
  const sleeps = [];
  let calls = 0;
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 5,
    fetchImplementation: async () => {
      calls += 1;
      return responses.shift();
    },
    sleepImplementation: async (milliseconds) => sleeps.push(milliseconds),
    randomImplementation: () => 0.5,
  });

  assert.equal(result.ok, true);
  assert.equal(result.attempts, 3);
  assert.equal(calls, 3);
  assert.equal(sleeps.length, 2);
  assert.ok(sleeps[0] >= 250 && sleeps[0] <= 500);
  assert.ok(sleeps[1] >= 500 && sleeps[1] <= 1_000);
});

test("RPC classifies 4xx before canceling its unreadable body", async () => {
  let calls = 0;
  let cancellations = 0;
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 5,
    fetchImplementation: async () => {
      calls += 1;
      if (calls > 1) {
        return rpcResponse();
      }
      return nonSuccessResponseWithUnreadableBody(
        401,
        () => {
          cancellations += 1;
        },
      );
    },
    sleepImplementation: async () => {
      throw new Error("authentication failures must not retry");
    },
  });

  assert.equal(result.result, "auth-rejected");
  assert.equal(result.classification, "deterministic");
  assert.equal(calls, 1);
  assert.equal(cancellations, 1);
});

test("RPC classifies 5xx before canceling its unreadable body", async () => {
  let calls = 0;
  let cancellations = 0;
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 2,
    fetchImplementation: async () => {
      calls += 1;
      if (calls === 1) {
        return nonSuccessResponseWithUnreadableBody(
          503,
          () => {
            cancellations += 1;
          },
        );
      }
      return rpcResponse();
    },
    sleepImplementation: async () => undefined,
    randomImplementation: () => 0,
  });

  assert.equal(result.ok, true);
  assert.equal(result.attempts, 2);
  assert.equal(calls, 2);
  assert.equal(cancellations, 1);
});

test("RPC honors Retry-After without exceeding the retry cap", async () => {
  const responses = [
    new Response("", {
      status: 429,
      headers: { "Retry-After": "20" },
    }),
    rpcResponse(),
  ];
  const sleeps = [];
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 2,
    fetchImplementation: async () => responses.shift(),
    sleepImplementation: async (milliseconds) => sleeps.push(milliseconds),
    randomImplementation: () => 0,
  });

  assert.equal(result.ok, true);
  assert.deepEqual(sleeps, [4_000]);
});

test("RPC never retries auth, malformed, or oversized responses", async () => {
  const cases = [
    () => new Response("", { status: 401 }),
    () => new Response("{", { status: 200 }),
    () => new Response("x".repeat(128 * 1_024 + 1), { status: 200 }),
  ];
  for (const responseFactory of cases) {
    let calls = 0;
    const result = await validateRpcTarget(TARGET, "secret-token", {
      timeoutMs: 1_000,
      rpcAttempts: 5,
      fetchImplementation: async () => {
        calls += 1;
        return responseFactory();
      },
      sleepImplementation: async () => {
        throw new Error("deterministic failure must not sleep");
      },
    });
    assert.equal(result.classification, "deterministic");
    assert.equal(calls, 1);
  }
});

test("RPC observes redirects and rejects them without retrying", async () => {
  let calls = 0;
  let observedRedirect;
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 5,
    fetchImplementation: async (_url, init) => {
      calls += 1;
      observedRedirect = init.redirect;
      return new Response("", {
        status: 302,
        headers: {
          Location: "https://attacker.example/",
        },
      });
    },
    sleepImplementation: async () => {
      throw new Error("redirects must not retry");
    },
  });

  assert.equal(observedRedirect, "manual");
  assert.equal(result.status, 302);
  assert.equal(result.result, "http-error");
  assert.equal(result.classification, "deterministic");
  assert.equal(calls, 1);
});

test("RPC rejects an invalid Solana getVersion result without retrying", async () => {
  let calls = 0;
  const result = await validateRpcTarget(
    {
      kind: "solana",
      host: "solana-mainnet.g.alchemy.com",
      url: "https://solana-mainnet.g.alchemy.com/v2",
    },
    "secret-token",
    {
      timeoutMs: 1_000,
      rpcAttempts: 5,
      fetchImplementation: async () => {
        calls += 1;
        return new Response(
          JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            result: { "solana-core": "", "feature-set": -1 },
          }),
          { status: 200 },
        );
      },
      sleepImplementation: async () => {
        throw new Error("invalid result must not retry");
      },
    },
  );
  assert.equal(result.result, "invalid-version");
  assert.equal(result.classification, "deterministic");
  assert.equal(calls, 1);
});

test("RPC classifies exhausted transient attempts separately", async () => {
  let calls = 0;
  const result = await validateRpcTarget(TARGET, "secret-token", {
    timeoutMs: 1_000,
    rpcAttempts: 3,
    fetchImplementation: async () => {
      calls += 1;
      throw new Error("temporary network failure");
    },
    sleepImplementation: async () => undefined,
  });
  assert.equal(result.classification, "transient-exhausted");
  assert.equal(result.attempts, 3);
  assert.equal(calls, 3);
});

test("failed eth-mainnet canary stops the RPC matrix", async () => {
  const targets = [
    TARGET,
    {
      kind: "evm",
      host: "eth-sepolia.g.alchemy.com",
      url: "https://eth-sepolia.g.alchemy.com/v2",
    },
  ];
  const called = [];
  const output = [];
  const validation = await validateRpcMatrix(
    targets,
    "secret-token",
    { timeoutMs: 1_000, rpcAttempts: 3, concurrency: 2 },
    (result) => output.push(result.host),
    async (target) => {
      called.push(target.host);
      return {
        host: target.host,
        status: 401,
        result: "auth-rejected",
        ok: false,
        retryable: false,
        attempts: 1,
        classification: "deterministic",
      };
    },
  );
  assert.deepEqual(called, ["eth-mainnet.g.alchemy.com"]);
  assert.deepEqual(output, ["eth-mainnet.g.alchemy.com"]);
  assert.equal(validation.stoppedAfterCanary, true);
  assert.equal(validation.results.length, 1);
});
