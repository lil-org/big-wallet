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
const responseReadFlights = new Map;
const manualSwitches = new Map;
let manualSwitchAlarmFlight = null;
let manualSwitchRecoveryFlight = null;

function sendRawNativeMessage(message) {
    return browser.runtime.sendNativeMessage(APPLICATION_ID, message);
}

const sendNativeMessage = WIRE.createTrustedNativeMessageSender({
    sendRawNativeMessage,
});

function privateBrowsing(sender) {
    return sender?.tab?.incognito === true || sender?.incognito === true;
}

function privateBrowsingUnsupportedMessage() {
    try {
        const message = browser.i18n.getMessage("private_browsing_unsupported");
        if (message) { return message; }
    } catch {}
    return "Big Wallet requests are unavailable in Private Browsing.";
}

function senderIdentity(sender) {
    return WIRE.configurationIdentityForURL(sender?.url || sender?.tab?.url);
}

function trustedIdentity(request, sender) {
    const identity = senderIdentity(sender);
    return identity && request.host === identity.host &&
        request.configurationKey === identity.configurationKey
        ? identity
        : null;
}

function trustedPopupIdentity(request, sender) {
    if (sender?.tab || sender?.id !== browser.runtime.id ||
        sender?.url !== browser.runtime.getURL("popup.html")) {
        return null;
    }
    const identity = WIRE.configurationIdentityForURL(request.configurationKey);
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

async function installApprovalLease(
    configurationKey,
    revisions,
    canAcquire = () => true
) {
    if (await readLiveApprovalLease(configurationKey)) { return null; }
    if (!canAcquire()) { return null; }
    const now = Date.now();
    const value = {
        configurationKey: approvalLeaseLineageKey(configurationKey),
        executionDeadline: now + APPROVAL_EXECUTION_TIMEOUT,
        expiresAt: now + APPROVAL_EXECUTION_TIMEOUT + APPROVAL_LEASE_GRACE,
        issuedAt: now,
        revisions: {...revisions},
        token: WIRE.genPrivateToken(),
        workflowVersion: WORKFLOW_VERSION,
    };
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

function validatedDappMessage(request, sender, state) {
    const identity = trustedIdentity(request, sender);
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
            : typeof sender?.tab?.favIconUrl === "string"
                && sender.tab.favIconUrl.length <= 16 * 1024
                ? sender.tab.favIconUrl
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

function readStoredResponse(context) {
    return withProviderRevisionLease(
        context.configurationKey,
        context.legacyConfigurationKey,
        lease => sendNativeMessage({
            subject: context.quiet ? "getManualSwitchResponse" : "getResponse",
            id: context.id,
            configurationKey: context.configurationKey,
            requestToken: context.requestToken,
            executionDeadline: lease.expiresAt,
            revisions: {...lease.revisions},
            workflowVersion: WORKFLOW_VERSION,
        }, false)
    );
}

async function completeResponse(context, terminal) {
    const applied = await applyDappResponse(
        context.configurationKey, terminal, context.revisions, context.legacyConfigurationKey
    );
    if (!applied) { return undefined; }
    return {
        ...applied,
        acknowledgement: context.requestToken
            ? acknowledgeCompletedResponse(context.id, context.configurationKey, context.requestToken)
            : Promise.resolve(true),
    };
}

async function readAndApplyDappResponse(
    id,
    configurationKey,
    requestToken,
    revisions,
    legacyConfigurationKey = null,
    quiet = false
) {
    const key = JSON.stringify([configurationKey, id, requestToken]);
    const existing = responseReadFlights.get(key);
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
        const response = await readStoredResponse(context);
        if (isMissingStoredResponse(response, id)) { return {response}; }
        if (WIRE.hasExactKeys(response, ["id", "pending"]) &&
            response.id === id && response.pending === true) {
            return {pending: true, response};
        }
        const terminal = decodeNativeTerminal(response, id);
        return terminal ? completeResponse(context, terminal) : undefined;
    })();
    const entry = {promise, revisions: {...revisions}, quiet};
    responseReadFlights.set(key, entry);
    const clear = () => {
        if (responseReadFlights.get(key) === entry) {
            responseReadFlights.delete(key);
        }
    };
    promise.then(clear, clear);
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

function hydrateManualSwitch(request) {
    const existing = manualSwitches.get(request.configurationKey);
    if (existing && (existing.id !== request.id ||
        existing.requestToken !== request.requestToken)) {
        return null;
    }
    const identity = WIRE.configurationIdentityForURL(request.configurationKey);
    const context = existing || {
        ...identity,
        id: request.id,
        requestToken: request.requestToken,
        revisions: {...request.revisions},
        pollingDeadline: Infinity,
        quiet: true,
        polling: null,
        timer: null,
    };
    if (context.quiet) {
        context.fastPolling = request.state === "approved";
        context.admission = Promise.resolve({
            id: request.id,
            requestToken: request.requestToken,
            revisions: {...request.revisions},
            approvalRequired: request.state !== "completed",
            configurationKey: request.configurationKey,
            subject: WIRE.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
            workflowVersion: WORKFLOW_VERSION,
        });
    }
    manualSwitches.set(request.configurationKey, context);
    return context;
}

function recoverManualSwitches() {
    if (browser.extension?.inIncognitoContext === true) { return Promise.resolve(); }
    if (manualSwitchRecoveryFlight) { return manualSwitchRecoveryFlight; }
    const pending = (async () => {
        await ensureManualSwitchAlarm();
        const requests = [];
        const cursors = new Set;
        let cursor;
        do {
            const id = WIRE.genId();
            const response = await WIRE.withTimeout(sendNativeMessage({
                id,
                subject: "getManualSwitchRequests",
                workflowVersion: WORKFLOW_VERSION,
                ...(cursor ? {cursor} : {}),
            }, false), TRANSPORT_TIMEOUT);
            if (!WIRE.hasExactKeys(response, ["id", "requests", "nextCursor"]) ||
                response.id !== id || !Array.isArray(response.requests) ||
                response.requests.length > WIRE.WORKFLOW_POLICY.maximumRetainedRequests ||
                !response.requests.every(validManualSwitchDescriptor) ||
                response.nextCursor !== null &&
                    (typeof response.nextCursor !== "string" ||
                        response.nextCursor.length === 0 ||
                        response.nextCursor.length > 4096 ||
                        cursors.has(response.nextCursor))) {
                throw new Error("Invalid manual-switch discovery");
            }
            requests.push(...response.requests);
            cursor = response.nextCursor;
            if (cursor) { cursors.add(cursor); }
        } while (cursor);
        const discovered = new Set(requests.map(request => request.requestToken));
        for (const context of manualSwitches.values()) {
            if (context.quiet && !discovered.has(context.requestToken)) {
                forgetManualSwitch(context);
            }
        }
        const origins = new Map;
        for (const request of requests) {
            const previous = origins.get(request.configurationKey) || Promise.resolve();
            origins.set(request.configurationKey, previous.then(async () => {
                const context = request.state === "completed"
                    ? manualSwitches.get(request.configurationKey)
                    : hydrateManualSwitch(request);
                if (request.state === "pending") {
                    if (context?.quiet) { clearTimeout(context.timer); }
                    return;
                }
                if (context?.id === request.id &&
                    context.requestToken === request.requestToken) {
                    await pollManualSwitch(context, true);
                    return;
                }
                const identity = WIRE.configurationIdentityForURL(request.configurationKey);
                const completed = await readAndApplyDappResponse(
                    request.id, request.configurationKey, request.requestToken,
                    request.revisions, identity.legacyConfigurationKey, true
                );
                await completed?.acknowledgement;
            }).catch(() => {}));
        }
        await Promise.all(origins.values());
    })();
    manualSwitchRecoveryFlight = pending;
    const clear = () => {
        if (manualSwitchRecoveryFlight === pending) { manualSwitchRecoveryFlight = null; }
    };
    pending.then(clear, clear);
    return pending;
}

function forgetManualSwitch(context) {
    clearTimeout(context.timer);
    if (manualSwitches.get(context.configurationKey) === context) {
        manualSwitches.delete(context.configurationKey);
    }
}

function scheduleManualSwitchPoll(context) {
    clearTimeout(context.timer);
    if (manualSwitches.get(context.configurationKey) !== context) { return; }
    if (context.quiet && !context.fastPolling) { return; }
    if (Date.now() >= context.pollingDeadline) {
        forgetManualSwitch(context);
        return;
    }
    context.timer = setTimeout(() => {
        void pollManualSwitch(context).catch(() => {});
    }, MANUAL_SWITCH_POLL_DELAY);
}

function pollManualSwitch(context, quiet = context.quiet === true) {
    if (context.polling) {
        return quiet && !context.polling.quiet
            ? Promise.resolve()
            : context.polling.promise;
    }
    if (!context.requestToken ||
        manualSwitches.get(context.configurationKey) !== context) {
        return Promise.resolve();
    }
    clearTimeout(context.timer);
    if (Date.now() >= context.pollingDeadline) {
        forgetManualSwitch(context);
        return Promise.resolve();
    }
    const pending = (async () => {
        try {
            const completed = await readAndApplyDappResponse(
                context.id,
                context.configurationKey,
                context.requestToken,
                context.revisions,
                context.legacyConfigurationKey,
                quiet
            );
            if (completed?.pending && context.quiet) { context.fastPolling = false; }
            if (isMissingStoredResponse(completed?.response, context.id)) {
                if (manualSwitches.get(context.configurationKey) !== context) { return; }
                forgetManualSwitch(context);
                return true;
            }
            if (completed && await completed.acknowledgement) {
                forgetManualSwitch(context);
            }
        } catch {}
        finally {
            context.polling = null;
            scheduleManualSwitchPoll(context);
        }
    })();
    context.polling = {promise: pending, quiet};
    return pending;
}

function beginManualSwitch(identity) {
    const existing = manualSwitches.get(identity.configurationKey);
    if (existing) {
        if (Date.now() < existing.pollingDeadline) {
            existing.quiet = false;
            void pollManualSwitch(existing, false).then(missing => {
                if (missing && !manualSwitches.has(identity.configurationKey)) {
                    return beginManualSwitch(identity);
                }
            }).catch(() => {});
            return existing.admission;
        }
        forgetManualSwitch(existing);
    }
    const admissionDeadline = Date.now() +
        WIRE.WORKFLOW_POLICY.requestTTLMilliseconds;
    const context = {
        ...identity,
        admissionDeadline,
        pollingDeadline: admissionDeadline +
            WIRE.WORKFLOW_POLICY.responseExpiryMilliseconds,
        timer: null,
        polling: null,
    };
    manualSwitches.set(identity.configurationKey, context);
    context.admission = (async () => {
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
                admissionDeadline: context.admissionDeadline,
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
                Object.assign(context, {
                    id: response.id,
                    requestToken: response.requestToken,
                    revisions: {...response.revisions},
                });
                if (response.approvalRequired) {
                    notifyPendingRequestAvailable();
                    cuePopup();
                }
                scheduleManualSwitchPoll(context);
                return {
                    ...response,
                    configurationKey: identity.configurationKey,
                    subject: WIRE.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
                    workflowVersion: WORKFLOW_VERSION,
                };
            }
            const terminal = WIRE.decodeNativeResponse(response, id);
            if (!terminal || terminal.name !== "switchAccount") {
                forgetManualSwitch(context);
                return undefined;
            }
            const completed = await completeResponse({
                id,
                ...identity,
                revisions: snapshot.revisions,
            }, terminal);
            forgetManualSwitch(context);
            return completed?.response;
        } catch {
            forgetManualSwitch(context);
            return undefined;
        }
    })();
    return context.admission;
}

async function handleManualSwitchIntent(request, sender) {
    const identity = trustedIdentity(request, sender);
    if (privateBrowsing(sender) || !Number.isSafeInteger(sender?.tab?.id) ||
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
            : typeof sender.tab.favIconUrl === "string"
                ? sender.tab.favIconUrl
                : "",
    });
}

async function handleDappRequest(request, sender) {
    if (privateBrowsing(sender)) {
        return pageFailure(request?.message?.id, request?.message?.provider,
            request?.message?.name || "request", privateBrowsingUnsupportedMessage(), 4200);
    }
    const identity = trustedIdentity(request, sender);
    if (!identity) { return undefined; }
    const state = await queueConfigurationOperation(
        identity.configurationKey,
        current => ({value: {
            configurations: current.configurations.map(cleanConfiguration),
            revisions: {...current.revisions},
        }}),
        identity.legacyConfigurationKey
    );
    const message = validatedDappMessage(request, sender, state);
    if (!message) { return undefined; }
    const authorized = isAuthorized(message, state);
    const directResponseRevisions = {...message.revisions};
    const response = await WIRE.withTimeout(
        sendNativeMessage(authorized ? message : {...message, replayOnly: true}, false),
        TRANSPORT_TIMEOUT
    );
    if (WIRE.isNativeEnqueueAcknowledgement(response, message.id)) {
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

async function handleGetResponse(request, sender) {
    const identity = senderIdentity(sender);
    if (privateBrowsing(sender) || !WIRE.hasExactKeys(request, [
            "configurationKey", "id", "requestToken", "revisions", "subject",
            "workflowVersion",
        ]) || request.workflowVersion !== WORKFLOW_VERSION ||
        !WIRE.isConfigurationKey(request.configurationKey) ||
        identity?.configurationKey !== request.configurationKey ||
        !WIRE.isValidRequestId(request.id) ||
        !WIRE.isRequestToken(request.requestToken) ||
        !WIRE.isProviderRevisions(request.revisions)) {
        return undefined;
    }
    const completed = await readAndApplyDappResponse(
        request.id,
        request.configurationKey,
        request.requestToken,
        request.revisions,
        identity.legacyConfigurationKey
    );
    return completed?.pageResponse || completed?.response;
}

async function handleRPC(request, sender) {
    if (!WIRE.hasExactKeys(request, [
            "body", "chainId", "id", "subject", "workflowVersion",
        ]) || request.workflowVersion !== WORKFLOW_VERSION ||
        !WIRE.isValidRequestId(request.id) || typeof request.body !== "string" ||
        typeof request.chainId !== "string") {
        return pageFailure(request?.id, "ethereum", null);
    }
    if (privateBrowsing(sender)) { return pageFailure(request.id, "ethereum", null); }
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

async function approveWithCurrentRevisions(request, sender) {
    const identity = trustedPopupIdentity(request, sender);
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
        }, request.privateBrowsing),
        true
    );
}

async function applyCompletedResponse(request, sender) {
    const identity = trustedPopupIdentity(request, sender);
    if (!WIRE.hasExactKeys(request, [
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
    const completed = await readAndApplyDappResponse(
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

async function latestConfiguration(request, sender) {
    if (privateBrowsing(sender)) {
        return {kind: "configuration", state: {
            ethereum: {address: "", chainId: "0x1"}, solana: null, revisions: {ethereum: 0, solana: 0},
        }};
    }
    const identity = trustedIdentity(request, sender) ||
        trustedPopupIdentity(request, sender);
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

async function disconnect(request, sender) {
    if (!WIRE.isValidDisconnectRequest(request)) { return undefined; }
    const identity = trustedIdentity(request, sender);
    if (!identity || privateBrowsing(sender)) {
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

function updateBadge(request, sender) {
    if (sender?.tab || privateBrowsing(sender) ||
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
        }, privateBrowsing({tab})), TRANSPORT_TIMEOUT);
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
    if (!valid) {
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
    const polling = [...manualSwitches.values()]
        .filter(context => ids.includes(context.id))
        .map(context => pollManualSwitch(context, true));
    const recovery = recoverManualSwitches().catch(() => {});
    const tabs = await boundedTabsQuery();
    if (tabs) {
        for (const tab of tabs || []) {
            if (!Number.isSafeInteger(tab?.id)) { continue; }
            try { Promise.resolve(browser.tabs.sendMessage(tab.id, request)).catch(() => {}); } catch {}
        }
    }
    await Promise.all([...polling, recovery]);
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

async function handleMessage(request, sender) {
    if (!WIRE.isRecord(request)) { return undefined; }
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
        return handleRPC(request, sender);
    case "message-to-wallet":
        return handleDappRequest(request, sender);
    case WIRE.MANUAL_SWITCH_INTENT_SUBJECT:
        return handleManualSwitchIntent(request, sender);
    case "getResponse":
        return handleGetResponse(request, sender);
    case "getLatestConfiguration":
        return latestConfiguration(request, sender);
    case "approveRequestWithCurrentRevisions":
        return approveWithCurrentRevisions(request, sender);
    case "applyCompletedResponse":
        return applyCompletedResponse(request, sender);
    case "disconnect":
        return disconnect(request, sender);
    case "updatePendingRequestBadge":
        await updateBadge(request, sender);
        return undefined;
    case "responseReady":
        if (privateBrowsing(sender)) { return undefined; }
        await broadcastResponseReady(request);
        return undefined;
    case "pendingRequestAvailable":
        if (WIRE.isPendingRequestAvailable(request)) {
            cuePopup();
        }
        return undefined;
    default:
        return undefined;
    }
}

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    Promise.resolve(handleMessage(request, sender)).then(
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
    });
} catch {}

try {
    browser.runtime.onStartup?.addListener?.(() => {
        Promise.resolve(clearUpdateRecovery()).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        void recoverManualSwitches().catch(() => {});
    });
} catch {}

try {
    Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
    void recoverManualSwitches().catch(() => {});
} catch {}

try {
    browser.alarms.onAlarm.addListener(alarm => {
        if (alarm?.name !== MANUAL_SWITCH_RECOVERY_ALARM) { return undefined; }
        return recoverManualSwitches().catch(() => {});
    });
} catch {}

try {
    browser.action?.onClicked?.addListener?.(tab => {
        Promise.resolve(handleToolbarClick(tab)).catch(() => {});
    });
} catch {}
