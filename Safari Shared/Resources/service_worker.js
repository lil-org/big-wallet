// ∅ 2026 lil org

importScripts("bridge_wire.js");

const WIRE = BigWalletBridgeWire;
const WORKFLOW_VERSION = WIRE.WORKFLOW_VERSION;
const APPLICATION_ID = "org.lil.wallet";
const STORAGE_VERSION = 3;
const UPDATE_RECOVERY_STORAGE_KEY = "workflowUpdateRecoveryNeeded";
const TRANSPORT_TIMEOUT = 5000;
const TAB_QUERY_TIMEOUT = 1000;
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

function cleanConfiguration(configuration) {
    const clean = {...configuration};
    delete clean.__bwEthereumAuthorization;
    delete clean[WIRE.ETHEREUM_AUTHORIZATION_FAILURE_KEY];
    delete clean.accountRevision;
    delete clean.solanaAuthorizationEpoch;
    return clean;
}

function normalizedLegacyEthereumConfiguration(configuration) {
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

function normalizedLegacyConfigurationState(value) {
    if (Array.isArray(value)) {
        return value.map(normalizedLegacyEthereumConfiguration);
    }
    if (!WIRE.isRecord(value)) { return value; }
    if (Array.isArray(value.latestConfigurations)) {
        return {
            ...value,
            latestConfigurations: value.latestConfigurations.map(
                normalizedLegacyEthereumConfiguration
            ),
        };
    }
    return normalizedLegacyEthereumConfiguration(value);
}

function decodeConfigurationState(value) {
    const isV3 = WIRE.isRecord(value) &&
        value.workflowVersion === STORAGE_VERSION;
    const candidate = isV3
        ? value
        : normalizedLegacyConfigurationState(value);
    const parsed = WIRE.parseLatestConfigurations(candidate);
    if (!parsed.valid) { throw new Error("Invalid stored configuration"); }
    const configurations = parsed.latestConfigurations.map(cleanConfiguration);
    if (isV3) {
        if (!WIRE.isProviderRevisions(value.revisions)) {
            throw new Error("Invalid stored revisions");
        }
        return {
            configurations,
            revisions: {...value.revisions},
            migrated: false,
        };
    }
    const legacyRevision = Number.isSafeInteger(candidate?.bridgeState?.revision) &&
        candidate.bridgeState.revision >= 0 ? candidate.bridgeState.revision : 0;
    const legacySolanaRevision = Number.isSafeInteger(
        candidate?.bridgeState?.solanaAuthorizationEpoch
    ) && candidate.bridgeState.solanaAuthorizationEpoch >= 0
        ? candidate.bridgeState.solanaAuthorizationEpoch
        : legacyRevision;
    return {
        configurations,
        revisions: {ethereum: legacyRevision, solana: legacySolanaRevision},
        migrated: typeof value !== "undefined",
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
        const state = decodeConfigurationState(result[configurationKey]);
        state.legacyConfigurationKey = hasLegacyKey &&
            Object.prototype.hasOwnProperty.call(result, legacyConfigurationKey)
            ? legacyConfigurationKey
            : null;
        return state;
    }
    if (hasLegacyKey &&
        Object.prototype.hasOwnProperty.call(result || {}, legacyConfigurationKey)) {
        const state = decodeConfigurationState(result[legacyConfigurationKey]);
        state.migrated = true;
        state.legacyConfigurationKey = legacyConfigurationKey;
        return state;
    }
    const state = decodeConfigurationState(undefined);
    state.legacyConfigurationKey = null;
    return state;
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
        const result = await operation(state);
        if (state.migrated || state.legacyConfigurationKey ||
            result?.changed === true) {
            await browser.storage.local.set({
                [configurationKey]: encodedConfigurationState(state),
            });
            state.migrated = false;
        }
        if (state.legacyConfigurationKey) {
            await browser.storage.local.remove(state.legacyConfigurationKey);
            state.legacyConfigurationKey = null;
        }
        return {
            configurationState: result?.changed === true
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
    return state.configurations.map(configuration => {
        const value = cleanConfiguration(configuration);
        value.accountRevision = state.revisions[configuration.provider];
        if (configuration.provider === "solana") {
            value.solanaAuthorizationEpoch = state.revisions.solana;
        }
        return value;
    });
}

function configurationFor(state, provider) {
    return state.configurations.find(item => item.provider === provider) || null;
}

function replaceConfiguration(configurations, replacement) {
    const next = configurations.filter(item => item.provider !== replacement.provider);
    next.push(cleanConfiguration(replacement));
    return next;
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
    return message.provider === "unknown" && message.name === "switchAccount";
}

function validatedDappMessage(request, sender, state) {
    const identity = trustedIdentity(request, sender);
    const message = request.message;
    const manualSwitch = message?.provider === "unknown" &&
        message?.name === "switchAccount";
    const requestKeys = manualSwitch
        ? [
            "admissionDeadline", "configurationKey", "enqueueAttempt", "host",
            "manualSwitch", "message", "subject", "workflowVersion",
        ]
        : [
            "admissionDeadline", "configurationKey", "enqueueAttempt", "host",
            "message", "subject", "workflowVersion",
        ];
    if (!identity || !WIRE.hasExactKeys(request, requestKeys) ||
        (manualSwitch && request.manualSwitch !== true) ||
        request.subject !== "message-to-wallet" ||
        request.workflowVersion !== WORKFLOW_VERSION ||
        !Number.isSafeInteger(request.admissionDeadline) ||
        request.admissionDeadline <= 0 ||
        !WIRE.isPrivateToken(request.enqueueAttempt) || !WIRE.isRecord(message) ||
        !WIRE.hasExactKeys(message, ["body", "id", "name", "provider"]) ||
        !WIRE.isValidRequestId(message.id) || typeof message.name !== "string" ||
        !WIRE.isRecord(message.body) ||
        !["ethereum", "solana", "unknown"].includes(message.provider)) {
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
                ? sender.tab.favIconUrl
                : "",
        host: identity.host,
        configurationKey: identity.configurationKey,
        enqueueAttempt: request.enqueueAttempt,
        revisions: {...state.revisions},
        workflowVersion: WORKFLOW_VERSION,
    };
}

function affectedProviders(response, storedConfigurations) {
    const providers = new Set;
    if (storedConfigurations !== null) {
        storedConfigurations.forEach(item => providers.add(item.provider));
    }
    if (response?.provider === "ethereum" &&
        (response.name === "addEthereumChain" ||
            response.name === "switchEthereumChain") &&
        typeof response.chainId === "string" &&
        !Object.prototype.hasOwnProperty.call(response, "error")) {
        providers.add("ethereum");
    }
    if (response?.provider === "solana" && response.errorCode === 4100 &&
        typeof response.errorPublicKey === "string" &&
        response.errorPublicKey.length > 0) {
        providers.add("solana");
    }
    if (Array.isArray(response?.providersToDisconnect)) {
        response.providersToDisconnect.forEach(provider => {
            if (provider === "ethereum" || provider === "solana") {
                providers.add(provider);
            }
        });
    }
    return providers;
}

function sameConfiguration(left, right) {
    if (left?.provider !== right?.provider) { return false; }
    if (left.provider === "ethereum") {
        return left.chainId === right.chainId &&
            JSON.stringify(left.results || []) === JSON.stringify(right.results || []);
    }
    return left.provider === "solana" && left.publicKey === right.publicKey;
}

function sameProviderConfiguration(left, right) {
    if (!left || !right) { return left === right; }
    return sameConfiguration(left, right);
}

function replacingProviderConfiguration(configurations, provider, replacement) {
    const next = configurations.filter(item => item.provider !== provider);
    if (replacement) { next.push(cleanConfiguration(replacement)); }
    return next;
}

function configurationsAfterResponse(state, response, storedConfigurations) {
    const trustedEthereum = configurationFor(state, "ethereum");
    let configurations = state.configurations;
    if (storedConfigurations !== null) {
        for (const configuration of storedConfigurations) {
            configurations = replaceConfiguration(configurations, configuration);
        }
    }
    if (response.provider === "ethereum" &&
        (response.name === "addEthereumChain" ||
            response.name === "switchEthereumChain") &&
        typeof response.chainId === "string" &&
        !Object.prototype.hasOwnProperty.call(response, "error")) {
        configurations = replaceConfiguration(configurations, {
            provider: "ethereum",
            chainId: response.chainId,
            results: trustedEthereum?.results || [],
        });
    }
    if (response.provider === "solana" && response.errorCode === 4100 &&
        configurationFor({...state, configurations}, "solana")?.publicKey ===
            response.errorPublicKey) {
        configurations = configurations.filter(item => item.provider !== "solana");
    }
    if (Array.isArray(response.providersToDisconnect)) {
        configurations = configurations.filter(item => {
            return !response.providersToDisconnect.includes(item.provider);
        });
    }
    return configurations;
}

function applyResponseToState(
    state,
    response,
    expectedRevisions,
    storedConfigurations
) {
    if (!WIRE.isRecord(response) || response[WIRE.NATIVE_STALE_RESPONSE_KEY] === true) {
        return {changed: false, stale: false};
    }
    const affected = [...affectedProviders(response, storedConfigurations)];
    if (affected.length === 0) {
        return {changed: false, replay: false, stale: false};
    }
    const configurations = configurationsAfterResponse(
        state,
        response,
        storedConfigurations
    );
    const committed = response[WIRE.APPROVAL_COMMITTED_KEY] === true;
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

function responseForPage(response, configurationState, stale) {
    const clean = stale ? {
        id: response.id,
        name: response.name,
        provider: response.provider,
        error: "Authorization changed while the request was pending",
        errorCode: 4100,
    } : {...response};
    if (!stale && clean.provider === "ethereum" &&
        (clean.name === "addEthereumChain" ||
            clean.name === "switchEthereumChain") &&
        !Object.prototype.hasOwnProperty.call(clean, "error") &&
        Object.prototype.hasOwnProperty.call(clean, "results")) {
        const configuration = configurationState?.latestConfigurations.find(item => {
            return item.provider === "ethereum";
        });
        clean.results = [...(configuration?.results || [])];
    }
    delete clean.configurationToStore;
    delete clean.latestConfigurations;
    delete clean.revisions;
    delete clean[WIRE.NATIVE_STALE_RESPONSE_KEY];
    if (configurationState) {
        clean.latestConfigurations = configurationState.latestConfigurations;
        clean.revisions = configurationState.revisions;
        if (!stale && clean.provider === "multiple") {
            delete clean.bodies;
            delete clean.providersToDisconnect;
        }
    }
    return clean;
}

async function applyDappResponse(configurationKey, response, revisions) {
    if (!WIRE.isProviderRevisions(revisions)) { return undefined; }
    const successfulChainMutation = response?.provider === "ethereum" &&
        (response.name === "addEthereumChain" ||
            response.name === "switchEthereumChain") &&
        !Object.prototype.hasOwnProperty.call(response, "error");
    if (successfulChainMutation &&
        !WIRE.isCanonicalEthereumChainId(response.chainId)) {
        return {
            id: response.id,
            name: response.name,
            provider: response.provider,
            error: "Failed to process provider response",
            errorCode: -32603,
        };
    }
    const hasStoredConfiguration = WIRE.isRecord(response) &&
        Object.prototype.hasOwnProperty.call(response, "configurationToStore");
    const parsed = WIRE.parseLatestConfigurations(response?.configurationToStore);
    if (hasStoredConfiguration &&
        (typeof response.configurationToStore === "undefined" || !parsed.valid)) {
        return {
            id: response.id,
            name: response.name,
            provider: response.provider,
            error: "Failed to process provider response",
            errorCode: -32603,
        };
    }
    const storedConfigurations = hasStoredConfiguration
        ? parsed.latestConfigurations
        : null;
    return queueConfigurationOperation(configurationKey, state => {
        const applied = applyResponseToState(
            state,
            response,
            revisions,
            storedConfigurations
        );
        return {
            changed: applied.changed,
            value: responseForPage(
                response,
                applied.changed || applied.replay || applied.stale ||
                    applied.committedDrift
                    ? publicConfigurationState(state)
                    : null,
                applied.stale
            ),
        };
    });
}

async function readAndApplyDappResponse(
    id,
    configurationKey,
    requestToken,
    revisions
) {
    const response = await WIRE.withTimeout(sendNativeMessage({
        subject: "getResponse",
        id,
        configurationKey,
        requestToken,
        workflowVersion: WORKFLOW_VERSION,
    }, false), TRANSPORT_TIMEOUT);
    if (WIRE.hasExactKeys(response, ["id", "missing"]) &&
        response.id === id && response.missing === true) {
        return response;
    }
    return WIRE.isCorrelatedDappResponse(response, id)
        ? applyDappResponse(configurationKey, response, revisions)
        : undefined;
}

async function handleDappRequest(request, sender) {
    if (privateBrowsing(sender)) {
        return {
            id: request?.message?.id,
            name: request?.message?.name || "request",
            provider: request?.message?.provider || "unknown",
            error: privateBrowsingUnsupportedMessage(),
            errorCode: 4200,
        };
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
    if (!isAuthorized(message, state)) {
        return {
            id: message.id,
            name: message.name,
            provider: message.provider,
            error: "Authorization changed while the request was pending",
            errorCode: 4100,
            latestConfigurations: publicConfigurations(state),
            revisions: {...state.revisions},
        };
    }
    const directResponseRevisions = {...message.revisions};
    const response = await WIRE.withTimeout(
        sendNativeMessage(message, false),
        TRANSPORT_TIMEOUT
    );
    if (WIRE.isNativeEnqueueAcknowledgement(response, message.id)) {
        if (response.approvalRequired) {
            notifyPendingRequestAvailable();
            cuePopup();
        }
        return response;
    }
    if (WIRE.isCorrelatedDappResponse(response, message.id)) {
        return applyDappResponse(
            message.configurationKey,
            response,
            directResponseRevisions
        );
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
    return readAndApplyDappResponse(
        request.id,
        request.configurationKey,
        request.requestToken,
        request.revisions
    );
}

async function handleRPC(request, sender) {
    if (!WIRE.hasExactKeys(request, [
            "body", "chainId", "id", "subject", "workflowVersion",
        ]) || request.workflowVersion !== WORKFLOW_VERSION ||
        !WIRE.isValidRequestId(request.id) || typeof request.body !== "string" ||
        typeof request.chainId !== "string") {
        return WIRE.rpcFailureResponse(request?.id);
    }
    if (privateBrowsing(sender)) { return WIRE.rpcFailureResponse(request.id); }
    try {
        const response = await sendNativeMessage(request, false);
        return WIRE.isCorrelatedRPCResponse(response, request.id)
            ? response
            : WIRE.rpcFailureResponse(request.id);
    } catch {
        return WIRE.rpcFailureResponse(request.id);
    }
}

async function providerRevisions(request, sender) {
    const identity = trustedPopupIdentity(request, sender);
    if (!WIRE.hasExactKeys(request, [
            "configurationKey", "host", "subject", "workflowVersion",
        ]) || request.subject !== "getProviderRevisions" ||
        request.workflowVersion !== WORKFLOW_VERSION ||
        !identity) {
        return undefined;
    }
    try {
        const revisions = await queueConfigurationOperation(
            request.configurationKey,
            state => ({value: {...state.revisions}}),
            identity.legacyConfigurationKey
        );
        return {revisions};
    } catch {
        return {configurationReadFailed: true};
    }
}

async function applyCompletedResponse(request, sender) {
    if (!WIRE.hasExactKeys(request, [
            "configurationKey", "host", "id", "requestToken", "revisions",
            "subject", "workflowVersion",
        ]) || request.subject !== "applyCompletedResponse" ||
        request.workflowVersion !== WORKFLOW_VERSION ||
        !trustedPopupIdentity(request, sender) ||
        !WIRE.isValidRequestId(request.id) ||
        !WIRE.isRequestToken(request.requestToken) ||
        !WIRE.isProviderRevisions(request.revisions)) {
        return undefined;
    }
    const response = await readAndApplyDappResponse(
        request.id,
        request.configurationKey,
        request.requestToken,
        request.revisions
    );
    if (WIRE.hasExactKeys(response, ["id", "missing"]) &&
        response.id === request.id && response.missing === true) {
        return response;
    }
    return WIRE.isCorrelatedDappResponse(response, request.id)
        ? {applied: true}
        : undefined;
}

async function latestConfiguration(request, sender) {
    if (privateBrowsing(sender)) {
        return {
            latestConfigurations: [],
            revisions: {ethereum: 0, solana: 0},
        };
    }
    const identity = trustedIdentity(request, sender) ||
        trustedPopupIdentity(request, sender);
    if (!identity) {
        return {configurationReadFailed: true};
    }
    try {
        return await queueConfigurationOperation(
            identity.configurationKey,
            state => ({value: publicConfigurationState(state)}),
            identity.legacyConfigurationKey
        );
    } catch {
        return {configurationReadFailed: true};
    }
}

async function disconnect(request, sender) {
    if (!WIRE.isValidDisconnectRequest(request)) { return undefined; }
    const identity = trustedIdentity(request, sender);
    if (!identity || privateBrowsing(sender)) {
        return {
            id: request.id,
            name: "revokePermissions",
            provider: request.provider,
            error: "Failed to revoke permissions",
            errorCode: -32603,
        };
    }
    await queueConfigurationOperation(identity.configurationKey, state => {
        state.configurations = state.configurations.filter(item => {
            return item.provider !== request.provider;
        });
        state.revisions[request.provider] += 1;
        return {changed: true};
    }, identity.legacyConfigurationKey);
    return {
        id: request.id,
        name: "revokePermissions",
        provider: request.provider,
        result: null,
    };
}

function cuePopup() {
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
    try {
        return browser.action?.setBadgeText?.({
            text: request.hasPendingRequests ? "•" : "",
        });
    } catch {
        return undefined;
    }
}

async function broadcastResponseReady(request) {
    const ids = WIRE.responseReadyIds(request);
    if (!ids) { return; }
    const tabs = await boundedTabsQuery();
    if (!tabs) { return; }
    for (const tab of tabs || []) {
        if (!Number.isSafeInteger(tab?.id)) { continue; }
        try { Promise.resolve(browser.tabs.sendMessage(tab.id, request)).catch(() => {}); } catch {}
    }
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
        latestConfigurations: configurationState.latestConfigurations,
        revisions: configurationState.revisions,
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
    switch (request.subject) {
    case "rpc":
        return handleRPC(request, sender);
    case "message-to-wallet":
        return handleDappRequest(request, sender);
    case "getResponse":
        return handleGetResponse(request, sender);
    case "getLatestConfiguration":
        return latestConfiguration(request, sender);
    case "getProviderRevisions":
        return providerRevisions(request, sender);
    case "applyCompletedResponse":
        return applyCompletedResponse(request, sender);
    case "disconnect":
        return disconnect(request, sender);
    case "updatePendingRequestBadge":
        await updateBadge(request, sender);
        return undefined;
    case "responseReady":
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
    });
} catch {}

try {
    browser.runtime.onStartup?.addListener?.(() => {
        Promise.resolve(clearUpdateRecovery()).catch(() => {});
    });
} catch {}
