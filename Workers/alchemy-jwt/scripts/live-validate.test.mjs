import assert from "node:assert/strict";
import { test } from "node:test";

import {
  SafeValidationError,
  assertBrokerHeaders,
  parseArguments,
  parseBrokerURL,
  probeHttpRedirect,
  validateIssuancePayload,
  validateRpcMatrix,
  validateRpcTarget,
} from "./live-validate.mjs";

const VERSION = "db7cd8d3-4425-4fe7-8c81-01bf963b6067";
const KID = "expected-test-kid";
const TARGET = {
  kind: "evm",
  host: "eth-mainnet.g.alchemy.com",
  url: "https://eth-mainnet.g.alchemy.com/v2",
};

function rpcResponse(result = "0x1") {
  return new Response(
    JSON.stringify({ jsonrpc: "2.0", id: 1, result }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
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

function jwtPayload(kid = KID, ttlSeconds = 86_400) {
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
  assert.equal(defaults.workerName, "big-wallet-alchemy-jwt");
  const options = parseArguments([
    "--expected-kid",
    KID,
    "--expected-version",
    VERSION,
    "--version-override",
    "--rpc-attempts",
    "5",
  ]);
  assert.equal(options.expectedKid, KID);
  assert.equal(options.expectedVersion, VERSION);
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
