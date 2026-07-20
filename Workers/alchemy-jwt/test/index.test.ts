import { SELF } from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  handleRequest,
  type AlchemyJWTIssuerEnvironment,
} from "../src/handler";

const ENDPOINT = "https://api.lil.org/v1/alchemy/jwt";
const PROOF_HEADER = "X-Lil-Alchemy-Proof";
const PROOF_PREFIX =
  "LIL-ALCHEMY-JWT-PROOF-V1\n"
  + "POST\n"
  + "https://api.lil.org/v1/alchemy/jwt\n";
const TEST_KEY_ID = "alchemy-test-key-id";
const TEST_WORKER_VERSION = "6ac1816b-1a72-4715-9d96-08f8f85467bb";
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const FIXED_TIME_MILLISECONDS = 1_784_558_400_123;
const FIXED_ISSUED_AT = 1_784_558_400;
const GOLDEN_PROOF_KEY =
  "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const GOLDEN_NONCE = "AAECAwQFBgcICQoLDA0ODw";
const GOLDEN_BODY =
  '{"timestamp":1784558400,"nonce":"AAECAwQFBgcICQoLDA0ODw"}';
const GOLDEN_PROOF =
  "ctfhJTYThhT35Q05ptrHCn16ylcrBkNb5c5unj1u1Jk";

type SigningFixture = {
  privateKeyPem: string;
  publicKey: CryptoKey;
};

type TestEnvironmentOptions = {
  privateKeyPem?: string;
  keyId?: string;
  proofKey?: string;
  ttlSeconds?: string;
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

function base64UrlEncode(bytes: Uint8Array): string {
  return bytesToBase64(bytes)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
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
): AlchemyJWTIssuerEnvironment {
  return {
    ALCHEMY_KEY_ID: options.keyId ?? TEST_KEY_ID,
    JWT_TTL_SECONDS: options.ttlSeconds ?? "21600",
    ALCHEMY_JWT_PRIVATE_KEY:
      options.privateKeyPem ?? signingFixture.privateKeyPem,
    ALCHEMY_JWT_REQUEST_PROOF_KEY:
      options.proofKey ?? GOLDEN_PROOF_KEY,
    CF_VERSION_METADATA: {
      id: options.workerVersion ?? TEST_WORKER_VERSION,
      tag: "test",
      timestamp: "2027-01-15T08:00:00.000Z",
    },
  };
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

function proofBody(
  timestamp = FIXED_ISSUED_AT,
  nonce = GOLDEN_NONCE,
): string {
  return JSON.stringify({ timestamp, nonce });
}

async function proofFor(
  body: Uint8Array,
  encodedKey = GOLDEN_PROOF_KEY,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    decodeBase64Url(encodedKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const prefix = new TextEncoder().encode(PROOF_PREFIX);
  const input = new Uint8Array(prefix.byteLength + body.byteLength);
  input.set(prefix);
  input.set(body, prefix.byteLength);
  const proof = await crypto.subtle.sign("HMAC", key, input);
  return base64UrlEncode(new Uint8Array(proof));
}

async function signedPost(
  bodyText = GOLDEN_BODY,
  {
    encodedKey = GOLDEN_PROOF_KEY,
    proof,
    contentType = "application/json",
    url = ENDPOINT,
  }: {
    encodedKey?: string;
    proof?: string;
    contentType?: string;
    url?: string;
  } = {},
): Promise<Request> {
  const body = new TextEncoder().encode(bodyText);
  return post(
    body,
    {
      "Content-Type": contentType,
      [PROOF_HEADER]: proof ?? await proofFor(body, encodedKey),
    },
    url,
  );
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

describe("state-free request proof", () => {
  it("freezes the cross-language HMAC golden vector", async () => {
    expect(
      await proofFor(new TextEncoder().encode(GOLDEN_BODY)),
    ).toBe(GOLDEN_PROOF);

    const response = await handleRequest(
      post(GOLDEN_BODY, {
        "Content-Type": "application/json",
        [PROOF_HEADER]: GOLDEN_PROOF,
      }),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(200);
  });

  it("signs the exact raw body bytes after the fixed prefix", async () => {
    const body = `${GOLDEN_BODY}\n`;
    const correctProof = await proofFor(new TextEncoder().encode(body));
    const alteredProof = await proofFor(
      new TextEncoder().encode(GOLDEN_BODY),
    );
    const env = createTestEnvironment();

    const accepted = await handleRequest(
      post(body, {
        "Content-Type": "application/json",
        [PROOF_HEADER]: correctProof,
      }),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );
    const rejected = await handleRequest(
      post(body, {
        "Content-Type": "application/json",
        [PROOF_HEADER]: alteredProof,
      }),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );

    expect(accepted.status).toBe(200);
    expect(rejected.status).toBe(401);
  });

  it.each([
    ["missing proof", undefined],
    ["empty proof", ""],
    ["malformed proof", "not-base64url"],
    ["padded proof", `${GOLDEN_PROOF}=`],
    ["wrong proof", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
  ])("returns the same generic 401 for %s", async (_name, proof) => {
    const headers: Record<string, string> = {
      "Content-Type": "application/json",
    };
    if (proof !== undefined) {
      headers[PROOF_HEADER] = proof;
    }
    const response = await handleRequest(
      post(GOLDEN_BODY, headers),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );

    expect(response.status).toBe(401);
    assertPrivateResponseHeaders(response);
    expect(await responseObject(response)).toEqual({
      error: "Unauthorized",
    });
  });

  it.each([
    ["lower boundary", FIXED_ISSUED_AT - 300, 200],
    ["upper boundary", FIXED_ISSUED_AT + 300, 200],
    ["too old", FIXED_ISSUED_AT - 301, 401],
    ["too far in the future", FIXED_ISSUED_AT + 301, 401],
  ])("enforces the ±300-second window at the %s", async (
    _name,
    timestamp,
    expectedStatus,
  ) => {
    const body = proofBody(timestamp);
    const response = await handleRequest(
      await signedPost(body),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(expectedStatus);
  });

  it("accepts an exact replay while it remains inside the window", async () => {
    const env = createTestEnvironment();
    const first = await handleRequest(
      await signedPost(),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );
    const second = await handleRequest(
      await signedPost(),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
  });

  it("coalesces request-proof key import for concurrent requests", async () => {
    const proofKey = base64UrlEncode(new Uint8Array(32).fill(0xa5));
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const env = createTestEnvironment({ proofKey });
    const [first, second] = await Promise.all([
      handleRequest(
        await signedPost(GOLDEN_BODY, { encodedKey: proofKey }),
        env,
        () => FIXED_TIME_MILLISECONDS,
      ),
      handleRequest(
        await signedPost(GOLDEN_BODY, { encodedKey: proofKey }),
        env,
        () => FIXED_TIME_MILLISECONDS,
      ),
    ]);

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(
      importKey.mock.calls.filter(([format]) => format === "raw"),
    ).toHaveLength(3);
  });

  it("replaces the proof-key cache when the exact secret changes", async () => {
    const firstKey = base64UrlEncode(new Uint8Array(32).fill(0xb1));
    const secondKey = base64UrlEncode(new Uint8Array(32).fill(0xb2));
    const importKey = vi.spyOn(crypto.subtle, "importKey");

    const first = await handleRequest(
      await signedPost(GOLDEN_BODY, { encodedKey: firstKey }),
      createTestEnvironment({ proofKey: firstKey }),
      () => FIXED_TIME_MILLISECONDS,
    );
    const second = await handleRequest(
      await signedPost(GOLDEN_BODY, { encodedKey: secondKey }),
      createTestEnvironment({ proofKey: secondKey }),
      () => FIXED_TIME_MILLISECONDS,
    );

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(
      importKey.mock.calls.filter(([format]) => format === "raw"),
    ).toHaveLength(4);
  });
});

describe("JWT issuance", () => {
  it("returns a verifiable six-hour RS256 JWT with minimal claims", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment(),
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
    expect(body.expiresAt).toBe(FIXED_ISSUED_AT + 21_600);
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
      exp: FIXED_ISSUED_AT + 21_600,
    });
    expect(
      await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5",
        signingFixture.publicKey,
        decodeBase64Url(encodedSignature),
        new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
      ),
    ).toBe(true);
    expect(log).not.toHaveBeenCalled();
    expect(errorLog).not.toHaveBeenCalled();
  });

  it.each(["3600", "7200", "21600"])(
    "accepts bounded JWT TTL configuration %s",
    async (ttl) => {
      const response = await handleRequest(
        await signedPost(),
        createTestEnvironment({ ttlSeconds: ttl }),
        () => FIXED_TIME_MILLISECONDS,
      );
      expect(response.status).toBe(200);
      const body = await responseObject(response);
      expect(body.expiresAt).toBe(FIXED_ISSUED_AT + Number(ttl));
    },
  );

  it.each(["3599", "21601", "21600 ", "021600", "not-a-number"])(
    "rejects out-of-bounds or noncanonical TTL configuration %s",
    async (ttl) => {
      vi.spyOn(console, "error").mockImplementation(() => undefined);
      const response = await handleRequest(
        await signedPost(),
        createTestEnvironment({ ttlSeconds: ttl }),
        () => FIXED_TIME_MILLISECONDS,
      );

      expect(response.status).toBe(500);
      expect(await responseObject(response)).toEqual({
        error: "Service unavailable",
      });
    },
  );

  it("coalesces signing-key import while signing each JWT freshly", async () => {
    const fixture = await createSigningFixture();
    const importKey = vi.spyOn(crypto.subtle, "importKey");
    const env = createTestEnvironment({
      privateKeyPem: fixture.privateKeyPem,
    });
    const [firstResponse, secondResponse] = await Promise.all([
      handleRequest(
        await signedPost(),
        env,
        () => FIXED_TIME_MILLISECONDS,
      ),
      handleRequest(
        await signedPost(proofBody(FIXED_ISSUED_AT + 1)),
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
    const pkcs8Calls = importKey.mock.calls.filter(
      ([format]) => format === "pkcs8",
    );
    expect(pkcs8Calls).toHaveLength(1);
  });
});

describe("routing and bounded input", () => {
  it.each(["GET", "PUT", "PATCH", "DELETE", "OPTIONS"])(
    "rejects %s on the issuance path",
    async (method) => {
      const response = await handleRequest(
        new Request(ENDPOINT, { method }),
        createTestEnvironment(),
      );
      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("POST");
      assertPrivateResponseHeaders(response);
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
    const response = await handleRequest(
      post(GOLDEN_BODY, undefined, url),
      createTestEnvironment(),
    );
    expect(response.status).toBe(404);
    assertPrivateResponseHeaders(response);
  });

  it("rejects direct cleartext requests before authentication", async () => {
    const response = await handleRequest(
      post(
        GOLDEN_BODY,
        undefined,
        "http://api.lil.org/v1/alchemy/jwt",
      ),
      createTestEnvironment(),
    );
    expect(response.status).toBe(400);
    expect(await responseObject(response)).toEqual({
      error: "HTTPS required",
    });
  });

  it("accepts JSON with a UTF-8 media type parameter", async () => {
    const response = await handleRequest(
      await signedPost(GOLDEN_BODY, {
        contentType: "application/json; charset=UTF-8",
      }),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(200);
  });

  it.each([
    ["missing content type", null, {}],
    ["wrong content type", GOLDEN_BODY, { "Content-Type": "text/plain" }],
  ])("returns 415 for %s", async (_name, body, headers) => {
    const response = await handleRequest(
      post(body, headers),
      createTestEnvironment(),
    );
    expect(response.status).toBe(415);
  });

  it.each([
    ["empty body", ""],
    ["malformed JSON", "{"],
    ["JSON null", "null"],
    ["JSON array", "[]"],
    ["missing fields", "{}"],
    ["extra property", `${GOLDEN_BODY.slice(0, -1)},"unexpected":true}`],
    ["non-integer timestamp", proofBody(FIXED_ISSUED_AT + 0.5)],
    ["negative timestamp", proofBody(-1)],
    ["non-string nonce", `{"timestamp":${FIXED_ISSUED_AT},"nonce":123}`],
    ["short nonce", proofBody(FIXED_ISSUED_AT, "AAAA")],
    [
      "noncanonical nonce",
      proofBody(FIXED_ISSUED_AT, "AAECAwQFBgcICQoLDA0ODx"),
    ],
  ])("returns a generic 401 for %s", async (_name, body) => {
    const response = await handleRequest(
      post(body, {
        "Content-Type": "application/json",
        [PROOF_HEADER]: GOLDEN_PROOF,
      }),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(401);
    expect(await responseObject(response)).toEqual({
      error: "Unauthorized",
    });
  });

  it("accepts either JSON property order when the raw body proof matches", async () => {
    const body =
      `{"nonce":"${GOLDEN_NONCE}","timestamp":${FIXED_ISSUED_AT}}`;
    const response = await handleRequest(
      await signedPost(body),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(200);
  });

  it("rejects invalid UTF-8 with the generic 401", async () => {
    const response = await handleRequest(
      post(new Uint8Array([0xff]), {
        "Content-Type": "application/json",
        [PROOF_HEADER]: GOLDEN_PROOF,
      }),
      createTestEnvironment(),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(401);
  });

  it("rejects an invalid Content-Length", async () => {
    const response = await handleRequest(
      post("{}", {
        "Content-Type": "application/json",
        "Content-Length": "invalid",
      }),
      createTestEnvironment(),
    );
    expect(response.status).toBe(400);
  });

  it("rejects a declared body larger than 1 KiB without reading it", async () => {
    const response = await handleRequest(
      post("{}", {
        "Content-Type": "application/json",
        "Content-Length": "1025",
      }),
      createTestEnvironment(),
    );
    expect(response.status).toBe(413);
  });

  it("stops reading an undeclared body after 1 KiB", async () => {
    const response = await handleRequest(
      post(`{"timestamp":${FIXED_ISSUED_AT},"nonce":"${"x".repeat(1_024)}"}`),
      createTestEnvironment(),
    );
    expect(response.status).toBe(413);
  });

  it("returns a redacted 400 when the body stream fails", async () => {
    const sentinel = "request-body-stream-secret";
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode('{"timestamp":'));
        controller.error(new Error(sentinel));
      },
    });

    const response = await handleRequest(
      post(stream),
      createTestEnvironment(),
    );
    expect(response.status).toBe(400);
    expect(await response.text()).toBe('{"error":"Invalid request"}');
    expect(errorLog).not.toHaveBeenCalled();
  });
});

describe("configuration and signing failures", () => {
  it.each([
    ["NaN", Number.NaN],
    ["infinity", Number.POSITIVE_INFINITY],
    ["negative time", -1],
    ["unsafe time", Number.MAX_VALUE],
  ])("fails closed for a %s clock", async (_name, clockValue) => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment(),
      () => clockValue,
    );
    expect(response.status).toBe(500);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "configuration",
      }),
    );
  });

  it("fails closed when reading the clock throws", async () => {
    const sentinel = "clock-secret-sentinel";
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment(),
      () => {
        throw new Error(sentinel);
      },
    );
    expect(response.status).toBe(500);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    expect(errorLog.mock.calls.flat().join(" ")).not.toContain(sentinel);
  });

  it("reads the clock exactly once for freshness and JWT timestamps", async () => {
    const now = vi.fn(() => FIXED_TIME_MILLISECONDS);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment(),
      now,
    );
    expect(response.status).toBe(200);
    expect(now).toHaveBeenCalledOnce();
    expect((await responseObject(response)).issuedAt).toBe(FIXED_ISSUED_AT);
  });

  it("fails closed when adding the configured TTL would overflow", async () => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const timestamp = Number.MAX_SAFE_INTEGER;
    const body = proofBody(timestamp);
    const response = await handleRequest(
      await signedPost(body),
      createTestEnvironment(),
      () => timestamp * 1_000,
    );
    expect(response.status).toBe(500);
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
  });

  it.each([
    ["missing", undefined],
    ["malformed", "not-a-version-id"],
    ["uppercase", TEST_WORKER_VERSION.toUpperCase()],
  ])("fails closed for %s version metadata", async (_name, version) => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const env = createTestEnvironment({
      workerVersion: version ?? TEST_WORKER_VERSION,
    });
    if (version === undefined) {
      expect(Reflect.deleteProperty(env, "CF_VERSION_METADATA")).toBe(true);
    }

    const response = await handleRequest(
      await signedPost(),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(500);
    expect(response.headers.has("X-Alchemy-JWT-Worker-Version")).toBe(false);
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "configuration",
      }),
    );
  });

  it.each([
    ["missing proof key", undefined],
    ["empty proof key", ""],
    ["short proof key", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"],
    ["padded proof key", `${GOLDEN_PROOF_KEY}=`],
    [
      "noncanonical proof key",
      "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh_",
    ],
  ])("fails closed for %s", async (_name, proofKey) => {
    const errorLog = vi
      .spyOn(console, "error")
      .mockImplementation(() => undefined);
    const env = createTestEnvironment({ proofKey: proofKey ?? GOLDEN_PROOF_KEY });
    if (proofKey === undefined) {
      expect(
        Reflect.deleteProperty(env, "ALCHEMY_JWT_REQUEST_PROOF_KEY"),
      ).toBe(true);
    }
    const response = await handleRequest(
      await signedPost(),
      env,
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(500);
    expect(await responseObject(response)).toEqual({
      error: "Service unavailable",
    });
    const logs = errorLog.mock.calls.flat().join(" ");
    expect(logs).not.toContain(GOLDEN_PROOF_KEY);
    expect(logs).not.toContain(GOLDEN_PROOF);
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
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment({ privateKeyPem }),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(500);
    const responseText = await response.text();
    expect(responseText).toBe('{"error":"Service unavailable"}');
    if (privateKeyPem !== "") {
      expect(responseText).not.toContain(privateKeyPem);
      expect(errorLog.mock.calls.flat().join(" ")).not.toContain(privateKeyPem);
    }
    expect(errorLog).toHaveBeenCalledWith(
      JSON.stringify({
        event: "alchemy_jwt_issuer_failure",
        failure: "signing",
      }),
    );
  });

  it.each([
    ["RSA-3072", () => rsa3072SigningFixture.privateKeyPem],
    ["RSA-2048 exponent 3", () => rsa2048Exponent3SigningFixture.privateKeyPem],
  ])("rejects a %s private key", async (_name, privateKeyPem) => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment({ privateKeyPem: privateKeyPem() }),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(500);
  });

  it.each([
    ["placeholder key ID", { keyId: "pending-alchemy-key-id" }],
    ["invalid key ID", { keyId: "contains whitespace" }],
  ])("fails safely for %s", async (_name, options) => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    const response = await handleRequest(
      await signedPost(),
      createTestEnvironment(options),
      () => FIXED_TIME_MILLISECONDS,
    );
    expect(response.status).toBe(500);
  });
});
