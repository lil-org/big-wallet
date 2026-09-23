// ∅ 2026 lil org

importScripts("bridge_wire.js");

const WIRE = BigWalletBridgeWire;
const WORKFLOW_VERSION = WIRE.WORKFLOW_VERSION;
const BUILD_VERSION = WIRE.BUILD_VERSION;
const APPLICATION_ID = "org.lil.wallet";
const STORAGE_VERSION = 3;
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const TRANSPORT_TIMEOUT = 5000;
const TAB_QUERY_TIMEOUT = 1000;
const MANUAL_SWITCH_INTENT_TIMEOUT = TRANSPORT_TIMEOUT * 2;
const NATIVE_OPERATION_TIMEOUT = 180 * 1000;
const APPROVAL_EXECUTION_TIMEOUT = 150 * 1000;
const APPROVAL_LEASE_GRACE = 10 * 1000;
const APPROVAL_LEASE_STORAGE_PREFIX = "providerApprovalLease:";
const INVALID_APPROVAL_LEASE = Symbol("invalidApprovalLease");
const EXECUTION_JOBS_STORAGE_KEY = "nativeExecutionJobs";
const EXECUTION_MAINTENANCE_INTERVAL = 30 * 1000;
const executionLineageFlights = new Set;
const executionMaintenanceDeadlines = new Map;
let executionJobsTail = Promise.resolve();
let executionRecoveryFlight = null;
let executionTimer = null;
const MANUAL_SWITCH_POLL_DELAY = 1000;
const MANUAL_SWITCH_RECOVERY_ALARM = "manualSwitchRecovery";
const ETHEREUM_ACCOUNT_METHODS = new Set([
    "signMessage",
    "signPersonalMessage",
    "signTransaction",
    "signTypedMessage",
]);
const ETHEREUM_CHAIN_METHODS = new Set([
    "addEthereumChain",
    "switchEthereumChain",
]);
const SOLANA_ACCOUNT_METHODS = new Set([
    "signMessage",
    "signTransaction",
    "signAllTransactions",
    "signAndSendTransaction",
]);
const configurationOperationTails = new Map;
const completionFlights = new Map;
const manualSwitchEnqueues = new Map;
let manualSwitchAlarmFlight = null;
let manualSwitchDiscoveryFlight = null;
let manualSwitchDiscoveryQueued = false;
let manualSwitchPollTimer = null;
let manualSwitchPollingDeadline = 0;

function sendRawNativeMessage(message) {
    return browser.runtime.sendNativeMessage(APPLICATION_ID, message);
}

const sendNativeMessage = WIRE.createTrustedNativeMessageSender({
    sendRawNativeMessage,
});

function privateBrowsingUnsupportedMessage() {
    try {
        const message = browser.i18n.getMessage("private_browsing_unsupported");
        if (message) { return message; }
    } catch {}
    return "Big Wallet requests are unavailable in Private Browsing.";
}

function requestIdentity(request, context) {
    const identity = context.kind === "content" ? context.identity
        : context.kind === "popup"
            ? WIRE.configurationIdentityForURL(request.configurationKey)
            : null;
    return identity && request.host === identity.host &&
        request.configurationKey === identity.configurationKey
        ? identity
        : null;
}

function approvalLeaseLineageKey(configurationKey) {
    return WIRE.configurationIdentityForURL(configurationKey)
        ?.legacyConfigurationKey || configurationKey;
}

function approvalLeaseStorageKey(configurationKey) {
    return `${APPROVAL_LEASE_STORAGE_PREFIX}${
        approvalLeaseLineageKey(configurationKey)
    }`;
}

function validApprovalLease(value, configurationKey) {
    return WIRE.hasExactKeys(value, [
        "configurationKey", "executionDeadline", "expiresAt", "issuedAt",
        "revisions", "token", "workflowVersion",
    ]) && value.workflowVersion === WORKFLOW_VERSION &&
        value.configurationKey === approvalLeaseLineageKey(configurationKey) &&
        WIRE.isPrivateToken(value.token) &&
        WIRE.isProviderRevisions(value.revisions) &&
        Number.isSafeInteger(value.issuedAt) &&
        Number.isSafeInteger(value.executionDeadline) &&
        Number.isSafeInteger(value.expiresAt) &&
        value.issuedAt > 0 &&
        value.executionDeadline - value.issuedAt ===
            APPROVAL_EXECUTION_TIMEOUT &&
        value.expiresAt - value.executionDeadline === APPROVAL_LEASE_GRACE;
}

async function readLiveApprovalLease(configurationKey) {
    const key = approvalLeaseStorageKey(configurationKey);
    const stored = await browser.storage.local.get(key);
    const value = stored?.[key];
    if (typeof value === "undefined") { return null; }
    const now = Date.now();
    if (!validApprovalLease(value, configurationKey)) {
        return INVALID_APPROVAL_LEASE;
    }
    if (value.expiresAt > now) {
        return value;
    }
    await browser.storage.local.remove(key);
    return null;
}

function makeApprovalLease(configurationKey, revisions) {
    const now = Date.now();
    return {
        configurationKey: approvalLeaseLineageKey(configurationKey),
        executionDeadline: now + APPROVAL_EXECUTION_TIMEOUT,
        expiresAt: now + APPROVAL_EXECUTION_TIMEOUT + APPROVAL_LEASE_GRACE,
        issuedAt: now,
        revisions: {...revisions},
        token: WIRE.genPrivateToken(),
        workflowVersion: WORKFLOW_VERSION,
    };
}

function sameApprovalLease(left, right) {
    return !!left && left !== INVALID_APPROVAL_LEASE &&
        Object.keys(right).every(key => key === "revisions"
            ? left.revisions.ethereum === right.revisions.ethereum &&
                left.revisions.solana === right.revisions.solana
            : left[key] === right[key]);
}

async function installApprovalLease(
    configurationKey,
    revisions,
    canAcquire = () => true
) {
    if (await readLiveApprovalLease(configurationKey)) { return null; }
    if (!canAcquire()) { return null; }
    const value = makeApprovalLease(configurationKey, revisions);
    await browser.storage.local.set({
        [approvalLeaseStorageKey(configurationKey)]: value,
    });
    return value;
}

async function clearApprovalLease(configurationKey, token) {
    const key = approvalLeaseStorageKey(configurationKey);
    const stored = await browser.storage.local.get(key);
    const value = stored?.[key];
    if (!validApprovalLease(value, configurationKey) || value.token !== token) {
        return;
    }
    await browser.storage.local.remove(key);
}

async function withProviderRevisionLease(
    configurationKey,
    legacyConfigurationKey,
    operation,
    waitForLease = false
) {
    const releaseLease = lease => queueConfigurationOperation(
        configurationKey,
        async () => {
            await clearApprovalLease(configurationKey, lease.token);
            return {value: undefined};
        },
        legacyConfigurationKey
    );
    const acquisitionDeadline = Date.now() + TRANSPORT_TIMEOUT;
    let acceptingLease = true;
    let retryTimer;
    const canAcquire = () => !waitForLease ||
        acceptingLease && Date.now() < acquisitionDeadline;
    const acquire = async () => {
        while (canAcquire()) {
            const lease = await queueConfigurationOperation(
                configurationKey,
                async state => ({value: canAcquire()
                    ? await installApprovalLease(
                        configurationKey,
                        state.revisions,
                        canAcquire
                    )
                    : null}),
                legacyConfigurationKey
            );
            if (lease) {
                if (canAcquire()) { return lease; }
                await releaseLease(lease);
                return null;
            }
            if (!waitForLease || !canAcquire()) { return null; }
            await new Promise(resolve => {
                retryTimer = setTimeout(resolve, Math.min(
                    100,
                    acquisitionDeadline - Date.now()
                ));
            });
        }
        return null;
    };
    let lease;
    try {
        lease = await (waitForLease
            ? WIRE.withTimeout(acquire(), TRANSPORT_TIMEOUT)
            : acquire());
    } finally {
        acceptingLease = false;
        clearTimeout(retryTimer);
    }
    if (!lease) { return undefined; }
    try {
        if (waitForLease && Date.now() >= acquisitionDeadline) {
            return undefined;
        }
        return await WIRE.withTimeout(
            operation({
                executionDeadline: lease.executionDeadline,
                expiresAt: lease.expiresAt,
                revisions: {...lease.revisions},
            }),
            NATIVE_OPERATION_TIMEOUT
        );
    } finally {
        await releaseLease(lease);
    }
}

function validPopupApprovalPayload(payload) {
    if (!WIRE.isRecord(payload)) { return false; }
    const allowed = new Set([
        "chainId", "cluster", "selectedAccounts",
    ]);
    if (Object.keys(payload).some(key => !allowed.has(key))) { return false; }
    if (Object.prototype.hasOwnProperty.call(payload, "chainId") &&
        !WIRE.isCanonicalEthereumChainId(payload.chainId)) {
        return false;
    }
    if (Object.prototype.hasOwnProperty.call(payload, "cluster") &&
        !WIRE.WORKFLOW_POLICY.solanaClusterValues.includes(payload.cluster)) {
        return false;
    }
    if (!Object.prototype.hasOwnProperty.call(payload, "selectedAccounts")) {
        return true;
    }
    if (!Array.isArray(payload.selectedAccounts) ||
        payload.selectedAccounts.length >
            WIRE.WORKFLOW_POLICY.selectionAccountCoins.length) {
        return false;
    }
    const coins = new Set;
    return payload.selectedAccounts.every(account => {
        if (!WIRE.hasExactKeys(account, [
                "address", "coin", "derivationPath", "walletId",
            ]) ||
            typeof account.walletId !== "string" || account.walletId.length === 0 ||
            typeof account.address !== "string" || account.address.length === 0 ||
            typeof account.derivationPath !== "string" ||
            account.derivationPath.length === 0 ||
            !WIRE.WORKFLOW_POLICY.selectionAccountCoins.includes(account.coin) ||
            coins.has(account.coin)) {
            return false;
        }
        coins.add(account.coin);
        return true;
    });
}

function cleanConfiguration(configuration) {
    return configuration.provider === "ethereum"
        ? {provider: "ethereum", chainId: configuration.chainId, results: [...configuration.results]}
        : {provider: "solana", publicKey: configuration.publicKey};
}

function normalizedReleasedEthereumConfiguration(configuration) {
    if (!WIRE.isRecord(configuration) || configuration.provider !== "ethereum" ||
        typeof configuration.chainId !== "string" ||
        !/^0x[0-9a-f]+$/i.test(configuration.chainId)) {
        return configuration;
    }
    const digits = configuration.chainId.slice(2).toLowerCase()
        .replace(/^0+/, "");
    const chainId = `0x${digits}`;
    return digits.length > 0 && WIRE.isCanonicalEthereumChainId(chainId)
        ? {...configuration, chainId}
        : configuration;
}

function normalizedReleasedHostConfigurationState(value) {
    if (Array.isArray(value)) {
        return value.map(normalizedReleasedEthereumConfiguration);
    }
    if (!WIRE.isRecord(value)) { return value; }
    if (Array.isArray(value.latestConfigurations)) {
        return {
            ...value,
            latestConfigurations: value.latestConfigurations.map(
                normalizedReleasedEthereumConfiguration
            ),
        };
    }
    return normalizedReleasedEthereumConfiguration(value);
}

function decodeCurrentConfigurationState(value) {
    if (!WIRE.hasExactKeys(value, [
            "latestConfigurations", "revisions", "workflowVersion",
        ]) || value.workflowVersion !== STORAGE_VERSION ||
        !Array.isArray(value.latestConfigurations) ||
        !value.latestConfigurations.every(configuration => WIRE.hasExactKeys(
            configuration, configuration?.provider === "ethereum"
                ? ["provider", "chainId", "results"] : ["provider", "publicKey"]
        ))) {
        throw new Error("Invalid stored configuration");
    }
    const parsed = WIRE.parseLatestConfigurations(value.latestConfigurations);
    if (!parsed.valid) { throw new Error("Invalid stored configuration"); }
    if (!WIRE.isProviderRevisions(value.revisions)) {
        throw new Error("Invalid stored revisions");
    }
    return {
        configurations: parsed.latestConfigurations.map(cleanConfiguration),
        revisions: {...value.revisions},
    };
}

function decodeReleasedHostConfigurationState(value) {
    if (typeof value === "undefined" || WIRE.isRecord(value) && (
        Object.prototype.hasOwnProperty.call(value, "workflowVersion") ||
        Object.prototype.hasOwnProperty.call(value, "bridgeState")
    )) {
        throw new Error("Invalid stored configuration");
    }
    const parsed = WIRE.parseLatestConfigurations(
        normalizedReleasedHostConfigurationState(value)
    );
    if (!parsed.valid) { throw new Error("Invalid stored configuration"); }
    return {
        configurations: parsed.latestConfigurations.map(cleanConfiguration),
        revisions: {ethereum: 0, solana: 0},
    };
}

function encodedConfigurationState(state) {
    return {
        latestConfigurations: state.configurations.map(cleanConfiguration),
        revisions: {...state.revisions},
        workflowVersion: STORAGE_VERSION,
    };
}

async function readConfigurationState(configurationKey, legacyConfigurationKey) {
    const hasLegacyKey = typeof legacyConfigurationKey === "string" &&
        legacyConfigurationKey !== configurationKey;
    const keys = hasLegacyKey
        ? [configurationKey, legacyConfigurationKey]
        : configurationKey;
    const result = await browser.storage.local.get(keys);
    if (Object.prototype.hasOwnProperty.call(result || {}, configurationKey)) {
        const state = decodeCurrentConfigurationState(result[configurationKey]);
        state.legacyConfigurationKey = hasLegacyKey &&
            Object.prototype.hasOwnProperty.call(result, legacyConfigurationKey)
            ? legacyConfigurationKey
            : null;
        return state;
    }
    if (hasLegacyKey &&
        Object.prototype.hasOwnProperty.call(result || {}, legacyConfigurationKey)) {
        const state = decodeReleasedHostConfigurationState(result[legacyConfigurationKey]);
        state.legacyConfigurationKey = legacyConfigurationKey;
        return state;
    }
    return {
        configurations: [],
        revisions: {ethereum: 0, solana: 0},
        legacyConfigurationKey: null,
    };
}

function queueConfigurationOperation(
    configurationKey,
    operation,
    legacyConfigurationKey = null
) {
    const operationKey = WIRE.configurationIdentityForURL(configurationKey)
        ?.legacyConfigurationKey || configurationKey;
    const previous = configurationOperationTails.get(operationKey) ||
        Promise.resolve();
    const persisted = previous.catch(() => {}).then(async () => {
        const state = await readConfigurationState(
            configurationKey,
            legacyConfigurationKey
        );
        const originalRevisions = {...state.revisions};
        const result = await operation(state);
        const revisionsChanged = state.revisions.ethereum !==
                originalRevisions.ethereum ||
            state.revisions.solana !== originalRevisions.solana;
        if (result?.changed === true && revisionsChanged &&
            await readLiveApprovalLease(configurationKey)) {
            throw new Error("Provider revisions are leased for approval");
        }
        if (state.legacyConfigurationKey || result?.changed === true) {
            await browser.storage.local.set({
                [configurationKey]: encodedConfigurationState(state),
            });
        }
        if (state.legacyConfigurationKey) {
            await browser.storage.local.remove(state.legacyConfigurationKey);
            state.legacyConfigurationKey = null;
        }
        return {
            configurationState: result?.changed === true || result?.broadcastConfiguration === true
                ? publicConfigurationState(state)
                : null,
            value: result?.value,
        };
    });
    configurationOperationTails.set(operationKey, persisted);
    const clearOperation = () => {
        if (configurationOperationTails.get(operationKey) === persisted) {
            configurationOperationTails.delete(operationKey);
        }
    };
    persisted.then(clearOperation, clearOperation);
    return persisted.then(async result => {
        if (result.configurationState) {
            await broadcastConfigurationChanged(
                configurationKey,
                result.configurationState
            );
        }
        return result.value;
    });
}

function publicConfigurationState(state) {
    return {
        latestConfigurations: publicConfigurations(state),
        revisions: {...state.revisions},
    };
}

function publicConfigurations(state) {
    return state.configurations.map(cleanConfiguration);
}

function configurationFor(state, provider) {
    return state.configurations.find(item => item.provider === provider) || null;
}

function normalizedEthereumAddress(value) {
    return typeof value === "string" && /^0x[0-9a-f]{40}$/i.test(value)
        ? value.toLowerCase()
        : null;
}

function isAuthorized(message, state) {
    if (message.provider === "ethereum") {
        const accountMethod = ETHEREUM_ACCOUNT_METHODS.has(message.name);
        const chainMethod = ETHEREUM_CHAIN_METHODS.has(message.name);
        if (!accountMethod && !chainMethod) { return true; }
        if (chainMethod && message.body?.address === "") { return true; }
        const address = normalizedEthereumAddress(message.body?.address);
        const configuration = configurationFor(state, "ethereum");
        return !!address && configuration?.results?.some(result => {
            return normalizedEthereumAddress(result) === address;
        });
    }
    if (message.provider === "solana") {
        if (!SOLANA_ACCOUNT_METHODS.has(message.name)) { return true; }
        return configurationFor(state, "solana")?.publicKey ===
            message.body?.publicKey;
    }
    return false;
}

function validatedDappMessage(request, context, state) {
    const identity = requestIdentity(request, context);
    const message = request.message;
    if (!identity || !WIRE.hasExactKeys(request, [
            "admissionDeadline", "configurationKey", "enqueueAttempt", "host",
            "message", "subject", "workflowVersion",
        ]) ||
        request.subject !== "message-to-wallet" ||
        request.workflowVersion !== WORKFLOW_VERSION ||
        !Number.isSafeInteger(request.admissionDeadline) ||
        request.admissionDeadline <= 0 ||
        !WIRE.isPrivateToken(request.enqueueAttempt) || !WIRE.isRecord(message) ||
        !WIRE.hasExactKeys(message, ["body", "id", "name", "provider"]) ||
        !WIRE.isValidRequestId(message.id) || typeof message.name !== "string" ||
        !WIRE.isRecord(message.body) ||
        !["ethereum", "solana"].includes(message.provider)) {
        return null;
    }
    return {
        admissionDeadline: request.admissionDeadline,
        id: message.id,
        name: message.name,
        provider: message.provider,
        body: {...message.body},
        favicon: identity.configurationKey.startsWith("file:")
            ? ""
            : context.favicon !== null && context.favicon.length <= 16 * 1024
                ? context.favicon
                : "",
        host: identity.host,
        configurationKey: identity.configurationKey,
        enqueueAttempt: request.enqueueAttempt,
        revisions: {...state.revisions},
        workflowVersion: WORKFLOW_VERSION,
    };
}

function affectedProviders(mutation) {
    if (mutation?.kind === "accounts") { return Object.keys(mutation.updates); }
    if (mutation?.kind === "ethereumChain") { return ["ethereum"]; }
    if (mutation?.kind === "revokeSolana") { return ["solana"]; }
    return [];
}

function sameProviderConfiguration(left, right) {
    if (!left || !right) { return left === right; }
    if (left.provider !== right.provider) { return false; }
    if (left.provider === "ethereum") {
        return left.chainId === right.chainId &&
            JSON.stringify(left.results || []) === JSON.stringify(right.results || []);
    }
    return left.provider === "solana" && left.publicKey === right.publicKey;
}

function canAdvanceProviderRevision(state, provider) {
    return state.revisions[provider] < Number.MAX_SAFE_INTEGER;
}

function replacingProviderConfiguration(configurations, provider, replacement) {
    const next = configurations.filter(item => item.provider !== provider);
    if (replacement) { next.push(cleanConfiguration(replacement)); }
    return next;
}

function disconnectedConfiguration(state, provider) {
    return provider === "ethereum" ? {
        provider,
        chainId: configurationFor(state, provider)?.chainId || "0x1",
        results: [],
    } : null;
}

function configurationsAfterResponse(state, mutation) {
    let configurations = state.configurations;
    if (mutation?.kind === "accounts") {
        for (const [provider, update] of Object.entries(mutation.updates)) {
            const configuration = update === null ? disconnectedConfiguration(state, provider) : provider === "ethereum"
                ? {provider, results: [update.address], chainId: update.chainId}
                : {provider, publicKey: update.publicKey};
            configurations = replacingProviderConfiguration(configurations, provider, configuration);
        }
    } else if (mutation?.kind === "ethereumChain") {
        configurations = replacingProviderConfiguration(configurations, "ethereum", {
            provider: "ethereum", chainId: mutation.chainId,
            results: configurationFor(state, "ethereum")?.results || [],
        });
    } else if (mutation?.kind === "revokeSolana" &&
        configurationFor(state, "solana")?.publicKey === mutation.publicKey) {
        configurations = replacingProviderConfiguration(configurations, "solana", null);
    }
    return configurations;
}

function applyResponseToState(
    state,
    response,
    expectedRevisions
) {
    const affected = affectedProviders(response.mutation);
    if (affected.length === 0) {
        return {changed: false, replay: false, stale: false};
    }
    const configurations = configurationsAfterResponse(
        state,
        response.mutation
    );
    const committed = response.approvalCommitted;
    const plans = [];
    for (const provider of affected) {
        const current = configurationFor(state, provider);
        const desired = configurationFor({configurations}, provider);
        if (state.revisions[provider] === expectedRevisions[provider]) {
            plans.push({provider, desired, mode: "apply"});
        } else if (
            state.revisions[provider] === expectedRevisions[provider] + 1 &&
            sameProviderConfiguration(current, desired)
        ) {
            plans.push({provider, desired, mode: "replay"});
        } else if (committed) {
            plans.push({provider, desired, mode: "preserve"});
        } else {
            return {changed: false, replay: false, stale: true};
        }
    }
    let changed = false;
    let committedDrift = false;
    let replay = false;
    if (plans.some(plan => plan.mode === "apply" &&
        !canAdvanceProviderRevision(state, plan.provider))) {
        return {changed: false, replay: false, stale: true};
    }
    for (const plan of plans) {
        if (plan.mode === "apply") {
            state.configurations = replacingProviderConfiguration(
                state.configurations,
                plan.provider,
                plan.desired
            );
            state.revisions[plan.provider] += 1;
            changed = true;
        } else if (plan.mode === "replay") {
            replay = true;
        } else {
            committedDrift = true;
        }
    }
    return {changed, committedDrift, replay, stale: false};
}

function pageConfigurationState(configurationState) {
    const configuration = provider => configurationState.latestConfigurations.find(item => item.provider === provider);
    const ethereum = configuration("ethereum");
    const solana = configuration("solana");
    return WIRE.decodeConfigurationSnapshot({
        revisions: {...configurationState.revisions},
        ethereum: {
            address: ethereum?.results[0] || "",
            chainId: ethereum?.chainId || "0x1",
        },
        solana: solana ? {publicKey: solana.publicKey} : null,
    });
}

function pageFailure(id, provider, name, message = "Failed to communicate with Big Wallet", code = -32603) {
    return {
        kind: "error", id, provider, name, state: null,
        error: {code, message},
    };
}

function pageConfigurationFailure() {
    return {kind: "configurationError", error: {
        code: 4900, message: "Failed to communicate with Big Wallet",
    }};
}

function rpcPageResponse(response, id) {
    if (!WIRE.isRecord(response) || response.id !== id) {
        return pageFailure(id, "ethereum", null, "Failed to process RPC response");
    }
    const base = {id, provider: "ethereum", name: null, state: null};
    if (Object.prototype.hasOwnProperty.call(response, "error")) {
        if (Object.prototype.hasOwnProperty.call(response, "result")) {
            return pageFailure(id, "ethereum", null, "Failed to process RPC response");
        }
        const raw = response.error;
        const error = {
            code: Number.isFinite(raw?.code) ? raw.code : -32603,
            message: typeof raw?.message === "string" ? raw.message
                : typeof raw === "string" ? raw : "Failed to process RPC response",
            ...(raw && typeof raw === "object" && Object.prototype.hasOwnProperty.call(raw, "data")
                ? {data: raw.data} : {}),
        };
        return WIRE.decodePageResponse({...base, kind: "error", error}, id) ||
            pageFailure(id, "ethereum", null, "Failed to process RPC response");
    }
    return WIRE.decodePageResponse({...base, kind: "result", result: response.result, approvalCommitted: false}, id) ||
        pageFailure(id, "ethereum", null, "Failed to process RPC response");
}

function terminalFailure(response, message, code = -32603) {
    return {
        id: response.id, name: response.name, provider: response.provider, kind: "error",
        approvalCommitted: false, mutation: null, error: {code, message}, authorizationFailure: false,
    };
}

function decodeNativeTerminal(response, id) {
    const terminal = WIRE.decodeNativeResponse(response, id);
    if (terminal) { return terminal; }
    if (!WIRE.isRecord(response) || response.id !== id ||
        typeof response.name !== "string" || response.name === "switchAccount" ||
        !["ethereum", "solana"].includes(response.provider)) { return null; }
    return terminalFailure(response, "Failed to process provider response");
}

function pageResponse(terminal, configurationState = null) {
    const state = configurationState ? pageConfigurationState(configurationState) : null;
    if (terminal.provider === "multiple") {
        return terminal.kind === "error"
            ? {kind: "configurationError", error: terminal.error}
            : {kind: "configuration", state};
    }
    const base = {id: terminal.id, provider: terminal.provider, name: terminal.name, state};
    const result = terminal.mutation?.kind === "ethereumChain" ? null : terminal.result;
    return terminal.kind === "error"
        ? {...base, kind: "error", error: terminal.error}
        : {...base, kind: "result", result, approvalCommitted: terminal.approvalCommitted};
}

function applyDappResponseToState(state, terminal, revisions) {
    if (!WIRE.isProviderRevisions(revisions)) { return {value: undefined}; }
    const applied = applyResponseToState(state, terminal, revisions);
    const manualSwitch = terminal.name === "switchAccount" && terminal.kind === "result";
    const configurationState = manualSwitch || applied.changed || applied.replay || applied.stale || applied.committedDrift
        ? publicConfigurationState(state) : null;
    const response = applied.stale
        ? terminalFailure(terminal, "Authorization changed while the request was pending", 4100)
        : terminal;
    return {
        changed: applied.changed,
        broadcastConfiguration: manualSwitch,
        value: {response, pageResponse: pageResponse(response, configurationState)},
    };
}

async function applyDappResponse(
    configurationKey,
    response,
    revisions,
    legacyConfigurationKey = null
) {
    return queueConfigurationOperation(
        configurationKey,
        state => applyDappResponseToState(state, response, revisions),
        legacyConfigurationKey
    );
}

function nativeRequestIdentity(context) {
    return {
        id: context.id,
        configurationKey: context.configurationKey,
        requestToken: context.requestToken,
        workflowVersion: WORKFLOW_VERSION,
    };
}

function nativeRequestStatus(response, id) {
    for (const status of ["pending", "ready", "missing", "unavailable"]) {
        if (WIRE.hasExactKeys(response, ["id", status]) &&
            response.id === id && response[status] === true) {
            return response;
        }
    }
    return undefined;
}

function prepareStoredResponseDelivery(context) {
    return WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(context),
        subject: "prepareResponseDelivery",
    }, false), TRANSPORT_TIMEOUT);
}

async function completeResponse(context, terminal) {
    if (context.requestToken) { await releaseCompletedExecution(context); }
    const applied = await applyDappResponse(
        context.configurationKey, terminal, context.revisions, context.legacyConfigurationKey
    );
    if (!applied) { return undefined; }
    const acknowledged = !context.requestToken || await acknowledgeCompletedResponse(
        context.id, context.configurationKey, context.requestToken
    );
    if (!acknowledged) { return undefined; }
    if (context.requestToken) { await removeExecutionJob(context); }
    if (applied.pageResponse.state) {
        const current = await readConfigurationState(context.configurationKey,
            context.legacyConfigurationKey);
        applied.pageResponse = pageResponse(applied.response, publicConfigurationState(current));
    }
    return {...applied, acknowledgement: Promise.resolve(true)};
}

async function consumeDappResponse(
    id,
    configurationKey,
    requestToken,
    revisions,
    legacyConfigurationKey = null,
    quiet = false
) {
    const key = JSON.stringify([configurationKey, id, requestToken]);
    const existing = completionFlights.get(key);
    if (existing) {
        if (quiet && !existing.quiet) { return undefined; }
        return existing.revisions.ethereum === revisions.ethereum &&
            existing.revisions.solana === revisions.solana
            ? existing.promise
            : undefined;
    }
    const context = {
        id, configurationKey, requestToken, revisions, legacyConfigurationKey, quiet,
    };
    const promise = (async () => {
        const response = await prepareStoredResponseDelivery(context);
        if (isMissingStoredResponse(response, id)) { return {response}; }
        if (WIRE.hasExactKeys(response, ["id", "pending"]) &&
            response.id === id && response.pending === true) {
            return {pending: true, response};
        }
        const terminal = decodeNativeTerminal(response, id);
        return terminal ? completeResponse(context, terminal) : undefined;
    })();
    const entry = {promise, configurationKey, revisions: {...revisions}, quiet};
    completionFlights.set(key, entry);
    const clear = () => {
        if (completionFlights.get(key) === entry) {
            completionFlights.delete(key);
        }
    };
    promise.then(completed => {
        if (completed?.response?.name === "switchAccount" && completed.acknowledgement) {
            completed.acknowledgement.then(clear, clear);
        } else {
            clear();
        }
    }, clear);
    return promise;
}

async function acknowledgeCompletedResponse(id, configurationKey, requestToken) {
    try {
        const response = await WIRE.withTimeout(sendNativeMessage({
            subject: "acknowledgeResponse",
            id,
            configurationKey,
            requestToken,
            workflowVersion: WORKFLOW_VERSION,
        }, false), TRANSPORT_TIMEOUT);
        return response?.id === id && (
            WIRE.hasExactKeys(response, ["id", "acknowledged"]) &&
                response.acknowledged === true ||
            WIRE.hasExactKeys(response, ["id", "missing"]) &&
                response.missing === true
        );
    } catch {
        return false;
    }
}

function isMissingStoredResponse(response, id) {
    return WIRE.hasExactKeys(response, ["id", "missing"]) &&
        response.id === id && response.missing === true;
}

function executionJobKey(job) {
    return JSON.stringify([job.configurationKey, job.id, job.requestToken]);
}

function validExecutionJob(job) {
    const identity = WIRE.configurationIdentityForURL(job?.configurationKey);
    return WIRE.hasExactKeys(job, [
        "attempt", "configurationKey", "createdAt", "expiresAt", "id", "manual",
        "nextMaintenanceAt", "requestToken", "revisions", "tabId", "workflowVersion",
    ]) && job.workflowVersion === WORKFLOW_VERSION &&
        identity?.configurationKey === job.configurationKey &&
        WIRE.isValidRequestId(job.id) && WIRE.isRequestToken(job.requestToken) &&
        WIRE.isProviderRevisions(job.revisions) && typeof job.manual === "boolean" &&
        (job.manual ? job.tabId === null : Number.isSafeInteger(job.tabId) && job.tabId >= 0) &&
        Number.isSafeInteger(job.createdAt) && job.createdAt > 0 &&
        Number.isSafeInteger(job.expiresAt) && job.expiresAt - job.createdAt ===
            WIRE.WORKFLOW_POLICY.requestTTLMilliseconds + WIRE.WORKFLOW_POLICY.responseExpiryMilliseconds &&
        Number.isSafeInteger(job.nextMaintenanceAt) && job.nextMaintenanceAt >= 0 &&
        (job.attempt === null || WIRE.hasExactKeys(job.attempt, ["attemptID", "lease"]) &&
            WIRE.isRequestToken(job.attempt.attemptID) &&
            validApprovalLease(job.attempt.lease, job.configurationKey));
}

function withExecutionJobs(operation) {
    const pending = executionJobsTail.catch(() => {}).then(async () => {
        const stored = await browser.storage.local.get(EXECUTION_JOBS_STORAGE_KEY);
        const jobs = stored?.[EXECUTION_JOBS_STORAGE_KEY] ?? [];
        if (!Array.isArray(jobs) || jobs.length > WIRE.WORKFLOW_POLICY.maximumRetainedRequests ||
            !jobs.every(validExecutionJob) || new Set(jobs.map(executionJobKey)).size !== jobs.length) {
            throw new Error("Invalid execution jobs");
        }
        const result = await operation(jobs);
        if (result.changed) {
            await browser.storage.local.set({[EXECUTION_JOBS_STORAGE_KEY]: jobs});
        }
        return result.value;
    });
    executionJobsTail = pending;
    return pending;
}

function persistExecutionJob(context) {
    return withExecutionJobs(jobs => {
        const existing = jobs.find(job => executionJobKey(job) === executionJobKey(context));
        if (existing) { return {value: existing}; }
        if (jobs.length >= WIRE.WORKFLOW_POLICY.maximumRetainedRequests) {
            throw new Error("Execution job capacity reached");
        }
        const createdAt = Date.now();
        const job = {
            attempt: null,
            configurationKey: context.configurationKey,
            createdAt,
            expiresAt: createdAt + WIRE.WORKFLOW_POLICY.requestTTLMilliseconds +
                WIRE.WORKFLOW_POLICY.responseExpiryMilliseconds,
            id: context.id,
            manual: context.manual,
            nextMaintenanceAt: 0,
            requestToken: context.requestToken,
            revisions: {...context.revisions},
            tabId: context.tabId,
            workflowVersion: WORKFLOW_VERSION,
        };
        if (!validExecutionJob(job)) { throw new Error("Invalid execution job"); }
        jobs.push(job);
        return {changed: true, value: job};
    });
}

function updateExecutionJob(job) {
    return withExecutionJobs(jobs => {
        const index = jobs.findIndex(value => executionJobKey(value) === executionJobKey(job));
        if (index < 0) { return {value: false}; }
        if (!validExecutionJob(job)) { throw new Error("Invalid execution job"); }
        jobs[index] = job;
        return {changed: true, value: true};
    });
}

function removeExecutionJob(context) {
    return withExecutionJobs(jobs => {
        const index = jobs.findIndex(job => executionJobKey(job) === executionJobKey(context));
        if (index < 0) { return {value: undefined}; }
        jobs.splice(index, 1);
        if (jobs.length === 0) {
            clearTimeout(executionTimer);
            executionTimer = null;
        }
        return {changed: true, value: undefined};
    }).then(() => {
        executionMaintenanceDeadlines.delete(executionJobKey(context));
    });
}

async function releaseCompletedExecution(context) {
    const job = await withExecutionJobs(jobs => ({value: jobs.find(value =>
        executionJobKey(value) === executionJobKey(context))}));
    if (!job?.attempt) { return; }
    const identity = WIRE.configurationIdentityForURL(job.configurationKey);
    await queueConfigurationOperation(job.configurationKey, async () => {
        await clearApprovalLease(job.configurationKey, job.attempt.lease.token);
        return {value: undefined};
    }, identity.legacyConfigurationKey);
}

async function requestStillActive(job) {
    if (job.manual) { return true; }
    try {
        const response = await WIRE.withTimeout(browser.tabs.sendMessage(job.tabId, {
            ...nativeRequestIdentity(job), subject: "requestActive",
        }), TAB_QUERY_TIMEOUT);
        return WIRE.hasExactKeys(response, ["id", "requestToken", "active"]) &&
            response.id === job.id && response.requestToken === job.requestToken &&
            response.active === true;
    } catch { return false; }
}

async function executionState(job) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(job), subject: "getExecutionStatus",
    }, false), TRANSPORT_TIMEOUT);
    if (WIRE.hasExactKeys(response, ["id", "state"]) && response.id === job.id &&
        ["awaitingReview", "awaitingExecution", "executing", "completed"].includes(response.state)) {
        return response.state;
    }
    return nativeRequestStatus(response, job.id)?.missing === true ? "missing" : null;
}

async function acquireExecutionAttempt(job) {
    const identity = WIRE.configurationIdentityForURL(job.configurationKey);
    return queueConfigurationOperation(job.configurationKey, async state => {
        let current = await readLiveApprovalLease(job.configurationKey);
        if (!job.attempt) {
            if (current || !await requestStillActive(job)) { return {value: null}; }
            const lease = makeApprovalLease(job.configurationKey, state.revisions);
            const token = lease.token;
            job.attempt = {
                attemptID: `${token.slice(0, 8)}-${token.slice(8, 12)}-${token.slice(12, 16)}-` +
                    `${token.slice(16, 20)}-${token.slice(20)}`,
                lease,
            };
            if (!await updateExecutionJob(job)) { return {value: null}; }
        }
        const lease = job.attempt.lease;
        if (Date.now() >= lease.expiresAt || current && !sameApprovalLease(current, lease)) {
            return {value: null};
        }
        if (!current) {
            if (state.revisions.ethereum !== lease.revisions.ethereum ||
                state.revisions.solana !== lease.revisions.solana) { return {value: null}; }
            await browser.storage.local.set({[approvalLeaseStorageKey(job.configurationKey)]: lease});
            current = await readLiveApprovalLease(job.configurationKey);
        }
        const persisted = await withExecutionJobs(jobs => ({value: jobs.find(value =>
            executionJobKey(value) === executionJobKey(job))}));
        return {value: sameApprovalLease(current, lease) &&
            persisted?.attempt?.attemptID === job.attempt.attemptID &&
            sameApprovalLease(persisted.attempt.lease, lease) ? job.attempt : null};
    }, identity.legacyConfigurationKey);
}

async function driveExecution(job) {
    const key = executionJobKey(job);
    const nextMaintenanceAt = Math.max(job.nextMaintenanceAt,
        executionMaintenanceDeadlines.get(key) || 0);
    const expired = Date.now() >= job.expiresAt;
    if (expired && Date.now() < nextMaintenanceAt) { return; }
    if (Date.now() >= nextMaintenanceAt) {
        job.nextMaintenanceAt = Date.now() + EXECUTION_MAINTENANCE_INTERVAL;
        executionMaintenanceDeadlines.set(key, job.nextMaintenanceAt);
        try {
            if (!await updateExecutionJob(job)) {
                executionMaintenanceDeadlines.delete(key);
                return;
            }
        } catch {}
        const response = await WIRE.withTimeout(sendNativeMessage({
            ...nativeRequestIdentity(job), subject: "maintainRequest",
            allowDelivery: !expired && await requestStillActive(job),
        }, false), TRANSPORT_TIMEOUT);
        if (!nativeRequestStatus(response, job.id)) { return; }
        if (response.missing) {
            await releaseCompletedExecution(job);
            await removeExecutionJob(job);
            return;
        }
    }
    const state = await executionState(job);
    if (state === "missing") {
        await releaseCompletedExecution(job);
        await removeExecutionJob(job);
        return;
    }
    if (state === "completed") {
        await releaseCompletedExecution(job);
        if (job.manual) {
            const identity = WIRE.configurationIdentityForURL(job.configurationKey);
            await consumeDappResponse(job.id, job.configurationKey, job.requestToken,
                job.revisions, identity.legacyConfigurationKey, true);
        } else {
            await removeExecutionJob(job);
        }
        return;
    }
    if (Date.now() >= job.expiresAt ||
        state !== "awaitingExecution" && state !== "executing") { return; }
    if (state === "executing" && !job.attempt) { return; }
    const attempt = await acquireExecutionAttempt(job);
    if (!attempt || !await requestStillActive(job) || Date.now() >= job.expiresAt) { return; }
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(job),
        subject: "executeNativeApproval",
        attemptID: attempt.attemptID,
        revisions: {...attempt.lease.revisions},
        executionDeadline: attempt.lease.expiresAt,
    }, false), NATIVE_OPERATION_TIMEOUT);
    const status = nativeRequestStatus(response, job.id);
    if (status?.ready || status?.missing) {
        await releaseCompletedExecution(job);
        if (status.missing) { await removeExecutionJob(job); }
        else if (job.manual) {
            const identity = WIRE.configurationIdentityForURL(job.configurationKey);
            await consumeDappResponse(job.id, job.configurationKey, job.requestToken,
                job.revisions, identity.legacyConfigurationKey, true);
        } else {
            await removeExecutionJob(job);
        }
    }
}

function recoverExecutions() {
    if (browser.extension?.inIncognitoContext === true) { return Promise.resolve(); }
    if (executionRecoveryFlight) { return executionRecoveryFlight; }
    const pending = (async () => {
        const jobs = await withExecutionJobs(values => ({value: values}));
        const keys = new Set(jobs.map(executionJobKey));
        for (const key of executionMaintenanceDeadlines.keys()) {
            if (!keys.has(key)) { executionMaintenanceDeadlines.delete(key); }
        }
        if (jobs.length === 0) { return; }
        await ensureManualSwitchAlarm();
        for (const job of jobs) {
            const lineage = approvalLeaseLineageKey(job.configurationKey);
            if (executionLineageFlights.has(lineage)) { continue; }
            executionLineageFlights.add(lineage);
            const candidates = jobs.filter(value => approvalLeaseLineageKey(value.configurationKey) === lineage);
            const flight = (async () => {
                for (const candidate of candidates) {
                    try { await driveExecution(candidate); } catch {}
                }
            })();
            const clear = () => {
                executionLineageFlights.delete(lineage);
            };
            flight.then(clear, clear);
        }
        if (executionTimer === null) {
            executionTimer = setTimeout(() => {
                executionTimer = null;
                void recoverExecutions().catch(() => {});
            }, MANUAL_SWITCH_POLL_DELAY);
        }
    })();
    executionRecoveryFlight = pending;
    const clear = () => {
        if (executionRecoveryFlight === pending) { executionRecoveryFlight = null; }
    };
    pending.then(clear, clear);
    return pending;
}

function ensureManualSwitchAlarm() {
    if (manualSwitchAlarmFlight) { return manualSwitchAlarmFlight; }
    const pending = (async () => {
        const alarm = await browser.alarms.get(MANUAL_SWITCH_RECOVERY_ALARM);
        if (!alarm) {
            await browser.alarms.create(MANUAL_SWITCH_RECOVERY_ALARM, {
                delayInMinutes: 1,
                periodInMinutes: 1,
            });
        }
    })();
    manualSwitchAlarmFlight = pending;
    const clear = () => {
        if (manualSwitchAlarmFlight === pending) { manualSwitchAlarmFlight = null; }
    };
    pending.then(clear, clear);
    return pending;
}

function validManualSwitchDescriptor(request) {
    if (!WIRE.hasExactKeys(request, [
        "id", "host", "configurationKey", "requestToken", "revisions", "state",
    ])) { return false; }
    const identity = WIRE.configurationIdentityForURL(request.configurationKey);
    return WIRE.isValidRequestId(request.id) &&
        identity?.configurationKey === request.configurationKey &&
        identity.host === request.host &&
        WIRE.isRequestToken(request.requestToken) &&
        WIRE.isProviderRevisions(request.revisions) &&
        ["pending", "approved", "completed"].includes(request.state);
}

function scheduleManualSwitchPoll() {
    if (manualSwitchPollTimer !== null) { return; }
    if (Date.now() >= manualSwitchPollingDeadline) { return; }
    manualSwitchPollTimer = setTimeout(() => {
        manualSwitchPollTimer = null;
        if (Date.now() < manualSwitchPollingDeadline) {
            void recoverManualSwitches().catch(() => {});
        }
    }, MANUAL_SWITCH_POLL_DELAY);
}

async function discoverManualSwitches() {
    const id = WIRE.genId();
    const response = await WIRE.withTimeout(sendNativeMessage({
        id,
        subject: "getManualSwitchRequests",
        workflowVersion: WORKFLOW_VERSION,
    }, false), TRANSPORT_TIMEOUT);
    if (!WIRE.hasExactKeys(response, ["id", "requests"]) ||
        response.id !== id || !Array.isArray(response.requests) ||
        response.requests.length > WIRE.WORKFLOW_POLICY.maximumRequests ||
        !response.requests.every(validManualSwitchDescriptor)) {
        throw new Error("Invalid manual-switch discovery");
    }
    return response.requests;
}


function recoverManualSwitches() {
    if (browser.extension?.inIncognitoContext === true) { return Promise.resolve(); }
    if (manualSwitchDiscoveryFlight) {
        manualSwitchDiscoveryQueued = true;
        return manualSwitchDiscoveryFlight;
    }
    const pending = (async () => {
        await ensureManualSwitchAlarm();
        const requests = await discoverManualSwitches();
        if (requests.length === 0 && manualSwitchEnqueues.size === 0) {
            manualSwitchPollingDeadline = 0;
            clearTimeout(manualSwitchPollTimer);
            manualSwitchPollTimer = null;
        }
        for (const request of requests) {
            await persistExecutionJob({...request, tabId: null, manual: true});
        }
        void recoverExecutions().catch(() => {});
    })();
    manualSwitchDiscoveryFlight = pending;
    const clear = () => {
        if (manualSwitchDiscoveryFlight === pending) { manualSwitchDiscoveryFlight = null; }
        if (manualSwitchDiscoveryQueued) {
            manualSwitchDiscoveryQueued = false;
            void recoverManualSwitches().catch(() => {});
        } else {
            scheduleManualSwitchPoll();
        }
    };
    pending.then(clear, clear);
    return pending;
}

function beginManualSwitch(identity) {
    manualSwitchPollingDeadline = Date.now() + WIRE.WORKFLOW_POLICY.requestTTLMilliseconds;
    scheduleManualSwitchPoll();
    const existing = manualSwitchEnqueues.get(identity.configurationKey);
    if (existing) { return existing; }
    const admissionDeadline = manualSwitchPollingDeadline;
    const pending = (async () => {
        try {
            await ensureManualSwitchAlarm();
            const snapshot = await queueConfigurationOperation(
                identity.configurationKey,
                state => ({value: {
                    configurations: state.configurations.map(configuration =>
                        configuration.provider === "ethereum" ? {
                            provider: "ethereum",
                            chainId: configuration.chainId,
                            results: [...configuration.results],
                        } : {
                            provider: "solana",
                            publicKey: configuration.publicKey,
                        }),
                    revisions: {...state.revisions},
                }}),
                identity.legacyConfigurationKey
            );
            const id = WIRE.genId();
            const response = await WIRE.withTimeout(sendNativeMessage({
                admissionDeadline,
                body: {latestConfigurations: snapshot.configurations},
                configurationKey: identity.configurationKey,
                enqueueAttempt: WIRE.genPrivateToken(),
                favicon: identity.favicon.length <= 16 * 1024 ? identity.favicon : "",
                host: identity.host,
                id,
                name: "switchAccount",
                provider: "unknown",
                revisions: snapshot.revisions,
                workflowVersion: WORKFLOW_VERSION,
            }, false), TRANSPORT_TIMEOUT);
            if (WIRE.isValidRequestId(response?.id) &&
                WIRE.isNativeEnqueueAcknowledgement(response, response.id)) {
                await persistExecutionJob({
                    ...identity, id: response.id, requestToken: response.requestToken,
                    revisions: response.revisions, tabId: null, manual: true,
                });
                void recoverExecutions().catch(() => {});
                if (response.approvalRequired) {
                    notifyPendingRequestAvailable();
                    cuePopup();
                }
                return {
                    ...response,
                    configurationKey: identity.configurationKey,
                    subject: WIRE.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
                    workflowVersion: WORKFLOW_VERSION,
                };
            }
            const terminal = WIRE.decodeNativeResponse(response, id);
            if (!terminal || terminal.name !== "switchAccount") { return undefined; }
            const completed = await completeResponse({
                id,
                ...identity,
                revisions: snapshot.revisions,
            }, terminal);
            return completed?.response;
        } catch {
            return undefined;
        }
    })();
    manualSwitchEnqueues.set(identity.configurationKey, pending);
    const clear = async () => {
        await manualSwitchDiscoveryFlight?.catch(() => {});
        if (manualSwitchEnqueues.get(identity.configurationKey) === pending) {
            manualSwitchEnqueues.delete(identity.configurationKey);
        }
        void recoverManualSwitches().catch(() => {});
    };
    pending.then(clear, clear);
    return pending;
}

async function handleManualSwitchIntent(request, context) {
    const identity = requestIdentity(request, context);
    if (context.privateBrowsing ||
        !identity || !WIRE.hasExactKeys(request, [
            "configurationKey", "host", "subject", "workflowVersion",
        ]) || request.subject !== WIRE.MANUAL_SWITCH_INTENT_SUBJECT ||
        request.workflowVersion !== WORKFLOW_VERSION) {
        return undefined;
    }
    return beginManualSwitch({
        ...identity,
        favicon: identity.configurationKey.startsWith("file:")
            ? ""
            : context.favicon || "",
    });
}

async function handleDappRequest(request, context) {
    if (context.privateBrowsing) {
        return pageFailure(request?.message?.id, request?.message?.provider,
            request?.message?.name || "request", privateBrowsingUnsupportedMessage(), 4200);
    }
    const identity = requestIdentity(request, context);
    if (!identity) { return undefined; }
    const state = await queueConfigurationOperation(
        identity.configurationKey,
        current => ({value: {
            configurations: current.configurations.map(cleanConfiguration),
            revisions: {...current.revisions},
        }}),
        identity.legacyConfigurationKey
    );
    const message = validatedDappMessage(request, context, state);
    if (!message) { return undefined; }
    const authorized = isAuthorized(message, state);
    const directResponseRevisions = {...message.revisions};
    await ensureManualSwitchAlarm();
    const response = await WIRE.withTimeout(
        sendNativeMessage(authorized ? message : {...message, replayOnly: true}, false),
        TRANSPORT_TIMEOUT
    );
    if (WIRE.isNativeEnqueueAcknowledgement(response, message.id)) {
        await persistExecutionJob({
            ...message, requestToken: response.requestToken, revisions: response.revisions,
            tabId: context.tabId, manual: false,
        });
        void recoverExecutions().catch(() => {});
        if (authorized && response.approvalRequired) {
            notifyPendingRequestAvailable();
            cuePopup();
        }
        return response;
    }
    const terminal = decodeNativeTerminal(response, message.id);
    if (terminal) {
        if (!authorized) {
            return pageResponse(terminalFailure(terminal,
                "Authorization changed while the request was pending", 4100), {
                latestConfigurations: publicConfigurations(state), revisions: {...state.revisions},
            });
        }
        const applied = await applyDappResponse(message.configurationKey, terminal, directResponseRevisions);
        return applied?.pageResponse;
    }
    return undefined;
}

function validContentResponseRequest(request, context, consuming) {
    const keys = ["configurationKey", "id", "requestToken", "subject", "workflowVersion"];
    if (consuming) { keys.push("revisions"); }
    return !context.privateBrowsing && WIRE.hasExactKeys(request, keys) &&
        request.workflowVersion === WORKFLOW_VERSION &&
        context.identity?.configurationKey === request.configurationKey &&
        WIRE.isValidRequestId(request.id) && WIRE.isRequestToken(request.requestToken) &&
        (!consuming || WIRE.isProviderRevisions(request.revisions));
}

async function handleGetResponse(request, context) {
    if (!validContentResponseRequest(request, context, false)) { return undefined; }
    const response = await WIRE.withTimeout(sendNativeMessage({
        ...nativeRequestIdentity(request), subject: "getResponse",
    }, false), TRANSPORT_TIMEOUT);
    return nativeRequestStatus(response, request.id);
}

async function consumeResponse(request, context) {
    if (!validContentResponseRequest(request, context, true)) { return undefined; }
    const completed = await consumeDappResponse(
        request.id, request.configurationKey, request.requestToken, request.revisions,
        context.identity.legacyConfigurationKey
    );
    return completed?.pageResponse || completed?.response;
}

async function handleRPC(request, context) {
    if (!WIRE.hasExactKeys(request, [
            "body", "chainId", "id", "subject", "workflowVersion",
        ]) || request.workflowVersion !== WORKFLOW_VERSION ||
        !WIRE.isValidRequestId(request.id) || typeof request.body !== "string" ||
        typeof request.chainId !== "string") {
        return pageFailure(request?.id, "ethereum", null);
    }
    if (context.privateBrowsing) { return pageFailure(request.id, "ethereum", null); }
    try {
        const response = await WIRE.withTimeout(
            sendNativeMessage(request, false),
            NATIVE_OPERATION_TIMEOUT
        );
        return WIRE.isCorrelatedRPCResponse(response, request.id)
            ? rpcPageResponse(response, request.id)
            : pageFailure(request.id, "ethereum", null);
    } catch {
        return pageFailure(request.id, "ethereum", null);
    }
}

async function approveWithCurrentRevisions(request, context) {
    const identity = requestIdentity(request, context);
    if (!WIRE.hasExactKeys(request, [
            "configurationKey", "host", "id", "payload", "privateBrowsing",
            "requestToken", "reviewToken", "subject", "workflowVersion",
        ]) || request.subject !== "approveRequestWithCurrentRevisions" ||
        request.workflowVersion !== WORKFLOW_VERSION || !identity ||
        !WIRE.isValidRequestId(request.id) ||
        !WIRE.isRequestToken(request.requestToken) ||
        !WIRE.isRequestToken(request.reviewToken) ||
        typeof request.privateBrowsing !== "boolean" ||
        !validPopupApprovalPayload(request.payload)) {
        return undefined;
    }
    return withProviderRevisionLease(
        request.configurationKey,
        identity.legacyConfigurationKey,
        lease => sendNativeMessage({
            subject: "approveRequest",
            id: request.id,
            requestToken: request.requestToken,
            reviewToken: request.reviewToken,
            payload: {
                ...request.payload,
                executionDeadline: lease.executionDeadline,
                revisions: {...lease.revisions},
            },
            workflowVersion: WORKFLOW_VERSION,
        }, request.privateBrowsing || context.privateBrowsing),
        true
    );
}

async function applyCompletedResponse(request, context) {
    const identity = requestIdentity(request, context);
    if (context.privateBrowsing || !WIRE.hasExactKeys(request, [
            "configurationKey", "host", "id", "requestToken", "revisions",
            "subject", "workflowVersion",
        ]) || request.subject !== "applyCompletedResponse" ||
        request.workflowVersion !== WORKFLOW_VERSION ||
        !identity ||
        !WIRE.isValidRequestId(request.id) ||
        !WIRE.isRequestToken(request.requestToken) ||
        !WIRE.isProviderRevisions(request.revisions)) {
        return undefined;
    }
    const completed = await consumeDappResponse(
        request.id,
        request.configurationKey,
        request.requestToken,
        request.revisions,
        identity.legacyConfigurationKey
    );
    const response = completed?.response;
    if (isMissingStoredResponse(response, request.id)) {
        return response;
    }
    return completed?.pageResponse && await completed.acknowledgement
        ? {applied: true}
        : undefined;
}

async function latestConfiguration(request, context) {
    if (context.privateBrowsing) {
        return {kind: "configuration", state: {
            ethereum: {address: "", chainId: "0x1"}, solana: null, revisions: {ethereum: 0, solana: 0},
        }};
    }
    const identity = requestIdentity(request, context);
    if (!identity) {
        return pageConfigurationFailure();
    }
    void recoverManualSwitches().catch(() => {});
    try {
        const state = await readConfigurationState(
            identity.configurationKey,
            identity.legacyConfigurationKey
        );
        return {kind: "configuration", state: pageConfigurationState(publicConfigurationState(state))};
    } catch {
        return pageConfigurationFailure();
    }
}

function disconnectFailure(request) {
    return pageFailure(request?.id, request?.provider, "revokePermissions", "Failed to revoke permissions");
}

async function disconnect(request, context) {
    if (!WIRE.isValidDisconnectRequest(request)) { return undefined; }
    const identity = requestIdentity(request, context);
    if (!identity || context.privateBrowsing) {
        return disconnectFailure(request);
    }
    return queueConfigurationOperation(identity.configurationKey, async state => {
        if (await readLiveApprovalLease(identity.configurationKey)) {
            return {value: disconnectFailure(request)};
        }
        if (!canAdvanceProviderRevision(state, request.provider)) {
            return {value: disconnectFailure(request)};
        }
        state.configurations = replacingProviderConfiguration(
            state.configurations, request.provider, disconnectedConfiguration(state, request.provider)
        );
        state.revisions[request.provider] += 1;
        return {changed: true, value: pageResponse({
            id: request.id,
            name: "revokePermissions",
            provider: request.provider,
            kind: "result",
            approvalCommitted: false,
            mutation: null,
            result: null,
        }, publicConfigurationState(state))};
    }, identity.legacyConfigurationKey).catch(() => disconnectFailure(request));
}

function cuePopup() {
    if (!hasConfiguredPopup()) {
        clearBadgeWithoutPopup();
        return;
    }
    try {
        Promise.resolve(browser.action?.setBadgeText?.({text: "•"})).catch(() => {});
    } catch {}
    try { Promise.resolve(browser.action?.openPopup?.()).catch(() => {}); } catch {}
}

function notifyPendingRequestAvailable() {
    try {
        Promise.resolve(browser.runtime.sendMessage({
            subject: "pendingRequestAvailable",
            workflowVersion: WORKFLOW_VERSION,
        })).catch(() => {});
    } catch {}
}

function updateBadge(request, context) {
    if (context.privateBrowsing ||
        !WIRE.hasExactKeys(request, [
            "hasPendingRequests", "subject", "workflowVersion",
        ]) || typeof request.hasPendingRequests !== "boolean" ||
        request.workflowVersion !== WORKFLOW_VERSION) {
        return undefined;
    }
    if (!hasConfiguredPopup()) { return clearBadgeWithoutPopup(); }
    try {
        return browser.action?.setBadgeText?.({
            text: request.hasPendingRequests ? "•" : "",
        });
    } catch {
        return undefined;
    }
}

function clearBadgeWithoutPopup() {
    if (hasConfiguredPopup()) { return undefined; }
    try {
        return browser.action?.setBadgeText?.({text: ""});
    } catch {
        return undefined;
    }
}

function hasConfiguredPopup() {
    try {
        const manifest = browser.runtime.getManifest?.();
        const popup = manifest?.action?.default_popup ||
            manifest?.browser_action?.default_popup;
        return typeof popup === "string" && popup.length > 0;
    } catch {
        return false;
    }
}

async function openNativeWallet(tab) {
    try {
        await WIRE.withTimeout(sendNativeMessage({
            subject: "openApp",
            id: WIRE.genId(),
            workflowVersion: WORKFLOW_VERSION,
        }, tab?.incognito === true), TRANSPORT_TIMEOUT);
    } catch {}
}

async function handleToolbarClick(tab) {
    if (hasConfiguredPopup()) { return; }
    const identity = WIRE.configurationIdentityForURL(tab?.url || tab?.pendingUrl);
    if (!identity || !Number.isSafeInteger(tab?.id) || tab?.incognito === true) {
        await openNativeWallet(tab);
        return;
    }
    const nonce = WIRE.genPrivateToken();
    let probe;
    try {
        probe = await WIRE.withTimeout(browser.tabs.sendMessage(tab.id, {
            nonce,
            subject: "workflowProbe",
            workflowVersion: WORKFLOW_VERSION,
        }), TAB_QUERY_TIMEOUT);
    } catch {
        await openNativeWallet(tab);
        return;
    }
    if (!WIRE.hasExactKeys(probe, [
            "buildVersion", "nonce", "subject", "workflowVersion",
        ]) || probe.subject !== "workflowProbe" || probe.nonce !== nonce ||
        typeof probe.buildVersion !== "string" ||
        probe.buildVersion.length === 0 ||
        !Number.isSafeInteger(probe.workflowVersion)) {
        await openNativeWallet(tab);
        return;
    }
    if (probe.workflowVersion !== WORKFLOW_VERSION ||
        probe.buildVersion !== BUILD_VERSION) {
        await openNativeWallet(tab);
        return;
    }
    let response;
    try {
        response = await WIRE.withTimeout(
            browser.tabs.sendMessage(tab.id, {
                configurationKey: identity.configurationKey,
                subject: WIRE.MANUAL_SWITCH_INTENT_SUBJECT,
                workflowVersion: WORKFLOW_VERSION,
            }),
            MANUAL_SWITCH_INTENT_TIMEOUT
        );
    } catch {
        await openNativeWallet(tab);
        return;
    }
    const valid = WIRE.isManualSwitchAcknowledgement(
        response,
        response?.id,
        identity.configurationKey
    ) || WIRE.isManualSwitchTerminalResponse(response, response?.id);
    if (!valid || response.kind === "error") {
        await openNativeWallet(tab);
    } else if (WIRE.isManualSwitchAcknowledgement(
        response,
        response.id,
        identity.configurationKey
    ) && response.approvalRequired) {
        try {
            await WIRE.withTimeout(sendNativeMessage({
                subject: "showApproval",
                id: response.id,
                configurationKey: identity.configurationKey,
                requestToken: response.requestToken,
                workflowVersion: WORKFLOW_VERSION,
            }, false), TRANSPORT_TIMEOUT);
        } catch {}
    }
}

async function broadcastResponseReady(request) {
    const ids = WIRE.responseReadyIds(request);
    if (!ids) { return; }
    const recovery = recoverManualSwitches().catch(() => {});
    const tabs = await boundedTabsQuery();
    if (tabs) {
        for (const tab of tabs || []) {
            if (!Number.isSafeInteger(tab?.id)) { continue; }
            try { Promise.resolve(browser.tabs.sendMessage(tab.id, request)).catch(() => {}); } catch {}
        }
    }
    await recovery;
}

async function boundedTabsQuery() {
    try {
        return await WIRE.withTimeout(
            browser.tabs.query({}),
            TAB_QUERY_TIMEOUT
        );
    } catch {
        return null;
    }
}

function persistUpdateRecovery(details) {
    if (details?.reason !== "update") { return; }
    try {
        return browser.storage.local.set({[UPDATE_RECOVERY_STORAGE_KEY]: true});
    } catch {}
}

function clearUpdateRecovery() {
    try {
        return browser.storage.local.remove(UPDATE_RECOVERY_STORAGE_KEY);
    } catch {}
}

async function broadcastConfigurationChanged(configurationKey, configurationState) {
    const tabs = await boundedTabsQuery();
    if (!tabs) { return; }
    const message = {
        subject: "configurationChanged",
        configurationKey,
        state: pageConfigurationState(configurationState),
        workflowVersion: WORKFLOW_VERSION,
    };
    for (const tab of tabs || []) {
        if (tab?.incognito === true || !Number.isSafeInteger(tab?.id) ||
            WIRE.configurationIdentityForURL(tab.url)?.configurationKey !==
                configurationKey) {
            continue;
        }
        try {
            Promise.resolve(browser.tabs.sendMessage(tab.id, message)).catch(() => {});
        } catch {}
    }
}

async function handleMessage(request, context) {
    if (request.subject === "getResponse" && request.workflowVersion === undefined) {
        if (!Number.isFinite(request.id)) { return undefined; }
        return {
            id: request.id,
            provider: "multiple",
            bodies: ["ethereum", "solana"].map(provider => ({
                provider,
                error: "Big Wallet was updated. Reload this page to continue.",
                errorCode: -32603,
            })),
            providersToDisconnect: [],
        };
    }
    switch (request.subject) {
    case "rpc":
        return handleRPC(request, context);
    case "message-to-wallet":
        return handleDappRequest(request, context);
    case WIRE.MANUAL_SWITCH_INTENT_SUBJECT:
        return handleManualSwitchIntent(request, context);
    case "getResponse":
        return handleGetResponse(request, context);
    case "consumeResponse":
        return consumeResponse(request, context);
    case "getLatestConfiguration":
        return latestConfiguration(request, context);
    case "approveRequestWithCurrentRevisions":
        return approveWithCurrentRevisions(request, context);
    case "applyCompletedResponse":
        return applyCompletedResponse(request, context);
    case "disconnect":
        return disconnect(request, context);
    case "updatePendingRequestBadge":
        await updateBadge(request, context);
        return undefined;
    case "responseReady":
        if (context.privateBrowsing) { return undefined; }
        await broadcastResponseReady(request);
        return undefined;
    default:
        return undefined;
    }
}

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    const context = WIRE.authorizeRuntimeMessage("worker", request, sender, browser.runtime);
    if (!context) { return false; }
    Promise.resolve(handleMessage(request, context)).then(
        sendResponse,
        () => sendResponse()
    );
    return true;
});

try {
    browser.runtime.onInstalled?.addListener?.(details => {
        Promise.resolve(persistUpdateRecovery(details)).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        void recoverManualSwitches().catch(() => {});
        void recoverExecutions().catch(() => {});
    });
} catch {}

try {
    browser.runtime.onStartup?.addListener?.(() => {
        Promise.resolve(clearUpdateRecovery()).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        void recoverManualSwitches().catch(() => {});
        void recoverExecutions().catch(() => {});
    });
} catch {}

try {
    Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
    void recoverManualSwitches().catch(() => {});
    void recoverExecutions().catch(() => {});
} catch {}

try {
    browser.alarms.onAlarm.addListener(alarm => {
        if (alarm?.name !== MANUAL_SWITCH_RECOVERY_ALARM) { return undefined; }
        return Promise.allSettled([recoverManualSwitches(), recoverExecutions()]);
    });
} catch {}

try {
    browser.action?.onClicked?.addListener?.(tab => {
        Promise.resolve(handleToolbarClick(tab)).catch(() => {});
    });
} catch {}
