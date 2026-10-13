import {closeSync, fsyncSync, openSync, writeSync} from "node:fs";
import {createHash} from "node:crypto";
import {createRequire} from "node:module";
import {LifecycleFailure} from "./scheduler.mjs";
import {assertEthereumTransaction, assertSolanaTransaction, solanaMessage} from "./crypto_assertions.mjs";

const require = createRequire(new URL("../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {keccak_256} = require("@noble/hashes/sha3");
const bs58Module = require("bs58");
const bs58 = bs58Module.default || bs58Module;

export function handleKey(handle) {
    if (!handle || !Number.isSafeInteger(handle.id) || typeof handle.token !== "string") {
        throw new LifecycleFailure("oracle-input", "Missing complete request handle", {handle});
    }
    return `${handle.profileIdentifier ?? "default"}|${handle.id}|${handle.token}`;
}

export function canonicalAccount(value) {
    if (value == null) { return null; }
    if (typeof value === "string") { return value.startsWith("0x") ? value.toLowerCase() : value; }
    const source = value.account || value;
    return canonicalAccount(source.address ?? source.normalizedAddress ?? source.publicKey);
}

export function digest(value) {
    return createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
}

function canonical(value) {
    if (Array.isArray(value)) { return value.map(canonical); }
    if (value && typeof value === "object") { return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])); }
    return value;
}

export class EffectLedger {
    constructor(path) {
        this.path = path;
        this.descriptor = openSync(path, "ax", 0o600);
        this.events = [];
        this.closed = false;
    }
    append(event) {
        if (this.closed) { throw new Error("Ledger is closed"); }
        const recorded = {sequence: this.events.length + 1, ...event};
        const bytes = Buffer.from(JSON.stringify(recorded) + "\n");
        let offset = 0;
        while (offset < bytes.length) { offset += writeSync(this.descriptor, bytes, offset, bytes.length - offset); }
        fsyncSync(this.descriptor);
        this.events.push(recorded);
        return recorded;
    }
    close() {
        if (this.closed) { return; }
        fsyncSync(this.descriptor);
        closeSync(this.descriptor);
        this.closed = true;
    }
}

export class LifecycleOracle {
    constructor() {
        this.requests = new Map;
        this.admissions = new Map;
        this.approvals = new Map;
        this.executions = new Map;
        this.settlements = new Map;
        this.authorities = new Map;
        this.permissions = new Map;
        this.coverage = new Set;
        this.events = [];
    }
    fail(invariant, message, details) { throw new LifecycleFailure(invariant, message, details); }
    permission(profileIdentifier, configurationKey, provider) {
        const key = `${profileIdentifier ?? "default"}|${configurationKey}|${provider}`;
        if (!this.permissions.has(key)) {
            this.permissions.set(key, {profileIdentifier: profileIdentifier ?? null, configurationKey, provider,
                generation: 0, revoked: false, tickets: [], lastAllowed: null, lastObserved: null, revocations: new Set, accountGenerations: new Map,
                committedGrants: new Map, authorityHistory: new Map, grantBoundaries: new Map});
        }
        return this.permissions.get(key);
    }
    authorityHistory(permission, context) {
        if (!permission.authorityHistory.has(context)) { permission.authorityHistory.set(context, new Map); }
        return permission.authorityHistory.get(context);
    }
    recordAuthority(permission, context, revision, snapshot, label) {
        const history = this.authorityHistory(permission, context);
        const previous = history.get(revision);
        if (previous && previous.state !== snapshot.state) {
            this.fail("replay", "Provider changed a known authority snapshot", {context, revision, snapshot, previous});
        }
        const priorGrant = label && permission.grantBoundaries.get(label);
        if (priorGrant && priorGrant.context !== context) {
            this.fail("replay", "A connection approval granted another authority context", {label, context, priorGrant});
        }
        const grant = label && {context, revision: Math.min(priorGrant?.revision ?? Infinity, revision)};
        const grantRevisions = new Set([...permission.grantBoundaries].filter(([key, value]) => key !== label && value.context === context)
            .map(([, value]) => value.revision));
        if (grant) { grantRevisions.add(grant.revision); }
        const observations = new Map(history).set(revision, snapshot);
        let address = null;
        for (const [observedRevision, observed] of [...observations].sort(([first], [second]) => first - second)) {
            if (!observed.address || grantRevisions.has(observedRevision)) { address = observed.address; }
            else if (observed.address !== address) {
                this.fail("replay", "Provider configuration falls outside its authorized account interval", {context, revision: observedRevision, address: observed.address});
            }
        }
        history.set(revision, snapshot);
        if (grant) { permission.grantBoundaries.set(label, grant); }
    }
    register({handle, configurationKey, provider, name, payloadDigest, account, enqueueAttempt, authority}) {
        const key = handleKey(handle);
        if (enqueueAttempt !== undefined) {
            const attempt = JSON.stringify([handle.profileIdentifier ?? null, configurationKey, enqueueAttempt]);
            const admitted = this.admissions.get(attempt);
            if (admitted && admitted.key !== key) {
                this.fail("replay", "An admission retry created another stored request", {enqueueAttempt, configurationKey, admitted: admitted.key, actual: key});
            }
            if (admitted?.payloadDigest !== undefined && payloadDigest !== undefined && admitted.payloadDigest !== payloadDigest) {
                this.fail("isolation", "An admission retry changed its payload", {enqueueAttempt, configurationKey, key});
            }
            this.admissions.set(attempt, {key, payloadDigest: admitted?.payloadDigest ?? payloadDigest});
        }
        const value = {handle: {...handle, profileIdentifier: handle.profileIdentifier ?? null}, configurationKey, provider, name, payloadDigest,
            account: canonicalAccount(account), authority: authority && structuredClone(authority), approvals: [], terminal: null, revoked: false};
        const previous = this.requests.get(key);
        if (previous) {
            const coalesced = enqueueAttempt !== undefined && previous.provider === "unknown" && previous.name === "switchAccount" &&
                provider === "unknown" && name === "switchAccount";
            for (const field of ["configurationKey", "provider", "name", ...(coalesced ? [] : ["payloadDigest"])]) {
                if (previous[field] !== undefined && value[field] !== undefined && previous[field] !== value[field]) { this.fail("isolation", "A request handle was rebound", {key, field}); }
            }
        } else { this.requests.set(key, value); }
        this.coverage.add(`request:${provider}`);
        return key;
    }
    approvalIntent({handle, label, revision, account, payloadDigest, selectedAccounts}) {
        const key = handleKey(handle);
        const request = this.requests.get(key);
        if (!request) { this.fail("consent", "Approval targets an unobserved request", {handle}); }
        if (this.approvals.has(label)) { this.fail("oracle-input", "Approval intent labels must be unique", {label}); }
        const approval = {key, label, revision, account: canonicalAccount(account ?? request.account),
            payloadDigest: payloadDigest ?? request.payloadDigest, accepted: false, consumed: false, revoked: request.revoked};
        approval.grantAccounts = {};
        if (["requestAccounts", "connect", "switchAccount"].includes(request.name)) {
            if (!Array.isArray(selectedAccounts)) { this.fail("oracle-input", "Connection approval omitted the reviewed accounts", {handle, label}); }
            for (const selected of selectedAccounts) {
                const provider = selected.coin;
                const address = canonicalAccount(selected);
                if (!["ethereum", "solana"].includes(provider) || !address || approval.grantAccounts[provider] ||
                    request.provider !== "unknown" && request.provider !== provider) {
                    this.fail("oracle-input", "Invalid reviewed account selection", {handle, selected});
                }
                approval.grantAccounts[provider] = address;
            }
        }
        approval.grantGenerations = Object.fromEntries(["ethereum", "solana"].map(provider => [provider,
            this.permission(request.handle.profileIdentifier, request.configurationKey, provider).generation]));
        approval.grantAccountGenerations = Object.fromEntries(Object.entries(approval.grantAccounts).map(([provider, address]) => [provider,
            this.permission(request.handle.profileIdentifier, request.configurationKey, provider).accountGenerations.get(address) || 0]));
        this.approvals.set(label, approval);
        request.approvals.push(label);
    }
    acceptConsent({handle, label, revision}) {
        const key = handleKey(handle);
        const request = this.requests.get(key);
        const approval = (label ? this.approvals.get(label) : null) ||
            request?.approvals.map(value => this.approvals.get(value)).findLast(value => !value.accepted);
        if (!approval || approval.key !== key) { this.fail("consent", "Native consent has no matching explicit user approval", {handle, label}); }
        if (approval.accepted || approval.consumed) { this.fail("consent", "A consumed approval was accepted again", {label: approval.label}); }
        if (approval.revision !== undefined && revision !== undefined && approval.revision !== revision) {
            this.fail("consent", "Native consent changed the reviewed revision", {approval, revision});
        }
        approval.accepted = true;
        if (label && label !== approval.label) { this.approvals.set(label, approval); }
        if (!approval.revoked && ["requestAccounts", "connect", "switchAccount"].includes(request.name)) {
            for (const [provider, address] of Object.entries(approval.grantAccounts)) {
                const permission = this.permission(request.handle.profileIdentifier, request.configurationKey, provider);
                const observed = permission.lastObserved;
                const reviewedAfterDisconnection = observed && !observed.address && request.authority?.context === observed.context &&
                    request.authority.revisions[provider] >= observed.revision;
                permission.tickets.push({label: approval.label, address, authority: request.authority,
                    accountGeneration: approval.grantAccountGenerations[provider],
                    generation: reviewedAfterDisconnection ? permission.generation : approval.grantGenerations[provider]});
            }
        }
        this.coverage.add("consent");
        return approval;
    }
    recordCommittedGrant({handle, state}) {
        const request = this.requests.get(handleKey(handle));
        if (!request || request.revoked || !["requestAccounts", "connect", "switchAccount"].includes(request.name)) { return; }
        for (const label of request.approvals) {
            const approval = this.approvals.get(label);
            if (!approval.accepted || approval.revoked) { continue; }
            for (const [provider, address] of Object.entries(approval.grantAccounts)) {
                if (canonicalAccount(provider === "ethereum" ? state.ethereum?.address : state.solana?.publicKey) !== address) { continue; }
                const revision = state.revisions[provider];
                if (request.authority && (request.authority.context !== state.context || revision < request.authority.revisions[provider])) { continue; }
                const permission = this.permission(request.handle.profileIdentifier, request.configurationKey, provider);
                const accountGeneration = permission.accountGenerations.get(address) || 0;
                const value = JSON.stringify(canonical(state[provider]));
                const allowed = permission.lastAllowed;
                const ticket = permission.tickets.some(ticket => ticket.label === label && ticket.generation === permission.generation &&
                    ticket.accountGeneration === accountGeneration);
                const boundary = permission.grantBoundaries.get(label);
                const earlier = boundary?.context === state.context && revision < boundary.revision;
                if (!ticket && (permission.revoked || allowed?.context !== state.context ||
                    !earlier && (allowed.revision !== state.revisions[provider] || allowed.state !== value))) { continue; }
                const key = `${state.context}|${state.revisions[provider]}`;
                this.recordAuthority(permission, state.context, revision, {address, state: value}, label);
                if (!permission.committedGrants.has(key)) { permission.committedGrants.set(key, {generation: permission.generation, accountGeneration}); }
                request.completedBeforeRevocation = true;
            }
        }
    }
    execution({handle, executionID, epoch, consentLabel, account, payloadDigest}) {
        const key = handleKey(handle);
        const request = this.requests.get(key);
        if (request?.broadcastCommitted) { this.fail("broadcast", "A committed request entered signing again", {handle, executionID}); }
        const approval = consentLabel ? this.approvals.get(consentLabel) :
            request?.approvals.map(value => this.approvals.get(value)).findLast(value => value.accepted);
        if (!approval || approval.key !== key || !approval.accepted) {
            this.fail("consent", "Signing entered without fresh matching consent", {handle, consentLabel});
        }
        if (account !== undefined && approval.account != null && canonicalAccount(account) !== approval.account) {
            this.fail("consent", "Signing account differs from reviewed account", {account, expected: approval.account});
        }
        if (payloadDigest !== undefined && approval.payloadDigest !== undefined && payloadDigest !== approval.payloadDigest) {
            this.fail("consent", "Signing payload differs from reviewed payload", {payloadDigest, expected: approval.payloadDigest});
        }
        const identity = executionID || `${epoch}|${key}|${approval.label}`;
        let execution = this.executions.get(identity);
        if (!execution) {
            if (approval.consumed) { this.fail("consent", "Consumed consent started another execution", {label: approval.label}); }
            approval.consumed = true;
            execution = {identity, key, approval: approval.label, epoch, entered: 0, returned: 0, checkpoint: false, dispatches: 0,
                accepted: false, revokedBeforeSigning: approval.revoked === true || request.revoked === true};
            this.executions.set(identity, execution);
        }
        if (execution.epoch !== epoch || execution.key !== key) {
            this.fail("isolation", "A process incarnation reused another execution", {identity, epoch});
        }
        execution.entered += 1;
        if (execution.entered > 1) { this.fail("consent", "An approved single-signature execution signed twice", {identity}); }
        this.coverage.add("signer.before");
        return execution;
    }
    findExecution(details) {
        const key = handleKey(details.handle);
        const execution = details.executionID ? this.executions.get(details.executionID) :
            [...this.executions.values()].findLast(value => value.key === key && (!details.epoch || value.epoch === details.epoch));
        if (!execution) { this.fail("consent", "Execution effect has no observed signing entry", details); }
        if (execution.key !== key || details.epoch && execution.epoch !== details.epoch) {
            this.fail("isolation", "Execution effect targets another handle or process incarnation", {details, execution});
        }
        return execution;
    }
    signed(details) {
        const execution = this.findExecution(details);
        if (details.succeeded === false) { execution.failed = true; return; }
        if (execution.revokedBeforeSigning) { this.fail("revocation", "A request revoked before signing produced a signature", details); }
        if (++execution.returned !== 1) { this.fail("consent", "Signing returned repeatedly", details); }
        this.coverage.add("signer.after");
    }
    checkpoint(details) {
        const execution = this.findExecution(details);
        if (execution.returned !== 1) { this.fail("broadcast", "Broadcast checkpoint precedes successful signing", details); }
        const approval = this.approvals.get(execution.approval);
        if (approval.revoked) { this.fail("revocation", "Revoked approval acquired a broadcast checkpoint", details); }
        const request = this.requests.get(execution.key);
        if (request.broadcastExecution && request.broadcastExecution !== execution.identity) {
            this.fail("broadcast", "Another execution already committed this request", details);
        }
        execution.checkpoint = true;
        request.broadcastCommitted = true;
        request.broadcastExecution = execution.identity;
        this.coverage.add("broadcast.prepared");
    }
    dispatch(details) {
        const execution = this.findExecution(details);
        if (!execution.checkpoint) { this.fail("broadcast", "RPC submission preceded the durable broadcast checkpoint", details); }
        const request = this.requests.get(execution.key);
        if (request.broadcastExecution !== execution.identity || request.broadcastDispatched) {
            this.fail("broadcast", "Committed request submitted through another or repeated dispatch", details);
        }
        if (++execution.dispatches !== 1) { this.fail("broadcast", "Committed execution submitted more than once", details); }
        request.broadcastDispatched = true;
        this.coverage.add("broadcast.dispatch");
    }
    accepted(details) {
        const execution = this.findExecution(details);
        if (execution.dispatches !== 1) { this.fail("broadcast", "Remote acceptance has no submission", details); }
        execution.accepted = true;
        execution.transactionID = details.transactionID;
        this.coverage.add("broadcast.accepted");
    }
    revoke({profileIdentifier, configurationKey, provider, account, attempt, definite = true, beforeSigning = false, definiteHandles, beforeSigningHandles}) {
        const removedAccount = canonicalAccount(account);
        const permissions = [...this.permissions.values()].filter(value => value.profileIdentifier === (profileIdentifier ?? null) &&
            (!configurationKey || value.configurationKey === configurationKey) && (!provider || value.provider === provider));
        const repeated = attempt && permissions.length && permissions.every(value => value.revocations.has(attempt));
        if (repeated) { return; }
        for (const permission of permissions) {
            if (attempt) { permission.revocations.add(attempt); }
            if (removedAccount) {
                permission.accountGenerations.set(removedAccount, (permission.accountGenerations.get(removedAccount) || 0) + 1);
                permission.tickets = permission.tickets.filter(ticket => ticket.address !== removedAccount);
                if (permission.lastAllowed?.address !== removedAccount) { continue; }
            }
            permission.generation += 1;
            permission.revoked = true;
            permission.tickets = [];
        }
        for (const request of this.requests.values()) {
            const selectedRemovedAccount = removedAccount && request.approvals.some(label => {
                const selected = this.approvals.get(label).grantAccounts;
                return provider ? selected[provider] === removedAccount : Object.values(selected).includes(removedAccount);
            });
            if (request.handle.profileIdentifier !== (profileIdentifier ?? null) ||
                configurationKey && request.configurationKey !== configurationKey ||
                provider && request.provider !== provider && request.provider !== "unknown" ||
                removedAccount && request.account !== removedAccount && !selectedRemovedAccount) { continue; }
            request.revoked = true;
            const requestKey = handleKey(request.handle);
            const certain = definiteHandles ? definiteHandles.includes(requestKey) : definite;
            const precededSigning = beforeSigningHandles ? beforeSigningHandles.includes(requestKey) : beforeSigning;
            request.definitelyRevoked ||= certain;
            for (const label of request.approvals) {
                const execution = [...this.executions.values()].find(value => value.approval === label);
                if (!execution?.checkpoint && certain) { this.approvals.get(label).revoked = true; }
                if (execution && precededSigning) { execution.revokedBeforeSigning = true; }
            }
        }
        this.coverage.add("revocation");
    }
    configuration({profileIdentifier, configurationKey, generation, state}) {
        const key = `${profileIdentifier ?? "default"}|${configurationKey}|${generation}`;
        const previous = this.authorities.get(key);
        if (previous && previous.context === state.context) {
            for (const provider of ["ethereum", "solana"]) {
                if (state.revisions[provider] < previous.revisions[provider]) {
                    this.fail("replay", "Provider configuration moved to an older authority revision", {key, provider, previous, state});
                }
            }
        }
        for (const provider of ["ethereum", "solana"]) {
            const permission = this.permission(profileIdentifier, configurationKey, provider);
            const revision = state.revisions[provider];
            const address = canonicalAccount(provider === "ethereum" ? state.ethereum.address : state.solana?.publicKey);
            const snapshot = {address, state: JSON.stringify(canonical(state[provider]))};
            const history = this.authorityHistory(permission, state.context);
            const known = history.get(revision);
            const committed = permission.committedGrants.get(`${state.context}|${revision}`);
            if (known && known.state !== snapshot.state) {
                this.fail("replay", "Provider changed a known authority snapshot", {provider, state});
            }
            if (previous?.context === state.context && previous.revisions[provider] === state.revisions[provider]) { continue; }
            const allowed = permission.lastAllowed;
            const observed = permission.lastObserved;
            if (observed?.context === state.context && observed.revision > revision) {
                this.recordAuthority(permission, state.context, revision, snapshot);
                continue;
            }
            if (observed?.context === state.context && observed.revision === revision) { continue; }
            if (committed && (committed.generation !== permission.generation || committed.accountGeneration !== (permission.accountGenerations.get(address) || 0))) { continue; }
            if (!address) {
                this.recordAuthority(permission, state.context, revision, snapshot);
                const generation = permission.generation;
                permission.generation += 1;
                permission.revoked = true;
                permission.tickets = permission.tickets.filter(ticket => ticket.generation === generation &&
                    ticket.authority?.context === state.context && ticket.authority.revisions[provider] >= revision);
                for (const ticket of permission.tickets) { ticket.generation = permission.generation; }
                permission.lastObserved = {context: state.context, revision, address};
                continue;
            }
            const needsConsent = !allowed || allowed.address !== address || permission.revoked || allowed.context !== state.context;
            const index = permission.tickets.findIndex(ticket => ticket.generation === permission.generation && ticket.address === address &&
                (!ticket.authority || ticket.authority.context === state.context && revision >= ticket.authority.revisions[provider]) &&
                ticket.accountGeneration === (permission.accountGenerations.get(address) || 0));
            if (needsConsent && index < 0) {
                this.fail("replay", "Provider granted an account without fresh matching approval", {profileIdentifier, configurationKey, provider, address, revision});
            }
            this.recordAuthority(permission, state.context, revision, snapshot, permission.tickets[index]?.label);
            if (needsConsent) { permission.revoked = false; }
            if (index >= 0) { permission.tickets.splice(index, 1); }
            permission.lastObserved = {context: state.context, revision, address};
            permission.lastAllowed = {context: state.context, revision, ...snapshot};
        }
        this.authorities.set(key, structuredClone(state));
    }
    settle({operation, document, currentDocument, handle, expectedHandle, result, error}) {
        if (this.settlements.has(operation)) { this.fail("replay", "A browser operation settled twice", {operation}); }
        if (document !== currentDocument && !error) { this.fail("isolation", "Retired document operation received success", {operation, document, currentDocument}); }
        if (handle && expectedHandle && handleKey(handle) !== handleKey(expectedHandle)) {
            this.fail("isolation", "Terminal result belongs to another request", {handle, expectedHandle});
        }
        const request = handle ? this.requests.get(handleKey(handle)) : null;
        const signingResponse = request && (request.provider === "ethereum" ?
            ["signPersonalMessage", "signTypedMessage", "signTransaction"].includes(request.name) :
            request.provider === "solana" && ["signMessage", "signTransaction", "signAllTransactions", "signAndSendTransaction"].includes(request.name));
        if (!error && signingResponse && ![...this.executions.values()].some(execution =>
            execution.key === handleKey(handle) && execution.returned === 1 && !execution.failed)) {
            this.fail("consent", "Signing success has no matching approved signing execution", {operation, handle});
        }
        if (!error && request?.definitelyRevoked && !request.completedBeforeRevocation && !request.broadcastCommitted) {
            this.fail("revocation", "Revoked uncommitted request published success", {operation, handle});
        }
        this.settlements.set(operation, {result, error});
        this.coverage.add(error ? "browser.rejected" : "browser.fulfilled");
    }
    completed(handle) {
        const request = this.requests.get(handleKey(handle));
        if (request && !request.revoked) { request.completedBeforeRevocation = true; }
    }
    observeDurable({handle, broadcastCheckpointed, terminal, terminalResponse, recoveryResponse}) {
        const request = this.requests.get(handleKey(handle));
        if (!request) { return; }
        if (broadcastCheckpointed === true) {
            request.broadcastCommitted = true;
        }
        if (terminal === true && !request.definitelyRevoked && (terminalResponse ?? recoveryResponse)?.approvalCommitted === true) {
            request.completedBeforeRevocation = true;
        }
    }
    requireCoverage(names) {
        const missing = names.filter(name => !this.coverage.has(name));
        if (missing.length) { this.fail("coverage", "Required lifecycle events were not exercised", {missing, observed: [...this.coverage]}); }
    }
}

export class FakeRPC {
    constructor({ledger, oracle, requestBody = () => null, onReceipt = async () => {}, onAccepted = async () => {}}) {
        this.ledger = ledger;
        this.oracle = oracle;
        this.onReceipt = onReceipt;
        this.onAccepted = onAccepted;
        this.requestBody = requestBody;
    }
    async respond(details) {
        const request = details.request;
        if (!request || typeof request.method !== "string" || !Array.isArray(request.params)) {
            throw new LifecycleFailure("protocol", "Malformed simulated RPC request", details);
        }
        const reply = result => ({jsonrpc: "2.0", id: request.id ?? 1, result});
        const provider = request.method.startsWith("eth_") ? "ethereum" :
            ["getBalance", "getLatestBlockhash", "getSignatureStatuses", "getBlockHeight", "getFeeForMessage", "sendTransaction"].includes(request.method) ? "solana" : null;
        const network = fixtureRPCNetworks.get(details.endpoint);
        if (provider && network?.provider !== provider) {
            throw new LifecycleFailure("rpc", "RPC request targeted an unknown or unrelated fixture endpoint", {method: request.method, endpoint: details.endpoint});
        }
        switch (request.method) {
        case "eth_chainId": return reply(network.chainId);
        case "eth_getBalance": return reply("0x56bc75e2d63100000");
        case "eth_getTransactionCount": return reply("0x0");
        case "eth_estimateGas": return reply("0x5208");
        case "eth_gasPrice": return reply("0x77359400");
        case "eth_maxPriorityFeePerGas": return reply("0x3b9aca00");
        case "eth_getBlockByNumber": return reply({number: "0x100", baseFeePerGas: "0x3b9aca00"});
        case "eth_feeHistory": return reply({oldestBlock: "0xff", baseFeePerGas: ["0x3b9aca00", "0x3b9aca00"], gasUsedRatio: [0.5], reward: [["0x3b9aca00"]]});
        case "getBalance": return reply({context: {slot: 1}, value: 100_000_000_000});
        case "getLatestBlockhash": return reply({context: {slot: 1}, value: {blockhash: "11111111111111111111111111111111", lastValidBlockHeight: 999999}});
        case "getSignatureStatuses": return reply({context: {slot: 1}, value: [{slot: 1, confirmations: null, err: null, confirmationStatus: "finalized"}]});
        case "getBlockHeight": return reply(1);
        case "getFeeForMessage": return reply({context: {slot: 1}, value: 5000});
        case "eth_sendRawTransaction":
        case "sendTransaction": {
            const raw = request.params[0];
            if (typeof raw !== "string" || !raw.length) { throw new LifecycleFailure("broadcast", "Native sender supplied no signed transaction bytes"); }
            let bytes;
            let transactionID;
            if (request.method === "eth_sendRawTransaction") {
                if (!/^0x(?:[0-9a-fA-F]{2})+$/.test(raw)) { throw new LifecycleFailure("broadcast", "Ethereum sender supplied malformed signed bytes"); }
                bytes = Buffer.from(raw.slice(2), "hex");
                transactionID = "0x" + Buffer.from(keccak_256(bytes)).toString("hex");
            } else {
                bytes = request.params[1]?.encoding === "base64" ? Buffer.from(raw, "base64") : Buffer.from(bs58.decode(raw));
                const parsed = solanaMessage(bytes);
                const signature = bytes.subarray(parsed.signaturesOffset, parsed.signaturesOffset + 64);
                if (signature.every(value => value === 0)) {
                    throw new LifecycleFailure("broadcast", "Solana sender supplied no complete signed transaction");
                }
                transactionID = bs58.encode(signature);
            }
            const effect = {...details, bytes: bytes.toString("base64"), bytesDigest: digest(bytes.toString("base64")), transactionID};
            const body = this.requestBody(details);
            if (body) {
                if (request.method === "eth_sendRawTransaction") {
                    assertEthereumTransaction(bytes, body);
                    if (BigInt(body.object?.chainId ?? body.chainId) !== BigInt(network.chainId)) {
                        throw new LifecycleFailure("broadcast", "Ethereum broadcast endpoint differs from the reviewed chain", {endpoint: details.endpoint, chainId: network.chainId});
                    }
                } else {
                    assertSolanaTransaction(bytes, body);
                    if (!body.reviewedCluster || body.reviewedCluster !== network.cluster || details.cluster !== body.reviewedCluster) {
                        throw new LifecycleFailure("broadcast", "Solana broadcast endpoint or cluster differs from the reviewed cluster", {
                            endpoint: details.endpoint, cluster: details.cluster, reviewedCluster: body.reviewedCluster,
                        });
                    }
                }
            }
            this.oracle.dispatch(effect);
            this.ledger.append({type: "rpc.received", ...effect});
            await this.onReceipt(effect);
            this.oracle.accepted(effect);
            this.ledger.append({type: "rpc.accepted", ...effect});
            await this.onAccepted(effect);
            return reply(transactionID);
        }
        default: throw new LifecycleFailure("rpc", "Unexpected external method; add an explicit isolated response", {method: request.method});
        }
    }
}

const fixtureRPCNetworks = new Map([
    ["https://rpc.fixture.invalid/1", {provider: "ethereum", chainId: "0x1"}],
    ["https://rpc.fixture.invalid/10", {provider: "ethereum", chainId: "0xa"}],
    ["https://chain-1337.lifecycle.invalid", {provider: "ethereum", chainId: "0x539"}],
    ["https://changed.fixture.invalid/1337", {provider: "ethereum", chainId: "0x539"}],
    ["https://solana.fixture.invalid/solana-mainnet", {provider: "solana", cluster: "mainnetBeta"}],
    ["https://solana.fixture.invalid/solana-devnet", {provider: "solana", cluster: "devnet"}],
    ["https://api.testnet.solana.com", {provider: "solana", cluster: "testnet"}],
]);
