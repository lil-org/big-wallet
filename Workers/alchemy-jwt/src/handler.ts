const JWT_PATH = "/v1/alchemy/jwt";
const PRODUCTION_HOST = "api.lil.org";
const PRODUCTION_ORIGIN = `https://${PRODUCTION_HOST}`;
const PRODUCTION_ENDPOINT = `${PRODUCTION_ORIGIN}${JWT_PATH}`;
const MAX_REQUEST_BYTES = 1_024;
const RETRY_AFTER_SECONDS = 60;
const HSTS_POLICY = "max-age=31536000";
const VERSION_HEADER = "X-Alchemy-JWT-Worker-Version";
const REQUIRED_JWT_TTL_SECONDS = 86_400;
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PENDING_KEY_ID = "pending-alchemy-key-id";

type Clock = () => number;

type BodyReadResult =
  | { status: "ok"; bytes: Uint8Array }
  | { status: "too-large" };

type IssuanceRequest = {
  installationId: string;
};

type JwtResponse = {
  token: string;
  issuedAt: number;
  expiresAt: number;
};

type SigningKeyCacheEntry = {
  privateKeyPem: string;
  importPromise: Promise<CryptoKey>;
};

let signingKeyCacheEntry: SigningKeyCacheEntry | undefined;

export type AlchemyJWTIssuerEnvironment = {
  [Binding in keyof Pick<
    Env,
    | "JWT_ISSUANCE_RATE_LIMITER"
    | "ALCHEMY_KEY_ID"
    | "JWT_TTL_SECONDS"
    | "ALCHEMY_JWT_PRIVATE_KEY"
    | "CF_VERSION_METADATA"
  >]: Env[Binding] extends string ? string : Env[Binding];
};

function jsonResponse(
  body: Readonly<Record<string, unknown>>,
  status: number,
  workerVersion?: string,
  additionalHeaders?: Readonly<Record<string, string>>,
): Response {
  const headers = new Headers(additionalHeaders);
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Strict-Transport-Security", HSTS_POLICY);
  headers.set("X-Content-Type-Options", "nosniff");
  if (workerVersion !== undefined) {
    headers.set(VERSION_HEADER, workerVersion);
  }

  return new Response(JSON.stringify(body), { status, headers });
}

function errorResponse(
  status: number,
  error: string,
  workerVersion?: string,
  additionalHeaders?: Readonly<Record<string, string>>,
): Response {
  return jsonResponse({ error }, status, workerVersion, additionalHeaders);
}

async function readBoundedBody(
  body: ReadableStream<Uint8Array> | null,
): Promise<BodyReadResult> {
  if (body === null) {
    return { status: "ok", bytes: new Uint8Array() };
  }

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let byteCount = 0;

  try {
    while (true) {
      const result = await reader.read();
      if (result.done) {
        break;
      }

      byteCount += result.value.byteLength;
      if (byteCount > MAX_REQUEST_BYTES) {
        try {
          await reader.cancel("request body too large");
        } catch {
          // The response is still a deterministic 413 if cancellation races EOF.
        }
        return { status: "too-large" };
      }
      chunks.push(result.value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { status: "ok", bytes };
}

function contentLengthStatus(
  contentLength: string | null,
): "ok" | "invalid" | "too-large" {
  if (contentLength === null) {
    return "ok";
  }
  if (!/^(0|[1-9][0-9]*)$/.test(contentLength)) {
    return "invalid";
  }

  const length = Number(contentLength);
  if (!Number.isSafeInteger(length)) {
    return "invalid";
  }
  return length > MAX_REQUEST_BYTES ? "too-large" : "ok";
}

function parseIssuanceRequest(bytes: Uint8Array): IssuanceRequest | null {
  let parsed: unknown;
  try {
    const text = new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: false,
    }).decode(bytes);
    parsed = JSON.parse(text);
  } catch {
    return null;
  }

  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return null;
  }

  const keys = Object.keys(parsed);
  if (keys.length !== 1 || keys[0] !== "installationId") {
    return null;
  }

  const installationId = Reflect.get(parsed, "installationId");
  if (
    typeof installationId !== "string" ||
    !CANONICAL_UUID.test(installationId)
  ) {
    return null;
  }
  return { installationId };
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

function encodeJson(value: Readonly<Record<string, unknown>>): string {
  return base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(value)),
  );
}

function decodePkcs8Pem(pem: string): Uint8Array {
  const beginMarker = "-----BEGIN PRIVATE KEY-----";
  const endMarker = "-----END PRIVATE KEY-----";
  const trimmed = pem.trim();

  if (
    !trimmed.startsWith(beginMarker) ||
    !trimmed.endsWith(endMarker)
  ) {
    throw new Error("invalid private key");
  }

  const encoded = trimmed
    .slice(beginMarker.length, -endMarker.length)
    .replace(/\s/gu, "");
  if (
    encoded.length === 0 ||
    encoded.length > 8_192 ||
    !/^[A-Za-z0-9+/]+={0,2}$/u.test(encoded)
  ) {
    throw new Error("invalid private key");
  }

  let binary: string;
  try {
    binary = atob(encoded);
  } catch {
    throw new Error("invalid private key");
  }

  if (binary.length === 0 || binary.length > 4_096) {
    throw new Error("invalid private key");
  }

  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function readIssuerConfiguration(env: AlchemyJWTIssuerEnvironment): {
  keyId: string;
  ttlSeconds: number;
} {
  const keyId: unknown = env.ALCHEMY_KEY_ID;
  if (
    typeof keyId !== "string" ||
    keyId === PENDING_KEY_ID ||
    !/^[\u0021-\u007e]{1,256}$/u.test(keyId)
  ) {
    throw new Error("invalid issuer configuration");
  }

  const configuredTtl: unknown = env.JWT_TTL_SECONDS;
  if (configuredTtl !== String(REQUIRED_JWT_TTL_SECONDS)) {
    throw new Error("invalid issuer configuration");
  }

  return { keyId, ttlSeconds: REQUIRED_JWT_TTL_SECONDS };
}

function readWorkerVersion(
  env: AlchemyJWTIssuerEnvironment,
): string {
  const metadata: unknown = env.CF_VERSION_METADATA;
  if (
    typeof metadata !== "object" ||
    metadata === null ||
    Array.isArray(metadata)
  ) {
    throw new Error("invalid version metadata");
  }

  const versionId = Reflect.get(metadata, "id");
  if (typeof versionId !== "string" || !CANONICAL_UUID.test(versionId)) {
    throw new Error("invalid version metadata");
  }
  return versionId;
}

async function importSigningKey(privateKeyPem: string): Promise<CryptoKey> {
  const privateKeyBytes = decodePkcs8Pem(privateKeyPem);
  const key = await crypto.subtle.importKey(
    "pkcs8",
    privateKeyBytes,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );

  const algorithm = key.algorithm;
  if (
    key.type !== "private" ||
    algorithm.name !== "RSASSA-PKCS1-v1_5" ||
    !("modulusLength" in algorithm) ||
    typeof algorithm.modulusLength !== "number" ||
    algorithm.modulusLength !== 2_048 ||
    !("publicExponent" in algorithm) ||
    !isPublicExponent65537(algorithm.publicExponent)
  ) {
    throw new Error("invalid private key");
  }
  return key;
}

function signingKeyForPem(privateKeyPem: string): Promise<CryptoKey> {
  if (signingKeyCacheEntry?.privateKeyPem === privateKeyPem) {
    return signingKeyCacheEntry.importPromise;
  }
  const importPromise = importSigningKey(privateKeyPem);
  signingKeyCacheEntry = { privateKeyPem, importPromise };
  return importPromise;
}

function isPublicExponent65537(value: unknown): boolean {
  let bytes: Uint8Array;
  if (value instanceof ArrayBuffer) {
    bytes = new Uint8Array(value);
  } else if (ArrayBuffer.isView(value)) {
    bytes = new Uint8Array(
      value.buffer,
      value.byteOffset,
      value.byteLength,
    );
  } else {
    return false;
  }

  return bytes.byteLength === 3
    && bytes[0] === 0x01
    && bytes[1] === 0x00
    && bytes[2] === 0x01;
}

async function issueJwt(
  env: AlchemyJWTIssuerEnvironment,
  now: Clock,
): Promise<JwtResponse> {
  const { keyId, ttlSeconds } = readIssuerConfiguration(env);
  const signingKey = await signingKeyForPem(env.ALCHEMY_JWT_PRIVATE_KEY);
  const issuedAt = Math.floor(now() / 1_000);
  const expiresAt = issuedAt + ttlSeconds;

  const header = encodeJson({
    alg: "RS256",
    typ: "JWT",
    kid: keyId,
  });
  const payload = encodeJson({
    iat: issuedAt,
    exp: expiresAt,
  });
  const signingInput = `${header}.${payload}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    signingKey,
    new TextEncoder().encode(signingInput),
  );

  return {
    token: `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`,
    issuedAt,
    expiresAt,
  };
}

function logInternalFailure(
  failure: "configuration" | "rate-limit" | "signing",
): void {
  console.error(
    JSON.stringify({
      event: "alchemy_jwt_issuer_failure",
      failure,
    }),
  );
}

export async function handleRequest(
  request: Request,
  env: AlchemyJWTIssuerEnvironment,
  now: Clock = Date.now,
): Promise<Response> {
  const url = new URL(request.url);
  let workerVersion: string;
  try {
    workerVersion = readWorkerVersion(env);
  } catch {
    logInternalFailure("configuration");
    return errorResponse(500, "Service unavailable");
  }

  if (
    url.hostname !== PRODUCTION_HOST ||
    url.username !== "" ||
    url.password !== ""
  ) {
    return errorResponse(404, "Not found", workerVersion);
  }

  if (url.protocol !== "https:") {
    return errorResponse(400, "HTTPS required", workerVersion);
  }

  if (url.href !== PRODUCTION_ENDPOINT) {
    return errorResponse(404, "Not found", workerVersion);
  }

  if (request.method !== "POST") {
    return errorResponse(405, "Method not allowed", workerVersion, {
      Allow: "POST",
    });
  }

  const mediaType = request.headers
    .get("Content-Type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase();
  if (mediaType !== "application/json") {
    return errorResponse(415, "Unsupported media type", workerVersion);
  }

  const lengthStatus = contentLengthStatus(
    request.headers.get("Content-Length"),
  );
  if (lengthStatus === "invalid") {
    return errorResponse(400, "Invalid request", workerVersion);
  }
  if (lengthStatus === "too-large") {
    return errorResponse(413, "Request body too large", workerVersion);
  }

  let body: BodyReadResult;
  try {
    body = await readBoundedBody(request.body);
  } catch {
    return errorResponse(400, "Invalid request", workerVersion);
  }
  if (body.status === "too-large") {
    return errorResponse(413, "Request body too large", workerVersion);
  }

  const issuanceRequest = parseIssuanceRequest(body.bytes);
  if (issuanceRequest === null) {
    return errorResponse(400, "Invalid request", workerVersion);
  }

  let rateLimitOutcome: RateLimitOutcome;
  try {
    rateLimitOutcome = await env.JWT_ISSUANCE_RATE_LIMITER.limit({
      key: issuanceRequest.installationId,
    });
  } catch {
    logInternalFailure("rate-limit");
    return errorResponse(500, "Service unavailable", workerVersion);
  }

  if (!rateLimitOutcome.success) {
    return errorResponse(
      429,
      "Too many requests",
      workerVersion,
      {
        "Retry-After": String(RETRY_AFTER_SECONDS),
      },
    );
  }

  try {
    const jwt = await issueJwt(env, now);
    return jsonResponse(jwt, 200, workerVersion);
  } catch {
    logInternalFailure("signing");
    return errorResponse(500, "Service unavailable", workerVersion);
  }
}
