import { SELF } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  handleRequest,
  type AlchemyJWTIssuerEnvironment,
} from "../src/handler";

const ENDPOINT = "https://api.lil.org/v1/alchemy/jwt";
const INSTALLATION_ID = "8e3100fc-1879-4b35-ae97-419d3511a289";
const SECOND_INSTALLATION_ID = "8e3100fc-1879-4b35-ae97-419d3511a288";
const TEST_KEY_ID = "alchemy-test-key-id";
const TEST_WORKER_VERSION = "6ac1816b-1a72-4715-9d96-08f8f85467bb";
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const FIXED_TIME_MILLISECONDS = 1_800_000_000_123;
const FIXED_ISSUED_AT = 1_800_000_000;

type SigningFixture = {
  privateKeyPem: string;
  publicKey: CryptoKey;
};

type TestEnvironmentOptions = {
  privateKeyPem?: string;
  keyId?: string;
  ttlSeconds?: string;
  rateLimitSuccess?: boolean;
  rateLimitError?: boolean;
  workerVersion?: string;
};

let signingFixture: SigningFixture;
let rsa3072SigningFixture: SigningFixture;
let rsa2048Exponent3SigningFixture: SigningFixture;

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function pemEncodePkcs8(bytes: Uint8Array): string {
  const encoded = bytesToBase64(bytes);
  const lines: string[] = [];
  for (let offset = 0; offset < encoded.length; offset += 64) {
    lines.push(encoded.slice(offset, offset + 64));
  }
  return [
    "-----BEGIN PRIVATE KEY-----",
    ...lines,
    "-----END PRIVATE KEY-----",
  ].join("\n");
}

async function createSigningFixture(
  modulusLength = 2_048,
  publicExponent = new Uint8Array([1, 0, 1]),
): Promise<SigningFixture> {
  const generated = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength,
      publicExponent,
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  if (!("privateKey" in generated)) {
    throw new Error("test key generation returned a symmetric key");
  }

  const pkcs8 = await crypto.subtle.exportKey("pkcs8", generated.privateKey);
  if (!(pkcs8 instanceof ArrayBuffer)) {
    throw new Error("test private key export was not binary");
  }
  return {
    privateKeyPem: pemEncodePkcs8(new Uint8Array(pkcs8)),
    publicKey: generated.publicKey,
  };
}

function createTestEnvironment(
  options: TestEnvironmentOptions = {},
): {
  env: AlchemyJWTIssuerEnvironment;
  limit: ReturnType<typeof vi.fn>;
} {
  const limit = vi.fn(
    async (rateLimitOptions: RateLimitOptions): Promise<RateLimitOutcome> => {
      void rateLimitOptions;
      if (options.rateLimitError === true) {
        throw new Error("test rate limiter failure");
      }
      return { success: options.rateLimitSuccess ?? true };
    },
  );

  const env: AlchemyJWTIssuerEnvironment = {
    JWT_ISSUANCE_RATE_LIMITER: { limit },
    ALCHEMY_KEY_ID: options.keyId ?? TEST_KEY_ID,
    JWT_TTL_SECONDS: options.ttlSeconds ?? "86400",
    ALCHEMY_JWT_PRIVATE_KEY:
      options.privateKeyPem ?? signingFixture.privateKeyPem,
    CF_VERSION_METADATA: {
      id: options.workerVersion ?? TEST_WORKER_VERSION,
      tag: "test",
      timestamp: "2027-01-15T08:00:00.000Z",
    },
  };

  return { env, limit };
}

function post(
  body: BodyInit | null,
  headers: HeadersInit = { "Content-Type": "application/json" },
  url = ENDPOINT,
): Request {
  return new Request(url, {
    method: "POST",
    headers,
    body,
  });
}

async function responseObject(
  response: Response,
): Promise<Record<string, unknown>> {
  const value: unknown = await response.json();
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("expected an object response");
  }
  return value as Record<string, unknown>;
}

function assertPrivateResponseHeaders(
  response: Response,
  expectedVersion: string | RegExp = TEST_WORKER_VERSION,
): void {
  expect(response.headers.get("Cache-Control")).toBe("no-store");
  expect(response.headers.get("Content-Type")).toBe(
    "application/json; charset=utf-8",
  );
  expect(response.headers.get("Strict-Transport-Security")).toBe(
    "max-age=31536000",
  );
  expect(response.headers.get("X-Content-Type-Options")).toBe("nosniff");
  const workerVersion = response.headers.get(
    "X-Alchemy-JWT-Worker-Version",
  );
  if (typeof expectedVersion === "string") {
    expect(workerVersion).toBe(expectedVersion);
  } else {
    expect(workerVersion).toMatch(expectedVersion);
  }
  expect(response.headers.has("Access-Control-Allow-Origin")).toBe(false);
  expect(response.headers.has("Access-Control-Allow-Headers")).toBe(false);
  expect(response.headers.has("Access-Control-Allow-Methods")).toBe(false);
}

function jwtSegments(token: string): [string, string, string] {
  const segments = token.split(".");
  if (segments.length !== 3) {
    throw new Error("expected three JWT segments");
  }
  const [header, payload, signature] = segments;
  if (
    header === undefined ||
    payload === undefined ||
    signature === undefined
  ) {
    throw new Error("missing JWT segment");
  }
  return [header, payload, signature];
}

function decodeBase64Url(segment: string): Uint8Array {
  const normalized = segment.replaceAll("-", "+").replaceAll("_", "/");
  const paddingLength = (4 - (normalized.length % 4)) % 4;
  const binary = atob(normalized + "=".repeat(paddingLength));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function decodeJsonSegment(segment: string): unknown {
  return JSON.parse(new TextDecoder().decode(decodeBase64Url(segment)));
}

beforeAll(async () => {
  [
    signingFixture,
    rsa3072SigningFixture,
    rsa2048Exponent3SigningFixture,
  ] = await Promise.all([
    createSigningFixture(),
    createSigningFixture(3_072),
    createSigningFixture(2_048, new Uint8Array([3])),
  ]);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("production entry point", () => {
  it("dispatches the configured main module to the issuer handler", async () => {
    const response = await SELF.fetch(ENDPOINT, { method: "GET" });

    expect(response.status).toBe(405);
    expect(response.headers.get("Allow")).toBe("POST");
    assertPrivateResponseHeaders(response, CANONICAL_UUID);
    expect(await responseObject(response)).toEqual({
      error: "Method not allowed",
    });
  });
});

describe("JWT issuance", () => {
  it("returns a verifiable RS256 JWT with only the required header and claims", async () => {
    const { env, limit } = createTestEnvironment();
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);

    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );

    expect(response.status).toBe(200);
    assertPrivateResponseHeaders(response);
    const body = await responseObject(response);
    expect(Object.keys(body).sort()).toEqual([
      "expiresAt",
      "issuedAt",
      "token",
    ]);
    expect(body.issuedAt).toBe(FIXED_ISSUED_AT);
    expect(body.expiresAt).toBe(FIXED_ISSUED_AT + 86_400);
    expect(typeof body.token).toBe("string");
    if (typeof body.token !== "string") {
      throw new Error("expected a token");
    }

    const [encodedHeader, encodedPayload, encodedSignature] = jwtSegments(
      body.token,
    );
    expect(encodedHeader).not.toContain("=");
    expect(encodedPayload).not.toContain("=");
    expect(encodedSignature).not.toContain("=");
    expect(decodeJsonSegment(encodedHeader)).toEqual({
      alg: "RS256",
      typ: "JWT",
      kid: TEST_KEY_ID,
    });
    expect(decodeJsonSegment(encodedPayload)).toEqual({
      iat: FIXED_ISSUED_AT,
      exp: FIXED_ISSUED_AT + 86_400,
    });

    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      signingFixture.publicKey,
      decodeBase64Url(encodedSignature),
      new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
    );
    expect(verified).toBe(true);
    expect(limit).toHaveBeenCalledOnce();
    expect(limit).toHaveBeenCalledWith({ key: INSTALLATION_ID });
    expect(log).not.toHaveBeenCalled();
    expect(errorLog).not.toHaveBeenCalled();
  });

  it.each(["21600", "43200", "86400 ", "086400"])(
    "rejects non-exact 24-hour TTL configuration %s",
    async (ttl) => {
      vi.spyOn(console, "error").mockImplementation(() => undefined);
      const { env, limit } = createTestEnvironment({ ttlSeconds: ttl });
      const response = await handleRequest(
        post(JSON.stringify({ installationId: INSTALLATION_ID })),
        env,
        () => FIXED_TIME_MILLISECONDS,
      );

      expect(response.status).toBe(500);
      assertPrivateResponseHeaders(response);
      expect(await responseObject(response)).toEqual({
        error: "Service unavailable",
      });
      expect(limit).toHaveBeenCalledOnce();
    },
  );

  it("coalesces signing-key import while signing every JWT freshly", async () => {
    const fixture = await createSigningFixture();
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const { env } = createTestEnvironment({
      privateKeyPem: fixture.privateKeyPem,
    });

    const [firstResponse, secondResponse] = await Promise.all([
      handleRequest(
        post(JSON.stringify({ installationId: INSTALLATION_ID })),
        env,
        () => FIXED_TIME_MILLISECONDS,
      ),
      handleRequest(
        post(JSON.stringify({ installationId: SECOND_INSTALLATION_ID })),
        env,
        () => FIXED_TIME_MILLISECONDS + 1_000,
      ),
    ]);

    expect(firstResponse.status).toBe(200);
    expect(secondResponse.status).toBe(200);
    const firstBody = await responseObject(firstResponse);
    const secondBody = await responseObject(secondResponse);
    expect(firstBody.token).not.toBe(secondBody.token);
    expect(firstBody.issuedAt).not.toBe(secondBody.issuedAt);
    expect(importKey).toHaveBeenCalledOnce();

    const thirdResponse = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
      () => FIXED_TIME_MILLISECONDS + 2_000,
    );
    expect(thirdResponse.status).toBe(200);
    expect(importKey).toHaveBeenCalledOnce();
  });

  it("replaces the signing-key cache when the exact PEM changes", async () => {
    const [firstFixture, secondFixture] = await Promise.all([
      createSigningFixture(),
      createSigningFixture(),
    ]);
    const importKey = vi.spyOn(crypto.subtle, "importKey");

    const first = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      createTestEnvironment({
        privateKeyPem: firstFixture.privateKeyPem,
      }).env,
    );
    const second = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      createTestEnvironment({
        privateKeyPem: secondFixture.privateKeyPem,
      }).env,
    );

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(importKey).toHaveBeenCalledTimes(2);
  });

  it("caches deterministic rejection for the current invalid PEM", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const invalidFixture = await createSigningFixture(3_072);
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const { env } = createTestEnvironment({
      privateKeyPem: invalidFixture.privateKeyPem,
    });

    const first = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );
    const second = await handleRequest(
      post(JSON.stringify({ installationId: SECOND_INSTALLATION_ID })),
      env,
    );

    expect(first.status).toBe(500);
    expect(second.status).toBe(500);
    expect(importKey).toHaveBeenCalledOnce();
  });

  it("does not inspect the signing key until rate limiting succeeds", async () => {
    const fixture = await createSigningFixture();
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const throttled = createTestEnvironment({
      privateKeyPem: fixture.privateKeyPem,
      rateLimitSuccess: false,
    });

    const throttledResponse = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      throttled.env,
    );
    expect(throttledResponse.status).toBe(429);
    expect(importKey).not.toHaveBeenCalled();

    const successfulResponse = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      createTestEnvironment({ privateKeyPem: fixture.privateKeyPem }).env,
    );
    expect(successfulResponse.status).toBe(200);
    expect(importKey).toHaveBeenCalledOnce();
  });
});

describe("routing and response policy", () => {
  it.each(["GET", "PUT", "PATCH", "DELETE", "OPTIONS"])(
    "rejects %s on the issuance path",
    async (method) => {
      const { env, limit } = createTestEnvironment();
      const response = await handleRequest(
        new Request(ENDPOINT, { method }),
        env,
      );

      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("POST");
      assertPrivateResponseHeaders(response);
      expect(limit).not.toHaveBeenCalled();
    },
  );

  it.each([
    "https://api.lil.org/",
    "https://api.lil.org/v1/alchemy/jwt/",
    "https://api.lil.org/v1/alchemy/jwt?unexpected=true",
    "https://api.lil.org/v1/alchemy/jwt?",
    "https://api.lil.org/v1/alchemy/other",
    "https://other.lil.org/v1/alchemy/jwt",
    "https://api.lil.org:444/v1/alchemy/jwt",
    "https://user@api.lil.org/v1/alchemy/jwt",
  ])("returns 404 for non-exact route %s", async (url) => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID }), undefined, url),
      env,
    );

    expect(response.status).toBe(404);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it("rejects direct cleartext Worker requests before request processing", async () => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post(
        JSON.stringify({ installationId: INSTALLATION_ID }),
        undefined,
        "http://api.lil.org/v1/alchemy/jwt",
      ),
      env,
    );

    expect(response.status).toBe(400);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "HTTPS required",
    });
    expect(limit).not.toHaveBeenCalled();
  });

  it("accepts JSON with a UTF-8 media type parameter", async () => {
    const { env } = createTestEnvironment();
    const response = await handleRequest(
      post(
        JSON.stringify({ installationId: INSTALLATION_ID }),
        { "Content-Type": "application/json; charset=UTF-8" },
      ),
      env,
    );

    expect(response.status).toBe(200);
    assertPrivateResponseHeaders(response);
  });
});

describe("input validation", () => {
  it.each([
    ["missing content type", null, {}],
    [
      "wrong content type",
      JSON.stringify({ installationId: INSTALLATION_ID }),
      { "Content-Type": "text/plain" },
    ],
  ])("returns 415 for %s", async (_name, body, headers) => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(post(body, headers), env);

    expect(response.status).toBe(415);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it.each([
    ["empty body", ""],
    ["malformed JSON", "{"],
    ["JSON null", "null"],
    ["JSON array", "[]"],
    ["missing installation ID", "{}"],
    [
      "extra property",
      JSON.stringify({
        installationId: INSTALLATION_ID,
        unexpected: true,
      }),
    ],
    [
      "uppercase UUID",
      JSON.stringify({ installationId: INSTALLATION_ID.toUpperCase() }),
    ],
    [
      "UUID without hyphens",
      JSON.stringify({ installationId: INSTALLATION_ID.replaceAll("-", "") }),
    ],
    [
      "non-string UUID",
      JSON.stringify({ installationId: 123 }),
    ],
  ])("returns 400 for %s", async (_name, body) => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(post(body), env);

    expect(response.status).toBe(400);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Invalid request",
    });
    expect(limit).not.toHaveBeenCalled();
  });

  it("rejects invalid UTF-8", async () => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post(new Uint8Array([0xff])),
      env,
    );

    expect(response.status).toBe(400);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it("rejects an invalid Content-Length", async () => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post("{}", {
        "Content-Type": "application/json",
        "Content-Length": "invalid",
      }),
      env,
    );

    expect(response.status).toBe(400);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it("rejects a declared body larger than 1 KiB without reading it", async () => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post("{}", {
        "Content-Type": "application/json",
        "Content-Length": "1025",
      }),
      env,
    );

    expect(response.status).toBe(413);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it("stops reading an undeclared body once it exceeds 1 KiB", async () => {
    const { env, limit } = createTestEnvironment();
    const response = await handleRequest(
      post(
        JSON.stringify({
          installationId: INSTALLATION_ID,
          padding: "x".repeat(1_024),
        }),
      ),
      env,
    );

    expect(response.status).toBe(413);
    assertPrivateResponseHeaders(response);
    expect(limit).not.toHaveBeenCalled();
  });

  it("returns a redacted 400 when the request body stream fails", async () => {
    const sentinel = "request-body-stream-secret";
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env, limit } = createTestEnvironment();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(
          new TextEncoder().encode('{"installationId":"'),
        );
        controller.error(new Error(sentinel));
      },
    });

    const response = await handleRequest(post(stream), env);

    expect(response.status).toBe(400);
    assertPrivateResponseHeaders(response);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Invalid request"}');
    expect(responseText).not.toContain(sentinel);
    expect(limit).not.toHaveBeenCalled();
    expect(errorLog).not.toHaveBeenCalled();
  });
});

describe("throttling and failures", () => {
  it.each([
    ["missing", undefined],
    ["malformed", "not-a-version-id"],
    ["uppercase", TEST_WORKER_VERSION.toUpperCase()],
  ])("fails closed for %s version metadata", async (_name, version) => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env, limit } = createTestEnvironment({
      workerVersion: version ?? TEST_WORKER_VERSION,
    });
    if (version === undefined) {
      expect(Reflect.deleteProperty(env, "CF_VERSION_METADATA")).toBe(true);
    }

    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );

    expect(response.status).toBe(500);
    expect(response.headers.get("Strict-Transport-Security")).toBe(
      "max-age=31536000",
    );
    expect(response.headers.has("X-Alchemy-JWT-Worker-Version")).toBe(false);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    expect(limit).not.toHaveBeenCalled();
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "configuration",
      }),
    );
  });

  it("returns 429 with Retry-After when the installation is throttled", async () => {
    const { env, limit } = createTestEnvironment({
      privateKeyPem: "not a private key",
      rateLimitSuccess: false,
    });
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );

    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("60");
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Too many requests",
    });
    expect(limit).toHaveBeenCalledOnce();
    expect(limit).toHaveBeenCalledWith({ key: INSTALLATION_ID });
  });

  it("fails closed if the rate-limit binding throws", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env } = createTestEnvironment({ rateLimitError: true });
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "rate-limit",
      }),
    );
  });

  it.each([
    ["empty private key", ""],
    ["malformed private key", "super-secret-private-key-material"],
    [
      "PKCS1 private key",
      "-----BEGIN RSA PRIVATE KEY-----\nYWJj\n-----END RSA PRIVATE KEY-----",
    ],
  ])("returns a redacted 500 for %s", async (_name, privateKeyPem) => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env } = createTestEnvironment({ privateKeyPem });
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID }), {
        "Content-Type": "application/json",
        Authorization: "Bearer incoming-secret",
      }),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Service unavailable"}');
    if (privateKeyPem !== "") {
      expect(responseText).not.toContain(privateKeyPem);
    }
    expect(responseText).not.toContain(TEST_KEY_ID);
    expect(responseText).not.toContain("incoming-secret");

    const logs = errorLog.mock.calls.flat().join(" ");
    if (privateKeyPem !== "") {
      expect(logs).not.toContain(privateKeyPem);
    }
    expect(logs).not.toContain(TEST_KEY_ID);
    expect(logs).not.toContain("incoming-secret");
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
  });

  it("returns a redacted 500 for an RSA-3072 private key", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env, limit } = createTestEnvironment({
      privateKeyPem: rsa3072SigningFixture.privateKeyPem,
    });
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID }), {
        "Content-Type": "application/json",
        Authorization: "Bearer incoming-secret",
      }),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Service unavailable"}');
    expect(responseText).not.toContain(rsa3072SigningFixture.privateKeyPem);
    expect(responseText).not.toContain(TEST_KEY_ID);
    expect(responseText).not.toContain("incoming-secret");

    const logs = errorLog.mock.calls.flat().join(" ");
    expect(logs).not.toContain(rsa3072SigningFixture.privateKeyPem);
    expect(logs).not.toContain(TEST_KEY_ID);
    expect(logs).not.toContain("incoming-secret");
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
    expect(limit).toHaveBeenCalledOnce();
    expect(limit).toHaveBeenCalledWith({ key: INSTALLATION_ID });
  });

  it("returns a redacted 500 for an RSA-2048 exponent-3 private key", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env, limit } = createTestEnvironment({
      privateKeyPem: rsa2048Exponent3SigningFixture.privateKeyPem,
    });
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID }), {
        "Content-Type": "application/json",
        Authorization: "Bearer incoming-secret",
      }),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Service unavailable"}');
    expect(responseText).not.toContain(
      rsa2048Exponent3SigningFixture.privateKeyPem,
    );
    expect(responseText).not.toContain(TEST_KEY_ID);
    expect(responseText).not.toContain("incoming-secret");

    const logs = errorLog.mock.calls.flat().join(" ");
    expect(logs).not.toContain(
      rsa2048Exponent3SigningFixture.privateKeyPem,
    );
    expect(logs).not.toContain(TEST_KEY_ID);
    expect(logs).not.toContain("incoming-secret");
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
    expect(limit).toHaveBeenCalledOnce();
    expect(limit).toHaveBeenCalledWith({ key: INSTALLATION_ID });
  });

  it("returns a redacted 500 when the private-key binding is absent", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env } = createTestEnvironment();
    expect(Reflect.deleteProperty(env, "ALCHEMY_JWT_PRIVATE_KEY")).toBe(true);

    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
  });

  it("returns a redacted 500 when the key-ID binding is absent", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const { env } = createTestEnvironment();
    expect(Reflect.deleteProperty(env, "ALCHEMY_KEY_ID")).toBe(true);

    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID }), {
        "Content-Type": "application/json",
        Authorization: "Bearer incoming-secret",
      }),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Service unavailable"}');
    expect(responseText).not.toContain(signingFixture.privateKeyPem);
    expect(responseText).not.toContain(TEST_KEY_ID);
    expect(responseText).not.toContain("incoming-secret");
    expect(responseText).not.toContain("undefined");

    const logs = errorLog.mock.calls.flat().join(" ");
    expect(logs).not.toContain(signingFixture.privateKeyPem);
    expect(logs).not.toContain(TEST_KEY_ID);
    expect(logs).not.toContain("incoming-secret");
    expect(logs).not.toContain("undefined");
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
  });

  it.each([
    ["placeholder key ID", { keyId: "pending-alchemy-key-id" }],
    ["invalid key ID", { keyId: "contains whitespace" }],
    ["unsupported TTL", { ttlSeconds: "90000" }],
    ["non-numeric TTL", { ttlSeconds: "not-a-number" }],
  ])("fails safely for %s", async (_name, options) => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const { env } = createTestEnvironment(options);
    const response = await handleRequest(
      post(JSON.stringify({ installationId: INSTALLATION_ID })),
      env,
    );

    expect(response.status).toBe(500);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
  });
});
