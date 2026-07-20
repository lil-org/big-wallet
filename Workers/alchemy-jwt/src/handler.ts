const JWT_PATH = "/v1/alchemy/jwt";
const PRODUCTION_HOST = "api.lil.org";
const PRODUCTION_ORIGIN = `https://${PRODUCTION_HOST}`;
const PRODUCTION_ENDPOINT = `${PRODUCTION_ORIGIN}${JWT_PATH}`;
const BROKER_METHOD = "POST";
const MAX_REQUEST_BYTES = 1_024;
const HSTS_POLICY = "max-age=31536000";
const VERSION_HEADER = "X-Alchemy-JWT-Worker-Version";
const REQUEST_PROOF_HEADER = "X-Lil-Alchemy-Proof";
const REQUEST_PROOF_PREFIX =
  "LIL-ALCHEMY-JWT-PROOF-V1\n"
  + `${BROKER_METHOD}\n`
  + `${PRODUCTION_ENDPOINT}\n`;
const REQUEST_PROOF_WINDOW_SECONDS = 300;
const MINIMUM_JWT_TTL_SECONDS = 3_600;
const MAXIMUM_JWT_TTL_SECONDS = 21_600;
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CANONICAL_BASE64URL_128 = /^[A-Za-z0-9_-]{22}$/u;
const CANONICAL_BASE64URL_256 = /^[A-Za-z0-9_-]{43}$/u;
const PENDING_KEY_ID = "pending-alchemy-key-id";

type Clock = () => number;

type BodyReadResult =
  | { status: "ok"; bytes: Uint8Array }
  | { status: "too-large" };

type IssuanceRequest = {
  timestamp: number;
  nonce: string;
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

type RequestProofKeyCacheEntry = {
  encodedKey: string;
  importPromise: Promise<CryptoKey>;
};

let signingKeyCacheEntry: SigningKeyCacheEntry | undefined;
let requestProofKeyCacheEntry: RequestProofKeyCacheEntry | undefined;
const requestProofPrefixBytes = new TextEncoder().encode(
  REQUEST_PROOF_PREFIX,
);

export type AlchemyJWTIssuerEnvironment = {
  [Binding in keyof Pick<
    Env,
    | "ALCHEMY_KEY_ID"
    | "JWT_TTL_SECONDS"
    | "ALCHEMY_JWT_PRIVATE_KEY"
    | "ALCHEMY_JWT_REQUEST_PROOF_KEY"
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
  if (
    keys.length !== 2 ||
    !Object.hasOwn(parsed, "timestamp") ||
    !Object.hasOwn(parsed, "nonce")
  ) {
    return null;
  }

  const timestamp = Reflect.get(parsed, "timestamp");
  const nonce = Reflect.get(parsed, "nonce");
  if (
    typeof timestamp !== "number" ||
    !Number.isSafeInteger(timestamp) ||
    timestamp < 0 ||
    typeof nonce !== "string" ||
    !CANONICAL_BASE64URL_128.test(nonce) ||
    decodeCanonicalBase64Url(nonce, 16) === null
  ) {
    return null;
  }
  return { timestamp, nonce };
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

function decodeCanonicalBase64Url(
  encoded: string,
  expectedByteLength: number,
): Uint8Array | null {
  const paddingLength = (4 - (encoded.length % 4)) % 4;
  const padded = encoded
    .replaceAll("-", "+")
    .replaceAll("_", "/")
    .padEnd(encoded.length + paddingLength, "=");

  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    return null;
  }
  if (binary.length !== expectedByteLength) {
    return null;
  }

  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return base64UrlEncode(bytes) === encoded ? bytes : null;
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
  if (
    typeof configuredTtl !== "string" ||
    !/^[1-9][0-9]*$/u.test(configuredTtl)
  ) {
    throw new Error("invalid issuer configuration");
  }

  const ttlSeconds = Number(configuredTtl);
  if (
    !Number.isSafeInteger(ttlSeconds) ||
    ttlSeconds < MINIMUM_JWT_TTL_SECONDS ||
    ttlSeconds > MAXIMUM_JWT_TTL_SECONDS
  ) {
    throw new Error("invalid issuer configuration");
  }

  return { keyId, ttlSeconds };
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

async function importRequestProofKey(encodedKey: string): Promise<CryptoKey> {
  if (!CANONICAL_BASE64URL_256.test(encodedKey)) {
    throw new Error("invalid request proof key");
  }
  const keyBytes = decodeCanonicalBase64Url(encodedKey, 32);
  if (keyBytes === null) {
    throw new Error("invalid request proof key");
  }
  return crypto.subtle.importKey(
    "raw",
    keyBytes,
    {
      name: "HMAC",
      hash: "SHA-256",
    },
    false,
    ["verify"],
  );
}

function requestProofKeyForEncodedKey(encodedKey: string): Promise<CryptoKey> {
  if (requestProofKeyCacheEntry?.encodedKey === encodedKey) {
    return requestProofKeyCacheEntry.importPromise;
  }
  const importPromise = importRequestProofKey(encodedKey);
  requestProofKeyCacheEntry = { encodedKey, importPromise };
  return importPromise;
}

function requestProofInput(body: Uint8Array): Uint8Array {
  const input = new Uint8Array(
    requestProofPrefixBytes.byteLength + body.byteLength,
  );
  input.set(requestProofPrefixBytes);
  input.set(body, requestProofPrefixBytes.byteLength);
  return input;
}

async function hasValidRequestProof(
  body: Uint8Array,
  encodedProof: string | null,
  encodedKey: string,
): Promise<boolean> {
  if (
    encodedProof === null ||
    !CANONICAL_BASE64URL_256.test(encodedProof)
  ) {
    return false;
  }
  const proof = decodeCanonicalBase64Url(encodedProof, 32);
  if (proof === null) {
    return false;
  }
  const key = await requestProofKeyForEncodedKey(encodedKey);
  return crypto.subtle.verify(
    "HMAC",
    key,
    proof,
    requestProofInput(body),
  );
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
  issuedAt: number,
): Promise<JwtResponse> {
  const { keyId, ttlSeconds } = readIssuerConfiguration(env);
  const signingKey = await signingKeyForPem(env.ALCHEMY_JWT_PRIVATE_KEY);
  const expiresAt = issuedAt + ttlSeconds;
  if (!Number.isSafeInteger(expiresAt)) {
    throw new Error("invalid issuer timestamp");
  }

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
  failure: "configuration" | "signing",
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

  if (request.method !== BROKER_METHOD) {
    return errorResponse(405, "Method not allowed", workerVersion, {
      Allow: BROKER_METHOD,
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

  let issuedAt: number;
  try {
    issuedAt = Math.floor(now() / 1_000);
  } catch {
    logInternalFailure("configuration");
    return errorResponse(500, "Service unavailable", workerVersion);
  }
  if (!Number.isSafeInteger(issuedAt) || issuedAt < 0) {
    logInternalFailure("configuration");
    return errorResponse(500, "Service unavailable", workerVersion);
  }

  const issuanceRequest = parseIssuanceRequest(body.bytes);
  if (
    issuanceRequest === null ||
    Math.abs(issuedAt - issuanceRequest.timestamp)
      > REQUEST_PROOF_WINDOW_SECONDS
  ) {
    return errorResponse(401, "Unauthorized", workerVersion);
  }

  let hasValidProof: boolean;
  try {
    hasValidProof = await hasValidRequestProof(
      body.bytes,
      request.headers.get(REQUEST_PROOF_HEADER),
      env.ALCHEMY_JWT_REQUEST_PROOF_KEY,
    );
  } catch {
    logInternalFailure("configuration");
    return errorResponse(500, "Service unavailable", workerVersion);
  }

  if (!hasValidProof) {
    return errorResponse(401, "Unauthorized", workerVersion);
  }

  try {
    const jwt = await issueJwt(env, issuedAt);
    return jsonResponse(jwt, 200, workerVersion);
  } catch {
    logInternalFailure("signing");
    return errorResponse(500, "Service unavailable", workerVersion);
  }
}
