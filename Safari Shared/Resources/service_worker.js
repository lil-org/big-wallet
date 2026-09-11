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
const MANUAL_SWITCH_POLL_ALARM_NAME = "manualSwitchCompletionPoll";
const MANUAL_SWITCH_POLL_ALARM_MINUTES = 1;
const MANUAL_SWITCH_FAST_POLL_INITIAL_DELAY = 1000;
const MANUAL_SWITCH_FAST_POLL_DELAY = 3000;
const MANUAL_SWITCH_FAST_POLL_DURATION = 60 * 1000;
const MANUAL_SWITCH_ADMISSION_FUTURE_SKEW = 60 * 1000;
const MANUAL_SWITCH_ADMISSION_ATTEMPTS = 2;
const MANUAL_SWITCH_REPAIR_SCAN_LIMIT =
    WIRE.WORKFLOW_POLICY.maximumRetainedRequests * 64;
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
const manualSwitchResumeFlights = new Map;
let manualSwitchRegistryTail = Promise.resolve();
let manualSwitchPollingTail = Promise.resolve();
let manualSwitchPollAlarmState = null;
let manualSwitchFastPollTimer = null;
let manualSwitchFastPollDeadline = 0;
let manualSwitchFastPollDelay = MANUAL_SWITCH_FAST_POLL_INITIAL_DELAY;
const MANUAL_SWITCH_MISSING = Symbol("manualSwitchMissing");

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
        const originalRevisions = {...state.revisions};
        const result = await operation(state);
        const revisionsChanged = state.revisions.ethereum !==
                originalRevisions.ethereum ||
            state.revisions.solana !== originalRevisions.solana;
        if (result?.changed === true && revisionsChanged &&
            await readLiveApprovalLease(configurationKey)) {
            throw new Error("Provider revisions are leased for approval");
        }
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

function emptyManualSwitchRegistry() {
    return {owners: [], workflowVersion: WORKFLOW_VERSION};
}

function normalizeManualSwitchRegistry(candidate) {
    if (!WIRE.hasExactKeys(candidate, ["owners", "workflowVersion"]) ||
        candidate.workflowVersion !== WORKFLOW_VERSION ||
        !Array.isArray(candidate.owners)) {
        return emptyManualSwitchRegistry();
    }
    const owners = [];
    const configurationKeys = new Set;
    const ids = new Set;
    let scanned = 0;
    for (const owner of candidate.owners) {
        if (owners.length >= WIRE.WORKFLOW_POLICY.maximumRequests ||
            scanned >= MANUAL_SWITCH_REPAIR_SCAN_LIMIT) {
            break;
        }
        scanned += 1;
        if (!WIRE.isManualSwitchOwnerRecord(owner) ||
            configurationKeys.has(owner.configurationKey) || ids.has(owner.id)) {
            continue;
        }
        const copy = {...owner};
        const next = {
            owners: [...owners, copy],
            workflowVersion: WORKFLOW_VERSION,
        };
        if (!WIRE.isManualSwitchOwnerRegistry(next)) { continue; }
        configurationKeys.add(owner.configurationKey);
        ids.add(owner.id);
        owners.push(copy);
    }
    return {owners, workflowVersion: WORKFLOW_VERSION};
}

function canonicalManualSwitchConfigurations(configurations) {
    return configurations.map(configuration => configuration.provider === "ethereum"
        ? {
            provider: "ethereum",
            chainId: configuration.chainId,
            results: [...configuration.results],
        }
        : {
            provider: "solana",
            publicKey: configuration.publicKey,
        });
}

function queueManualSwitchRegistryOperation(operation) {
    const pending = manualSwitchRegistryTail.catch(() => {}).then(async () => {
        const stored = await browser.storage.local.get(
            WIRE.MANUAL_SWITCH_OWNER_STORAGE_KEY
        );
        const hasStored = Object.prototype.hasOwnProperty.call(
            stored || {},
            WIRE.MANUAL_SWITCH_OWNER_STORAGE_KEY
        );
        const candidate = stored?.[WIRE.MANUAL_SWITCH_OWNER_STORAGE_KEY];
        const registry = hasStored
            ? normalizeManualSwitchRegistry(candidate)
            : emptyManualSwitchRegistry();
        const repaired = hasStored &&
            !WIRE.isManualSwitchOwnerRegistry(candidate);
        const result = await operation(registry);
        const next = result?.registry || registry;
        if (!WIRE.isManualSwitchOwnerRegistry(next)) {
            throw new Error("Invalid manual-switch owner registry");
        }
        if (repaired || result?.changed === true) {
            if (next.owners.length === 0) {
                await browser.storage.local.remove(
                    WIRE.MANUAL_SWITCH_OWNER_STORAGE_KEY
                );
            } else {
                await browser.storage.local.set({
                    [WIRE.MANUAL_SWITCH_OWNER_STORAGE_KEY]: next,
                });
            }
        }
        return result?.value;
    });
    manualSwitchRegistryTail = pending;
    const clear = () => {
        if (manualSwitchRegistryTail === pending) {
            manualSwitchRegistryTail = Promise.resolve();
        }
    };
    pending.then(clear, clear);
    return pending;
}

async function reserveManualSwitchOwner(identity) {
    const owners = await readAllManualSwitchOwners();
    const existing = owners.find(owner =>
        owner.configurationKey === identity.configurationKey
    );
    if (existing) { return existing; }
    if (owners.length >= WIRE.WORKFLOW_POLICY.maximumRequests) { return null; }
    const snapshot = await queueConfigurationOperation(
        identity.configurationKey,
        state => ({value: {
            configurations: canonicalManualSwitchConfigurations(
                state.configurations
            ),
            revisions: {...state.revisions},
        }}),
        identity.legacyConfigurationKey
    );
    return queueManualSwitchRegistryOperation(registry => {
        const pruned = pruneExpiredManualSwitchOwners(registry);
        const reserved = registry.owners.find(owner =>
            owner.configurationKey === identity.configurationKey
        );
        if (reserved) { return {changed: pruned, value: reserved}; }
        if (registry.owners.length >= WIRE.WORKFLOW_POLICY.maximumRequests) {
            return {changed: pruned, value: null};
        }
        let id;
        for (let attempt = 0; attempt < 16; attempt += 1) {
            const candidate = WIRE.genId();
            if (!registry.owners.some(owner => owner.id === candidate)) {
                id = candidate;
                break;
            }
        }
        if (!WIRE.isValidRequestId(id)) {
            return {changed: pruned, value: null};
        }
        const owner = {
            admissionDeadline: Date.now() +
                WIRE.WORKFLOW_POLICY.requestTTLMilliseconds,
            configurationKey: identity.configurationKey,
            enqueueAttempt: WIRE.genPrivateToken(),
            favicon: identity.favicon,
            host: identity.host,
            id,
            latestConfigurations: snapshot.configurations,
            phase: "admitting",
            revisions: snapshot.revisions,
            workflowVersion: WORKFLOW_VERSION,
        };
        if (!WIRE.isManualSwitchOwnerRecord(owner)) {
            owner.favicon = "";
        }
        if (!WIRE.isManualSwitchOwnerRecord(owner)) {
            return {changed: pruned, value: null};
        }
        registry.owners.push(owner);
        return {changed: true, value: owner};
    });
}

function readManualSwitchOwner(configurationKey) {
    return queueManualSwitchRegistryOperation(registry => {
        const changed = pruneExpiredManualSwitchOwners(registry);
        return {
            changed,
            value: registry.owners.find(owner =>
                owner.configurationKey === configurationKey
            ) || null,
        };
    });
}

async function matchingManualSwitchOwner(owner) {
    const current = await readManualSwitchOwner(owner.configurationKey);
    return current?.id === owner.id &&
        current.enqueueAttempt === owner.enqueueAttempt ? current : null;
}

function updateManualSwitchOwner(owner, replacement) {
    return queueManualSwitchRegistryOperation(registry => {
        let index = registry.owners.findIndex(candidate =>
            candidate.configurationKey === owner.configurationKey &&
            candidate.id === owner.id &&
            candidate.enqueueAttempt === owner.enqueueAttempt
        );
        if (replacement === null && index >= 0) {
            registry.owners.splice(index, 1);
            pruneExpiredManualSwitchOwners(registry);
            return {changed: true, value: true};
        }
        const pruned = pruneExpiredManualSwitchOwners(registry);
        index = registry.owners.findIndex(candidate =>
            candidate.configurationKey === owner.configurationKey &&
            candidate.id === owner.id &&
            candidate.enqueueAttempt === owner.enqueueAttempt
        );
        if (index < 0) { return {changed: pruned, value: null}; }
        if (!WIRE.isManualSwitchOwnerRecord(replacement)) {
            return {changed: pruned, value: null};
        }
        registry.owners[index] = replacement;
        return {changed: true, value: replacement};
    });
}

function readManualSwitchOwnersForIds(ids) {
    const ready = new Set(ids);
    return queueManualSwitchRegistryOperation(registry => {
        const changed = pruneExpiredManualSwitchOwners(registry);
        return {
            changed,
            value: registry.owners.filter(owner => ready.has(owner.id)),
        };
    });
}

function readAllManualSwitchOwners() {
    return queueManualSwitchRegistryOperation(registry => {
        const changed = pruneExpiredManualSwitchOwners(registry);
        return {changed, value: registry.owners.slice()};
    });
}

function manualSwitchInFlightStatus(owner) {
    return {
        admissionDeadline: owner.admissionDeadline,
        configurationKey: owner.configurationKey,
        id: owner.id,
        subject: WIRE.MANUAL_SWITCH_IN_FLIGHT_SUBJECT,
        workflowVersion: WORKFLOW_VERSION,
    };
}

function manualSwitchAcknowledgement(owner) {
    return {
        approvalRequired: owner.approvalRequired,
        configurationKey: owner.configurationKey,
        id: owner.id,
        requestToken: owner.requestToken,
        revisions: {...owner.revisions},
        subject: WIRE.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
        workflowVersion: WORKFLOW_VERSION,
    };
}

function manualSwitchPollingDeadline(owner) {
    const deadline = owner.admissionDeadline +
        WIRE.WORKFLOW_POLICY.responseExpiryMilliseconds;
    return Number.isSafeInteger(deadline) ? deadline : 0;
}

function manualSwitchFastPollingDeadline(owner) {
    const deadline = owner.admissionDeadline -
        WIRE.WORKFLOW_POLICY.requestTTLMilliseconds +
        MANUAL_SWITCH_FAST_POLL_DURATION;
    return Number.isSafeInteger(deadline) ? deadline : 0;
}

function fastManualSwitchOwners(owners, now = Date.now()) {
    return owners.filter(owner => manualSwitchFastPollingDeadline(owner) > now);
}

function liveManualSwitchOwners(owners, now = Date.now()) {
    const maximumAdmissionDeadline = now +
        WIRE.WORKFLOW_POLICY.requestTTLMilliseconds +
        MANUAL_SWITCH_ADMISSION_FUTURE_SKEW;
    if (!Number.isSafeInteger(maximumAdmissionDeadline)) { return []; }
    return owners.filter(owner =>
        owner.admissionDeadline <= maximumAdmissionDeadline &&
        manualSwitchPollingDeadline(owner) >= now
    );
}

function manualSwitchResumeKey(owner) {
    return JSON.stringify([
        owner.configurationKey,
        owner.id,
        owner.enqueueAttempt,
    ]);
}

function manualSwitchOwnerCommitProtected(owner) {
    return manualSwitchResumeFlights.get(
        manualSwitchResumeKey(owner)
    )?.commitProtected === true;
}

function pruneExpiredManualSwitchOwners(registry, now = Date.now()) {
    const live = new Set(
        liveManualSwitchOwners(registry.owners, now).map(manualSwitchResumeKey)
    );
    const owners = registry.owners.filter(owner =>
        live.has(manualSwitchResumeKey(owner)) ||
        manualSwitchOwnerCommitProtected(owner)
    );
    if (owners.length === registry.owners.length) { return false; }
    registry.owners = owners;
    return true;
}

async function setManualSwitchPollAlarm(enabled) {
    if (manualSwitchPollAlarmState === enabled) { return; }
    try {
        if (enabled) {
            await browser.alarms?.create?.(MANUAL_SWITCH_POLL_ALARM_NAME, {
                delayInMinutes: MANUAL_SWITCH_POLL_ALARM_MINUTES,
                periodInMinutes: MANUAL_SWITCH_POLL_ALARM_MINUTES,
            });
        } else {
            await browser.alarms?.clear?.(MANUAL_SWITCH_POLL_ALARM_NAME);
        }
        manualSwitchPollAlarmState = enabled;
    } catch {
        manualSwitchPollAlarmState = null;
    }
}

function stopManualSwitchFastPolling() {
    if (manualSwitchFastPollTimer !== null) {
        clearTimeout(manualSwitchFastPollTimer);
        manualSwitchFastPollTimer = null;
    }
    manualSwitchFastPollDeadline = 0;
    manualSwitchFastPollDelay = MANUAL_SWITCH_FAST_POLL_INITIAL_DELAY;
}

function scheduleManualSwitchFastPoll() {
    if (manualSwitchFastPollTimer !== null) { return; }
    const remaining = manualSwitchFastPollDeadline - Date.now();
    if (remaining <= 0) {
        manualSwitchFastPollDeadline = 0;
        manualSwitchFastPollDelay = MANUAL_SWITCH_FAST_POLL_INITIAL_DELAY;
        return;
    }
    manualSwitchFastPollTimer = setTimeout(() => {
        manualSwitchFastPollTimer = null;
        return Promise.resolve(runManualSwitchFastPoll()).catch(() => {});
    }, Math.min(manualSwitchFastPollDelay, remaining));
}

function startManualSwitchFastPolling(owners) {
    const fastOwners = fastManualSwitchOwners(owners);
    if (fastOwners.length === 0) { return; }
    const ownerDeadline = Math.max(
        ...fastOwners.map(manualSwitchFastPollingDeadline)
    );
    manualSwitchFastPollDeadline = Math.max(
        manualSwitchFastPollDeadline,
        ownerDeadline
    );
    scheduleManualSwitchFastPoll();
}

function refreshManualSwitchPolling(startFast = false) {
    const pending = manualSwitchPollingTail.catch(() => {}).then(async () => {
        let owners;
        try {
            owners = await readAllManualSwitchOwners();
        } catch {
            await setManualSwitchPollAlarm(true);
            return null;
        }
        if (owners.length === 0) {
            stopManualSwitchFastPolling();
            await setManualSwitchPollAlarm(false);
            return owners;
        }
        await setManualSwitchPollAlarm(true);
        if (startFast) { startManualSwitchFastPolling(owners); }
        return owners;
    });
    manualSwitchPollingTail = pending;
    return pending;
}

async function runManualSwitchFastPoll() {
    const owners = await refreshManualSwitchPolling();
    if (!owners?.length) { return; }
    const fastOwners = fastManualSwitchOwners(owners);
    if (fastOwners.length === 0) {
        stopManualSwitchFastPolling();
        return;
    }
    await resumeManualSwitchOwnerList(fastOwners);
    const remainingOwners = await refreshManualSwitchPolling();
    if (!remainingOwners?.length) { return; }
    const remainingFastOwners = fastManualSwitchOwners(remainingOwners);
    if (remainingFastOwners.length === 0) {
        stopManualSwitchFastPolling();
        return;
    }
    manualSwitchFastPollDelay = MANUAL_SWITCH_FAST_POLL_DELAY;
    startManualSwitchFastPolling(remainingFastOwners);
    scheduleManualSwitchFastPoll();
}

async function reconcileAllManualSwitchOwners(startFast = false) {
    const owners = await refreshManualSwitchPolling(startFast);
    if (!owners?.length) { return; }
    await resumeManualSwitchOwnerList(owners);
    await refreshManualSwitchPolling();
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

function canAdvanceProviderRevision(state, provider) {
    return state.revisions[provider] < Number.MAX_SAFE_INTEGER;
}

function replacingProviderConfiguration(configurations, provider, replacement) {
    const next = configurations.filter(item => item.provider !== provider);
    if (replacement) { next.push(cleanConfiguration(replacement)); }
    return next;
}

function configurationAccount(configuration) {
    return configuration?.provider === "ethereum"
        ? normalizedEthereumAddress(configuration.results?.[0])
        : configuration?.publicKey || null;
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
    if (plans.some(plan => plan.mode === "apply" &&
        !canAdvanceProviderRevision(state, plan.provider))) {
        return {changed: false, replay: false, stale: true};
    }
    for (const plan of plans) {
        if (plan.mode === "apply") {
            let desired = plan.desired;
            if (desired) {
                desired = {...desired};
                delete desired.reauthorizationRevision;
                const current = configurationFor(state, plan.provider);
                const account = configurationAccount(desired);
                if (account && response.name === "switchAccount" &&
                    response.provider === "multiple" &&
                    !Object.prototype.hasOwnProperty.call(response, "error")) {
                    desired.reauthorizationRevision = state.revisions[plan.provider] + 1;
                } else if (account && account === configurationAccount(current) &&
                    Number.isSafeInteger(current?.reauthorizationRevision) &&
                    current.reauthorizationRevision > 0) {
                    desired.reauthorizationRevision = current.reauthorizationRevision;
                }
            }
            state.configurations = replacingProviderConfiguration(
                state.configurations,
                plan.provider,
                desired
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

function applyDappResponseToState(state, response, revisions) {
    if (!WIRE.isProviderRevisions(revisions)) { return {value: undefined}; }
    const contradictoryError = WIRE.isRecord(response) &&
        Object.prototype.hasOwnProperty.call(response, "error") && [
            "bodies", "configurationToStore", "providersToDisconnect",
        ].some(key => Object.prototype.hasOwnProperty.call(response, key));
    if (contradictoryError) {
        return {value: {
            id: response.id,
            name: response.name,
            provider: response.provider,
            error: "Failed to process provider response",
            errorCode: -32603,
        }};
    }
    const successfulChainMutation = response?.provider === "ethereum" &&
        (response.name === "addEthereumChain" ||
            response.name === "switchEthereumChain") &&
        !Object.prototype.hasOwnProperty.call(response, "error");
    if (successfulChainMutation &&
        !WIRE.isCanonicalEthereumChainId(response.chainId)) {
        return {value: {
            id: response.id,
            name: response.name,
            provider: response.provider,
            error: "Failed to process provider response",
            errorCode: -32603,
        }};
    }
    const hasStoredConfiguration = WIRE.isRecord(response) &&
        Object.prototype.hasOwnProperty.call(response, "configurationToStore");
    const parsed = WIRE.parseLatestConfigurations(response?.configurationToStore);
    if (hasStoredConfiguration &&
        (typeof response.configurationToStore === "undefined" || !parsed.valid)) {
        return {value: {
            id: response.id,
            name: response.name,
            provider: response.provider,
            error: "Failed to process provider response",
            errorCode: -32603,
        }};
    }
    const storedConfigurations = hasStoredConfiguration
        ? parsed.latestConfigurations
        : null;
    const applied = applyResponseToState(
        state,
        response,
        revisions,
        storedConfigurations
    );
    const manualSwitch = response?.name === "switchAccount" &&
        response.provider === "multiple" &&
        !Object.prototype.hasOwnProperty.call(response, "error");
    return {
        changed: applied.changed,
        value: responseForPage(
            response,
            manualSwitch || applied.changed || applied.replay || applied.stale ||
                applied.committedDrift
                ? publicConfigurationState(state)
                : null,
            applied.stale
        ),
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

async function readAndApplyDappResponse(
    id,
    configurationKey,
    requestToken,
    revisions,
    legacyConfigurationKey = null
) {
    const key = JSON.stringify([configurationKey, id, requestToken]);
    const existing = responseReadFlights.get(key);
    if (existing) {
        return existing.revisions.ethereum === revisions.ethereum &&
            existing.revisions.solana === revisions.solana
            ? existing.promise
            : undefined;
    }
    const promise = (async () => {
        const response = await withProviderRevisionLease(
            configurationKey,
            legacyConfigurationKey,
            lease => sendNativeMessage({
                subject: "getResponse",
                id,
                configurationKey,
                requestToken,
                executionDeadline: lease.expiresAt,
                revisions: {...lease.revisions},
                workflowVersion: WORKFLOW_VERSION,
            }, false)
        );
        if (WIRE.hasExactKeys(response, ["id", "missing"]) &&
            response.id === id && response.missing === true) {
            return {response};
        }
        if (!WIRE.isCorrelatedDappResponse(response, id)) { return undefined; }
        const applied = await applyDappResponse(
            configurationKey,
            response,
            revisions,
            legacyConfigurationKey
        );
        if (!WIRE.isCorrelatedDappResponse(applied, id)) { return undefined; }
        return {
            response: applied,
            acknowledgement: acknowledgeCompletedResponse(
                id,
                configurationKey,
                requestToken
            ),
        };
    })();
    const entry = {promise, revisions: {...revisions}};
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

function isMissingManualSwitchResponse(response, id) {
    return WIRE.hasExactKeys(response, ["id", "missing"]) &&
        response.id === id && response.missing === true;
}

function nativeManualSwitchRequest(owner) {
    return {
        admissionDeadline: owner.admissionDeadline,
        body: {
            latestConfigurations: owner.latestConfigurations.map(configuration =>
                configuration.provider === "ethereum"
                    ? {...configuration, results: [...configuration.results]}
                    : {...configuration}
            ),
        },
        configurationKey: owner.configurationKey,
        enqueueAttempt: owner.enqueueAttempt,
        favicon: owner.favicon,
        host: owner.host,
        id: owner.id,
        name: "switchAccount",
        provider: "unknown",
        revisions: {...owner.revisions},
        workflowVersion: WORKFLOW_VERSION,
    };
}

async function broadcastManualSwitchResult(configurationKey, response) {
    const tabs = await boundedTabsQuery();
    if (!tabs) { return; }
    const message = {
        configurationKey,
        response,
        subject: WIRE.MANUAL_SWITCH_RESULT_SUBJECT,
        workflowVersion: WORKFLOW_VERSION,
    };
    const deliveries = [];
    for (const tab of tabs) {
        if (tab?.incognito === true || !Number.isSafeInteger(tab?.id) ||
            WIRE.configurationIdentityForURL(tab.url)?.configurationKey !==
                configurationKey) {
            continue;
        }
        deliveries.push((async () => {
            try {
                await WIRE.withTimeout(
                    browser.tabs.sendMessage(tab.id, message),
                    TAB_QUERY_TIMEOUT
                );
            } catch {}
        })());
    }
    await Promise.all(deliveries);
}

async function applyOwnedManualSwitchTerminal(owner, response) {
    if (!WIRE.isManualSwitchTerminalResponse(response, owner.id)) { return null; }
    const identity = WIRE.configurationIdentityForURL(owner.configurationKey);
    const applied = await queueConfigurationOperation(
        owner.configurationKey,
        async state => {
            const current = await matchingManualSwitchOwner(owner);
            const flight = manualSwitchResumeFlights.get(
                manualSwitchResumeKey(owner)
            );
            if (!current || !flight) {
                return {value: MANUAL_SWITCH_MISSING};
            }
            flight.commitProtected = true;
            return applyDappResponseToState(state, response, current.revisions);
        },
        identity?.legacyConfigurationKey
    );
    if (applied === MANUAL_SWITCH_MISSING) { return MANUAL_SWITCH_MISSING; }
    if (!WIRE.isManualSwitchTerminalResponse(applied, owner.id)) { return null; }
    if (owner.requestToken && !await acknowledgeCompletedResponse(
        owner.id,
        owner.configurationKey,
        owner.requestToken
    )) { return null; }
    const removed = await updateManualSwitchOwner(owner, null);
    if (removed !== true) { return MANUAL_SWITCH_MISSING; }
    await broadcastManualSwitchResult(owner.configurationKey, applied);
    return applied;
}

async function readOwnedManualSwitchResponse(owner) {
    const identity = WIRE.configurationIdentityForURL(owner.configurationKey);
    return withProviderRevisionLease(
        owner.configurationKey,
        identity?.legacyConfigurationKey,
        async lease => {
            const response = await sendNativeMessage({
                subject: "getResponse",
                id: owner.id,
                configurationKey: owner.configurationKey,
                requestToken: owner.requestToken,
                executionDeadline: lease.expiresAt,
                revisions: {...lease.revisions},
                workflowVersion: WORKFLOW_VERSION,
            }, false);
            if (isMissingManualSwitchResponse(response, owner.id)) {
                return response;
            }
            return WIRE.isManualSwitchTerminalResponse(
                response,
                owner.id
            ) ? response : undefined;
        }
    );
}

async function performManualSwitchResume(initialOwner) {
    let owner = await matchingManualSwitchOwner(initialOwner);
    if (!owner) { return MANUAL_SWITCH_MISSING; }
    if (owner.phase === "admitting") {
        let response;
        try {
            response = await WIRE.withTimeout(
                sendNativeMessage(nativeManualSwitchRequest(owner), false),
                TRANSPORT_TIMEOUT
            );
        } catch {
            owner = await matchingManualSwitchOwner(owner);
            return owner ? manualSwitchInFlightStatus(owner) : MANUAL_SWITCH_MISSING;
        }
        owner = await matchingManualSwitchOwner(owner);
        if (!owner) { return MANUAL_SWITCH_MISSING; }
        if (WIRE.isNativeEnqueueAcknowledgement(response, owner.id)) {
            const admitted = {
                ...owner,
                approvalRequired: response.approvalRequired,
                phase: "admitted",
                requestToken: response.requestToken,
                revisions: {...response.revisions},
            };
            const stored = await updateManualSwitchOwner(owner, admitted);
            if (!stored) { return MANUAL_SWITCH_MISSING; }
            if (stored.approvalRequired) {
                notifyPendingRequestAvailable();
                cuePopup();
            }
            return manualSwitchAcknowledgement(stored);
        }
        const terminal = await applyOwnedManualSwitchTerminal(owner, response);
        if (terminal === MANUAL_SWITCH_MISSING) { return terminal; }
        return terminal || manualSwitchInFlightStatus(owner);
    }
    let response;
    try {
        response = await readOwnedManualSwitchResponse(owner);
    } catch {
        owner = await matchingManualSwitchOwner(owner);
        return owner ? manualSwitchAcknowledgement(owner) : MANUAL_SWITCH_MISSING;
    }
    owner = await matchingManualSwitchOwner(owner);
    if (!owner) { return MANUAL_SWITCH_MISSING; }
    if (isMissingManualSwitchResponse(response, owner.id)) {
        await updateManualSwitchOwner(owner, null);
        return MANUAL_SWITCH_MISSING;
    }
    const terminal = await applyOwnedManualSwitchTerminal(owner, response);
    if (terminal === MANUAL_SWITCH_MISSING) { return terminal; }
    return terminal || manualSwitchAcknowledgement(owner);
}

function resumeManualSwitchOwner(owner) {
    const key = manualSwitchResumeKey(owner);
    const existing = manualSwitchResumeFlights.get(key);
    if (existing) { return existing.promise; }
    const entry = {commitProtected: false, promise: null};
    const promise = Promise.resolve().then(() => performManualSwitchResume(owner));
    entry.promise = promise;
    manualSwitchResumeFlights.set(key, entry);
    const clear = () => {
        if (manualSwitchResumeFlights.get(key) === entry) {
            manualSwitchResumeFlights.delete(key);
        }
    };
    promise.then(clear, clear);
    return promise;
}

async function resumeAdmittedManualSwitchOwner(
    owner,
    identity,
    nextAttempt
) {
    let response;
    try {
        response = await resumeManualSwitchOwner(owner);
    } catch {}
    await refreshManualSwitchPolling();
    if (response === MANUAL_SWITCH_MISSING &&
        nextAttempt < MANUAL_SWITCH_ADMISSION_ATTEMPTS) {
        await runManualSwitchAdmissionAttempts(identity, nextAttempt);
    }
}

async function runManualSwitchAdmissionAttempts(identity, firstAttempt) {
    for (let attempt = firstAttempt;
        attempt < MANUAL_SWITCH_ADMISSION_ATTEMPTS;
        attempt += 1) {
        let owner = await reserveManualSwitchOwner(identity);
        if (!owner) { return undefined; }
        await refreshManualSwitchPolling(true);
        owner = await matchingManualSwitchOwner(owner);
        if (!owner) { continue; }
        if (owner.phase === "admitted") {
            void resumeAdmittedManualSwitchOwner(
                owner,
                identity,
                attempt + 1
            ).catch(() => {});
            return manualSwitchAcknowledgement(owner);
        }
        const response = await resumeManualSwitchOwner(owner);
        await refreshManualSwitchPolling();
        if (response !== MANUAL_SWITCH_MISSING) { return response; }
    }
    return undefined;
}

function beginManualSwitch(identity) {
    return runManualSwitchAdmissionAttempts(identity, 0);
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

async function resumeManualSwitchOwners(ids) {
    let owners;
    try {
        owners = await readManualSwitchOwnersForIds(ids);
    } catch {
        return;
    }
    await resumeManualSwitchOwnerList(owners);
}

async function resumeManualSwitchOwnerList(owners) {
    await Promise.all(owners.map(owner =>
        resumeManualSwitchOwner(owner).catch(() => undefined)
    ));
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
    const completed = await readAndApplyDappResponse(
        request.id,
        request.configurationKey,
        request.requestToken,
        request.revisions,
        identity.legacyConfigurationKey
    );
    return completed?.response;
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
        const response = await WIRE.withTimeout(
            sendNativeMessage(request, false),
            NATIVE_OPERATION_TIMEOUT
        );
        return WIRE.isCorrelatedRPCResponse(response, request.id)
            ? response
            : WIRE.rpcFailureResponse(request.id);
    } catch {
        return WIRE.rpcFailureResponse(request.id);
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
    if (WIRE.hasExactKeys(response, ["id", "missing"]) &&
        response.id === request.id && response.missing === true) {
        return response;
    }
    return WIRE.isCorrelatedDappResponse(response, request.id) &&
        await completed.acknowledgement
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
        const state = await readConfigurationState(
            identity.configurationKey,
            identity.legacyConfigurationKey
        );
        return publicConfigurationState(state);
    } catch {
        return {configurationReadFailed: true};
    }
}

function disconnectFailure(request) {
    return {
        id: request?.id,
        name: "revokePermissions",
        provider: request?.provider,
        error: "Failed to revoke permissions",
        errorCode: -32603,
    };
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
        state.configurations = state.configurations.filter(item => {
            return item.provider !== request.provider;
        });
        state.revisions[request.provider] += 1;
        return {changed: true, value: {
            id: request.id,
            name: "revokePermissions",
            provider: request.provider,
            result: null,
            ...publicConfigurationState(state),
        }};
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
    const valid = WIRE.isManualSwitchInFlightStatus(
        response,
        identity.configurationKey
    ) || WIRE.isManualSwitchAcknowledgement(
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
    const resuming = resumeManualSwitchOwners(ids);
    const tabs = await boundedTabsQuery();
    if (tabs) {
        for (const tab of tabs || []) {
            if (!Number.isSafeInteger(tab?.id)) { continue; }
            try { Promise.resolve(browser.tabs.sendMessage(tab.id, request)).catch(() => {}); } catch {}
        }
    }
    await resuming;
    await refreshManualSwitchPolling();
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
    });
} catch {}

try {
    browser.runtime.onStartup?.addListener?.(() => {
        Promise.resolve(clearUpdateRecovery()).catch(() => {});
        Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
        Promise.resolve(reconcileAllManualSwitchOwners(true)).catch(() => {});
    });
} catch {}

try {
    Promise.resolve(clearBadgeWithoutPopup()).catch(() => {});
    Promise.resolve(reconcileAllManualSwitchOwners(true)).catch(() => {});
} catch {}

try {
    browser.alarms?.onAlarm?.addListener?.(alarm => {
        if (alarm?.name !== MANUAL_SWITCH_POLL_ALARM_NAME) { return; }
        return reconcileAllManualSwitchOwners();
    });
} catch {}

try {
    browser.action?.onClicked?.addListener?.(tab => {
        Promise.resolve(handleToolbarClick(tab)).catch(() => {});
    });
} catch {}
