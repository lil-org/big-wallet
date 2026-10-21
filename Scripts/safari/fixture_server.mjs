import {createServer} from "node:http";
import {createRequire} from "node:module";
import {randomBytes, randomUUID} from "node:crypto";
import {constants} from "node:fs";
import {readFile, writeFile, rename, mkdir, realpath, open, lstat, unlink} from "node:fs/promises";
import {dirname, join} from "node:path";
import {userInfo} from "node:os";
import {execFile} from "node:child_process";
import {promisify} from "node:util";
import {SAFARI_SCENARIOS} from "./scenarios.mjs";
import {NativeEvidenceReader} from "./native_evidence.mjs";
import {assertEthereumSignature, assertEthereumTransaction, assertSolanaSignature, assertSolanaTransaction} from "../approval_lifecycle/crypto_assertions.mjs";

const require = createRequire(new URL("../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {keccak_256} = require("@noble/hashes/sha3");
const {secp256k1} = require("@noble/curves/secp256k1");
const {ed25519} = require("@noble/curves/ed25519");
const bs58 = require("bs58");
const base58 = bs58.default || bs58;
const {Transaction, SystemProgram, PublicKey} = require("@solana/web3.js");
const exec = promisify(execFile);
const json = value => JSON.stringify(value);
const maxBody = 4 * 1024 * 1024;
const maximumWebsiteOrigins = SAFARI_SCENARIOS.length * 24;
const maximumOriginRegistryBytes = 64 * 1024;
const canonicalUUID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const ethereumSendActions = new Set(["ethereum-send", "ethereum-send-custom", "ethereum-send-estimated"]);
const lockProbeScenarios = new Set(["install-native-roundtrip", "ethereum-signing"]);
const zeroSigningScenarios = new Set(["install-native-roundtrip", "profiles-private",
    "authority-revocation", "malformed-requests"]);
const oneSigningScenarios = new Set(["ethereum-signing", "solana-signing", "rejection-duplicate-approval",
    "ethereum-broadcast", "solana-broadcast", "navigation-tab-closure", "macos-auth-isolation", "browser-restart",
    "background-foreground", "fee-auth-cancel", "ambiguous-broadcast", "rpc-failure-capacity", "native-process-recovery",
    "document-reload", "account-chain-switch", "fee-change-reapproval", "nonce-editor", "account-removal",
    "vault-replacement", "custom-network-replacement"]);
const hex = bytes => "0x" + Buffer.from(bytes).toString("hex");

export async function atomicJSON(path, value) {
    const temporary = `${path}.${randomUUID()}.tmp`;
    await writeFile(temporary, json(value), {mode: 0o600, flag: "wx"});
    await rename(temporary, path);
}

export function fixtures() {
    const ethereum = hex(keccak_256(secp256k1.getPublicKey(Buffer.alloc(32, 1), false).subarray(1)).subarray(12));
    const solana = base58.encode(ed25519.getPublicKey(Buffer.alloc(32, 2)));
    const message = "Big Wallet isolated Safari lifecycle test";
    const alternateAddresses = {ethereum: "0x9858EffD232B4033E47d90003D41EC34EcaEda94", solana: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"};
    return {addresses: {ethereum, solana}, alternateAddresses, message, messageHex: hex(Buffer.from(message)),
        ethereumTransaction: {to: "0x2222222222222222222222222222222222222222", value: "0x1", data: "0x", nonce: "0x0", gas: "0xc350", gasPrice: "0x77359400", chainId: "0x1"}};
}

function solanaTransfer(address, lamports, recentBlockhash) {
    const transaction = new Transaction({feePayer: new PublicKey(address), recentBlockhash});
    transaction.add(SystemProgram.transfer({fromPubkey: new PublicKey(address), toPubkey: new PublicKey(Buffer.alloc(32, 4)), lamports}));
    return {transaction: base58.encode(transaction.serialize({requireAllSignatures: false, verifySignatures: false})),
        message: base58.encode(transaction.serializeMessage()), messageHash: hex(keccak_256(transaction.serializeMessage()))};
}

async function body(request) {
    const parts = [];
    let length = 0;
    for await (const chunk of request) {
        length += chunk.length;
        if (length > maxBody) { throw new Error("Request exceeds fixture limit"); }
        parts.push(chunk);
    }
    return parts.length ? JSON.parse(Buffer.concat(parts).toString("utf8")) : {};
}

function respond(response, status, value, type = "application/json") {
    response.writeHead(status, {"Content-Type": type, "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"});
    response.end(type === "application/json" ? json(value) : value);
}

function writeGuestClipboard(value) {
    return new Promise((resolve, reject) => {
        const child = execFile("/usr/bin/pbcopy", [], {timeout: 5000, maxBuffer: 1024, env: {...process.env, LC_ALL: "en_US.UTF-8"}}, error => {
            if (error) { reject(new Error("Guest credential transfer failed")); }
            else { resolve(); }
        });
        child.stdin.on("error", () => {});
        child.stdin.end(value);
    });
}

export async function inspectProcess(processID, command = exec, wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))) {
    if (!Number.isInteger(processID) || processID <= 1) { throw new Error("Invalid process inspection identity"); }
    const attempts = [];
    const bounded = (value, maximum) => {
        const bytes = Buffer.from(value);
        let end = Math.min(bytes.length, maximum);
        while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) { end -= 1; }
        return bytes.subarray(0, end).toString("utf8");
    };
    for (let attempt = 0; attempt < 2; attempt += 1) {
        let output;
        try {
            output = (await command("/bin/ps", ["-ww", "-p", String(processID), "-o", "stat=", "-o", "comm="],
                {timeout: 5000, maxBuffer: 8192, env: {...process.env, LC_ALL: "C"}})).stdout;
        } catch (error) {
            if (error.code === 1 && !error.killed && !error.signal &&
                typeof error.stdout === "string" && !error.stdout.trim() &&
                typeof error.stderr === "string" && !error.stderr.trim()) { return null; }
            throw error;
        }
        const row = typeof output === "string" && /^\s*([IRSTUZ][^\s]*)[ \t]+([^\r\n]+)\s*$/.exec(output);
        if (row?.[1].startsWith("Z")) { return null; }
        if (row && row[2].startsWith("/") && !row[2].includes("\0")) { return row[2].trimEnd(); }
        const metadata = typeof output === "string" && /^\s*(\S+)[ \t]+([^\r\n]+)\s*$/.exec(output);
        attempts.push({attempt: attempt + 1, stat: metadata ? bounded(metadata[1], 32) : null,
            comm: metadata ? bounded(metadata[2].trimEnd(), 512) : null,
            ...(metadata ? {} : {output: typeof output === "string" ? bounded(output, 512) : null}),
            truncated: typeof output === "string" && Buffer.byteLength(output) > 512});
        if (attempt === 0) { await wait(100); }
    }
    throw new Error("Live process executable identity is unavailable: " + JSON.stringify({processID, attempts}));
}

export class SafariFixtureServer {
    constructor({descriptor, iterations = 1, stageId, artifacts, interactiveActivation = false, preparedActivation = false,
        preparation, preparationNonce, guestCredentialPath, clipboardWriter = writeGuestClipboard,
        processInspector = inspectProcess, processTerminator = (pid, signal) => process.kill(pid, signal),
        httpServerFactory = createServer}) {
        this.descriptor = descriptor;
        if (typeof interactiveActivation !== "boolean" || interactiveActivation && descriptor.platform !== "macos") {
            throw new Error("Interactive activation requires macOS Safari");
        }
        if (typeof preparedActivation !== "boolean" || preparedActivation &&
            (descriptor.platform !== "macos" || descriptor.signingMode !== "local" || interactiveActivation || preparationNonce !== undefined ||
             !preparation || typeof preparation !== "object" || Array.isArray(preparation) ||
             Object.keys(preparation).sort().join(",") !== "preparationRunID,receiptSHA256" ||
             typeof preparation.preparationRunID !== "string" ||
             !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(preparation.preparationRunID) ||
             preparation.preparationRunID.includes("..") ||
             typeof preparation.receiptSHA256 !== "string" || !/^[0-9a-f]{64}$/.test(preparation.receiptSHA256)) ||
            !preparedActivation && preparation !== undefined) {
            throw new Error("Prepared activation requires verified macOS preparation provenance");
        }
        if (preparationNonce !== undefined && (descriptor.platform !== "macos" || descriptor.signingMode !== "local" || interactiveActivation ||
            typeof preparationNonce !== "string" || !canonicalUUID.test(preparationNonce))) {
            throw new Error("Safari activation preparation requires a canonical macOS preparation nonce");
        }
        this.interactiveActivation = interactiveActivation;
        this.activationMode = preparedActivation ? "prepared" : interactiveActivation ? "interactive" : "automatic";
        this.preparation = preparation === undefined ? undefined : {...preparation};
        this.preparationNonce = preparationNonce;
        this.activationRequests = [];
        this.iterations = iterations;
        this.stageId = stageId;
        this.artifacts = artifacts;
        this.guestCredentialPath = guestCredentialPath ?? join("/Volumes/BigWalletBuild/Exchange", descriptor.runID, "safari/guest-credential.json");
        this.clipboardWriter = clipboardWriter;
        this.guestCredentialStaged = false;
        this.guestCredentialTimer = null;
        this.guestCredentialGeneration = 0;
        this.credentialQueue = Promise.resolve();
        this.closing = false;
        this.processInspector = processInspector;
        this.processTerminator = processTerminator;
        this.httpServerFactory = httpServerFactory;
        this.originRegistryQueue = Promise.resolve();
        this.originRegistrySeen = false;
        this.candidateServers = new Set();
        this.token = randomBytes(32).toString("hex");
        this.pageToken = randomBytes(32).toString("hex");
        this.fixture = fixtures();
        this.fixture.solanaBlockhash = base58.encode(keccak_256(Buffer.from(`${descriptor.runID}:${stageId}`)));
        this.current = null;
        this.recoveryRequired = false;
        this.requiresApprovalDrain = false;
        this.results = [];
        this.started = new Map();
        this.documents = new Map();
        this.scenarioOrigins = new Map();
        this.solanaRequests = new Map();
        this.solanaSigningRequests = new Map();
        this.solanaSequence = 0;
        this.broadcasts = [];
        this.processFaults = [];
        this.scenarios = [];
        this.scenarioStarts = new Set();
        this.evidence = [];
        this.errors = [];
        this.providerReady = false;
        this.nativeReady = false;
        this.rpcMode = "normal";
        this.feeMultiplier = 1;
        this.preparationMode = "normal";
        this.preparationWaiters = new Set();
        this.broadcastMode = "normal";
        this.gates = {};
        this.servers = [];
        this.activeRequests = new Set();
        this.browser = null;
        this.extension = null;
        this.runtime = null;
        this.stageEventOffset = 0;
        this.scenarioEventOffset = 0;
        this.allowedExecutables = new Set();
        this.registrationRefreshes = [];
        this.registrationRefresh = null;
        this.lockProbe = null;
        this.cleanup = {status: "pending"};
        this.rpcWaiters = new Set();
        this.rpcPeak = 0;
        this.rpcHeldByProcess = new Map();
        this.rpcOutcomes = [];
        this.nativeReader = new NativeEvidenceReader(join(descriptor.root, "native-events.ndjson"), {runID: descriptor.runID});
    }

    async start() {
        this.stageEventOffset = (await this.nativeEvents()).length;
        this.scenarioEventOffset = this.stageEventOffset;
        this.nativeReady = false;
        try {
            await this.withOriginRegistry(() => this.readOriginRegistry());
            this.url = await this.listen();
            this.fixture.customNetwork = {chainId: 64001, name: "Safari Fixture Network", rpcURL: "https://safari-fixture.invalid/rpc/ethereum?chainId=64001&configuration=original", replacementRPCURL: "https://safari-fixture.invalid/rpc/ethereum?chainId=64001&configuration=replaced"};
            await atomicJSON(join(this.descriptor.root, "control.json"), {url: this.url, token: this.token});
            await atomicJSON(join(this.descriptor.root, "gates.json"), {});
            return this;
        } catch (error) {
            for (const server of [...this.servers, ...this.candidateServers]) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
            throw error;
        }
    }

    async listen(scenario = null) {
        if (this.servers.length >= 1 + SAFARI_SCENARIOS.length * this.iterations * 2) { throw new Error("Safari fixture origin limit exceeded"); }
        for (let attempt = 0; attempt < 32; attempt += 1) {
            if (this.closing) { throw new Error("Safari fixture is closing"); }
            const context = {scenario, origin: null, ready: false};
            const server = this.httpServerFactory((request, response) => {
                if (this.closing) { respond(response, 503, {error: "Safari fixture is closing"}); return; }
                if (!context.ready) { respond(response, 503, {error: "Website origin reservation is pending"}); return; }
                const pending = this.handle(request, response, context).catch(error => {
                    if (this.errors.length < 256) { this.errors.push(String(error.message).slice(0, 2048)); }
                    if (response.destroyed) { return; }
                    if (!response.headersSent) { respond(response, 400, {error: error.message}); }
                    else { response.destroy(); }
                });
                this.activeRequests.add(pending);
                pending.then(() => this.activeRequests.delete(pending), () => this.activeRequests.delete(pending));
            });
            this.candidateServers.add(server);
            let accepted = false;
            try {
                server.requestTimeout = 10000;
                server.maxConnections = 256;
                await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
                context.origin = "http://127.0.0.1:" + server.address().port;
                if (scenario && !await this.reserveWebsiteOrigin(context.origin)) { continue; }
                if (this.closing) { throw new Error("Safari fixture is closing"); }
                context.ready = true;
                accepted = true;
                this.servers.push(server);
                return context.origin;
            } finally {
                if (!accepted) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
                this.candidateServers.delete(server);
            }
        }
        throw new Error("Safari could not reserve a fresh website origin within its retry limit");
    }

    get originRegistryRoot() {
        return this.descriptor.signingMode === "apple" ? dirname(this.descriptor.root) : this.descriptor.root;
    }

    originRegistryIdentity() {
        const {version, runID, platform, configuration} = this.descriptor;
        if (version !== 1 || typeof runID !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runID) || runID.includes("..") ||
            !["macos", "ios"].includes(platform) || !["Debug", "Release"].includes(configuration)) {
            throw new Error("Invalid website origin registry identity");
        }
        return {version: 1, runID, platform, configuration: this.descriptor.signingMode === "apple" ? null : configuration};
    }

    async readOriginRegistry() {
        const identity = this.originRegistryIdentity();
        let file;
        try { file = await open(join(this.originRegistryRoot, "website-origins.json"), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
        catch (error) {
            if (error.code !== "ENOENT") { throw error; }
            if (this.originRegistrySeen || this.stageId.startsWith("safari.soak-")) {
                throw new Error("Website origin registry disappeared or is missing before the soak");
            }
            return {...identity, origins: []};
        }
        try {
            const info = await file.stat();
            if (!info.isFile() || info.uid !== process.getuid() || info.nlink !== 1 || (info.mode & 0o7777) !== 0o600 ||
                info.size < 1 || info.size > maximumOriginRegistryBytes) { throw new Error("Unsafe website origin registry file"); }
            const bytes = Buffer.alloc(maximumOriginRegistryBytes + 1);
            let length = 0;
            while (length < bytes.length) {
                const {bytesRead} = await file.read(bytes, length, bytes.length - length, length);
                if (!bytesRead) { break; }
                length += bytesRead;
            }
            const after = await file.stat();
            if (length !== info.size || after.size !== info.size || after.mtimeMs !== info.mtimeMs || after.ctimeMs !== info.ctimeMs) {
                throw new Error("Website origin registry changed while reading");
            }
            let registry;
            try { registry = JSON.parse(bytes.subarray(0, length).toString("utf8")); }
            catch { throw new Error("Malformed website origin registry"); }
            if (!registry || Array.isArray(registry) || typeof registry !== "object" ||
                Object.keys(registry).sort().join(",") !== "configuration,origins,platform,runID,version" ||
                Object.entries(identity).some(([key, value]) => registry[key] !== value) ||
                !Array.isArray(registry.origins) || registry.origins.length > maximumWebsiteOrigins ||
                new Set(registry.origins).size !== registry.origins.length || registry.origins.some(origin => {
                    if (typeof origin !== "string") { return true; }
                    const port = /^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})$/.exec(origin)?.[1];
                    return !port || Number(port) > 65535;
                })) { throw new Error("Malformed or mismatched website origin registry"); }
            this.originRegistrySeen = true;
            return registry;
        } finally { await file.close(); }
    }

    withOriginRegistry(operation) {
        const pending = this.originRegistryQueue.then(async () => {
            const root = this.originRegistryRoot;
            const directory = await lstat(root);
            if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid() ||
                directory.mode & 0o077 || await realpath(root) !== root) { throw new Error("Unsafe website origin registry directory"); }
            const path = join(root, ".website-origins.lock");
            let lock;
            for (let attempt = 0; attempt < 50; attempt += 1) {
                try { lock = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600); break; }
                catch (error) { if (error.code !== "EEXIST") { throw error; } }
                let info;
                try { info = await lstat(path); } catch (error) { if (error.code === "ENOENT") { continue; } throw error; }
                if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || info.nlink !== 1 ||
                    (info.mode & 0o7777) !== 0o600) { throw new Error("Unsafe website origin registry lock"); }
                await new Promise(resolve => setTimeout(resolve, 20));
            }
            if (!lock) { throw new Error("Website origin registry is busy"); }
            try { return await operation(); }
            finally {
                const held = await lock.stat();
                await lock.close();
                const current = await lstat(path);
                if (!current.isFile() || current.isSymbolicLink() || current.dev !== held.dev || current.ino !== held.ino) {
                    throw new Error("Website origin registry lock ownership changed");
                }
                await unlink(path);
            }
        });
        this.originRegistryQueue = pending.catch(() => {});
        return pending;
    }

    reserveWebsiteOrigin(origin) {
        return this.withOriginRegistry(async () => {
            const registry = await this.readOriginRegistry();
            if (registry.origins.includes(origin)) { return false; }
            if (registry.origins.length >= maximumWebsiteOrigins) { throw new Error("Website origin registry limit exceeded"); }
            registry.origins.push(origin);
            await atomicJSON(join(this.originRegistryRoot, "website-origins.json"), registry);
            this.originRegistrySeen = true;
            return true;
        });
    }

    async nativeEvents() {
        const events = await this.nativeReader.read();
        for (let index = this.validatedPreparationEvents ?? 0; index < events.length; index += 1) {
            const event = events[index];
            if (event.kind !== "safariExtensionState" || !Object.hasOwn(event, "preparationNonce")) { continue; }
            const success = typeof event.enabled === "boolean" && event.errorDomain === null && event.errorCode === null;
            const failure = event.enabled === null && typeof event.errorDomain === "string" &&
                event.errorDomain.length > 0 && event.errorDomain.length <= 128 && Number.isSafeInteger(event.errorCode);
            if (typeof event.preparationNonce !== "string" || !canonicalUUID.test(event.preparationNonce) ||
                !Number.isSafeInteger(event.processID) || event.processID <= 1 ||
                typeof event.incarnation !== "string" || !canonicalUUID.test(event.incarnation) ||
                !Number.isFinite(event.time) || event.time <= 0 ||
                event.scenario !== null || event.iteration !== null || event.requestID !== null || !(success || failure)) {
                throw new Error("Invalid Safari activation preparation native state evidence");
            }
        }
        this.validatedPreparationEvents = events.length;
        this.nativeReady ||= events.slice(this.stageEventOffset).some(event => this.isSiteIngress(event));
        return events;
    }

    isSiteIngress(event) {
        const scenario = this.scenarioOrigins.get(event.configurationKey);
        return event.kind === "nativeIngress" && event.source === "site" && scenario !== undefined &&
            event.scenario === scenario.id && event.iteration === scenario.iteration &&
            event.host === new URL(event.configurationKey).host && typeof event.privateBrowsing === "boolean" &&
            Number.isInteger(event.tabID) && event.tabID >= 0 && Number.isInteger(event.frameID) && event.frameID >= 0 &&
            typeof event.documentID === "string" && event.documentID.length > 0 && event.documentID.length <= 256 &&
            Object.hasOwn(event, "profileIdentifier") && (event.profileIdentifier === null ||
                (typeof event.profileIdentifier === "string" && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(event.profileIdentifier)));
    }

    async state() {
        const events = (await this.nativeEvents()).slice(this.scenarioEventOffset).filter(event => event.scenario === this.current?.id &&
            event.iteration === this.current?.iteration);
        return {scenario: this.current, results: this.results, events, broadcasts: this.broadcasts, errors: this.errors, processFaults: this.processFaults,
            registrationRefreshes: this.registrationRefreshes,
            activationRequests: this.activationRequests,
            lockProbe: this.lockProbe,
            rpc: {held: this.rpcWaiters.size, peak: this.rpcPeak, outcomes: this.rpcOutcomes, preparationHeld: this.preparationWaiters.size},
            handshake: {provider: this.providerReady, native: events.some(event => this.isSiteIngress(event))}};
    }

    async handle(request, response, context) {
        const url = new URL(request.url, context.origin);
        if (url.pathname.startsWith("/control/")) {
            if (context.scenario || request.headers.authorization !== `Bearer ${this.token}`) { respond(response, 403, {error: "Control authentication required"}); return; }
            const value = await body(request);
            switch (url.pathname) {
            case "/control/config":
                respond(response, 200, {...this.fixture, dappURL: this.dappURL ?? this.url, secondOriginURL: this.secondURL ?? this.url,
                    fixtureRoot: this.descriptor.root, platform: this.descriptor.platform, iterations: this.iterations,
                    signingMode: this.descriptor.signingMode,
                    activationMode: this.activationMode,
                    interactiveActivation: this.interactiveActivation,
                    requiresApprovalDrain: this.requiresApprovalDrain,
                    profilePrefix: `Wallet VM ${this.descriptor.runID.slice(-8)}-${this.descriptor.configuration}-${this.stageId.includes("soak") ? "soak" : "run"}`,
                    walletBundleIdentifier: "org.lil.wallet",
                    helperBundleIdentifier: "org.lil.wallet.ambient",
                    walletApplicationPath: this.walletApplicationPath, helperApplicationPath: this.helperApplicationPath}); return;
            case "/control/interactive-activation": {
                if (!this.interactiveActivation || !this.current || this.closing ||
                    this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) {
                    respond(response, 403, {error: "Interactive Safari activation is not applicable"}); return;
                }
                if (!value || typeof value !== "object" || Array.isArray(value) ||
                    Object.keys(value).sort().join(",") !== "enabled,phase" || typeof value.enabled !== "boolean" ||
                    !["waiting", "observed"].includes(value.phase)) {
                    respond(response, 400, {error: "Invalid Safari activation checkpoint"}); return;
                }
                const previous = this.activationRequests.at(-1);
                if (value.phase === "waiting") {
                    if (this.activationRequests.length >= 512 || previous && !previous.observedAt) {
                        respond(response, 409, {error: "A Safari activation checkpoint is already pending or its limit was reached"}); return;
                    }
                    this.activationRequests.push({scenario: {...this.current}, enabled: value.enabled, requestedAt: new Date().toISOString()});
                    process.stdout.write(`Safari user action required: ${value.enabled ? "enable" : "disable"} the Wallet extension in Safari Settings > Extensions inside the Safari Activation VM window (${this.current.id}, iteration ${this.current.iteration}).\n`);
                } else {
                    if (!previous || previous.observedAt || previous.enabled !== value.enabled ||
                        previous.scenario.id !== this.current.id || previous.scenario.iteration !== this.current.iteration) {
                        respond(response, 409, {error: "Safari activation observation does not match a pending checkpoint"}); return;
                    }
                    previous.observedAt = new Date().toISOString();
                    process.stdout.write(`Safari extension ${value.enabled ? "enabled" : "disabled"} state observed; continuing ${this.current.id}, iteration ${this.current.iteration}.\n`);
                }
                await mkdir(this.artifacts, {recursive: true, mode: 0o700});
                await atomicJSON(join(this.artifacts, `${this.stageId}.safari-activation.json`), {
                    version: 1, runId: this.descriptor.runID, stageId: this.stageId,
                    activationMode: "interactive", requests: this.activationRequests,
                });
                respond(response, 200, {recorded: true}); return;
            }
            case "/control/stage-guest-credential":
                if (this.descriptor.platform !== "macos" || this.descriptor.signingMode !== "local" || !this.current ||
                    this.closing || this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) { respond(response, 403, {error: "Guest Safari authorization is not applicable"}); return; }
                await this.stageGuestCredential();
                respond(response, 200, {staged: true}); return;
            case "/control/clear-guest-credential":
                if (this.descriptor.platform !== "macos" || this.descriptor.signingMode !== "local") { respond(response, 403, {error: "Guest Safari authorization is not applicable"}); return; }
                await this.clearGuestCredential();
                respond(response, 200, {cleared: true}); return;
            case "/control/refresh-extension-registration": {
                if (this.descriptor.platform !== "macos" || this.descriptor.signingMode !== "local" || !this.current ||
                    this.closing || typeof this.refreshExtensionRegistration !== "function" ||
                    this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) {
                    respond(response, 403, {error: "Safari registration refresh is not applicable"}); return;
                }
                if (this.registrationRefresh || this.registrationRefreshes.length >= 16) { throw new Error("Safari registration refresh limit exceeded"); }
                const scenario = {...this.current};
                this.registrationRefresh = (async () => {
                    const result = await this.refreshExtensionRegistration();
                    this.registrationRefreshes.push({...result, scenario});
                })();
                try { await this.registrationRefresh; }
                finally { this.registrationRefresh = null; }
                respond(response, 200, {registered: true}); return;
            }
            case "/control/start": {
                const id = value.scenario;
                if (!SAFARI_SCENARIOS.some(scenario => scenario.id === id && scenario.platforms.includes(this.descriptor.platform)) ||
                    !Number.isInteger(value.iteration) || value.iteration < 1 || value.iteration > this.iterations ||
                    this.scenarioStarts.has(`${id}:${value.iteration}`)) { throw new Error("Invalid or repeated scenario"); }
                if (this.registrationRefresh) { throw new Error("Safari registration refresh is unfinished"); }
                if (this.current && !this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) {
                    this.recoveryRequired = true;
                    this.errors.push("XCTest ended without finishing this scenario");
                    await this.recordScenario("failed", {abandoned: true});
                }
                const previous = this.current && this.scenarios.find(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration);
                const requiresApprovalDrain = this.recoveryRequired || previous?.status === "failed";
                this.recoveryRequired = requiresApprovalDrain;
                if (this.recoveryRequired) {
                    await this.clearGuestCredential();
                    await this.stopOwnedProcesses();
                    this.recoveryRequired = false;
                }
                this.scenarioStarts.add(`${id}:${value.iteration}`);
                this.current = {id, iteration: value.iteration};
                this.requiresApprovalDrain = requiresApprovalDrain;
                this.dappURL = await this.listen({...this.current});
                this.secondURL = await this.listen({...this.current});
                this.scenarioOrigins.set(this.dappURL, {...this.current});
                this.scenarioOrigins.set(this.secondURL, {...this.current});
                this.scenarioEventOffset = (await this.nativeEvents()).length;
                this.results = []; this.started.clear(); this.documents.clear(); this.solanaRequests.clear(); this.broadcasts = []; this.processFaults = []; this.errors = []; this.gates = {};
                this.solanaSigningRequests.clear();
                this.registrationRefreshes = [];
                this.lockProbe = null;
                this.releaseRPC(); this.rpcPeak = 0; this.rpcOutcomes = [];
                this.providerReady = false;
                this.rpcMode = this.broadcastMode = "normal";
                this.feeMultiplier = 1;
                this.preparationMode = "normal";
                await atomicJSON(join(this.descriptor.root, "scenario.json"), this.current);
                await atomicJSON(join(this.descriptor.root, "gates.json"), this.gates);
                respond(response, 200, {started: true}); return;
            }
            case "/control/state": respond(response, 200, await this.state()); return;
            case "/control/lock-probe": {
                if (!lockProbeScenarios.has(this.current?.id) || this.lockProbe || this.closing ||
                    this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) {
                    throw new Error("Fixture lock probe is not applicable or was already armed");
                }
                this.lockProbe = {version: 1, id: randomUUID(), scenario: {...this.current}};
                await atomicJSON(join(this.descriptor.root, "lock-probe.json"), this.lockProbe);
                respond(response, 200, {probeID: this.lockProbe.id}); return;
            }
            case "/control/gate": {
                const point = {authentication: "beforeAuthentication", signing: "beforeSigning", broadcast: "beforeDispatch"}[value.point] || value.point;
                if (!["beforeAuthentication", "beforeSigning", "afterSigning", "beforeBroadcastCheckpoint", "afterBroadcastCheckpoint", "beforeDispatch", "beforeCompletion"].includes(point) ||
                    !["hold", "release", "fail", "cancel"].includes(value.value)) { throw new Error("Invalid gate"); }
                this.gates[point] = value.value === "cancel" ? "fail" : value.value;
                await atomicJSON(join(this.descriptor.root, "gates.json"), this.gates);
                respond(response, 200, {updated: true}); return;
            }
            case "/control/fault": { const evidence = await this.fault(value); respond(response, 200, {injected: true, ...(evidence ? {evidence} : {})}); return; }
            case "/control/mutation": {
                if (!this.current || !["removeEthereumAccount", "restoreEthereumAccount", "replaceVaultGeneration", "replaceCustomNetwork"].includes(value.operation)) { throw new Error("Invalid fixture mutation"); }
                if (value.operation === "replaceCustomNetwork" && (value.chainId !== this.fixture.customNetwork.chainId ||
                    ![this.fixture.customNetwork.rpcURL, this.fixture.customNetwork.replacementRPCURL].includes(value.rpcURL))) { throw new Error("Invalid custom network mutation"); }
                const mutation = {id: randomUUID(), scenario: this.current, operation: value.operation};
                if (value.operation === "replaceCustomNetwork") { Object.assign(mutation, {chainId: value.chainId, rpcURL: value.rpcURL}); }
                await atomicJSON(join(this.descriptor.root, "mutation.json"), mutation);
                respond(response, 200, {mutationID: mutation.id}); return;
            }
            case "/control/finish": {
                if (this.registrationRefresh) { throw new Error("Safari registration refresh is unfinished"); }
                if (value.scenario !== this.current?.id || value.iteration !== this.current?.iteration) { throw new Error("Scenario result identity mismatch"); }
                const row = await this.recordScenario(value.status, value.evidence ?? []);
                respond(response, row.status === "passed" ? 200 : 422, row); return;
            }
            case "/control/browser":
                if (typeof value.bundleIdentifier !== "string" || typeof value.version !== "string") { throw new Error("Missing actual browser identity"); }
                this.browser = value; respond(response, 200, {recorded: true}); return;
            default: respond(response, 404, {error: "Unknown control endpoint"}); return;
            }
        }
        if (url.pathname.startsWith("/rpc/")) {
            if (context.scenario || request.headers["x-big-wallet-test-token"] !== this.token) { respond(response, 403, {error: "Native fixture token required"}); return; }
            await this.rpc(request, response, url); return;
        }
        if (!context.scenario) { respond(response, 404, {error: "Website origin required"}); return; }
        if (context.scenario.id !== this.current?.id || context.scenario.iteration !== this.current?.iteration) { respond(response, 409, {error: "Retired scenario origin"}); return; }
        if (["/page-result", "/rpc-outcome", "/page-solana-transaction", "/page-solana-signing-messages"].includes(url.pathname)) {
            if (request.headers["x-page-token"] !== this.pageToken) { respond(response, 403, {}); return; }
            const value = await body(request);
            if (!this.current) { throw new Error("No active Safari scenario"); }
            if (value.scenario?.id !== this.current.id || value.scenario?.iteration !== this.current.iteration) { respond(response, 409, {error: "Stale scenario page"}); return; }
            if (value.origin !== context.origin || this.documents.get(value.documentId) !== context.origin) { throw new Error("Unregistered or mismatched Safari document"); }
            if (url.pathname === "/page-solana-transaction") {
                const started = this.started.get(value.requestId);
                if (!started || started.action !== "solana-send" || started.documentId !== value.documentId ||
                    started.origin !== context.origin) { throw new Error("Invalid Solana transaction request"); }
                const transaction = this.solanaRequests.get(value.requestId) ?? solanaTransfer(this.fixture.addresses.solana, ++this.solanaSequence, this.fixture.solanaBlockhash);
                this.solanaRequests.set(value.requestId, transaction);
                respond(response, 200, {transaction: transaction.transaction}); return;
            }
            if (url.pathname === "/page-solana-signing-messages") {
                const started = this.started.get(value.requestId);
                if (!started || !["solana-transaction-sign", "solana-batch-sign"].includes(started.action) ||
                    started.documentId !== value.documentId || started.origin !== context.origin) { throw new Error("Invalid Solana transaction signing request"); }
                const messages = this.solanaSigningRequests.get(value.requestId) ?? Array.from(
                    {length: started.action === "solana-batch-sign" ? 2 : 1},
                    () => solanaTransfer(this.fixture.addresses.solana, ++this.solanaSequence, this.fixture.solanaBlockhash).message);
                this.solanaSigningRequests.set(value.requestId, messages);
                respond(response, 200, {messages}); return;
            }
            if (url.pathname === "/rpc-outcome") {
                const burst = this.started.get(value.requestId);
                if (!burst || burst.action !== "rpc-burst" || burst.documentId !== value.documentId || burst.origin !== context.origin ||
                    Buffer.byteLength(json(value)) > 2048 || typeof value.ok !== "boolean" ||
                    (value.ok ? value.result !== "0x100" : value.error?.code !== -32005 ||
                        typeof value.error?.data?.reason !== "string" || !value.error.data.reason.length || value.error.data.reason.length > 128)) { throw new Error("Invalid RPC burst settlement"); }
                if (this.rpcOutcomes.length >= 140 || !Number.isInteger(value.index) || value.index < 0 || value.index >= 140 ||
                    this.rpcOutcomes.some(outcome => outcome.index === value.index)) { throw new Error("Invalid or repeated RPC burst outcome"); }
                this.rpcOutcomes.push(value.ok ? {index: value.index, ok: true, result: value.result} :
                    {index: value.index, ok: false, error: {code: value.error.code, data: {reason: value.error.data.reason}}});
                respond(response, 200, {}); return;
            }
            if (value.phase === "provider-ready") { this.providerReady = true; respond(response, 200, {}); return; }
            if (typeof value.requestId !== "string" || value.requestId.length > 128 ||
                typeof value.action !== "string" || !/^[a-z][a-z-]{0,63}$/.test(value.action) ||
                Buffer.byteLength(json(value)) > 65_536) { throw new Error("Malformed or oversized page result"); }
            if (value.phase === "started") {
                if (this.started.size >= 512) { throw new Error("Page request limit exceeded"); }
                if (this.started.has(value.requestId)) { throw new Error("Page reused a request ID"); }
                this.started.set(value.requestId, value);
            } else {
                const started = this.started.get(value.requestId);
                if (value.phase !== "settled" || !started || this.results.some(result => result.requestId === value.requestId)) { throw new Error("Unexpected or repeated provider settlement"); }
                if (["action", "origin", "documentId"].some(field => value[field] !== started[field])) { throw new Error("Provider settlement changed its original document or action"); }
                if (this.results.length >= 512) { throw new Error("Page result limit exceeded"); }
                this.verifyResult(value);
                this.results.push(value);
            }
            respond(response, 200, {}); return;
        }
        if (url.pathname === "/page-config") {
            if (this.documents.size >= 512) { throw new Error("Page document limit exceeded"); }
            const documentId = randomUUID();
            this.documents.set(documentId, context.origin);
            respond(response, 200, {...this.fixture, pageToken: this.pageToken, documentId, scenario: context.scenario}); return;
        }
        if (url.pathname === "/page.js") { respond(response, 200, await readFile(new URL("page.js", import.meta.url), "utf8"), "text/javascript"); return; }
        respond(response, 200, await readFile(new URL("page.html", import.meta.url), "utf8"), "text/html");
    }

    verifyResult(value) {
        if (!value.ok) { return; }
        if (ethereumSendActions.has(value.action) || value.action === "solana-send") {
            const chain = value.action === "solana-send" ? "solana" : "ethereum";
            const broadcasts = this.broadcasts.filter(broadcast => broadcast.chain === chain && broadcast.requestId === value.requestId);
            const hash = chain === "solana" ? value.result?.signature
                : typeof value.result === "string" ? value.result.toLowerCase() : null;
            if (broadcasts.length !== 1 || typeof hash !== "string" || hash !== broadcasts[0].hash ||
                chain === "solana" && value.result?.publicKey !== this.fixture.addresses.solana) {
                throw new Error("Transaction send result does not match its request's verified broadcast");
            }
        }
        const message = `${this.fixture.message} | ${value.requestId}`;
        if (value.action === "ethereum-sign") { assertEthereumSignature(value.result, message, this.fixture.addresses.ethereum); }
        if (value.action === "solana-sign") {
            const signature = value.result?.signature;
            if (value.result?.publicKey !== this.fixture.addresses.solana || !Array.isArray(signature) || signature.length !== 64 ||
                signature.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) {
                throw new Error("Solana message signing returned an unexpected account or signature byte array");
            }
            assertSolanaSignature(Uint8Array.from(signature), Buffer.from(message), this.fixture.addresses.solana);
        }
        if (["solana-transaction-sign", "solana-batch-sign"].includes(value.action)) {
            const messages = this.solanaSigningRequests.get(value.requestId);
            const signatures = value.action === "solana-batch-sign" ? value.result?.signatures : [value.result?.signature];
            const expected = value.action === "solana-batch-sign" ? 2 : 1;
            if (value.result?.publicKey !== this.fixture.addresses.solana || messages?.length !== expected ||
                !Array.isArray(signatures) || signatures.length !== expected || signatures.some(signature => typeof signature !== "string")) {
                throw new Error("Solana transaction signing result does not match its original request");
            }
            for (let index = 0; index < expected; index += 1) {
                assertSolanaSignature(signatures[index], base58.decode(messages[index]), this.fixture.addresses.solana);
            }
        }
    }

    async guestCredential() {
        let file;
        try {
            file = await open(this.guestCredentialPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
            const info = await file.stat();
            if (!info.isFile() || info.size < 1 || info.size > 4096 || info.uid !== process.getuid() ||
                (info.mode & 0o777) !== 0o600 || info.nlink !== 1) { throw new Error(); }
            const bytes = Buffer.alloc(info.size);
            let offset = 0;
            while (offset < bytes.length) {
                const {bytesRead} = await file.read(bytes, offset, bytes.length - offset, offset);
                if (!bytesRead) { throw new Error(); }
                offset += bytesRead;
            }
            const after = await file.stat();
            if (after.size !== info.size || after.mtimeMs !== info.mtimeMs || after.ctimeMs !== info.ctimeMs) { throw new Error(); }
            const value = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(bytes));
            if (value.version !== 1 || value.runID !== this.descriptor.runID ||
                value.consoleUser !== userInfo().username ||
                typeof value.password !== "string" || !value.password.length || value.password.length > 1024 || /[\r\n\0]/.test(value.password)) { throw new Error(); }
            return value.password;
        } catch { throw new Error("The dedicated guest credential is unavailable or invalid; refresh VM setup"); }
        finally { await file?.close(); }
    }

    credentialOperation(operation) {
        const pending = this.credentialQueue.then(operation);
        this.credentialQueue = pending.catch(() => {});
        return pending;
    }

    stageGuestCredential() {
        return this.credentialOperation(async () => {
            if (this.guestCredentialStaged) { await this.clipboardWriter(""); this.guestCredentialStaged = false; }
            clearTimeout(this.guestCredentialTimer);
            this.guestCredentialTimer = null;
            const password = await this.guestCredential();
            const generation = ++this.guestCredentialGeneration;
            this.guestCredentialStaged = true;
            try { await this.clipboardWriter(password); }
            finally {
                this.guestCredentialTimer = setTimeout(() => {
                    void this.clearGuestCredential(generation).catch(() => {
                        if (this.errors.length < 256) { this.errors.push("Guest credential auto-clear failed"); }
                    });
                }, 30_000);
                this.guestCredentialTimer.unref();
            }
        });
    }

    async stagePreparationGuestCredential(nonce) {
        if (!this.preparationNonce || nonce !== this.preparationNonce || this.descriptor.platform !== "macos" ||
            this.descriptor.signingMode !== "local" || this.current || this.closing) {
            throw new Error("Guest credential staging requires the owned Safari activation preparation");
        }
        let file;
        try {
            const markerPath = join(this.descriptor.root, "activation-preparation.json");
            file = await open(markerPath, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
            const before = await file.stat();
            if (!before.isFile() || before.uid !== process.getuid() || before.nlink !== 1 ||
                (before.mode & 0o777) !== 0o600 || before.size < 1 || before.size > 4096) { throw new Error(); }
            const bytes = Buffer.alloc(before.size);
            let offset = 0;
            while (offset < bytes.length) {
                const {bytesRead} = await file.read(bytes, offset, bytes.length - offset, offset);
                if (!bytesRead) { throw new Error(); }
                offset += bytesRead;
            }
            const after = await file.stat();
            const pathInfo = await lstat(markerPath);
            if (after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs ||
                !pathInfo.isFile() || pathInfo.isSymbolicLink() || pathInfo.dev !== before.dev || pathInfo.ino !== before.ino) {
                throw new Error();
            }
            const marker = JSON.parse(new TextDecoder("utf-8", {fatal: true}).decode(bytes));
            if (!marker || typeof marker !== "object" || Array.isArray(marker) ||
                Object.keys(marker).sort().join(",") !== "nonce,runID,showPreferences,version" ||
                marker.version !== 1 || marker.runID !== this.descriptor.runID || marker.nonce !== nonce ||
                typeof marker.showPreferences !== "boolean") { throw new Error(); }
        } catch { throw new Error("Safari activation preparation marker is unavailable or invalid"); }
        finally { await file?.close(); }
        await this.stageGuestCredential();
    }

    clearGuestCredential(generation = null) {
        return this.credentialOperation(async () => {
            if (generation !== null && generation !== this.guestCredentialGeneration) { return; }
            clearTimeout(this.guestCredentialTimer);
            this.guestCredentialTimer = null;
            if (this.guestCredentialStaged) {
                await this.clipboardWriter("");
                this.guestCredentialStaged = false;
            }
        });
    }

    check(state, scenarioID = this.current.id) {
        const issues = [...state.errors];
        if (!state.handshake.provider || !state.handshake.native) { issues.push("Missing real provider/native handshake"); }
        if (lockProbeScenarios.has(scenarioID)) {
            const probe = state.lockProbe;
            const events = state.events.filter(event => event.kind.startsWith("fixtureLock"));
            const [held, excluded, released, acquired] = events;
            const holder = held && {processID: held.processID, incarnation: held.incarnation};
            const contender = excluded && {processID: excluded.processID, incarnation: excluded.incarnation};
            const validProcess = process => process && Number.isInteger(process.processID) && process.processID > 1 &&
                typeof process.incarnation === "string" && process.incarnation.length > 0;
            if (!probe || probe.scenario?.id !== scenarioID || events.length !== 4 ||
                !validProcess(holder) || !validProcess(contender) || holder.processID === contender.processID || holder.incarnation === contender.incarnation ||
                !["fixtureLockHeld", "fixtureLockExcluded", "fixtureLockReleased", "fixtureLockAcquired"].every((kind, index) => events[index]?.kind === kind) ||
                !events.every((event, index) => {
                    const identity = index === 0 || index === 2 ? holder : contender;
                    return event.probeID === probe.id && event.lockName === "safari-lock-probe.lock" &&
                        event.scenario === probe.scenario.id && event.iteration === probe.scenario.iteration &&
                        event.role === (index === 0 || index === 2 ? "extension" : "app") &&
                        event.processID === identity.processID && event.incarnation === identity.incarnation &&
                        event.holderProcessID === holder.processID && event.holderIncarnation === holder.incarnation &&
                        (index === 0 || (event.contenderProcessID === contender.processID && event.contenderIncarnation === contender.incarnation));
                })) { issues.push("Missing acknowledged app/extension lock exclusion on the shared fixture path"); }
        } else if (state.events.some(event => event.kind === "fixtureLockFailed")) {
            issues.push("Fixture lock probe failed");
        }
        for (const broadcast of state.broadcasts) { if (broadcast.count !== 1) { issues.push("Transaction submitted more than once"); } }
        const signing = state.events.filter(event => event.kind === "signingStarted");
        if (zeroSigningScenarios.has(scenarioID) && (signing.length || state.broadcasts.length ||
            state.events.some(event => ["broadcastCheckpoint", "broadcastDispatch"].includes(event.kind)))) {
            issues.push("Scenario must not sign or dispatch: " + scenarioID);
        }
        if (oneSigningScenarios.has(scenarioID) && signing.length !== 1) {
            issues.push(`Expected exactly one signing execution for ${scenarioID}; observed ${signing.length}`);
        }
        const executions = signing.map(event => event.executionID).filter(Boolean);
        if (new Set(executions).size !== executions.length) { issues.push("Execution used signing more than once"); }
        const authorizations = state.events.filter(event => event.kind === "authorization");
        const consents = state.events.filter(event => event.kind === "consentAccepted");
        const usedConsents = new Set();
        const signedRequests = new Set();
        for (const authorization of authorizations) {
            const matching = consents.filter(consent => consent.consentID === authorization.consentID &&
                consent.requestID === authorization.requestID && consent.requestToken === authorization.requestToken &&
                consent.profileIdentifier === authorization.profileIdentifier && consent.configurationKey === authorization.configurationKey);
            if (typeof authorization.consentID !== "string" || typeof authorization.requestToken !== "string" || !authorization.requestToken.length ||
                typeof authorization.configurationKey !== "string" || !Number.isSafeInteger(authorization.requestID) ||
                matching.length !== 1 || usedConsents.has(authorization.consentID)) {
                issues.push("Execution lacks a distinct fresh consent for its original request");
            }
            usedConsents.add(authorization.consentID);
        }
        for (const attempt of signing) {
            const matching = authorizations.filter(authorization => authorization.executionID === attempt.executionID && authorization.requestID === attempt.requestID);
            if (typeof attempt.executionID !== "string" || matching.length !== 1) { issues.push("Signing lacks a correlated authorized execution"); }
            else {
                const authorization = matching[0];
                const identity = json([authorization.requestID, authorization.requestToken, authorization.profileIdentifier ?? null, authorization.configurationKey]);
                if (signedRequests.has(identity)) { issues.push("Original request used signing more than once"); }
                signedRequests.add(identity);
            }
        }
        if (scenarioID === "ethereum-signing" && !state.results.some(result => result.action === "ethereum-sign" && result.ok)) { issues.push("Missing verified Ethereum signature"); }
        if (scenarioID === "solana-signing" && !state.results.some(result => result.action === "solana-sign" && result.ok)) { issues.push("Missing verified Solana signature"); }
        if (scenarioID === "solana-transaction-signing") {
            if (!state.results.some(result => result.action === "solana-transaction-sign" && result.ok) ||
                !state.results.some(result => result.action === "solana-batch-sign" && result.ok) ||
                !state.results.some(result => result.action === "solana-batch-sign" && !result.ok && result.error?.code === 4001) || signing.length !== 2) {
                issues.push("Missing verified Solana single/batch transaction signing and explicit batch rejection");
            }
            if (state.broadcasts.length || state.events.some(event => ["broadcastCheckpoint", "broadcastDispatch"].includes(event.kind))) {
                issues.push("Solana transaction signing unexpectedly dispatched a transaction");
            }
        }
        if (["ethereum-broadcast", "solana-broadcast", "ambiguous-broadcast"].includes(scenarioID) && state.broadcasts.length !== 1) { issues.push("Expected exactly one verified broadcast"); }
        if (scenarioID === "rpc-failure-capacity") {
            const outcomes = state.rpc?.outcomes ?? [];
            if (outcomes.length !== 140 || !outcomes.some(outcome => outcome.ok && outcome.result === "0x100") ||
                !outcomes.some(outcome => !outcome.ok && outcome.error?.code === -32005 && typeof outcome.error?.data?.reason === "string") ||
                !outcomes.every(outcome => outcome.ok ? outcome.result === "0x100" : outcome.error?.code === -32005 && typeof outcome.error?.data?.reason === "string" && outcome.error.data.reason.length > 0) ||
                !(state.rpc.peak >= 1 && state.rpc.peak <= 4)) { issues.push("RPC burst did not prove bounded admission and successful recovery"); }
        }
        return issues;
    }

    async fault(value) {
        if (value.kind === "rpc-preparation" && ["hold", "normal"].includes(value.mode)) {
            this.preparationMode = value.mode;
            if (value.mode === "normal") { for (const release of [...this.preparationWaiters]) { release(); } }
            return;
        }
        if (value.kind === "rpc-fees" && Number.isInteger(value.multiplier) && value.multiplier >= 1 && value.multiplier <= 10) {
            this.feeMultiplier = value.multiplier;
            return;
        }
        if (value.kind === "rpc" && ["normal", "unavailable", "hold"].includes(value.mode)) {
            this.rpcMode = value.mode;
            if (value.mode !== "hold") { this.releaseRPC(); }
            return;
        }
        if (value.kind === "broadcast" && ["normal", "ambiguous"].includes(value.mode)) { this.broadcastMode = value.mode; return; }
        if (["native-process", "extension-process"].includes(value.kind) && value.action === "terminate") {
            if (this.processFaults.length >= 16) { throw new Error("Native process fault limit exceeded"); }
            await this.refreshAllowedExecutables();
            const role = value.kind === "extension-process" || this.descriptor.platform === "ios" ? "extension" : "helper";
            const events = (await this.nativeEvents()).slice(this.stageEventOffset);
            const processes = new Map(events.filter(item => item.kind === "processStarted" && item.role === role).map(event => [event.processID, event]));
            const killed = [];
            const evidence = {kind: value.kind, scope: "role-pool", role, status: "failed", killed};
            this.processFaults.push(evidence);
            for (const event of processes.values()) {
                if (!Number.isInteger(event.processID) || event.processID <= 1 || event.processID === process.pid || typeof event.executablePath !== "string") { throw new Error("Invalid run-owned process identity"); }
                const executable = await this.processInspector(event.processID);
                if (executable === null) { continue; }
                if (await realpath(executable) !== await realpath(event.executablePath) || !this.allowedExecutables.has(event.executablePath)) { throw new Error("Run-owned process identity changed before termination"); }
                try { this.processTerminator(event.processID, "SIGKILL"); }
                catch (error) { if (error.code === "ESRCH") { continue; } throw error; }
                killed.push({processID: event.processID, incarnation: event.incarnation, role, executablePath: event.executablePath});
            }
            if (!killed.length) { throw new Error("No verified run-owned process available for termination"); }
            evidence.status = "passed";
            return evidence;
        }
        throw new Error("Unsupported fault; authority changes must use actual wallet/provider actions");
    }

    async rpc(request, response, url) {
        const payload = await body(request);
        if (!payload || Array.isArray(payload) || typeof payload.method !== "string") { throw new Error("Invalid fixture RPC payload"); }
        const noArguments = ["eth_chainId", "eth_blockNumber", "eth_gasPrice", "eth_maxPriorityFeePerGas"].includes(payload.method);
        if (noArguments && payload.params === undefined) { payload.params = []; }
        if (!Array.isArray(payload.params) || noArguments && payload.params.length !== 0) { throw new Error("Invalid fixture RPC payload"); }
        if (this.rpcMode === "unavailable") { respond(response, 503, {jsonrpc: "2.0", id: payload.id, error: {code: -32000, message: "Injected RPC outage"}}); return; }
        const chain = url.pathname === "/rpc/solana" ? "solana" : "ethereum";
        if (!this.closing && this.preparationMode === "hold" && payload.method === "eth_estimateGas") {
            await new Promise(resolve => {
                const release = () => {
                    if (!this.preparationWaiters.delete(release)) { return; }
                    response.removeListener("close", release); resolve();
                };
                this.preparationWaiters.add(release);
                response.once("close", release);
            });
            if (response.destroyed) { return; }
        }
        if (!this.closing && this.rpcMode === "hold" && payload.method === "eth_blockNumber") {
            const processID = request.headers["x-big-wallet-test-process"];
            if (typeof processID !== "string" || !/^[1-9][0-9]*$/.test(processID)) { throw new Error("RPC process identity is missing"); }
            await new Promise(resolve => {
                const count = (this.rpcHeldByProcess.get(processID) ?? 0) + 1;
                this.rpcHeldByProcess.set(processID, count);
                this.rpcPeak = Math.max(this.rpcPeak, count);
                const release = () => {
                    if (!this.rpcWaiters.delete(release)) { return; }
                    this.rpcHeldByProcess.set(processID, this.rpcHeldByProcess.get(processID) - 1);
                    response.removeListener("close", release); resolve();
                };
                this.rpcWaiters.add(release);
                response.once("close", release);
            });
            if (response.destroyed) { return; }
        }
        let result;
        const fee = amount => "0x" + (BigInt(amount) * BigInt(this.feeMultiplier)).toString(16);
        switch (payload.method) {
        case "eth_chainId": result = "0x" + BigInt(url.searchParams.get("chainId") || 1).toString(16); break;
        case "eth_blockNumber": result = "0x100"; break;
        case "eth_getBalance": result = "0xde0b6b3a7640000"; break;
        case "eth_getTransactionCount": result = "0x0"; break;
        case "eth_gasPrice": result = fee(2_000_000_000); break;
        case "eth_maxPriorityFeePerGas": result = fee(1_000_000_000); break;
        case "eth_getBlockByNumber": result = {number: "0x100", baseFeePerGas: fee(1_000_000_000)}; break;
        case "eth_feeHistory": {
            const [encodedCount, newestBlock, percentiles] = payload.params;
            const quantity = value => typeof value === "string" && /^0x(?:0|[1-9a-f][0-9a-f]{0,3})$/i.test(value) ? Number(value) : null;
            const requestedCount = quantity(encodedCount);
            const newest = ["latest", "pending", "safe", "finalized"].includes(newestBlock) ? 256
                : newestBlock === "earliest" ? 0 : quantity(newestBlock);
            if (payload.params.length !== 3 || requestedCount === null || requestedCount < 1 || requestedCount > 1024 ||
                newest === null || newest > 256 || !Array.isArray(percentiles) || percentiles.length > 100 ||
                percentiles.some((value, index) => typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 100 ||
                    index > 0 && value <= percentiles[index - 1])) {
                respond(response, 200, {jsonrpc: "2.0", id: payload.id, error: {code: -32602, message: "Invalid fixture fee history parameters"}});
                return;
            }
            const count = Math.min(requestedCount, newest + 1);
            const encodedFee = fee(1_000_000_000);
            result = {oldestBlock: "0x" + (newest - count + 1).toString(16),
                baseFeePerGas: Array(count + 1).fill(encodedFee),
                reward: Array.from({length: count}, () => percentiles.map(() => encodedFee)),
                gasUsedRatio: Array(count).fill(0.5)};
            break;
        }
        case "eth_estimateGas": result = "0xc350"; break;
        case "eth_sendRawTransaction": {
            const bytes = Buffer.from(String(payload.params[0]).replace(/^0x/, ""), "hex");
            await this.nativeEvents();
            const authorization = (await this.state()).events.filter(event => event.kind === "authorizedTransaction").at(-1);
            if (!authorization?.transaction) { throw new Error("Broadcast has no observed approved transaction"); }
            const approved = authorization.transaction;
            const requested = [...this.started.values()].find(value => ethereumSendActions.has(value.action) && hex(Buffer.from(value.requestId)) === approved.data);
            if (!requested) { throw new Error("Approved transaction is not bound to this scenario's page request"); }
            const expected = {...this.fixture.ethereumTransaction, from: this.fixture.addresses.ethereum, data: hex(Buffer.from(requested.requestId)), chainId: requested.action === "ethereum-send-custom" ? "0x" + this.fixture.customNetwork.chainId.toString(16) : "0x1"};
            for (const field of ["from", "to", "value", "data", "chainId"]) {
                if (String(approved[field]).toLowerCase() !== expected[field].toLowerCase()) { throw new Error(`Approval changed fixture ${field}`); }
            }
            assertEthereumTransaction(bytes, {address: this.fixture.addresses.ethereum, chainId: expected.chainId, object: approved});
            result = hex(keccak_256(bytes));
            this.recordBroadcast(chain, result, bytes, requested.requestId);
            if (this.broadcastMode === "ambiguous") { request.socket.destroy(); return; }
            break;
        }
        case "getLatestBlockhash": result = {context: {slot: 256}, value: {blockhash: this.fixture.solanaBlockhash, lastValidBlockHeight: 1000}}; break;
        case "getBlockHeight": result = 256; break;
        case "getBalance": result = {context: {slot: 256}, value: 1000000000}; break;
        case "getSignatureStatuses": result = {context: {slot: 256}, value: payload.params[0].map(() => ({slot: 256, confirmations: 1, err: null, confirmationStatus: "confirmed"}))}; break;
        case "sendTransaction": {
            const bytes = payload.params[1]?.encoding === "base64" ? Buffer.from(payload.params[0], "base64") : Buffer.from(base58.decode(payload.params[0]));
            const messageHash = hex(keccak_256(Transaction.from(bytes).serializeMessage()));
            const entry = [...this.solanaRequests].find(([, value]) => value.messageHash === messageHash);
            if (!entry) { throw new Error("Solana broadcast is not bound to this scenario's page request"); }
            const [requestId, requested] = entry;
            assertSolanaTransaction(bytes, {publicKey: this.fixture.addresses.solana, object: {params: {transaction: requested.transaction}}});
            result = base58.encode(bytes.subarray(1, 65));
            this.recordBroadcast(chain, result, bytes, requestId);
            if (this.broadcastMode === "ambiguous") { request.socket.destroy(); return; }
            break;
        }
        default: respond(response, 200, {jsonrpc: "2.0", id: payload.id, error: {code: -32601, message: "Fixture method not implemented"}}); return;
        }
        respond(response, 200, {jsonrpc: "2.0", id: payload.id, result});
    }

    recordBroadcast(chain, hash, bytes, requestId) {
        const existing = this.broadcasts.find(item => item.chain === chain && item.hash === hash);
        if (existing) { existing.count += 1; }
        else {
            if (this.broadcasts.length >= 512) { throw new Error("Broadcast evidence limit exceeded"); }
            this.broadcasts.push({chain, hash, requestId, bytes: bytes.toString("hex"), count: 1});
        }
    }

    releaseRPC() {
        for (const release of [...this.rpcWaiters]) { release(); }
        for (const release of [...this.preparationWaiters]) { release(); }
    }

    async recordScenario(status, evidence) {
        if (!this.current || this.scenarios.some(scenario => scenario.id === this.current.id && scenario.iteration === this.current.iteration)) {
            throw new Error("Scenario has already finished or was not started");
        }
        const state = await this.state();
        const issues = this.check(state);
        const row = {...this.current, status: status === "passed" && !issues.length ? "passed" : "failed", issues, evidence,
            resultCount: state.results.length, nativeEventCount: state.events.length, broadcasts: state.broadcasts.length};
        this.scenarios.push(row);
        this.evidence.push({...row, ...state});
        await this.persist();
        return row;
    }

    async persist({nativeRecords} = {}) {
        await mkdir(this.artifacts, {recursive: true, mode: 0o700});
        const nativeEvents = (nativeRecords ?? await this.nativeEvents()).slice(this.stageEventOffset);
        for (const evidence of this.evidence) {
            evidence.events = nativeEvents.filter(event => event.scenario === evidence.id && event.iteration === evidence.iteration);
            const issues = this.check(evidence, evidence.id);
            const row = this.scenarios.find(row => row.id === evidence.id && row.iteration === evidence.iteration);
            if (issues.length) { row.status = evidence.status = "failed"; row.issues = evidence.issues = issues; }
        }
        await atomicJSON(join(this.artifacts, `${this.stageId}.safari-evidence.json`), this.evidence);
        await atomicJSON(join(this.artifacts, `${this.stageId}.safari-native.json`), nativeEvents);
        await atomicJSON(join(this.artifacts, `${this.stageId}.safari.json`), {
            version: 1, runId: this.descriptor.runID, stageId: this.stageId, platform: this.descriptor.platform,
            configuration: this.descriptor.configuration, signing: this.descriptor.signingMode, iterations: this.iterations,
            activationMode: this.activationMode, ...(this.preparation === undefined ? {} : {preparation: this.preparation}),
            activationRequests: this.activationRequests,
            extensionIdentifier: "org.lil.wallet.Safari", extension: this.extension, browser: this.browser, runtime: this.runtime,
            handshake: {provider: this.providerReady, native: this.nativeReady}, scenarios: this.scenarios,
            authentication: this.descriptor.platform === "ios" ? (this.descriptor.signingMode === "local" ? "fixture" : "device-authentication") : "password-sheet",
            storage: this.descriptor.signingMode === "local" ? "fixture" : "production-entitlements",
            signingCoverage: this.signingCoverage ?? null,
            cleanup: this.cleanup,
        });
    }

    async close() {
        this.closing = true;
        this.releaseRPC();
        let failure;
        try { await this.registrationRefresh; }
        catch (error) { failure = error; }
        await this.originRegistryQueue;
        try { await this.clearGuestCredential(); }
        catch (error) { failure ??= error; }
        try { await this.stopOwnedProcesses(); }
        catch (error) { failure ??= error; }
        for (const server of [...this.servers, ...this.candidateServers]) {
            await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
        }
        await Promise.allSettled(this.activeRequests);
        try { await this.nativeReader.finish(); }
        catch (error) { failure ??= error; }
        this.cleanup = failure ? {status: "failed", reason: failure.message} : {status: "passed"};
        await this.persist({nativeRecords: this.nativeReader.failure ? this.nativeReader.records : undefined});
        if (failure) { throw failure; }
    }

    async stopOwnedProcesses(deadline = Date.now() + 60000) {
        if (!Number.isFinite(deadline) || deadline <= Date.now()) { throw new Error("Safari process cleanup exceeded its deadline"); }
        const cleanupDeadline = Math.min(deadline, Date.now() + 60000);
        let evidenceFailure;
        const processStarts = async () => {
            let events;
            try { events = await this.nativeEvents(); }
            catch (error) { evidenceFailure ??= error; events = this.nativeReader.records; }
            return events.slice(this.stageEventOffset).filter(event => event.kind === "processStarted");
        };
        const live = async event => {
            if (!Number.isInteger(event.processID) || event.processID <= 1 || event.processID === process.pid ||
                !this.allowedExecutables.has(event.executablePath)) { throw new Error("Cleanup encountered an unverified process identity"); }
            const executable = await this.processInspector(event.processID);
            if (executable === null) { return false; }
            return await realpath(executable) === await realpath(event.executablePath);
        };
        const signal = (event, value) => {
            try { this.processTerminator(event.processID, value); }
            catch (error) { if (error.code !== "ESRCH") { throw error; } }
        };
        try {
            for (let pass = 0; pass < 4; pass += 1) {
                await this.refreshAllowedExecutables();
                const starts = await processStarts();
                const processes = new Map(starts.map(event => [event.processID, event]));
                let terminated = false;
                for (const event of processes.values()) {
                    if (Date.now() >= cleanupDeadline) { throw new Error("Safari process cleanup exceeded its deadline"); }
                    if (!await live(event)) { continue; }
                    terminated = true;
                    signal(event, "SIGTERM");
                    const deadline = Math.min(cleanupDeadline, Date.now() + 3000);
                    while (await live(event) && Date.now() < deadline) { await new Promise(resolve => setTimeout(resolve, 100)); }
                    if (await live(event)) {
                        signal(event, "SIGKILL");
                        await new Promise(resolve => setTimeout(resolve, 200));
                        if (await live(event)) { throw new Error("Owned Safari fixture process did not terminate"); }
                    }
                }
                if (!terminated) {
                    const finalStarts = await processStarts();
                    if (finalStarts.length === starts.length) {
                        if (evidenceFailure) { throw evidenceFailure; }
                        return;
                    }
                }
            }
            throw new Error("Owned Safari fixture processes kept restarting during cleanup");
        } catch (error) { throw evidenceFailure ?? error; }
    }

    async refreshAllowedExecutables() {
        if (this.resolveAllowedExecutables) {
            const paths = await this.resolveAllowedExecutables();
            for (const path of paths) { this.allowedExecutables.add(path); }
        }
    }
}
