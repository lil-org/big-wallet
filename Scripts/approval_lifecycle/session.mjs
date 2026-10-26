import {cp, mkdir, mkdtemp, readFile, realpath, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join, resolve} from "node:path";
import {createRequire} from "node:module";
import {isDeepStrictEqual} from "node:util";
import {BrowserLifecycle, nativeSiteContext, requestNameForOperation} from "./browser.mjs";
import {NativeChild} from "./native_child.mjs";
import {EffectLedger, FakeRPC, LifecycleOracle, canonicalAccount, handleKey} from "./oracle.mjs";
import {LifecycleFailure, Scheduler} from "./scheduler.mjs";
import {origins, profiles} from "./scenarios.mjs";
import {assertEthereumSignature, assertEthereumTransaction, assertSolanaSignature, assertSolanaTransaction, solanaMessage} from "./crypto_assertions.mjs";

const require = createRequire(new URL("../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {PublicKey, SystemProgram, Transaction} = require("@solana/web3.js");
const base58Module = require("bs58");
const base58 = base58Module.default || base58Module;
const {keccak_256} = require("@noble/hashes/sha3");
const nonfatal = error => error?.native === true || error?.invariant === "process-restarted";
const pause = () => new Promise(resolve => setImmediate(resolve));

export class LifecycleSession {
    constructor(options) {
        this.options = options;
        this.sourceIdentity = options.sourceIdentity;
        this.originalSourceIdentity = options.originalSourceIdentity ?? options.sourceIdentity;
        this.mode = options.mode;
        this.seed = options.seed;
        this.trace = [];
        this.decisions = [];
        this.faultTargets = {};
        this.actionIndex = -1;
        this.coverage = new Set;
        this.oracle = new LifecycleOracle;
        this.scheduler = new Scheduler({seed: this.seed, trace: event => this.record(event)});
        this.children = new Map;
        this.epochs = new Map;
        this.gates = new Map;
        this.snapshots = new Map;
        this.admissions = new Map;
        this.nativeTimers = new Map;
        this.nativeRequests = new Map;
        this.approvalSerial = 0;
        this.popupApprovals = new Map;
        this.background = new Set;
        this.backgroundLifetimes = new Map;
        this.walletMutations = new Map;
        this.asyncFailure = null;
        this.currentAction = null;
        this.savedConsents = [];
        this.savedReviews = [];
        this.closed = false;
    }
    record(event) {
        this.trace.push({index: this.trace.length, time: this.scheduler.now, ...event});
        if (event.type === "browser-wire" && event.fault?.sourceAction !== undefined) {
            this.faultTargets[event.fault.sourceAction] = event.transportKey;
            this.coverage.add(`action:${event.fault.action}`);
            this.coverage.add(`fault:${event.channel}:${event.phase}:${event.fault.action}`);
        }
    }
    async initialize() {
        const parent = this.options.scratchDirectory ? resolve(this.options.scratchDirectory) : tmpdir();
        await mkdir(parent, {recursive: true});
        this.root = await realpath(await mkdtemp(join(parent, "approval-lifecycle-")));
        this.storeRoot = join(this.root, "store");
        await mkdir(this.storeRoot);
        this.ledger = new EffectLedger(join(this.root, "effects.jsonl"));
        this.rpc = new FakeRPC({ledger: this.ledger, oracle: this.oracle,
            requestBody: details => {
                const request = this.nativeRequests.get(handleKey(details.handle));
                if (!request) { throw new LifecycleFailure("payload", "Broadcast has no captured browser request", details); }
                const body = request.reviewedBody || request.expectedBody;
                if (!body) { throw new LifecycleFailure("payload", "Broadcast has no original provider payload", details); }
                return {...body, reviewedCluster: request.reviewedCluster};
            },
            onReceipt: effect => this.externalCheckpoint("rpc.received", effect),
            onAccepted: effect => this.externalCheckpoint("rpc.accepted", effect)});
        await this.start("bridge");
        if (this.mode === "native") {
            await this.start("approval");
            await this.child("bridge").command("runtime", {identity: this.child("approval").ready.identity});
        }
        this.accounts = this.child("bridge").ready.accounts;
        if (!Array.isArray(this.accounts) || !this.accounts.some(account => account.coin === "ethereum") || !this.accounts.some(account => account.coin === "solana")) {
            throw new LifecycleFailure("coverage", "Native worker did not expose both fixture accounts", {ready: this.child("bridge").ready});
        }
        for (const child of this.children.values()) { await child.command("clock", {nowMilliseconds: this.scheduler.now}); }
        this.browser = new BrowserLifecycle({
            scheduler: this.scheduler, mode: this.mode, trace: event => this.record(event),
            native: (message, profileIdentifier) => this.sendNative(message, profileIdentifier),
            onNative: event => this.observeNativeMessage(event),
            onSettlement: operation => this.observeSettlement(operation),
        });
        this.tabs = [
            this.browser.openTab({profileIdentifier: profiles[0], url: origins[0] + "/first"}),
            this.browser.openTab({profileIdentifier: profiles[0], url: origins[0] + "/second"}),
            this.browser.openTab({profileIdentifier: profiles[0], url: origins[1] + "/first"}),
            this.browser.openTab({profileIdentifier: profiles[1], url: origins[0] + "/first"}),
        ];
        await this.pumpUntil(() => this.browser.snapshot().every(tab => tab.configuration));
        return this;
    }
    child(role) {
        const child = this.children.get(role);
        if (child?.failure) { throw child.failure; }
        if (!child || child.exited) { throw new LifecycleFailure("process-restarted", "Requested native role is unavailable", {role}); }
        return child;
    }
    async start(role) {
        const serial = (this.epochs.get(role) || 0) + 1;
        this.epochs.set(role, serial);
        const child = new NativeChild({executable: this.options.worker, role, root: this.storeRoot,
            epoch: `${role}-${serial}`, mode: this.mode, timeout: this.options.timeout,
            trace: event => this.record(event), onEvent: (event, source) => this.nativeEvent(event, source)});
        this.children.set(role, child);
        const ready = await child.waitEvent(event => event.event === "ready");
        child.ready = ready.details;
        return child;
    }
    sendNative(message, profileIdentifier) {
        const promise = this.child("bridge").command("native", {message, profileIdentifier}, {timeout: 60000}).then(reply => {
            if (message.subject === "pollResponse" && reply?.response?.kind === "result" && reply.response.approvalCommitted === true && reply.state) {
                this.oracle.recordCommittedGrant({handle: {id: message.id, token: message.requestToken, profileIdentifier}, state: reply.state});
            }
            return reply;
        });
        this.track(promise);
        return promise;
    }
    track(promise, isCurrent = () => true) {
        const tracked = Promise.resolve(promise).catch(error => {
            if (isCurrent() && !nonfatal(error)) { this.asyncFailure ??= error; }
            this.record({type: "background-result", error: error.message, native: error.native === true});
        }).finally(() => { this.background.delete(tracked); this.backgroundLifetimes.delete(tracked); });
        this.background.add(tracked);
        this.backgroundLifetimes.set(tracked, isCurrent);
        return tracked;
    }
    trackPopup(promise, profileIdentifier) {
        const profile = this.browser.profile(profileIdentifier);
        const popup = profile.popup;
        return this.track(promise, () => !!popup?.alive && profile.popup === popup);
    }
    queueWalletMutation(kind, account) {
        const child = this.child("bridge");
        const sourceAction = this.actionIndex;
        const target = structuredClone(account);
        const observe = (exercised, status, error) => this.record({type: "wallet-mutation-result", sourceAction, kind,
            account: target, epoch: child.epoch, exercised, status, ...(error ? {error: error.message} : {})});
        const previous = this.walletMutations.get(child) ?? Promise.resolve();
        const completion = previous.then(async () => {
            if (child.expectedExit) { observe(false, "interrupted"); return; }
            try {
                this.check();
                if (this.children.get("bridge") !== child) {
                    throw new LifecycleFailure("ownership", "Wallet mutation lost its native process before dispatch", {epoch: child.epoch});
                }
                this.record({type: "wallet-mutation-start", sourceAction, kind, account: target, epoch: child.epoch});
                const result = await child.command("wallet", {action: kind === "removeAccount" ? "removeAccount" : "restore",
                    walletID: target.walletID, coin: target.coin, address: target.address});
                if (typeof result?.changed !== "boolean") {
                    throw new LifecycleFailure("protocol", "Wallet mutation omitted its settlement result", {sourceAction, kind, result});
                }
                const exercised = result.changed;
                if (exercised) {
                    this.coverage.add(`action:${kind}`);
                    if (kind === "removeAccount") {
                        for (const profileIdentifier of profiles) {
                            this.oracle.revoke({profileIdentifier, provider: target.coin, account: target.address, definite: false});
                        }
                    }
                }
                observe(exercised, exercised ? "completed" : "unchanged");
            } catch (error) {
                const unavailable = error.native === true && error.details === "unavailable";
                const interrupted = child.expectedExit && error.invariant === "process-restarted";
                if (!unavailable && !interrupted) { this.asyncFailure ??= error; }
                observe(false, unavailable ? "unavailable" : interrupted ? "interrupted" : "failed", error);
            }
        }).finally(() => {
            if (this.walletMutations.get(child) === completion) { this.walletMutations.delete(child); }
        });
        this.walletMutations.set(child, completion);
        this.track(completion);
    }
    observeNativeMessage({profileIdentifier, owner, message}) {
        if (!message.subject) {
            this.admissions.set(message.enqueueAttempt, {message: structuredClone(message), profileIdentifier, owner,
                operation: this.admissions.get(message.enqueueAttempt)?.operation || this.operationForAttempt(message.enqueueAttempt)});
        }
        if (message.subject === "approveRequest") {
            const handle = {id: message.id, token: message.requestToken, profileIdentifier};
            const intent = this.popupApprovals.get(owner);
            if (!intent || handleKey(intent.handle) !== handleKey(handle) || intent.review.reviewToken !== message.reviewToken ||
                !isDeepStrictEqual(intent.payload, message.payload)) {
                throw new LifecycleFailure("consent", "Popup approval does not match an explicit user decision", {owner, handle, message, intent});
            }
            this.popupApprovals.delete(owner);
            const request = this.nativeRequests.get(handleKey(handle));
            const review = intent.review;
            if (request?.provider === "solana" && request.name === "signAndSendTransaction") { request.reviewedCluster = message.payload.cluster; }
            if (request && review?.kind === "sendTransaction") {
                if (!request.expectedBody) { throw new LifecycleFailure("payload", "Transaction review has no original provider payload", {handle}); }
                const object = {...request.expectedBody.object};
                const quantity = value => "0x" + BigInt(value).toString(16);
                const gwei = value => {
                    const [integer, fraction = ""] = value.split(".");
                    return quantity(BigInt(integer || "0") * 1_000_000_000n + BigInt(fraction.padEnd(9, "0")));
                };
                if (review.editor.nonce !== "") { object.nonce = quantity(review.editor.nonce); }
                if (review.editor.usesEIP1559) {
                    object.maxFeePerGas = gwei(review.editor.maxFeePerGasGwei);
                    object.maxPriorityFeePerGas = gwei(review.editor.maxPriorityFeePerGasGwei);
                    delete object.gasPrice;
                } else { object.gasPrice = gwei(review.editor.gasPriceGwei); }
                request.reviewedBody = {...request.expectedBody, object};
            }
            this.savedReviews.push({handle, reviewToken: message.reviewToken, payload: structuredClone(message.payload)});
        }
    }
    operationForAttempt(enqueueAttempt) {
        for (const tab of this.tabs || []) {
            const request = [...tab.document.contentContext.bigWalletRequests.values()].find(value => value.enqueueAttempt === enqueueAttempt);
            if (!request) { continue; }
            return [...this.browser.operations.values()].find(value => value.document === tab.document.owner &&
                value.provider === request.message.provider && value.wireKind === "request" &&
                value.providerGeneration === request.generation && value.wireID === request.message.id);
        }
    }
    observeSettlement(operation) {
        const signingMethod = operation.provider === "ethereum" ?
            ["personal_sign", "eth_signTypedData", "eth_signTypedData_v3", "eth_signTypedData_v4", "eth_sendTransaction"].includes(operation.payload.method) :
            operation.provider === "solana" && ["signMessage", "signTransaction", "signAllTransactions", "signAndSendTransaction"].includes(operation.payload.method);
        if (operation.status === "fulfilled" && signingMethod &&
            (!operation.handle || !this.oracle.requests.has(handleKey(operation.handle)))) {
            throw new LifecycleFailure("isolation", "Successful signing operation has no observed native admission", {
                operation: operation.label, provider: operation.provider, method: operation.payload.method,
            });
        }
        const admitted = operation.handle && this.oracle.requests.get(handleKey(operation.handle));
        if (admitted && ((operation.profileIdentifier ?? null) !== admitted.handle.profileIdentifier ||
            new URL(operation.url).origin !== admitted.configurationKey || operation.provider !== admitted.provider)) {
            throw new LifecycleFailure("isolation", "Browser settlement does not match its admitted profile, origin, or provider", {operation, admitted});
        }
        this.oracle.settle({operation: operation.label, document: operation.document,
            currentDocument: operation.currentDocument, result: operation.result, error: operation.error, handle: operation.handle});
        if (operation.status !== "fulfilled") { return; }
        if (operation.provider === "ethereum" && operation.payload.method === "eth_requestAccounts" ||
            operation.provider === "solana" && operation.payload.method === "connect") {
            const approval = admitted?.approvals.map(label => this.oracle.approvals.get(label)).findLast(value => value.accepted);
            const state = operation.requestBody || operation.publicState;
            const expected = approval ? approval.grantAccounts[operation.provider] :
                canonicalAccount(operation.provider === "ethereum" ? state?.address : state?.publicKey);
            const accounts = operation.provider === "ethereum" ? operation.result : [operation.result?.publicKey];
            if (approval?.revoked || !expected || !Array.isArray(accounts) || accounts.length !== 1 || canonicalAccount(accounts[0]) !== expected) {
                throw new LifecycleFailure("consent", "Connection result does not match an authorized or approved account", {operation, expected});
            }
        }
        if (operation.provider === "ethereum" && operation.payload.method === "personal_sign") {
            assertEthereumSignature(operation.result, operation.payload.params[0], operation.payload.params[1]);
            this.coverage.add("crypto:ethereum:message");
        }
        if (operation.provider === "solana" && ["signMessage", "signTransaction"].includes(operation.payload.method)) {
            const request = this.nativeRequests.get(handleKey(operation.handle));
            const publicKey = request?.expectedBody?.publicKey || admitted.account;
            if (operation.result.publicKey !== publicKey) { throw new LifecycleFailure("payload", "Solana result changed the approved account", {operation, publicKey}); }
            const params = request?.expectedBody?.object.params || operation.payload.params;
            const message = operation.payload.method === "signTransaction" ? base58.decode(params.message) :
                params.messageEncoding === "utf8" ? Buffer.from(params.message) : Buffer.from(params.message.replace(/^0x/, ""), "hex");
            const signature = operation.result.signature;
            assertSolanaSignature(signature, message, publicKey);
            this.coverage.add(`crypto:solana:${operation.payload.method}`);
        }
        if (["eth_sendTransaction", "signAndSendTransaction"].includes(operation.payload.method)) {
            const expected = this.nativeRequests.get(operation.handle && handleKey(operation.handle));
            const receipt = this.ledger.events.findLast(event => event.type === "rpc.accepted" && expected &&
                handleKey(event.handle) === handleKey(operation.handle));
            const actual = operation.provider === "ethereum" ? operation.result : operation.result.signature;
            if (!receipt || receipt.transactionID !== actual) { throw new LifecycleFailure("payload", "Browser broadcast result does not match the accepted signed bytes", {operation, receipt}); }
            this.coverage.add(`crypto:${operation.provider}:broadcast`);
        }
    }
    async nativeEvent(event, child) {
        const details = {...event.details, epoch: child.epoch, role: child.role};
        if (event.event === "ready") { return; }
        if (event.event === "task") {
            if (typeof details.id !== "string" || typeof details.label !== "string" || typeof details.active !== "boolean") {
                throw new LifecycleFailure("protocol", "Malformed tracked native task", {details});
            }
            this.record({type: "native-task", ...details});
            return;
        }
        if (event.event === "gateRetired") {
            this.gates.delete(`${child.epoch}:${details.gate}`);
            return;
        }
        if (event.event === "timer") {
            const key = `${child.epoch}:${details.id}`;
            if (details.active) { this.nativeTimers.set(key, {...details, monotonicDeadline: this.scheduler.monotonic + Math.max(0, details.deadlineMilliseconds - this.scheduler.now)}); }
            else { this.nativeTimers.delete(key); }
            return;
        }
        if (event.event === "presentation") { this.record({type: "presentation", ...details}); return; }
        if (event.event === "authority.event") {
            if (!["requestAdmitted", "consentAccepted", "authorization", "signingStarted", "signingFinished", "broadcastCheckpoint",
                "broadcastDispatch", "completion", "authenticationCompleted", "protectedKeyRead", "vaultPublication"].includes(details.kind)) {
                throw new LifecycleFailure("protocol", "Unknown authority observation", {details});
            }
            this.coverage.add(`authority:${details.kind}`);
            this.ledger.append({type: "authority.event", ...details});
            return;
        }
        if (event.event === "admission") {
            const admitted = this.admissions.get(details.enqueueAttempt);
            if (!admitted) { throw new LifecycleFailure("isolation", "Native admission has no captured browser attempt", details); }
            const message = admitted.message;
            const manualSwitch = message.provider === "unknown" && message.name === "switchAccount";
            if ((details.handle?.profileIdentifier ?? null) !== (admitted.profileIdentifier ?? null) ||
                details.configurationKey !== message.configurationKey || details.provider !== message.provider || details.name !== message.name ||
                !manualSwitch && details.handle?.id !== message.id) {
                throw new LifecycleFailure("isolation", "Native admission does not match its captured browser attempt", {details, admitted});
            }
            const operation = admitted.operation || this.operationForAttempt(details.enqueueAttempt);
            if (operation ? operation.provider !== details.provider || operation.wireKind !== "request" ||
                requestNameForOperation(operation) !== details.name : !manualSwitch) {
                throw new LifecycleFailure("isolation", "Native admission changed the original public request method or provider", {details, operation});
            }
            if (operation) { operation.handle = details.handle; }
            const key = handleKey(details.handle);
            const previous = this.nativeRequests.get(key);
            const expectedBody = previous?.expectedBody || operation?.requestBody;
            this.oracle.register({handle: details.handle, configurationKey: details.configurationKey, provider: details.provider, name: details.name,
                payloadDigest: details.payloadDigest, enqueueAttempt: details.enqueueAttempt, authority: admitted.message.authority,
                account: expectedBody?.address || expectedBody?.publicKey || admitted?.message.body?.address || admitted?.message.body?.publicKey || undefined});
            this.nativeRequests.set(key, {...previous, ...admitted.message, handle: details.handle, expectedBody});
            this.coverage.add("admission");
            return;
        }
        if (event.event === "launch") {
            try {
                let approval = this.children.get("approval");
                if (approval?.expectedExit && !approval.exited) { throw new LifecycleFailure("process-restarted", "Approval launch raced an intentional restart"); }
                if (!approval || approval.exited) { approval = await this.start("approval"); }
                if (details.url) { await approval.command("route", {url: details.url}); }
                if (!child.exited && !child.expectedExit && child.gates.has(event.gate)) { child.release(event.gate, {success: true, identity: approval.ready.identity}); }
            } catch (error) {
                if (error?.invariant !== "process-restarted") { throw error; }
                if (!child.exited && !child.expectedExit && child.gates.has(event.gate)) { child.release(event.gate, {success: false}); }
            }
            return;
        }
        if (event.event === "rpc") {
            const result = await this.rpc.respond(details);
            if (!child.exited && !child.expectedExit && child.gates.has(event.gate)) { child.release(event.gate, result); }
            return;
        }
        if (event.event === "consent") {
            this.oracle.acceptConsent({...details, revision: details.reviewedRevision});
            this.ledger.append({type: "consent", ...details});
            if (details.label) { this.savedConsents.push({label: details.label, handle: details.handle, role: child.role, epoch: child.epoch}); }
            return;
        }
        if (event.event === "checkpoint") {
            const name = details.name;
            if (typeof name !== "string") { throw new LifecycleFailure("protocol", "Checkpoint omitted its name", details); }
            this.coverage.add(name);
            if (details.fault === true && name.startsWith("persistence.")) {
                this.coverage.add("action:failPersistence");
                this.coverage.add(`fault:persistence:${name}`);
            }
            if (name === "signer.before") { this.oracle.execution({...details, account: details.approvedAccount}); }
            if (name === "signer.after") { this.oracle.signed(details); if (details.succeeded) { this.verifySigning(details); } }
            if (name === "broadcast.prepared") { this.oracle.checkpoint(details); }
            if (name === "completion.after" && details.handle) { this.oracle.completed(details.handle); }
            if (name === "revocation.after") {
                const pending = [...this.gates.values()].map(gate => gate.details).concat(
                    this.scheduler.pending({kind: "native-gate"}).map(task => ({name: task.details.subject, handle: task.details.handle})));
                const held = pending.filter(gate => ["signer.before", "signer.after", "authorize.after", "claim.after", "broadcast.prepare.before"].includes(gate.name));
                const definiteHandles = held.filter(gate => gate.handle).map(gate => handleKey(gate.handle));
                const beforeSigningHandles = held.filter(gate => gate.handle && gate.name === "signer.before").map(gate => handleKey(gate.handle));
                if (details.provider) { this.oracle.revoke({...details, definiteHandles, beforeSigningHandles}); }
                for (const removal of details.removals || []) {
                    const accounts = removal.kind === "accounts" ? removal.accounts : this.accounts.filter(account => account.walletID === removal.walletID);
                    for (const account of accounts) {
                        for (const profileIdentifier of profiles) { this.oracle.revoke({profileIdentifier, provider: account.coin, account: account.address, definiteHandles, beforeSigningHandles}); }
                    }
                }
            }
            this.ledger.append({type: "checkpoint", ...details});
            if (event.gate) {
                if (details.hold === true) { this.gates.set(`${child.epoch}:${event.gate}`, {event, child, details}); }
                else {
                    const request = details.handle && this.nativeRequests.get(handleKey(details.handle));
                    this.scheduler.schedule(() => {
                        if (!child.exited && !child.expectedExit && child.gates.has(event.gate)) { child.release(event.gate, null); }
                    }, 0, `native:${child.epoch}`, "native-gate", {subject: name, handle: details.handle,
                        transportKey: details.enqueueAttempt || request?.enqueueAttempt || ""});
                }
            }
            return;
        }
        if (event.event === "observation") { this.ledger.append({type: "observation", ...details}); return; }
        throw new LifecycleFailure("protocol", "Unknown native lifecycle event", {event});
    }
    async externalCheckpoint(name, details) {
        this.coverage.add(name);
        const rule = this.externalRule;
        if (rule?.name !== name) { return; }
        this.externalRule = null;
        await new Promise(resolveGate => {
            this.gates.set(`external:${name}`, {details: {...details, name}, external: true, release: resolveGate});
        });
    }
    verifySigning(details) {
        const request = this.nativeRequests.get(handleKey(details.handle));
        if (!request) { throw new LifecycleFailure("payload", "Signature has no original browser request", details); }
        const body = request.expectedBody;
        const response = details.response;
        if ((details.signedTransaction || response?.kind === "result") && !body) {
            throw new LifecycleFailure("payload", "Signature has no original provider payload", details);
        }
        if (details.signedTransaction) {
            const expectedBody = request.reviewedBody || body;
            const bytes = Buffer.from(details.signedTransaction.replace(/^0x/, ""), details.encoding === "hex" ? "hex" : "base64");
            let transactionID;
            if (request.provider === "ethereum") {
                assertEthereumTransaction(bytes, expectedBody);
                transactionID = "0x" + Buffer.from(keccak_256(bytes)).toString("hex");
            } else {
                assertSolanaTransaction(bytes, expectedBody);
                const parsed = solanaMessage(bytes);
                transactionID = base58.encode(bytes.subarray(parsed.signaturesOffset, parsed.signaturesOffset + 64));
            }
            if (transactionID !== details.transactionID) { throw new LifecycleFailure("payload", "Signing output transaction identity does not match its actual bytes", {transactionID, details}); }
            this.coverage.add(`signed-bytes:${request.provider}`);
        }
        if (response?.kind !== "result") { return; }
        if (request.provider === "ethereum" && request.name === "signPersonalMessage") {
            assertEthereumSignature(response.result, body.object.data, body.address);
        } else if (request.provider === "solana" && ["signMessage", "signTransaction"].includes(request.name)) {
            const params = body.object.params;
            const message = request.name === "signTransaction" ? base58.decode(params.message) :
                params.messageEncoding === "utf8" ? Buffer.from(params.message) : Buffer.from(params.message.replace(/^0x/, ""), "hex");
            assertSolanaSignature(response.result, message, body.publicKey);
        }
    }
    check() {
        if (this.asyncFailure) { throw this.asyncFailure; }
        for (const child of this.children.values()) { if (child.failure) { throw child.failure; } }
        this.browser?.check();
        for (const tab of this.browser?.snapshot() || []) {
            const cached = tab.configuration;
            if (cached?.state) {
                this.oracle.configuration({profileIdentifier: tab.profileIdentifier, configurationKey: cached.configurationKey,
                    generation: cached.providerGeneration, state: cached.state});
            }
        }
    }
    async pumpUntil(predicate, {timeout = this.options.timeout, advance = false} = {}) {
        const deadline = performance.now() + timeout;
        for (let iteration = 0; iteration < 1000000; iteration += 1) {
            this.check();
            if (predicate()) { return; }
            if (performance.now() >= deadline) { throw new LifecycleFailure("watchdog", "Lifecycle progress checkpoint was not reached", {action: this.currentAction, gates: [...this.gates.keys()], browser: this.browser?.snapshot()}); }
            if (await this.scheduler.deliver()) { continue; }
            await pause();
            const browserOnly = this.children.size === 0;
            if (advance && (browserOnly || iteration % 100 === 99) && !predicate()) {
                const nearest = (browserOnly ? [] : [...this.nativeTimers.values()].map(timer => timer.monotonicDeadline))
                    .concat(this.scheduler.pending().filter(task => !task.held).map(task => task.due))
                    .filter(value => value > this.scheduler.monotonic).sort((a, b) => a - b)[0];
                if (nearest !== undefined) {
                    const remaining = nearest - this.scheduler.monotonic;
                    await this.advance(browserOnly ? remaining : Math.min(250, remaining));
                }
            }
        }
        throw new LifecycleFailure("progress", "Lifecycle scheduler exceeded its action budget", {action: this.currentAction});
    }
    async pump() {
        if (this.scheduler.replay) {
            for (let turn = 0; turn < 8 && this.scheduler.expected?.phase === this.scheduler.phase && this.scheduler.expected.type === "schedule"; turn += 1) {
                this.check();
                if (await this.scheduler.deliver()) { turn = 0; continue; }
                await pause();
            }
            this.check();
            return;
        }
        for (let round = 0; round < 8; round += 1) { await this.scheduler.drain(); await pause(); }
        this.check();
    }
    async inspect() {
        const bridge = this.child("bridge");
        this.lastInspectionAvailable = true;
        for (const profileIdentifier of profiles) {
            let state;
            try { state = await bridge.command("inspect", {profileIdentifier}); }
            catch (error) {
                if (!error.native || !/Store unavailable/.test(error.message)) { throw error; }
                this.lastInspectionAvailable = false;
                this.record({type: "observation-unavailable", profileIdentifier});
                this.coverage.add("store-unavailable");
                continue;
            }
            if (!state || !Array.isArray(state.requests)) { throw new LifecycleFailure("protocol", "Native inspect omitted requests", {state}); }
            if (state.durableObservationAvailable !== true) { this.lastInspectionAvailable = false; }
            if (this.mode === "native") {
                try {
                    const nativeState = await this.child("approval").command("inspect", {profileIdentifier});
                    state.requests = state.requests.map(request => ({...request,
                        ...nativeState.requests.find(value => handleKey(value.handle) === handleKey(request.handle))}));
                } catch (error) {
                    if (!error.native || !/Store unavailable/.test(error.message)) { throw error; }
                    this.lastInspectionAvailable = false;
                    this.record({type: "observation-unavailable", profileIdentifier, role: "approval"});
                }
            }
            this.snapshots.set(profileIdentifier, state);
            for (const request of state.requests) {
                const handle = {...request.handle, profileIdentifier: request.handle?.profileIdentifier ?? profileIdentifier};
                const admitted = request.enqueueAttempt ? this.admissions.get(request.enqueueAttempt) :
                    [...this.admissions.values()].findLast(value => value.profileIdentifier === profileIdentifier && value.message.id === handle.id &&
                        value.message.provider === request.provider && value.message.configurationKey === request.configurationKey);
                if (request.provider && request.name) {
                    this.oracle.register({handle, configurationKey: request.configurationKey, provider: request.provider, name: request.name,
                        payloadDigest: request.requestFingerprint, enqueueAttempt: request.enqueueAttempt, authority: admitted?.message.authority ?? request.request?.authority,
                        account: request.account ?? admitted?.message.body?.address ?? admitted?.message.body?.publicKey});
                }
                this.oracle.observeDurable({...request, handle});
            }
        }
        return [...this.snapshots].flatMap(([profileIdentifier, state]) => state.requests.map(request => ({...request,
            handle: {...request.handle, profileIdentifier: request.handle?.profileIdentifier ?? profileIdentifier}})));
    }
    account(provider) {
        const account = this.accounts.find(value => value.coin === provider);
        if (!account) { throw new LifecycleFailure("coverage", "Fixture account missing", {provider}); }
        return account;
    }
    solanaTransaction(address = this.account("solana").address) {
        const key = new PublicKey(address);
        const transaction = new Transaction({feePayer: key, recentBlockhash: "11111111111111111111111111111111"});
        transaction.add(SystemProgram.transfer({fromPubkey: key, toPubkey: new PublicKey("11111111111111111111111111111111"), lamports: 1}));
        return transaction;
    }
    request(action) {
        const tab = this.tabs[action.tab];
        const provider = action.provider || "ethereum";
        const method = action.method || "message";
        if (method === "switchAccount") { this.browser.toolbar(tab.id); return null; }
        let payload;
        if (provider === "ethereum") {
            const address = tab.document.pageWindow.ethereum.selectedAddress || this.account(provider).address;
            switch (method) {
            case "connect": payload = {method: "eth_requestAccounts", params: []}; break;
            case "message": payload = {method: "personal_sign", params: ["0x010203", address]}; break;
            case "transaction":
            case "broadcast": payload = {method: "eth_sendTransaction", params: [{from: address,
                to: "0x0000000000000000000000000000000000000002", value: "0x1", gas: "0x5208", gasPrice: "0x77359400", nonce: "0x0", chainId: "0x1"}]}; break;
            case "addChain": payload = {method: "wallet_addEthereumChain", params: [{chainId: "0x539", chainName: "Lifecycle Fixture",
                nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18}, rpcUrls: ["https://chain-1337.lifecycle.invalid"], blockExplorerUrls: []}]}; break;
            default: throw new Error(`Unsupported request ${method}`);
            }
        } else {
            const address = tab.document.pageWindow.solana.publicKey?.toBase58() || this.account("solana").address;
            switch (method) {
            case "connect": payload = {method: "connect"}; break;
            case "message": payload = {method: "signMessage", params: {message: "0x010203", display: "hex"}}; break;
            case "transaction": payload = {method: "signTransaction", params: {message: base58.encode(this.solanaTransaction(address).serializeMessage())}}; break;
            case "broadcast": payload = {method: "signAndSendTransaction", params: {transaction: this.solanaTransaction(address).serialize({requireAllSignatures: false, verifySignatures: false}), options: {skipPreflight: false}}}; break;
            case "addChain": payload = {method: "connect", params: {onlyIfTrusted: true}}; break;
            default: throw new Error(`Unsupported Solana request ${method}`);
            }
        }
        this.coverage.add(`action:request:${provider}:${method}`);
        return this.browser.request(tab.id, provider, payload);
    }
    async chooseRequest(action = {}) {
        const requests = (await this.inspect()).filter(request => request.phase !== "responded" && request.phase !== "completed");
        return requests.length ? requests[(action.selector || 0) % requests.length] : null;
    }
    gateIdentity(gate) {
        if (gate.details.gateKey) { return `${gate.child?.role || "external"}|${gate.details.gateKey}`; }
        const request = gate.details.handle && this.nativeRequests.get(handleKey(gate.details.handle));
        return `${gate.child?.role || "external"}|${gate.details.name}|${request?.enqueueAttempt || ""}`;
    }
    async refreshTab(index) {
        const tab = this.tabs[index];
        const bridge = this.child("bridge");
        const deadline = performance.now() + this.options.timeout;
        let reply;
        for (let attempt = 0; ; attempt += 1) {
            const remaining = deadline - performance.now();
            if (remaining <= 0) { throw new LifecycleFailure("watchdog", "Fresh native configuration remained unavailable", {tab: index, reply}); }
            reply = await bridge.command("native", {profileIdentifier: tab.profile.id, message: {
                id: 1, subject: "getLatestConfiguration", configurationKey: new URL(tab.url).origin,
                workflowVersion: bridge.ready.workflowVersion, __bwContext: nativeSiteContext(tab),
            }}, {timeout: remaining});
            if (reply?.id === 1 && reply.state && !Object.hasOwn(reply, "unavailable")) { break; }
            if (reply?.id !== 1 || reply.unavailable !== true || Object.keys(reply).length !== 2 || attempt >= 2) {
                throw new LifecycleFailure("progress", "Fresh native configuration is unavailable", {tab: index, reply});
            }
            await this.pump();
            await this.advance(attempt === 0 ? 1000 : 5000);
        }
        if (!this.browser.configurationReady(tab.id, reply.state)) { this.browser.focus(tab.id); }
        await this.pumpUntil(() => this.browser.configurationReady(tab.id, reply.state), {advance: true});
        await this.pump();
    }
    async holdNative(action) {
        const phase = this.scheduler.phase;
        await this.quiesce({rejectReviews: true});
        this.scheduler.phase = phase;
        const tab = this.tabs[action.tab];
        await this.inspect();
        if (!(this.snapshots.get(tab.profile.id)?.accounts || []).some(account => account.coin === action.provider)) {
            await this.child("bridge").command("wallet", {action: "restore", walletID: this.account(action.provider).walletID});
        }
        await this.refreshTab(action.tab);
        await this.connect(action.tab, action.provider);
        if (action.provider === "ethereum" && tab.document.pageWindow.ethereum.chainId !== "0x1") {
            await this.complete(this.browser.request(tab.id, "ethereum", {method: "wallet_switchEthereumChain", params: [{chainId: "0x1"}]}), {expectedSuccess: true});
        }
        const owner = this.child(this.mode === "native" ? "approval" : "bridge");
        const early = this.mode === "native" && action.checkpoint === "authentication.before";
        const arm = () => owner.command("checkpoints", {rules: [{name: action.checkpoint, action: "hold", occurrence: 1}]});
        if (early) { await arm(); }
        const operation = this.request({...action, method: action.checkpoint === "broadcast.prepared" ? "broadcast" : "message"});
        if (!early) {
            const deadline = performance.now() + this.options.timeout;
            let request;
            while (performance.now() < deadline) {
                await this.pump();
                const requests = await this.inspect();
                request = requests.find(value => operation.handle && handleKey(value.handle) === handleKey(operation.handle));
                if (request && (this.mode === "native" ? request.presentation === "review" :
                    this.browser.popupState(tab.profile.id)?.id === request.handle.id && this.browser.popupState(tab.profile.id)?.actions.includes("approve"))) { break; }
                await this.advance(100);
            }
            if (!request) { throw new LifecycleFailure("coverage", "Native gate request did not reach a review", {action}); }
            await arm();
            if (!await this.decide({}, "approve", request)) { throw new LifecycleFailure("coverage", "Native gate could not obtain explicit approval", {action}); }
        }
        await this.pumpUntil(() => [...this.gates.values()].some(gate => gate.details.name === action.checkpoint && gate.details.handle &&
            operation.handle && handleKey(gate.details.handle) === handleKey(operation.handle)), {advance: true});
        const reached = [...this.gates.values()].find(gate => gate.details.name === action.checkpoint && gate.details.handle &&
            handleKey(gate.details.handle) === handleKey(operation.handle));
        const selected = this.decision("native-gate", this.gateIdentity(reached));
        if (selected !== this.gateIdentity(reached)) { throw new LifecycleFailure("replay-schedule", "Native checkpoint belongs to another replay request", {selected, reached: this.gateIdentity(reached)}); }
        this.coverage.add(`gate:${action.checkpoint}`);
    }
    async decide(action = {}, decision = "approve", request = null) {
        request ??= await this.chooseRequest(action);
        if (!request) { return false; }
        const profileIdentifier = request.handle.profileIdentifier;
        if (this.mode === "popup") {
            await this.browser.openPopup(profileIdentifier);
            await this.pump();
            let state = this.browser.popupState(profileIdentifier);
            const displayed = this.browser.popupRequest(profileIdentifier);
            if (!state || !this.browser.popupReviewing(profileIdentifier) || displayed?.id !== request.handle.id ||
                displayed.requestToken !== request.handle.token) { return false; }
            if (decision === "approve" && state.review?.requiresClusterSelection) {
                const popup = this.browser.profile(profileIdentifier).popup;
                const index = state.review.clusters.findIndex(cluster => cluster.value === "devnet");
                if (index >= 0) { await popup.harness.get("clusters").children[index].click(); state = this.browser.popupState(profileIdentifier); }
            }
            if (decision === "approve" && !state.actions.includes("approve")) { return false; }
            if (decision === "reject" && !state.actions.includes("reject")) { return false; }
            if (decision === "retry" && !state.actions.includes("retry") && !state.actions.includes("retryTransaction")) { return false; }
            const popup = this.browser.profile(profileIdentifier).popup;
            const buttonID = decision === "reject" ? "button-reject" : "button-approve";
            if (popup.harness.get(buttonID).disabled) { return false; }
            const before = popup.harness.nativeMessages.length;
            let intent;
            if (decision === "approve") {
                const presentation = this.browser.popupPresentation(profileIdentifier);
                const payload = {};
                if (state.review.kind === "accountSelection") {
                    payload.selectedAccounts = presentation.accounts;
                    if (state.review.canSelectNetwork && presentation.chainId) { payload.chainId = presentation.chainId; }
                } else if (state.review.kind === "signMessage" && presentation.cluster) { payload.cluster = presentation.cluster; }
                const label = `popup-approval-${++this.approvalSerial}`;
                this.oracle.approvalIntent({handle: request.handle, label, selectedAccounts: payload.selectedAccounts});
                intent = {handle: structuredClone(request.handle), payload, review: structuredClone(state.review)};
                this.popupApprovals.set(popup.owner, intent);
            }
            const subjects = decision === "approve" ? ["approveRequest"] : decision === "reject" ? ["rejectRequest"]
                : ["retryApproval", "retryTransaction"];
            const attempted = () => popup.harness.nativeMessages.slice(before).some(message => subjects.includes(message.subject));
            let clickFinished = false;
            try {
                this.trackPopup(Promise.resolve(this.browser.clickPopup(profileIdentifier, buttonID)).finally(() => {
                    clickFinished = true;
                }), profileIdentifier);
                await this.scheduler.until(() => attempted() || clickFinished || !popup.alive ||
                    this.browser.profile(profileIdentifier).popup !== popup, {timeout: this.options.timeout});
            } finally {
                if (intent && this.popupApprovals.get(popup.owner) === intent) { this.popupApprovals.delete(popup.owner); }
            }
            if (!attempted()) { return false; }
        } else {
            if (decision === "approve" && request.presentation !== "review") { return false; }
            const label = `native-approval-${++this.approvalSerial}`;
            let selectedAccounts;
            if (decision === "approve") {
                if (["requestAccounts", "connect", "switchAccount"].includes(request.name)) {
                    const catalog = this.snapshots.get(profileIdentifier)?.accounts || [];
                    const providers = request.provider === "unknown" ? ["ethereum", "solana"] : [request.provider];
                    selectedAccounts = providers.map(provider => catalog.find(account => account.coin === provider)).filter(Boolean)
                        .map(account => ({walletId: account.walletID, address: account.address, coin: account.coin, derivationPath: account.path}));
                }
                if (request.provider === "solana" && request.name === "signAndSendTransaction") {
                    const admitted = this.nativeRequests.get(handleKey(request.handle));
                    if (admitted) { admitted.reviewedCluster = "devnet"; }
                }
                this.oracle.approvalIntent({handle: request.handle, label, revision: request.revision, selectedAccounts});
                this.savedReviews.push({handle: request.handle, revision: request.revision});
            }
            this.track(this.child("approval").command("decide", {handle: request.handle, decision,
                ...(request.revision === undefined ? {} : {revision: request.revision}),
                ...(decision === "approve" ? {saveAs: label, ...(selectedAccounts ? {selectedAccounts} : {})} : {})}, {timeout: 60000}));
        }
        this.coverage.add(`action:${decision}`);
        return true;
    }
    async advance(milliseconds) {
        if (this.scheduler.replay) {
            await this.pump();
            const expected = this.scheduler.expected;
            if (!expected || expected.phase !== this.scheduler.phase || expected.type !== "clock") { return; }
            this.scheduler.setClock(expected.time);
            this.scheduler.replayIndex += 1;
        } else { this.scheduler.setClock(this.scheduler.now + milliseconds); }
        this.record({type: "clock", phase: this.scheduler.phase, time: this.scheduler.now});
        for (const child of this.children.values()) {
            if (!child.exited && !child.expectedExit) { await child.command("clock", {nowMilliseconds: this.scheduler.now}); }
        }
        await this.scheduler.drain();
    }
    async barrier(label) {
        this.record({type: "barrier", phase: this.scheduler.phase, label});
    }
    decision(type, proposed) {
        const ordinal = this.decisions.filter(value => value.phase === this.scheduler.phase && value.type === type).length;
        const saved = this.options.decisions?.[this.decisions.length];
        if (this.options.decisions !== undefined && !saved) {
            throw new LifecycleFailure("replay-schedule", "Replay reached an unrecorded scheduling decision", {
                expected: this.options.decisions.length, consumed: this.decisions.length,
                actual: {type, phase: this.scheduler.phase, ordinal},
            });
        }
        if (saved && (saved.phase !== this.scheduler.phase || saved.type !== type || saved.ordinal !== ordinal)) {
            throw new LifecycleFailure("replay-schedule", "Explicit scheduling decision diverged from the saved schedule", {
                expected: saved, actual: {type, phase: this.scheduler.phase, ordinal},
            });
        }
        const choice = saved ? saved.choice : proposed;
        this.decisions.push({type, phase: this.scheduler.phase, ordinal, choice});
        return choice;
    }
    async restart(role) {
        const old = this.child(role);
        await old.kill();
        this.scheduler.retire(`native:${old.epoch}`);
        for (const [key, gate] of this.gates) {
            if (gate.child === old) { this.gates.delete(key); }
        }
        const child = await this.start(role);
        await child.command("clock", {nowMilliseconds: this.scheduler.now});
        if (this.mode === "native") {
            await this.child("bridge").command("runtime", {identity: this.child("approval").ready.identity});
        }
        this.coverage.add(`restart:${role}`);
        return child;
    }
    async action(action) {
        await this.barrier("before-action");
        this.actionIndex += 1;
        this.scheduler.phase = this.options.actionPhases?.[this.actionIndex] ?? this.actionIndex;
        this.currentAction = structuredClone(action);
        this.record({type: "action", action});
        const tab = this.tabs[action.tab];
        let exercised = true;
        let pending = false;
        switch (action.kind) {
        case "request": this.request(action); break;
        case "holdNative": await this.holdNative(action); break;
        case "releaseNative": {
            const gates = [...this.gates.values()];
            const selected = this.decision("release-gate", gates.length ? this.gateIdentity(gates[action.selector % gates.length]) : null);
            exercised = selected !== null;
            if (selected !== null) {
                const pair = [...this.gates].find(([, gate]) => this.gateIdentity(gate) === selected);
                if (!pair) { throw new LifecycleFailure("replay-schedule", "Saved native gate is unavailable", {selected}); }
                const [key, gate] = pair;
                if (gate.external) { gate.release(); } else { gate.child.release(gate.event.gate, null); }
                this.gates.delete(key);
            }
            break;
        }
        case "approve":
        case "reject":
        case "retry": exercised = await this.decide(action, action.kind); break;
        case "closePopup": this.browser.closePopup(tab.profile.id); break;
        case "openPopup": await this.browser.openPopup(tab.profile.id); break;
        case "navigate": this.browser.navigate(tab.id, origins[action.selector % origins.length] + `/document-${this.trace.length}`); break;
        case "replaceDocument": this.browser.replaceProvider(tab.id); break;
        case "restartWorker": this.browser.restartWorker(tab.profile.id); break;
        case "restartNative": await this.restart(action.role || "bridge"); break;
        case "wake": this.browser.wake(tab.profile.id); break;
        case "focus": this.browser.focus(tab.id); break;
        case "delay":
        case "drop":
        case "duplicate": {
            const targets = this.options.faultTargets;
            if (targets === undefined || Object.hasOwn(targets, this.actionIndex)) {
                const target = targets?.[this.actionIndex];
                if (targets !== undefined && (typeof target !== "string" || !target.length)) {
                    throw new LifecycleFailure("replay-schedule", "Recorded transport fault has no target", {sourceAction: this.actionIndex, target});
                }
                this.browser.addFault({...action, action: action.kind, sourceAction: this.actionIndex, target});
            }
            exercised = false;
            break;
        }
        case "deliver": {
            const available = this.scheduler.pending({kind: "message", ready: true});
            const selected = this.decision("delivery", available.length ? available[action.selector % available.length].key : null);
            exercised = selected !== null;
            if (exercised) {
                const deadline = performance.now() + this.options.timeout;
                let task;
                while (!(task = this.scheduler.pending({kind: "message", ready: true}).find(value => value.key === selected))) {
                    this.check();
                    if (performance.now() >= deadline) { throw new LifecycleFailure("replay-schedule", "Selected transport delivery did not become available", {selected}); }
                    await pause();
                }
                await this.scheduler.deliver(task.id);
            }
            break;
        }
        case "expire":
        case "clockBackward": await this.advance(action.milliseconds); break;
        case "disconnect": {
            const provider = action.selector % 2 ? "solana" : "ethereum";
            this.browser.request(tab.id, provider, provider === "solana" ? {method: "disconnect"} : {method: "wallet_revokePermissions", params: [{eth_accounts: {}}]});
            break;
        }
        case "removeAccount":
        case "restoreAccount": {
            const currentAccounts = this.snapshots.get(tab.profile.id)?.accounts || [];
            const available = action.kind === "restoreAccount" ? this.accounts :
                currentAccounts.filter(account => account.walletID === "fixture-multicoin" &&
                    currentAccounts.filter(other => other.walletID === account.walletID).length > 1);
            if (!available.length) { exercised = false; break; }
            const account = available[action.selector % available.length];
            this.queueWalletMutation(action.kind, account);
            exercised = false;
            pending = true;
            break;
        }
        case "changeNetwork": await this.child("bridge").command("network", {chainId: 1337, action: action.selector % 2 ? "replace" : "remove", rpcURL: "https://chain-1337.lifecycle.invalid"}); break;
        case "failPersistence": await this.child(action.role || "bridge").command("checkpoints", {rules: [{name: action.checkpoint, occurrence: 1, action: "fail", errno: 5}], partialWriteBytes: action.partialWriteBytes}); exercised = false; break;
        case "staleConsent": {
            const saved = this.savedConsents.at(-1);
            exercised = !!saved;
            if (saved) { this.track(this.child(saved.role).command("decide", {handle: saved.handle, decision: "approve", useSaved: saved.label})); }
            break;
        }
        case "staleReview": {
            const saved = this.savedReviews[0];
            exercised = !!saved;
            if (saved) {
                if (this.mode === "native") { this.track(this.child("approval").command("decide", {handle: saved.handle, decision: "approve", revision: saved.revision ?? -1})); }
                else { this.track(this.child("bridge").command("native", {profileIdentifier: saved.handle.profileIdentifier,
                    message: {subject: "approveRequest", id: saved.handle.id, requestToken: saved.handle.token,
                        reviewToken: saved.reviewToken, payload: saved.payload || {}, workflowVersion: 4,
                        __bwContext: {source: "popup", privateBrowsing: false}}})); }
            }
            break;
        }
        case "compete": {
            const request = await this.chooseRequest(action);
            exercised = !!request;
            if (request && this.mode === "popup") {
                const owner = this.child("bridge");
                const claimed = await owner.command("claim", {handle: request.handle, label: "random-owner"});
                if (claimed === "claimed") {
                    const contender = this.children.get("approval") || await this.start("approval");
                    const other = await contender.command("claim", {handle: request.handle, label: "random-contender"});
                    if (other === "claimed") { throw new LifecycleFailure("ownership", "Two live processes claimed one request"); }
                    await owner.command("releaseClaim", {label: "random-owner"});
                    this.coverage.add("competing-processes");
                } else { exercised = false; }
            } else if (request) { exercised = await this.decide(action, "approve", request); await this.decide(action, "approve", request); }
            break;
        }
        case "cancelAuthentication": {
            const gate = [...this.gates.values()].find(value => value.details.name === "authentication.before");
            exercised = !!gate;
            if (gate) { gate.child.release(gate.event.gate, {cancel: true}); this.gates.delete(`${gate.child.epoch}:${gate.event.gate}`); }
            break;
        }
        case "editFees": {
            if (this.mode !== "popup") { exercised = false; break; }
            const popup = this.browser.profile(tab.profile.id).popup;
            const state = this.browser.popupState(tab.profile.id);
            exercised = !!popup && state?.actions.includes("editTransaction");
            if (exercised) {
                await popup.harness.get("tx-editor-summary").click();
                const gasPrice = popup.harness.get("edit-gas-price");
                gasPrice.value = "3";
                await gasPrice.emit("input");
                this.trackPopup(popup.harness.get("editor-apply").click(), tab.profile.id);
            }
            break;
        }
        default: throw new Error(`Unhandled action ${action.kind}`);
        }
        this.record({type: "action-result", kind: action.kind, exercised, ...(pending ? {pending} : {})});
        if (exercised) { this.coverage.add(`action:${action.kind}`); }
        await this.pump();
        await this.inspect();
        this.check();
        await this.barrier("action-end");
    }
    async complete(operation, {approve = true, expectedSuccess = false, maximum = 100} = {}) {
        for (let turn = 0; turn < maximum && operation.status === "pending"; turn += 1) {
            await this.pump();
            const requests = await this.inspect();
            if (approve) {
                const request = requests.find(request => request.provider === operation.provider && request.handle.profileIdentifier === operation.profileIdentifier &&
                    request.configurationKey === new URL(operation.url).origin && !["responded", "completed"].includes(request.phase));
                if (request) { await this.decide({}, "approve", request); }
            }
            await this.pump();
            if (operation.status === "pending") { await this.advance(1000); }
        }
        if (operation.status === "pending") { throw new LifecycleFailure("progress", "A live browser request did not finish after faults stopped", {operation, snapshots: [...this.snapshots]}); }
        if (expectedSuccess && operation.status !== "fulfilled") { throw new LifecycleFailure("coverage", "Required known-success request failed", {operation, snapshots: [...this.snapshots]}); }
        return operation;
    }
    async connect(tab = 0, provider = "ethereum") {
        const operation = this.request({tab, provider, method: "connect"});
        await this.complete(operation, {expectedSuccess: true});
        return operation;
    }
    async quiesce({rejectReviews = false} = {}) {
        await this.barrier("before-recovery");
        this.scheduler.phase = "recovery";
        this.browser.faults = [];
        if (this.mode === "popup") {
            for (const profileIdentifier of profiles) {
                this.browser.closePopup(profileIdentifier);
                await this.browser.openPopup(profileIdentifier);
            }
        }
        for (const child of this.children.values()) {
            if (!child.exited) { await child.command("checkpoints", {rules: []}); }
        }
        for (const gate of this.gates.values()) {
            if (gate.external) { gate.release(); }
            else if (!gate.child.exited) { gate.child.release(gate.event.gate, null); }
        }
        this.gates.clear();
        for (let step = 0; step < 80; step += 1) {
            await this.pump();
            const requests = await this.inspect();
            await this.pump();
            for (const [promise, isCurrent] of this.backgroundLifetimes) {
                if (!isCurrent()) { this.background.delete(promise); this.backgroundLifetimes.delete(promise); }
            }
            const pendingBrowser = [...this.browser.operations.values()].some(operation => operation.status === "pending");
            const nativeIsSettled = requests.every(request => {
                if (["responded", "completed"].includes(request.phase)) { return true; }
                if (request.phase !== "queued" || rejectReviews) { return false; }
                if (this.mode === "native") { return request.presentation === "review"; }
                const current = this.browser.popupRequest(request.handle.profileIdentifier);
                return current?.id === request.handle.id && current.requestToken === request.handle.token &&
                    this.browser.popupReviewing(request.handle.profileIdentifier) &&
                    typeof this.browser.popupState(request.handle.profileIdentifier)?.review?.reviewToken === "string";
            });
            if (!pendingBrowser && nativeIsSettled && this.background.size === 0 && this.lastInspectionAvailable &&
                this.scheduler.pending({kind: "message"}).length === 0) {
                for (let index = 0; index < (this.tabs?.length || 0); index += 1) {
                    if (this.tabs[index].alive) { await this.refreshTab(index); }
                }
                if (this.background.size === 0 && this.scheduler.pending({kind: "message"}).length === 0 && this.browser.snapshot().every(tab =>
                    this.browser.configurationReady(tab.id, tab.configuration?.state))) {
                    if (this.mode === "popup" && rejectReviews) {
                        for (const profileIdentifier of profiles) { this.browser.closePopup(profileIdentifier); }
                    }
                    await this.barrier("recovered");
                    return;
                }
            }
            if (this.mode === "popup" && this.lastInspectionAvailable && this.background.size === 0 &&
                this.scheduler.pending({kind: "message"}).length === 0) {
                const terminalProfile = profiles.find(profileIdentifier => {
                    const current = this.browser.popupRequest(profileIdentifier);
                    return current && requests.some(request => request.handle.profileIdentifier === profileIdentifier &&
                        request.handle.id === current.id && request.handle.token === current.requestToken &&
                        ["responded", "completed"].includes(request.phase));
                });
                if (terminalProfile !== undefined) {
                    this.browser.closePopup(terminalProfile);
                    await this.browser.openPopup(terminalProfile);
                    continue;
                }
            }
            for (const request of requests) {
                if (this.mode === "native" && request.phase === "queued" && (request.presentation === undefined ||
                    request.presentation === "none" && request.coordinatorPhase === "paused")) {
                    this.sendNative({subject: "showApproval", id: request.handle.id, requestToken: request.handle.token,
                        configurationKey: request.configurationKey, workflowVersion: this.child("bridge").ready.workflowVersion,
                        __bwContext: {source: "worker", privateBrowsing: false}}, request.handle.profileIdentifier);
                    continue;
                }
                if (!["responded", "completed"].includes(request.phase)) { await this.decide({}, "reject", request); }
            }
            if (this.background.size === 0) {
                for (const profileIdentifier of profiles) { this.browser.wake(profileIdentifier); }
            }
            await this.advance(1000);
        }
        throw new LifecycleFailure("progress", "Fault-free recovery did not settle or release surviving browser work", {operations: [...this.browser.operations.values()]});
    }
    async artifacts(error, scenario, destination) {
        const target = resolve(destination || join(this.root, "failure"));
        const checkpoints = [...this.gates.values()].map(gate => gate.details);
        await this.freeze();
        await mkdir(target, {recursive: true});
        await writeFile(join(target, "scenario.json"), JSON.stringify(scenario, null, 2) + "\n");
        await writeFile(join(target, "failure.json"), JSON.stringify({sourceIdentity: this.originalSourceIdentity,
            reproduction: {sourceIdentity: this.sourceIdentity}, invariant: error.invariant || "unexpected", message: error.message,
            details: error.details, stack: error.stack, checkpoint: checkpoints,
            processes: [...this.children].map(([role, child]) => ({role, epoch: child.epoch, pid: child.pid, stderr: child.stderr})),
            coverage: [...this.coverage], oracleCoverage: [...this.oracle.coverage], storeRoot: this.storeRoot}, null, 2) + "\n");
        await writeFile(join(target, "browser-trace.jsonl"), this.trace.map(event => JSON.stringify(event)).join("\n") + "\n");
        await cp(join(this.root, "effects.jsonl"), join(target, "effects.jsonl"));
        await cp(this.storeRoot, join(target, "store"), {recursive: true});
        return target;
    }
    async freeze() {
        this.browser?.close();
        for (const child of this.children.values()) {
            if (!child.exited) {
                try { await child.kill(); } catch (error) { if (!child.failure) { throw error; } }
            }
        }
    }
    async close({preserve = false} = {}) {
        if (this.closed) { return; }
        this.closed = true;
        this.browser?.close();
        for (const gate of this.gates.values()) {
            if (gate.external) { gate.release(); }
        }
        this.gates.clear();
        for (const child of this.children.values()) {
            if (!child.exited) {
                try { await child.kill(); } catch (error) { if (!child.failure) { throw error; } }
            }
        }
        this.ledger?.close();
        if (!preserve && this.root) { await rm(this.root, {recursive: true, force: true}); }
    }
}
