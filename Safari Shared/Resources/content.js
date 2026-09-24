// ∅ 2026 lil org

var bigWalletWire = BigWalletBridgeWire;
var bigWalletWorkflowVersion = bigWalletWire.WORKFLOW_VERSION;
var bigWalletPageDirection = bigWalletWire.PAGE_TO_CONTENT_DIRECTION;
var bigWalletContentDirection = bigWalletWire.CONTENT_TO_PAGE_DIRECTION;
var bigWalletRequests;
var bigWalletProviderGeneration;
var bigWalletProviderGenerationSerial;
var bigWalletContentInstalled;
var bigWalletConfigurationState;
var bigWalletFailedConfigurationGeneration;
var bigWalletConfigurationFlight;
var bigWalletConfigurationRefreshQueued;
var bigWalletConfigurationRefreshSerial;
if (bigWalletConfigurationRefreshQueued !== true) { bigWalletConfigurationRefreshQueued = false; }
if (!Number.isSafeInteger(bigWalletConfigurationRefreshSerial)) { bigWalletConfigurationRefreshSerial = 0; }
var bigWalletTransportTimeout = 5000;
var bigWalletDisconnectTimeout = bigWalletTransportTimeout * 3;
var bigWalletResponsePollTimeout = bigWalletTransportTimeout * 4;
var bigWalletNativeOperationRelayTimeout = 190 * 1000;

if (!(bigWalletRequests instanceof Map)) { bigWalletRequests = new Map; }
if (!Number.isSafeInteger(bigWalletProviderGenerationSerial)) {
    bigWalletProviderGenerationSerial = 0;
}

if (bigWalletContentInstalled !== true) {
    bigWalletContentInstalled = true;
    const contentBuildVersion = bigWalletWire.BUILD_VERSION;
    const runtimeMessage = bigWalletRuntimeMessage;
    browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
        const senderContext = bigWalletWire.authorizeRuntimeMessage(
            "content", request, sender, browser.runtime
        );
        if (!senderContext) { return false; }
        return runtimeMessage(
            request,
            senderContext,
            sendResponse,
            contentBuildVersion
        );
    });
    window.addEventListener("message", bigWalletPageMessage);
    window.addEventListener("focus", bigWalletVisibilityChanged);
    document.addEventListener("visibilitychange", bigWalletVisibilityChanged);
}
if (typeof bigWalletProviderGeneration !== "string" &&
    bigWalletShouldInjectProvider()) {
    const candidateGeneration = bigWalletNextGeneration();
    bigWalletProviderGeneration = candidateGeneration;
    if (bigWalletInjectProvider(candidateGeneration)) {
        bigWalletLoadConfiguration(candidateGeneration, 0);
    } else {
        bigWalletProviderGeneration = undefined;
    }
}

function bigWalletCurrentIdentity() {
    return bigWalletWire.configurationIdentityForURL(window.location.href);
}

function bigWalletNextGeneration() {
    bigWalletProviderGenerationSerial += 1;
    return `inpage:${bigWalletProviderGenerationSerial}:${bigWalletWire.genPrivateToken()}`;
}

function bigWalletMatchesGeneration(value) {
    return typeof value === "string" && value === bigWalletProviderGeneration;
}

function bigWalletHasAcceptedConfiguration(generation, configurationKey) {
    return bigWalletConfigurationState?.providerGeneration === generation &&
        bigWalletConfigurationState.configurationKey === configurationKey;
}

function bigWalletConfigurationDelivery(
    decoded,
    configurationKey,
    providerGeneration,
    terminal
) {
    if (!decoded || (terminal
        ? decoded.kind !== "result" && decoded.kind !== "error"
        : decoded.kind !== "configuration")) {
        return null;
    }
    const originalGeneration = providerGeneration;
    if (decoded.state) {
        const previous = bigWalletConfigurationState;
        if (previous?.providerGeneration === providerGeneration &&
            previous.configurationKey === configurationKey && previous.state.context !== decoded.state.context) {
            const nextGeneration = bigWalletNextGeneration();
            bigWalletProviderGeneration = nextGeneration;
            if (!bigWalletInjectProvider(nextGeneration)) {
                bigWalletProviderGeneration = providerGeneration;
                return null;
            }
            for (const request of bigWalletRequests.values()) { bigWalletFail(request); }
            providerGeneration = nextGeneration;
            bigWalletConfigurationState = undefined;
        }
        const current = bigWalletConfigurationState?.providerGeneration === providerGeneration
            ? bigWalletConfigurationState.state : null;
        let state = decoded.state;
        if (current && current.context === state.context) {
            const ethereum = state.revisions.ethereum >= current.revisions.ethereum;
            const solana = state.revisions.solana >= current.revisions.solana;
            if (state.revisions.ethereum === current.revisions.ethereum &&
                (state.ethereum.address !== current.ethereum.address || state.ethereum.chainId !== current.ethereum.chainId) ||
                state.revisions.solana === current.revisions.solana && state.solana?.publicKey !== current.solana?.publicKey) {
                return null;
            }
            state = {...state, ethereum: ethereum ? state.ethereum : current.ethereum,
                solana: solana ? state.solana : current.solana,
                revisions: {ethereum: Math.max(state.revisions.ethereum, current.revisions.ethereum),
                    solana: Math.max(state.revisions.solana, current.revisions.solana)}};
        }
        bigWalletConfigurationState = {configurationKey, providerGeneration, state};
        bigWalletFailedConfigurationGeneration = undefined;
    }
    if (terminal && providerGeneration !== originalGeneration) {
        window.postMessage({direction: bigWalletContentDirection, kind: "response",
            response: {kind: "configuration", state: decoded.state}, id: bigWalletWire.genId(), providerGeneration}, "*");
        return {response: {...decoded, state: null}, providerGeneration: originalGeneration};
    }
    return {response: decoded, providerGeneration};
}

function bigWalletErrorResponse(id, provider, name, message = "Failed to communicate with Big Wallet") {
    return {
        kind: "error", id, provider, name, state: null,
        error: {code: -32603, message},
    };
}

function bigWalletTerminal(response, id) {
    const decoded = bigWalletWire.decodePageResponse(response, id);
    if (decoded?.kind === "result" || decoded?.kind === "error") { return decoded; }
    if (bigWalletWire.isRecord(response) && response.id === id &&
        (response.kind === "result" || response.kind === "error")) {
        return bigWalletErrorResponse(id,
            response.provider === "solana" ? "solana" : "ethereum",
            typeof response.name === "string" ? response.name : null,
            "Failed to process provider response");
    }
    return null;
}

function bigWalletShouldInjectProvider() {
    const path = window.location.pathname;
    const documentName = document.documentElement?.nodeName?.toLowerCase();
    return (!document.doctype || document.doctype.name === "html") &&
        !/\.(pdf|xml)$/u.test(path) && (!documentName || documentName === "html");
}

function bigWalletInjectProvider(providerGeneration) {
    try {
        const container = document.head || document.documentElement;
        const script = document.createElement("script");
        const status = `complete:${providerGeneration}`;
        const request = new XMLHttpRequest;
        request.open("GET", browser.runtime.getURL("inpage.js"), false);
        request.send();
        script.setAttribute("data-big-wallet-injection-status", "pending");
        script.textContent = `"use strict";\n` +
            `window.bigWalletInstallingProviderGeneration = ${JSON.stringify(providerGeneration)};\n` +
            request.responseText +
            `\ndocument.currentScript.setAttribute("data-big-wallet-injection-status", ${JSON.stringify(status)});`;
        container.insertBefore(script, container.children[0]);
        const succeeded = script.getAttribute("data-big-wallet-injection-status") === status;
        container.removeChild(script);
        return succeeded;
    } catch (error) {
        console.error("Big Wallet: failed to inject", error);
        return false;
    }
}

function bigWalletPageMessage(event) {
    if (event.source !== window || !bigWalletWire.isRecord(event.data) ||
        event.data.direction !== bigWalletPageDirection) {
        return;
    }
    const generation = event.data.providerGeneration;
    if (event.data.kind === "rpc") {
        bigWalletRPC(event.data.message, generation);
    } else if (event.data.kind === "request") {
        if (event.data.message?.provider === "unknown") { return; }
        bigWalletEnqueue(event.data.message, generation, event.data.observedRevision);
    } else if (event.data.kind === "disconnect") {
        bigWalletDisconnect(event.data.message, generation);
    }
}

function bigWalletRPC(message, generation) {
    if (!bigWalletWire.isRecord(message) || !bigWalletWire.isValidRequestId(message.id)) {
        return;
    }
    if (!bigWalletMatchesGeneration(generation)) {
        bigWalletPostRPC(message.id, bigWalletErrorResponse(message.id, "ethereum", null), generation);
        return;
    }
    let pending;
    try {
        pending = bigWalletWire.withTimeout(
            browser.runtime.sendMessage({
                subject: "rpc",
                id: message.id,
                chainId: message.chainId,
                body: message.body,
                workflowVersion: bigWalletWorkflowVersion,
            }),
            bigWalletNativeOperationRelayTimeout
        );
    } catch {
        bigWalletPostRPC(message.id, undefined, generation);
        return;
    }
    Promise.resolve(pending).then(
        response => bigWalletPostRPC(message.id, response, generation),
        () => bigWalletPostRPC(message.id, undefined, generation)
    );
}

function bigWalletPostRPC(id, response, generation) {
    window.postMessage({
        direction: bigWalletContentDirection,
        kind: "rpc",
        response: bigWalletTerminal(response, id) || bigWalletErrorResponse(id, "ethereum", null),
        id,
        providerGeneration: generation,
    }, "*");
}

function bigWalletEnqueue(message, generation, observedRevision) {
    if (!bigWalletWire.isRecord(message) || !bigWalletWire.isRecord(message.body) ||
        !bigWalletWire.isValidRequestId(message.id) ||
        typeof message.name !== "string" ||
        !["ethereum", "solana"].includes(message.provider)) {
        return;
    }
    if (!bigWalletMatchesGeneration(generation) || !Number.isSafeInteger(observedRevision) || observedRevision < 0) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
    const identity = bigWalletCurrentIdentity();
    if (!identity) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
    const cached = bigWalletConfigurationState;
    if (cached?.providerGeneration !== generation || cached.configurationKey !== identity.configurationKey) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
    const authority = {context: cached.state.context,
        revisions: {...cached.state.revisions, [message.provider]: observedRevision}};
    const key = `${generation}:${message.provider}:${message.id}`;
    const existing = bigWalletRequests.get(key);
    if (existing) { return; }
    if (bigWalletRequests.size >=
        bigWalletWire.WORKFLOW_POLICY.maximumRequestsPerHost) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
    const admissionDeadline = Date.now() +
        bigWalletWire.WORKFLOW_POLICY.requestTTLMilliseconds;
    const state = {
        configurationKey: identity.configurationKey,
        admissionDeadline,
        delivered: false,
        generation,
        host: identity.host,
        key,
        message: {
            body: {...message.body},
            id: message.id,
            name: message.name,
            provider: message.provider,
        },
        phase: "enqueuing",
        requestToken: null,
        recoveryDeadline: admissionDeadline +
            bigWalletWire.WORKFLOW_POLICY.responseExpiryMilliseconds,
        responseFailureMilliseconds: 0,
        lastResponseFailureAt: null,
        authority,
        authorizationRetryUsed: false,
        rerunRequested: false,
        retryDelay: 500,
        running: false,
        timer: null,
    };
    state.enqueueAttempt = bigWalletWire.genPrivateToken();
    bigWalletRequests.set(key, state);
    bigWalletRun(state);
}

function bigWalletRun(state) {
    if (state.delivered || bigWalletRequests.get(state.key) !== state) {
        return;
    }
    if (state.phase === "enqueuing" &&
        Date.now() >= state.recoveryDeadline) {
        bigWalletFail(state);
        return;
    }
    if (state.running) {
        state.rerunRequested = true;
        return;
    }
    state.running = true;
    const operation = state.phase === "enqueuing"
        ? bigWalletSendEnqueue(state)
        : bigWalletReadResponse(state);
    Promise.resolve(operation).finally(() => {
        state.running = false;
        if (state.rerunRequested) {
            state.rerunRequested = false;
            clearTimeout(state.timer);
            state.timer = null;
            bigWalletRun(state);
        }
    });
}

async function bigWalletSendEnqueue(state) {
    const remaining = state.recoveryDeadline - Date.now();
    if (remaining <= 0) {
        bigWalletFail(state);
        return;
    }
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            admissionDeadline: state.admissionDeadline,
            authority: state.authority,
            subject: "message-to-wallet",
            message: state.message,
            host: state.host,
            configurationKey: state.configurationKey,
            enqueueAttempt: state.enqueueAttempt,
            workflowVersion: bigWalletWorkflowVersion,
        }), Math.min(bigWalletTransportTimeout, remaining));
    } catch {}
    if (!bigWalletIsCurrent(state, "enqueuing")) { return; }
    if (Date.now() >= state.recoveryDeadline) {
        bigWalletFail(state);
        return;
    }
    if (bigWalletWire.isNativeEnqueueAcknowledgement(response, state.message.id)) {
        state.requestToken = response.requestToken;
        bigWalletPublishConfiguration(response.state, state.configurationKey, state.generation);
        if (!bigWalletIsCurrent(state, "enqueuing")) { return; }
        state.phase = "waiting";
        bigWalletSchedule(state, response.approvalRequired ? 1000 : 0);
        return;
    }
    const terminal = bigWalletTerminal(response, state.message.id);
    if (terminal) {
        if (!state.authorizationRetryUsed && terminal.kind === "error" && terminal.error.code === 4100 &&
            ["requestAccounts", "connect", "switchEthereumChain", "addEthereumChain"].includes(state.message.name) &&
            terminal.state?.context === state.authority.context && Date.now() < state.admissionDeadline &&
            (terminal.state.revisions.ethereum > state.authority.revisions.ethereum ||
                terminal.state.revisions.solana > state.authority.revisions.solana)) {
            state.authorizationRetryUsed = true;
            bigWalletPublishConfiguration(terminal.state, state.configurationKey, state.generation);
            state.authority = {context: terminal.state.context, revisions: {...terminal.state.revisions}};
            if (state.message.provider === "ethereum" && state.message.name === "switchEthereumChain") {
                state.message.body.address = terminal.state.ethereum.address;
            }
            state.enqueueAttempt = bigWalletWire.genPrivateToken();
            bigWalletSchedule(state, 0);
            return;
        }
        bigWalletDeliver(state, terminal);
        return;
    }
    bigWalletSchedule(state, state.retryDelay);
    state.retryDelay = Math.min(state.retryDelay * 2, 5000);
}

async function bigWalletReadResponse(state) {
    const startedAt = Date.now();
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "getResponse",
            id: state.message.id,
            configurationKey: state.configurationKey,
            requestToken: state.requestToken,
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletResponsePollTimeout);
    } catch {}
    if (!bigWalletIsCurrent(state, "waiting")) { return; }
    if (bigWalletWire.hasExactKeys(response, ["id", "missing"]) &&
        response.id === state.message.id && response.missing === true) {
        bigWalletFail(state);
        return;
    }
    const terminal = bigWalletTerminal(response, state.message.id);
    if (terminal) {
        bigWalletDeliver(state, terminal);
        return;
    }
    bigWalletRetryResponse(state, response, startedAt);
}

function bigWalletRetryResponse(state, response, startedAt) {
    const retryDelay = document.visibilityState === "visible" ? 1000 : 5000;
    if (bigWalletWire.hasExactKeys(response, ["id", "pending"]) &&
        response.id === state.message.id && response.pending === true) {
        state.responseFailureMilliseconds = 0;
        state.lastResponseFailureAt = null;
    } else {
        const now = Date.now();
        state.responseFailureMilliseconds += Math.min(
            Math.max(0, now - (state.lastResponseFailureAt ?? startedAt)),
            bigWalletResponsePollTimeout + retryDelay
        );
        state.lastResponseFailureAt = now;
        if (state.responseFailureMilliseconds >=
            bigWalletWire.WORKFLOW_POLICY.responseExpiryMilliseconds) {
            bigWalletFail(state);
            return;
        }
    }
    bigWalletSchedule(state, retryDelay);
}

function bigWalletSchedule(state, delay) {
    if (state.phase === "enqueuing") {
        const remaining = state.recoveryDeadline - Date.now();
        if (remaining <= 0) {
            bigWalletFail(state);
            return;
        }
        delay = Math.min(delay, remaining);
    }
    if (delay === 0 && state.running) {
        bigWalletRun(state);
        return;
    }
    clearTimeout(state.timer);
    state.timer = setTimeout(() => {
        state.timer = null;
        bigWalletRun(state);
    }, delay);
}

function bigWalletIsCurrent(state, phase) {
    return !state.delivered && state.phase === phase &&
        bigWalletRequests.get(state.key) === state;
}

function bigWalletDeliver(state, response) {
    if (state.delivered || bigWalletRequests.get(state.key) !== state) { return; }
    state.delivered = true;
    state.phase = "delivered";
    clearTimeout(state.timer);
    const delivery = state.generation === bigWalletProviderGeneration
        ? bigWalletConfigurationDelivery(response, state.configurationKey, state.generation, true)
        : {response};
    const prepared = delivery?.response || bigWalletErrorResponse(
        state.message.id, state.message.provider, state.message.name
    );
    const envelope = {
        direction: bigWalletContentDirection,
        kind: "response",
        response: prepared,
        id: state.message.id,
        providerGeneration: delivery?.providerGeneration || state.generation,
    };
    window.postMessage(envelope, "*");
    bigWalletRequests.delete(state.key);
}

function bigWalletFail(state) {
    if (state.delivered || bigWalletRequests.get(state.key) !== state) { return; }
    state.delivered = true;
    state.phase = "delivered";
    clearTimeout(state.timer);
    state.timer = null;
    bigWalletRequests.delete(state.key);
    bigWalletDeliverFailure(state.message, state.generation);
}

function bigWalletDeliverFailure(message, generation) {
    const response = bigWalletErrorResponse(message.id, message.provider, message.name);
    window.postMessage({
        direction: bigWalletContentDirection,
        kind: "response",
        response,
        id: message.id,
        providerGeneration: generation,
    }, "*");
}

function bigWalletDisconnect(message, generation) {
    if (!bigWalletWire.isValidDisconnectRequest(message)) { return; }
    const identity = bigWalletCurrentIdentity();
    const cached = bigWalletConfigurationState;
    if (!bigWalletMatchesGeneration(generation) || cached?.providerGeneration !== generation ||
        cached.configurationKey !== identity?.configurationKey) {
        bigWalletPostDisconnect(message, undefined, generation);
        return;
    }
    const id = typeof message.id === "undefined" ? bigWalletWire.genId() : message.id;
    let request = {
        subject: "disconnect", id, provider: message.provider,
        host: identity.host, configurationKey: identity.configurationKey,
        attempt: bigWalletWire.genPrivateToken(),
        authority: {context: cached.state.context, revisions: {...cached.state.revisions}},
        workflowVersion: bigWalletWorkflowVersion,
    };
    void (async () => {
        let response;
        let staleRetried = false;
        let lostReplies = 0;
        for (;;) {
            response = undefined;
            try { response = await bigWalletWire.withTimeout(browser.runtime.sendMessage(request), bigWalletDisconnectTimeout); } catch {}
            if (!bigWalletMatchesGeneration(generation)) { break; }
            const terminal = bigWalletTerminal(response, id);
            if (!terminal) {
                if (lostReplies++ === 0) { continue; }
                break;
            }
            if (!staleRetried && terminal.kind === "error" && terminal.error.code === 4100 &&
                terminal.state?.context === request.authority.context) {
                staleRetried = true;
                lostReplies = 0;
                bigWalletPublishConfiguration(terminal.state, identity.configurationKey, generation);
                request = {...request, attempt: bigWalletWire.genPrivateToken(),
                    authority: {context: terminal.state.context, revisions: {...terminal.state.revisions}}};
                continue;
            }
            break;
        }
        bigWalletPostDisconnect({...message, id}, response, generation, identity.configurationKey);
    })();
}

function bigWalletPostDisconnect(message, response, generation, configurationKey) {
    if (typeof message.id === "undefined") {
        bigWalletLoadConfiguration(bigWalletProviderGeneration, 0);
        return;
    }
    const terminal = bigWalletTerminal(response, message.id);
    const valid = terminal?.name === "revokePermissions" && terminal.provider === message.provider;
    const prepared = valid ? terminal : bigWalletErrorResponse(
        message.id, message.provider, "revokePermissions", "Failed to revoke permissions"
    );
    const delivery = generation !== bigWalletProviderGeneration
        ? {response: prepared}
        : bigWalletConfigurationDelivery(
            prepared, configurationKey, generation, true
        );
    window.postMessage({
        direction: bigWalletContentDirection,
        kind: "response",
        response: delivery?.response || prepared,
        id: message.id,
        providerGeneration: delivery?.providerGeneration || generation,
    }, "*");
}

function bigWalletPublishConfiguration(state, configurationKey, generation) {
    const response = bigWalletWire.decodePageResponse({kind: "configuration", state});
    const delivery = bigWalletConfigurationDelivery(response, configurationKey, generation, false);
    if (!delivery?.response) { return false; }
    window.postMessage({direction: bigWalletContentDirection, kind: "response",
        response: delivery.response, id: bigWalletWire.genId(),
        providerGeneration: delivery.providerGeneration}, "*");
    return true;
}

function bigWalletLoadConfiguration(generation, attempt, followup = false) {
    if (!bigWalletMatchesGeneration(generation)) { return Promise.resolve(); }
    if (bigWalletConfigurationFlight) {
        if (followup) { bigWalletConfigurationRefreshQueued = true; }
        return bigWalletConfigurationFlight;
    }
    if (attempt === 0) { bigWalletConfigurationRefreshSerial += 1; }
    const pending = bigWalletReadConfiguration(generation, attempt, bigWalletConfigurationRefreshSerial);
    bigWalletConfigurationFlight = pending;
    const finish = () => {
        if (bigWalletConfigurationFlight !== pending) { return; }
        bigWalletConfigurationFlight = null;
        if (bigWalletConfigurationRefreshQueued) {
            bigWalletConfigurationRefreshQueued = false;
            void bigWalletLoadConfiguration(bigWalletProviderGeneration, 0);
        }
    };
    pending.then(finish, finish);
    return pending;
}

async function bigWalletReadConfiguration(generation, attempt, serial) {
    const identity = bigWalletCurrentIdentity();
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "getLatestConfiguration", host: identity?.host || "",
            configurationKey: identity?.configurationKey || "", workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletMatchesGeneration(generation)) { return; }
    const decoded = bigWalletWire.decodePageResponse(response);
    if (identity && decoded?.kind === "configuration" &&
        bigWalletPublishConfiguration(decoded.state, identity.configurationKey, generation)) { return; }
    const unsupported = decoded?.kind === "configurationError" && decoded.error.code === 4200;
    if (!unsupported && attempt < 2) {
        setTimeout(() => {
            if (bigWalletConfigurationRefreshSerial === serial) { void bigWalletLoadConfiguration(generation, attempt + 1); }
        }, attempt === 0 ? 1000 : 5000);
        return;
    }
    if (bigWalletHasAcceptedConfiguration(generation, identity?.configurationKey)) { return; }
    bigWalletFailedConfigurationGeneration = generation;
    window.postMessage({direction: bigWalletContentDirection, kind: "response",
        response: unsupported ? decoded : {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}},
        providerGeneration: generation}, "*");
}

function bigWalletRuntimeMessage(
    request,
    senderContext,
    sendResponse,
    contentBuildVersion
) {

    if (bigWalletWire.hasExactKeys(request, [
        "nonce", "subject", "workflowVersion",
    ]) &&
        request.subject === "workflowProbe" &&
        request.workflowVersion === bigWalletWorkflowVersion &&
        bigWalletWire.isPrivateToken(request.nonce) &&
        typeof contentBuildVersion === "string" &&
        contentBuildVersion.length > 0) {
        sendResponse({
            buildVersion: contentBuildVersion,
            nonce: request.nonce,
            subject: "workflowProbe",
            workflowVersion: bigWalletWorkflowVersion,
        });
        return true;
    }
    if (bigWalletWire.isConfigurationInvalidated(request)) {
        const identity = bigWalletCurrentIdentity();
        if (identity?.configurationKey === request.configurationKey && typeof bigWalletProviderGeneration === "string") {
            void bigWalletLoadConfiguration(bigWalletProviderGeneration, 0, true);
        }
        sendResponse();
        return true;
    }
    const ids = bigWalletWire.responseReadyIds(request);
    if (ids) {
        for (const state of bigWalletRequests.values()) {
            if (state.phase === "waiting" &&
                ids.includes(state.message.id)) {
                bigWalletSchedule(state, 0);
            }
        }
        sendResponse();
        return true;
    }
    if (request?.subject === bigWalletWire.MANUAL_SWITCH_INTENT_SUBJECT) {
        const identity = bigWalletCurrentIdentity();
        if (!bigWalletWire.hasExactKeys(request, [
                "configurationKey", "subject", "workflowVersion",
            ]) || request.workflowVersion !== bigWalletWorkflowVersion ||
            request.configurationKey !== identity?.configurationKey ||
            typeof bigWalletProviderGeneration !== "string") {
            sendResponse();
            return true;
        }
        let pending;
        try {
            pending = browser.runtime.sendMessage({
                configurationKey: identity.configurationKey,
                host: identity.host,
                subject: bigWalletWire.MANUAL_SWITCH_INTENT_SUBJECT,
                workflowVersion: bigWalletWorkflowVersion,
            });
        } catch {
            sendResponse();
            return true;
        }
        Promise.resolve(pending).then(sendResponse, () => sendResponse());
        return true;
    }
    sendResponse();
    return true;
}

function bigWalletVisibilityChanged(event) {
    if (event?.isTrusted === false) { return; }
    if (document.visibilityState !== "visible") { return; }
    for (const state of bigWalletRequests.values()) {
        if (state.phase === "waiting") {
            bigWalletSchedule(state, 0);
        }
    }
    const generation = bigWalletProviderGeneration;
    if (bigWalletMatchesGeneration(generation)) {
        void bigWalletLoadConfiguration(generation, 0, true);
    }
}
