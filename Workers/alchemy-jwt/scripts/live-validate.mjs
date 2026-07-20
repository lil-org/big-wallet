#!/usr/bin/env node

/**
 * Secret-safe production validation for the Alchemy JWT issuer.
 *
 * The JWT is accepted only from the issuer response and retained in memory for
 * this process. It is never accepted as a CLI argument, written to disk,
 * included in an error, or printed.
 */

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import {
  isValidWorkerName,
  loadProductionWranglerContract,
} from "./production-contract.mjs";

const DEFAULT_BROKER_URL = "https://api.lil.org/v1/alchemy/jwt";
const BROKER_ORIGIN = "https://api.lil.org";
const BROKER_PATH = "/v1/alchemy/jwt";
const REQUIRED_JWT_TTL_SECONDS = 86_400;
const DEFAULT_EXPECTED_EVM_HOSTS = 131;
const DEFAULT_CONCURRENCY = 8;
const DEFAULT_TIMEOUT_MS = 15_000;
const DEFAULT_RPC_ATTEMPTS = 3;
const MAX_RPC_ATTEMPTS = 5;
const MAX_CONCURRENCY = 32;
const MAX_BROKER_RESPONSE_BYTES = 32 * 1_024;
const MAX_RPC_RESPONSE_BYTES = 128 * 1_024;
const CLOCK_SKEW_SECONDS = 300;
const VERSION_WAIT_TIMEOUT_MS = 30_000;
const VERSION_WAIT_INTERVAL_MS = 1_000;
const RPC_RETRY_BASE_MS = 500;
const RPC_RETRY_CAP_MS = 4_000;
const HSTS_POLICY = "max-age=31536000";
const EXPECTED_JSON_CONTENT_TYPE = "application/json; charset=utf-8";
const VERSION_HEADER = "x-alchemy-jwt-worker-version";
const VERSION_OVERRIDE_HEADER = "Cloudflare-Workers-Version-Overrides";
const CANONICAL_UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;
const PRINTABLE_KEY_ID = /^[\u0021-\u007e]{1,256}$/u;
const ALCHEMY_NETWORK_PATTERN =
  /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u;

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const defaultCatalogPath = resolve(
  scriptDirectory,
  "../../../Shared/Ethereum/NetworkCatalog.json",
);
const DEFAULT_WORKER_NAME = (
  await loadProductionWranglerContract()
).workerName;

export class SafeValidationError extends Error {
  constructor(message, kind = "validation") {
    super(message);
    this.name = "SafeValidationError";
    this.kind = kind;
  }
}

function safeFailure(message, kind) {
  return new SafeValidationError(message, kind);
}

function usage() {
  return [
    "Usage: node scripts/live-validate.mjs [options]",
    "",
    "Live validation requires --expected-kid and --expected-version.",
    "",
    "Options:",
    `  --broker URL            Issuer endpoint (fixed origin default: ${DEFAULT_BROKER_URL})`,
    "  --catalog PATH          NetworkCatalog.json path",
    `  --expected-evm N        Required EVM host count (default: ${DEFAULT_EXPECTED_EVM_HOSTS})`,
    "  --expected-kid KID      Required JWT kid (never printed)",
    "  --expected-version UUID Required Worker version response header",
    `  --worker-name NAME      Worker override name (default: ${DEFAULT_WORKER_NAME})`,
    "  --version-override      Send requests to the expected 0%-traffic version",
    `  --rpc-attempts N        Transient-only attempts, 1-${MAX_RPC_ATTEMPTS} (default: ${DEFAULT_RPC_ATTEMPTS})`,
    `  --concurrency N         Parallel RPC checks, 1-${MAX_CONCURRENCY} (default: ${DEFAULT_CONCURRENCY})`,
    `  --timeout-ms N          Per-request timeout (default: ${DEFAULT_TIMEOUT_MS})`,
    "  --dry-run               Validate inputs/catalog without network access",
    "  --self-test             Run structural/tooling tests without network access",
    "  --help                  Show this help",
  ].join("\n");
}

function parsePositiveInteger(
  value,
  optionName,
  maximum = Number.MAX_SAFE_INTEGER,
) {
  if (!/^[1-9][0-9]*$/u.test(value)) {
    throw safeFailure(`${optionName} must be a positive integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed > maximum) {
    throw safeFailure(`${optionName} is outside the supported range`);
  }
  return parsed;
}

export function parseArguments(arguments_) {
  const options = {
    brokerURL: DEFAULT_BROKER_URL,
    catalogPath: defaultCatalogPath,
    expectedEvmHosts: DEFAULT_EXPECTED_EVM_HOSTS,
    expectedKid: undefined,
    expectedVersion: undefined,
    workerName: DEFAULT_WORKER_NAME,
    versionOverride: false,
    rpcAttempts: DEFAULT_RPC_ATTEMPTS,
    concurrency: DEFAULT_CONCURRENCY,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    dryRun: false,
    selfTest: false,
    help: false,
  };
  const valueOptions = new Map([
    ["--broker", "brokerURL"],
    ["--catalog", "catalogPath"],
    ["--expected-evm", "expectedEvmHosts"],
    ["--expected-kid", "expectedKid"],
    ["--expected-version", "expectedVersion"],
    ["--worker-name", "workerName"],
    ["--rpc-attempts", "rpcAttempts"],
    ["--concurrency", "concurrency"],
    ["--timeout-ms", "timeoutMs"],
  ]);
  const seen = new Set();

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--dry-run") {
      options.dryRun = true;
      continue;
    }
    if (argument === "--self-test") {
      options.selfTest = true;
      continue;
    }
    if (argument === "--version-override") {
      options.versionOverride = true;
      continue;
    }
    if (argument === "--help") {
      options.help = true;
      continue;
    }

    const key = valueOptions.get(argument);
    if (key === undefined) {
      throw safeFailure("Unknown command-line option");
    }
    if (seen.has(argument)) {
      throw safeFailure(`Duplicate command-line option ${argument}`);
    }
    seen.add(argument);
    const value = arguments_[index + 1];
    if (value === undefined || value.startsWith("--")) {
      throw safeFailure(`Missing value for ${argument}`);
    }
    index += 1;

    if (
      key === "brokerURL" ||
      key === "catalogPath" ||
      key === "expectedKid" ||
      key === "expectedVersion" ||
      key === "workerName"
    ) {
      options[key] = value;
    } else if (key === "concurrency") {
      options[key] = parsePositiveInteger(value, argument, MAX_CONCURRENCY);
    } else if (key === "rpcAttempts") {
      options[key] = parsePositiveInteger(value, argument, MAX_RPC_ATTEMPTS);
    } else if (key === "timeoutMs") {
      options[key] = parsePositiveInteger(value, argument, 120_000);
    } else {
      options[key] = parsePositiveInteger(value, argument, 10_000);
    }
  }

  if (options.dryRun && options.selfTest) {
    throw safeFailure("--dry-run and --self-test are mutually exclusive");
  }
  if (
    options.expectedKid !== undefined &&
    !PRINTABLE_KEY_ID.test(options.expectedKid)
  ) {
    throw safeFailure("--expected-kid is invalid");
  }
  if (
    options.expectedVersion !== undefined &&
    !CANONICAL_UUID.test(options.expectedVersion)
  ) {
    throw safeFailure("--expected-version must be a canonical lowercase UUID");
  }
  if (!isValidWorkerName(options.workerName)) {
    throw safeFailure("--worker-name is invalid");
  }
  if (options.versionOverride && options.expectedVersion === undefined) {
    throw safeFailure("--version-override requires --expected-version");
  }
  return options;
}

function requireLiveAttestation(options) {
  if (
    options.expectedKid === undefined ||
    options.expectedVersion === undefined
  ) {
    throw safeFailure(
      "Live validation requires --expected-kid and --expected-version",
    );
  }
}

export function parseBrokerURL(value) {
  if (value !== DEFAULT_BROKER_URL) {
    throw safeFailure(
      `Broker URL must be exactly ${BROKER_ORIGIN}${BROKER_PATH}`,
    );
  }
  let url;
  try {
    url = new URL(value);
  } catch {
    throw safeFailure("Broker URL is invalid");
  }
  if (
    url.username !== "" ||
    url.password !== "" ||
    url.href !== DEFAULT_BROKER_URL
  ) {
    throw safeFailure(
      `Broker URL must be exactly ${BROKER_ORIGIN}${BROKER_PATH}`,
    );
  }
  return url;
}

function isPlainObject(value) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, expectedKeys) {
  if (!isPlainObject(value)) {
    return false;
  }
  const actual = Object.keys(value).sort();
  const expected = [...expectedKeys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function isValidAlchemyNetwork(value) {
  return typeof value === "string" && ALCHEMY_NETWORK_PATTERN.test(value);
}

async function loadEvmTargets(catalogPath, expectedCount) {
  let parsed;
  try {
    const bytes = await readFile(catalogPath);
    if (bytes.byteLength > 2 * 1_024 * 1_024) {
      throw safeFailure("Network catalog is unexpectedly large");
    }
    parsed = JSON.parse(bytes.toString("utf8"));
  } catch (error) {
    if (error instanceof SafeValidationError) {
      throw error;
    }
    throw safeFailure("Network catalog could not be read or parsed");
  }
  if (!Array.isArray(parsed)) {
    throw safeFailure("Network catalog must contain an array");
  }

  const networks = [];
  for (const entry of parsed) {
    if (!isPlainObject(entry) || !Object.hasOwn(entry, "alchemyNetwork")) {
      continue;
    }
    const network = entry.alchemyNetwork;
    if (!isValidAlchemyNetwork(network)) {
      throw safeFailure("Network catalog contains an invalid Alchemy network");
    }
    networks.push(network);
  }
  if (networks.length !== expectedCount) {
    throw safeFailure(
      `Expected ${expectedCount} catalogued Alchemy EVM networks, found ${networks.length}`,
    );
  }
  if (new Set(networks).size !== networks.length) {
    throw safeFailure("Network catalog contains duplicate Alchemy networks");
  }
  return networks.map((network) => ({
    kind: "evm",
    host: `${network}.g.alchemy.com`,
    url: `https://${network}.g.alchemy.com/v2`,
  }));
}

function solanaTargets() {
  return ["solana-mainnet", "solana-devnet"].map((network) => ({
    kind: "solana",
    host: `${network}.g.alchemy.com`,
    url: `https://${network}.g.alchemy.com/v2`,
  }));
}

function assertBrokerPolicyHeaders(response, context) {
  if (response.headers.get("cache-control") !== "no-store") {
    throw safeFailure(`${context}: Cache-Control is not exactly no-store`);
  }
  if (
    response.headers.get("content-type")?.toLowerCase() !==
    EXPECTED_JSON_CONTENT_TYPE
  ) {
    throw safeFailure(`${context}: Content-Type does not match the contract`);
  }
  if (response.headers.get("strict-transport-security") !== HSTS_POLICY) {
    throw safeFailure(`${context}: HSTS policy is invalid`);
  }
  if (
    response.headers.get("x-content-type-options")?.toLowerCase() !==
    "nosniff"
  ) {
    throw safeFailure(`${context}: X-Content-Type-Options is not nosniff`);
  }
  for (const [name] of response.headers) {
    if (name.toLowerCase().startsWith("access-control-")) {
      throw safeFailure(
        `${context}: response unexpectedly includes CORS headers`,
      );
    }
  }
}

export function assertBrokerHeaders(response, context, expectedVersion) {
  assertBrokerPolicyHeaders(response, context);
  const observedVersion = response.headers.get(VERSION_HEADER);
  if (observedVersion !== expectedVersion) {
    throw safeFailure(`${context}: Worker version does not match expectation`);
  }
}

async function readBoundedResponse(response, byteLimit, context) {
  if (response.body === null) {
    return new Uint8Array();
  }
  const reader = response.body.getReader();
  const chunks = [];
  let byteCount = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) {
        break;
      }
      byteCount += result.value.byteLength;
      if (byteCount > byteLimit) {
        try {
          await reader.cancel();
        } catch {
          // The deterministic size failure wins if cancellation races EOF.
        }
        throw safeFailure(
          `${context}: response exceeded the byte limit`,
          "response-too-large",
        );
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
  return bytes;
}

function cancelUnusedResponseBody(body) {
  if (body === null) {
    return;
  }
  try {
    void body
      .cancel("unused non-success response body")
      .catch(() => undefined);
  } catch {
    // Cleanup must not override an already-known HTTP status.
  }
}

export async function fetchBoundedWithTimeout(
  url,
  init,
  timeoutMs,
  byteLimit,
  context,
  {
    fetchImplementation = fetch,
    readNonSuccessBody = true,
  } = {},
) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImplementation(url, {
      ...init,
      redirect: init.redirect ?? "error",
      signal: controller.signal,
    });
    if (!readNonSuccessBody && !response.ok) {
      cancelUnusedResponseBody(response.body);
      return { response, bytes: new Uint8Array() };
    }
    const bytes = await readBoundedResponse(response, byteLimit, context);
    return { response, bytes };
  } catch (error) {
    if (error instanceof SafeValidationError) {
      throw error;
    }
    if (controller.signal.aborted) {
      throw safeFailure(`${context}: request timed out`, "timeout");
    }
    throw safeFailure(`${context}: network request failed`, "network");
  } finally {
    clearTimeout(timer);
  }
}

function overrideHeaders(options) {
  if (!options.versionOverride) {
    return {};
  }
  return {
    [VERSION_OVERRIDE_HEADER]:
      `${options.workerName}="${options.expectedVersion}"`,
  };
}

export async function probeHttpRedirect(
  brokerURL,
  timeoutMs,
  fetchImplementation = fetch,
) {
  const probeURLs = [
    new URL(brokerURL),
    new URL(brokerURL),
  ];
  probeURLs[1].searchParams.set("alchemy-jwt-redirect-probe", "1");

  for (const expectedSecureURL of probeURLs) {
    const cleartextURL = new URL(expectedSecureURL);
    cleartextURL.protocol = "http:";
    const { response } = await fetchBoundedWithTimeout(
      cleartextURL,
      { method: "GET", redirect: "manual" },
      timeoutMs,
      MAX_BROKER_RESPONSE_BYTES,
      "HTTP redirect probe",
      { fetchImplementation },
    );
    if (response.status !== 308) {
      throw safeFailure(
        `HTTP redirect probe: received HTTP ${response.status}, expected 308`,
      );
    }
    if (response.headers.get("location") !== expectedSecureURL.href) {
      throw safeFailure(
        "HTTP redirect probe: Location is not the exact HTTPS URL",
      );
    }
    if (response.headers.has(VERSION_HEADER)) {
      throw safeFailure("HTTP redirect probe unexpectedly reached the Worker");
    }
  }
}

async function waitForExpectedVersion(
  brokerURL,
  options,
  {
    fetchImplementation = fetch,
    sleepImplementation = (milliseconds) =>
      new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds)),
    nowImplementation = Date.now,
  } = {},
) {
  const deadline = nowImplementation() + VERSION_WAIT_TIMEOUT_MS;
  let attempt = 0;
  while (attempt < 31 && nowImplementation() <= deadline) {
    attempt += 1;
    try {
      const remainingMilliseconds = Math.max(
        1,
        deadline - nowImplementation(),
      );
      const { response } = await fetchBoundedWithTimeout(
        brokerURL,
        {
          method: "GET",
          headers: overrideHeaders(options),
        },
        Math.min(options.timeoutMs, remainingMilliseconds),
        MAX_BROKER_RESPONSE_BYTES,
        "version propagation probe",
        { fetchImplementation },
      );
      if (
        response.status === 405 &&
        response.headers.get("allow") === "POST"
      ) {
        assertBrokerPolicyHeaders(response, "version propagation probe");
        if (
          response.headers.get(VERSION_HEADER) === options.expectedVersion
        ) {
          return attempt;
        }
      }
    } catch (error) {
      if (!(error instanceof SafeValidationError)) {
        throw error;
      }
      // A stale version may not yet expose the new response policy.
    }
    if (attempt < 31 && nowImplementation() < deadline) {
      await sleepImplementation(VERSION_WAIT_INTERVAL_MS);
    }
  }
  throw safeFailure(
    "Expected Worker version did not propagate within 30 seconds",
  );
}

function base64UrlDecode(segment, context) {
  if (
    typeof segment !== "string" ||
    segment.length === 0 ||
    segment.length % 4 === 1 ||
    !/^[A-Za-z0-9_-]+$/u.test(segment)
  ) {
    throw safeFailure(`${context}: JWT encoding is invalid`);
  }
  return Buffer.from(
    `${segment}${"=".repeat((4 - (segment.length % 4)) % 4)}`,
    "base64url",
  );
}

function decodeJwtObject(segment, context) {
  const bytes = base64UrlDecode(segment, context);
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw safeFailure(`${context}: JWT JSON is not valid UTF-8`);
  }
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw safeFailure(`${context}: JWT JSON is invalid`);
  }
  if (!isPlainObject(parsed)) {
    throw safeFailure(`${context}: JWT JSON is not an object`);
  }
  return parsed;
}

export function validateIssuancePayload(
  value,
  nowSeconds,
  expectedKid,
) {
  if (!exactKeys(value, ["token", "issuedAt", "expiresAt"])) {
    throw safeFailure("Issuance response shape is invalid");
  }
  if (
    typeof value.token !== "string" ||
    value.token.length === 0 ||
    value.token.length > 16 * 1_024 ||
    !Number.isSafeInteger(value.issuedAt) ||
    !Number.isSafeInteger(value.expiresAt)
  ) {
    throw safeFailure("Issuance response fields are invalid");
  }

  const segments = value.token.split(".");
  if (segments.length !== 3) {
    throw safeFailure("Issued JWT must have three segments");
  }
  const header = decodeJwtObject(segments[0], "JWT header");
  const payload = decodeJwtObject(segments[1], "JWT payload");
  const signature = base64UrlDecode(segments[2], "JWT signature");
  if (
    !exactKeys(header, ["alg", "typ", "kid"]) ||
    header.alg !== "RS256" ||
    header.typ !== "JWT" ||
    header.kid !== expectedKid
  ) {
    throw safeFailure("Issued JWT header does not match the expected kid");
  }
  if (
    !exactKeys(payload, ["iat", "exp"]) ||
    !Number.isSafeInteger(payload.iat) ||
    !Number.isSafeInteger(payload.exp) ||
    payload.iat !== value.issuedAt ||
    payload.exp !== value.expiresAt
  ) {
    throw safeFailure("Issued JWT claims are invalid");
  }
  if (signature.byteLength !== 256) {
    throw safeFailure("Issued JWT is not signed with an RSA-2048 signature");
  }

  const ttlSeconds = value.expiresAt - value.issuedAt;
  if (ttlSeconds !== REQUIRED_JWT_TTL_SECONDS) {
    throw safeFailure(
      `Issued JWT lifetime is ${ttlSeconds}s, expected ${REQUIRED_JWT_TTL_SECONDS}s`,
    );
  }
  if (
    value.issuedAt < nowSeconds - CLOCK_SKEW_SECONDS ||
    value.issuedAt > nowSeconds + CLOCK_SKEW_SECONDS ||
    value.expiresAt <= nowSeconds
  ) {
    throw safeFailure("Issued JWT timestamps are outside the accepted window");
  }
  return value.token;
}

async function runBrokerContractProbes(brokerURL, options) {
  const routeURL = new URL(brokerURL);
  routeURL.pathname = `${BROKER_PATH}/not-found`;
  const attestationHeaders = overrideHeaders(options);
  const probes = [
    {
      name: "method",
      url: brokerURL,
      init: { method: "GET", headers: attestationHeaders },
      expectedStatus: 405,
      verify(response) {
        if (response.headers.get("allow") !== "POST") {
          throw safeFailure("method probe: Allow header is not POST");
        }
      },
    },
    {
      name: "route",
      url: routeURL,
      init: {
        method: "POST",
        headers: {
          ...attestationHeaders,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          installationId: randomUUID().toLowerCase(),
        }),
      },
      expectedStatus: 404,
    },
    {
      name: "malformed",
      url: brokerURL,
      init: {
        method: "POST",
        headers: {
          ...attestationHeaders,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          installationId: "not-a-canonical-uuid",
        }),
      },
      expectedStatus: 400,
    },
  ];

  for (const probe of probes) {
    const { response } = await fetchBoundedWithTimeout(
      probe.url,
      probe.init,
      options.timeoutMs,
      MAX_BROKER_RESPONSE_BYTES,
      `${probe.name} probe`,
    );
    assertBrokerHeaders(
      response,
      `${probe.name} probe`,
      options.expectedVersion,
    );
    if (response.status !== probe.expectedStatus) {
      throw safeFailure(
        `${probe.name} probe: received HTTP ${response.status}, expected ${probe.expectedStatus}`,
      );
    }
    probe.verify?.(response);
  }
  return probes.length;
}

async function acquireToken(brokerURL, options) {
  const { response, bytes } = await fetchBoundedWithTimeout(
    brokerURL,
    {
      method: "POST",
      headers: {
        ...overrideHeaders(options),
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        installationId: randomUUID().toLowerCase(),
      }),
    },
    options.timeoutMs,
    MAX_BROKER_RESPONSE_BYTES,
    "issuance",
  );
  assertBrokerHeaders(response, "issuance", options.expectedVersion);
  if (response.status !== 200) {
    throw safeFailure(`Issuance failed with HTTP ${response.status}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw safeFailure("Issuance response is not valid JSON");
  }
  return validateIssuancePayload(
    parsed,
    Math.floor(Date.now() / 1_000),
    options.expectedKid,
  );
}

function rpcBody(target) {
  if (target.kind === "solana") {
    return JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "getVersion",
      params: [],
    });
  }
  return JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_chainId",
    params: [],
  });
}

function boundedRetryAfterMilliseconds(response, nowMilliseconds = Date.now()) {
  const value = response.headers.get("retry-after")?.trim();
  if (value === undefined || value === "") {
    return undefined;
  }

  let delayMilliseconds;
  if (/^(0|[1-9][0-9]*)$/u.test(value)) {
    const seconds = Number(value);
    if (!Number.isSafeInteger(seconds)) {
      return undefined;
    }
    delayMilliseconds = seconds * 1_000;
  } else {
    const retryAt = Date.parse(value);
    if (!Number.isFinite(retryAt)) {
      return undefined;
    }
    delayMilliseconds = Math.max(0, retryAt - nowMilliseconds);
  }
  return Math.min(delayMilliseconds, RPC_RETRY_CAP_MS);
}

export async function validateRpcAttempt(
  target,
  token,
  timeoutMs,
  fetchImplementation = fetch,
) {
  let response;
  let bytes;
  try {
    ({ response, bytes } = await fetchBoundedWithTimeout(
      target.url,
      {
        method: "POST",
        redirect: "manual",
        headers: {
          Accept: "application/json",
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: rpcBody(target),
      },
      timeoutMs,
      MAX_RPC_RESPONSE_BYTES,
      "RPC",
      {
        fetchImplementation,
        readNonSuccessBody: false,
      },
    ));
  } catch (error) {
    if (error instanceof SafeValidationError) {
      if (error.kind === "timeout" || error.kind === "network") {
        return {
          host: target.host,
          status: "-",
          result: error.kind,
          ok: false,
          retryable: true,
        };
      }
      if (error.kind === "response-too-large") {
        return {
          host: target.host,
          status: "-",
          result: "response-too-large",
          ok: false,
          retryable: false,
        };
      }
    }
    return {
      host: target.host,
      status: "-",
      result: "network",
      ok: false,
      retryable: true,
    };
  }

  if (response.status < 200 || response.status >= 300) {
    const status = response.status;
    const retryable =
      [408, 425, 429].includes(status) || (status >= 500 && status <= 599);
    let result = "http-error";
    if (status === 401) {
      result = "auth-rejected";
    } else if (status === 403) {
      result = "forbidden";
    } else if (status === 429) {
      result = "rate-limited";
    } else if (retryable) {
      result = "transient-http";
    }
    return {
      host: target.host,
      status,
      result,
      ok: false,
      retryable,
      retryAfterMs: retryable
        ? boundedRetryAfterMilliseconds(response)
        : undefined,
    };
  }

  let parsed;
  try {
    parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
  } catch {
    return {
      host: target.host,
      status: response.status,
      result: "malformed-json",
      ok: false,
      retryable: false,
    };
  }
  if (!isPlainObject(parsed) || parsed.jsonrpc !== "2.0" || parsed.id !== 1) {
    return {
      host: target.host,
      status: response.status,
      result: "malformed-rpc",
      ok: false,
      retryable: false,
    };
  }
  if (Object.hasOwn(parsed, "error")) {
    return {
      host: target.host,
      status: response.status,
      result: "rpc-error",
      ok: false,
      retryable: false,
    };
  }
  if (!Object.hasOwn(parsed, "result")) {
    return {
      host: target.host,
      status: response.status,
      result: "missing-result",
      ok: false,
      retryable: false,
    };
  }
  if (
    target.kind === "evm" &&
    (typeof parsed.result !== "string" ||
      !/^0x[0-9a-f]+$/iu.test(parsed.result))
  ) {
    return {
      host: target.host,
      status: response.status,
      result: "invalid-chain-id",
      ok: false,
      retryable: false,
    };
  }
  if (
    target.kind === "solana" &&
    (
      !isPlainObject(parsed.result) ||
      typeof parsed.result["solana-core"] !== "string" ||
      parsed.result["solana-core"].trim() === "" ||
      parsed.result["solana-core"].length > 256 ||
      !Number.isSafeInteger(parsed.result["feature-set"]) ||
      parsed.result["feature-set"] < 0
    )
  ) {
    return {
      host: target.host,
      status: response.status,
      result: "invalid-version",
      ok: false,
      retryable: false,
    };
  }
  return {
    host: target.host,
    status: response.status,
    result: "ok",
    ok: true,
    retryable: false,
  };
}

function retryDelay(attempt, randomImplementation) {
  const ceiling = Math.min(
    RPC_RETRY_BASE_MS * (2 ** (attempt - 1)),
    RPC_RETRY_CAP_MS,
  );
  return Math.floor((ceiling / 2) + (randomImplementation() * ceiling / 2));
}

export async function validateRpcTarget(
  target,
  token,
  {
    timeoutMs,
    rpcAttempts,
    fetchImplementation = fetch,
    sleepImplementation = (milliseconds) =>
      new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds)),
    randomImplementation = Math.random,
  },
) {
  for (let attempt = 1; attempt <= rpcAttempts; attempt += 1) {
    const result = await validateRpcAttempt(
      target,
      token,
      timeoutMs,
      fetchImplementation,
    );
    if (result.ok) {
      return { ...result, attempts: attempt, classification: "ok" };
    }
    if (!result.retryable) {
      return {
        ...result,
        attempts: attempt,
        classification: "deterministic",
      };
    }
    if (attempt === rpcAttempts) {
      return {
        ...result,
        attempts: attempt,
        classification: "transient-exhausted",
      };
    }
    const backoff = retryDelay(attempt, randomImplementation);
    const retryAfter = result.retryAfterMs ?? 0;
    await sleepImplementation(
      Math.min(Math.max(backoff, retryAfter), RPC_RETRY_CAP_MS),
    );
  }
  throw safeFailure("RPC retry loop exhausted unexpectedly");
}

async function validateTargets(
  targets,
  token,
  options,
  onResult,
  validateTargetImplementation,
) {
  const results = new Array(targets.length);
  let nextIndex = 0;
  async function worker() {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= targets.length) {
        return;
      }
      const result = await validateTargetImplementation(
        targets[index],
        token,
        options,
      );
      results[index] = result;
      onResult(result);
    }
  }
  await Promise.all(
    Array.from(
      { length: Math.min(options.concurrency, targets.length) },
      () => worker(),
    ),
  );
  return results;
}

export async function validateRpcMatrix(
  targets,
  token,
  options,
  onResult,
  validateTargetImplementation = validateRpcTarget,
) {
  const canaryIndex = targets.findIndex(
    (target) => target.host === "eth-mainnet.g.alchemy.com",
  );
  if (canaryIndex === -1) {
    throw safeFailure("RPC matrix is missing the eth-mainnet canary");
  }
  const canary = await validateTargetImplementation(
    targets[canaryIndex],
    token,
    options,
  );
  onResult(canary);
  if (!canary.ok) {
    return { results: [canary], stoppedAfterCanary: true };
  }

  const remaining = targets.filter((_, index) => index !== canaryIndex);
  const results = await validateTargets(
    remaining,
    token,
    options,
    onResult,
    validateTargetImplementation,
  );
  return {
    results: [canary, ...results],
    stoppedAfterCanary: false,
  };
}

function encodeJsonSegment(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

function successfulRpcResponse() {
  return new Response(
    JSON.stringify({ jsonrpc: "2.0", id: 1, result: "0x1" }),
    { status: 200, headers: { "Content-Type": "application/json" } },
  );
}

async function runSelfTest(catalogPath, expectedEvmHosts) {
  const evmTargets = await loadEvmTargets(catalogPath, expectedEvmHosts);
  assert.equal(evmTargets.length, expectedEvmHosts);
  assert.equal(
    new Set(evmTargets.map((target) => target.host)).size,
    expectedEvmHosts,
  );
  assert.ok(
    evmTargets.every(
      (target) =>
        target.url === `https://${target.host}/v2` &&
        target.kind === "evm",
    ),
  );

  const testKid = "self-test-key";
  const nowSeconds = 1_800_000_000;
  const expiresAt = nowSeconds + REQUIRED_JWT_TTL_SECONDS;
  const token = [
    encodeJsonSegment({ alg: "RS256", typ: "JWT", kid: testKid }),
    encodeJsonSegment({ iat: nowSeconds, exp: expiresAt }),
    Buffer.alloc(256, 1).toString("base64url"),
  ].join(".");
  assert.equal(
    validateIssuancePayload(
      { token, issuedAt: nowSeconds, expiresAt },
      nowSeconds,
      testKid,
    ),
    token,
  );
  assert.throws(
    () =>
      validateIssuancePayload(
        { token, issuedAt: nowSeconds, expiresAt },
        nowSeconds,
        "wrong-key",
      ),
    SafeValidationError,
  );

  const version = "f1bc23fe-48a6-487b-b42f-f5f0fef1a1c9";
  const validResponse = new Response("{}", {
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "Strict-Transport-Security": HSTS_POLICY,
      "X-Alchemy-JWT-Worker-Version": version,
      "X-Content-Type-Options": "nosniff",
    },
  });
  assert.doesNotThrow(() =>
    assertBrokerHeaders(validResponse, "self-test", version),
  );

  const calls = [];
  const sleeps = [];
  const target = {
    kind: "evm",
    host: "eth-mainnet.g.alchemy.com",
    url: "https://eth-mainnet.g.alchemy.com/v2",
  };
  const responses = [
    new Response("", { status: 503 }),
    successfulRpcResponse(),
  ];
  const retryResult = await validateRpcTarget(target, "redacted", {
    timeoutMs: 1_000,
    rpcAttempts: 3,
    fetchImplementation: async () => {
      calls.push(true);
      return responses.shift();
    },
    sleepImplementation: async (milliseconds) => {
      sleeps.push(milliseconds);
    },
    randomImplementation: () => 0.5,
  });
  assert.equal(retryResult.ok, true);
  assert.equal(retryResult.attempts, 2);
  assert.equal(calls.length, 2);
  assert.equal(sleeps.length, 1);

  let deterministicCalls = 0;
  const deterministicResult = await validateRpcTarget(target, "redacted", {
    timeoutMs: 1_000,
    rpcAttempts: 5,
    fetchImplementation: async () => {
      deterministicCalls += 1;
      return new Response("", { status: 401 });
    },
  });
  assert.equal(deterministicResult.classification, "deterministic");
  assert.equal(deterministicCalls, 1);

  console.log(
    `self-test: pass evm=${evmTargets.length} solana=${solanaTargets().length} retry-policy=pass`,
  );
}

function printRpcResult(result) {
  console.log(
    `${result.host}\t${result.status}\t${result.result}\tattempts=${result.attempts}`,
  );
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }
  const brokerURL = parseBrokerURL(options.brokerURL);
  const catalogPath = resolve(options.catalogPath);
  if (options.selfTest) {
    await runSelfTest(catalogPath, options.expectedEvmHosts);
    return;
  }

  const evmTargets = await loadEvmTargets(
    catalogPath,
    options.expectedEvmHosts,
  );
  const targets = [...evmTargets, ...solanaTargets()];
  if (options.dryRun) {
    console.log(
      [
        "dry-run: pass",
        `broker=${brokerURL.host}`,
        `evm=${evmTargets.length}`,
        `solana=${targets.length - evmTargets.length}`,
        `total=${targets.length}`,
        `concurrency=${options.concurrency}`,
        `rpc-attempts=${options.rpcAttempts}`,
        `expected-ttl=${REQUIRED_JWT_TTL_SECONDS}`,
        `attestation=${options.expectedKid !== undefined && options.expectedVersion !== undefined ? "provided" : "not-provided"}`,
        `version-override=${options.versionOverride}`,
      ].join(" "),
    );
    return;
  }

  requireLiveAttestation(options);
  await probeHttpRedirect(brokerURL, options.timeoutMs);
  console.log("http-redirect: pass status=308 exact-location=true");

  const versionAttempts = await waitForExpectedVersion(brokerURL, options);
  console.log(
    `worker-version: pass attempts=${versionAttempts} override=${options.versionOverride}`,
  );

  const probeCount = await runBrokerContractProbes(brokerURL, options);
  console.log(`broker-contract: pass probes=${probeCount}`);

  let token = "";
  try {
    token = await acquireToken(brokerURL, options);
    console.log(
      `issuance: pass ttl=${REQUIRED_JWT_TTL_SECONDS}s kid-match=true version-match=true no-store=true no-cors=true`,
    );

    const { results, stoppedAfterCanary } = await validateRpcMatrix(
      targets,
      token,
      {
        timeoutMs: options.timeoutMs,
        rpcAttempts: options.rpcAttempts,
        concurrency: options.concurrency,
      },
      printRpcResult,
    );
    const successes = results.filter((result) => result.ok).length;
    const deterministic = results.filter(
      (result) => result.classification === "deterministic",
    ).length;
    const transientExhausted = results.filter(
      (result) => result.classification === "transient-exhausted",
    ).length;
    console.log(
      `rpc-summary: total=${results.length} ok=${successes} deterministic=${deterministic} transient-exhausted=${transientExhausted}`,
    );
    if (stoppedAfterCanary) {
      console.log("rpc-canary: failed full-matrix-skipped=true");
    }
    if (successes !== results.length) {
      process.exitCode = 1;
    }
  } finally {
    token = "";
  }
}

const isDirectExecution =
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isDirectExecution) {
  try {
    await main();
  } catch (error) {
    const message =
      error instanceof SafeValidationError
        ? error.message
        : "Unexpected validation failure";
    console.error(`live-validation: failed: ${message}`);
    process.exitCode = 1;
  }
}
