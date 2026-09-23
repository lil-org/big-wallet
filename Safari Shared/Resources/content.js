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
var bigWalletTransportTimeout = 5000;
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
    if (decoded.state) {
        bigWalletConfigurationState = {configurationKey, providerGeneration};
        bigWalletFailedConfigurationGeneration = undefined;
    }
    return {response: decoded};
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
        bigWalletEnqueue(event.data.message, generation);
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

function bigWalletEnqueue(message, generation) {
    if (!bigWalletWire.isRecord(message) || !bigWalletWire.isRecord(message.body) ||
        !bigWalletWire.isValidRequestId(message.id) ||
        typeof message.name !== "string" ||
        !["ethereum", "solana"].includes(message.provider)) {
        return;
    }
    if (!bigWalletMatchesGeneration(generation)) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
    const identity = bigWalletCurrentIdentity();
    if (!identity) {
        bigWalletDeliverFailure(message, generation);
        return;
    }
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
        revisions: null,
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
        : state.phase === "completing"
            ? bigWalletConsumeResponse(state)
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
        state.revisions = response.revisions;
        state.phase = "waiting";
        bigWalletSchedule(state, response.approvalRequired ? 1000 : 0);
        return;
    }
    const terminal = bigWalletTerminal(response, state.message.id);
    if (terminal) {
        bigWalletDeliver(state, terminal);
        return;
    }
    bigWalletSchedule(state, state.retryDelay);
    state.retryDelay = Math.min(state.retryDelay * 2, 5000);
}

async function bigWalletReadResponse(state) {
    const readStartedAt = Date.now();
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "getResponse",
            id: state.message.id,
            configurationKey: state.configurationKey,
            requestToken: state.requestToken,
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletIsCurrent(state, "waiting")) { return; }
    if (bigWalletWire.hasExactKeys(response, ["id", "missing"]) &&
        response.id === state.message.id && response.missing === true) {
        bigWalletFail(state);
        return;
    }
    if (bigWalletWire.hasExactKeys(response, ["id", "ready"]) &&
        response.id === state.message.id && response.ready === true) {
        state.phase = "completing";
        state.responseFailureMilliseconds = 0;
        state.lastResponseFailureAt = null;
        bigWalletSchedule(state, 0);
        return;
    }
    bigWalletRetryResponse(state, response, readStartedAt);
}

async function bigWalletConsumeResponse(state) {
    const startedAt = Date.now();
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "consumeResponse",
            id: state.message.id,
            configurationKey: state.configurationKey,
            requestToken: state.requestToken,
            revisions: state.revisions,
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletIsCurrent(state, "completing")) { return; }
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
            bigWalletTransportTimeout + retryDelay
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
        providerGeneration: state.generation,
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
    if (!bigWalletMatchesGeneration(generation)) {
        bigWalletPostDisconnect(message, undefined, generation);
        return;
    }
    const identity = bigWalletCurrentIdentity();
    bigWalletWire.withTimeout(browser.runtime.sendMessage({
        subject: "disconnect",
        id: message.id,
        provider: message.provider,
        host: identity?.host || "",
        configurationKey: identity?.configurationKey || "",
        workflowVersion: bigWalletWorkflowVersion,
    }), bigWalletTransportTimeout).then(
        response => bigWalletPostDisconnect(
            message, response, generation, identity?.configurationKey
        ),
        () => bigWalletPostDisconnect(message, undefined, generation)
    );
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
        response: delivery.response,
        id: message.id,
        providerGeneration: generation,
    }, "*");
}

async function bigWalletLoadConfiguration(generation, attempt) {
    if (!bigWalletMatchesGeneration(generation)) { return; }
    if (attempt === 0) { bigWalletFailedConfigurationGeneration = undefined; }
    const identity = bigWalletCurrentIdentity();
    if (attempt > 0 && bigWalletHasAcceptedConfiguration(
        generation,
        identity?.configurationKey
    )) {
        return;
    }
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "getLatestConfiguration",
            host: identity?.host || "",
            configurationKey: identity?.configurationKey || "",
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletMatchesGeneration(generation)) { return; }
    const delivery = identity
        ? bigWalletConfigurationDelivery(
            bigWalletWire.decodePageResponse(response),
            identity.configurationKey,
            generation,
            false
        )
        : null;
    if (delivery?.response) {
        window.postMessage({
            direction: bigWalletContentDirection,
            kind: "response",
            response: delivery.response,
            id: bigWalletWire.genId(),
            providerGeneration: generation,
        }, "*");
    } else if (bigWalletHasAcceptedConfiguration(
        generation,
        identity?.configurationKey
    )) {
        return;
    } else if (attempt < 2) {
        setTimeout(() => bigWalletLoadConfiguration(generation, attempt + 1),
            attempt === 0 ? 1000 : 5000);
    } else {
        bigWalletFailedConfigurationGeneration = generation;
        window.postMessage({
            direction: bigWalletContentDirection,
            kind: "response",
            response: {kind: "configurationError", error: {
                code: 4900, message: "Failed to communicate with Big Wallet",
            }},
            providerGeneration: generation,
        }, "*");
    }
}

function bigWalletRuntimeMessage(
    request,
    senderContext,
    sendResponse,
    contentBuildVersion
) {
    if (request?.subject === "requestActive") {
        if (senderContext.kind !== "worker" ||
            !bigWalletWire.hasExactKeys(request, [
                "subject", "id", "configurationKey", "requestToken", "workflowVersion",
            ]) || request.workflowVersion !== bigWalletWorkflowVersion ||
            !bigWalletWire.isValidRequestId(request.id) ||
            !bigWalletWire.isRequestToken(request.requestToken)) {
            sendResponse();
            return true;
        }
        const identity = bigWalletCurrentIdentity();
        const active = identity?.configurationKey === request.configurationKey &&
            [...bigWalletRequests.values()].some(state =>
                bigWalletIsCurrent(state, "waiting") &&
                bigWalletMatchesGeneration(state.generation) &&
                state.message.id === request.id &&
                state.requestToken === request.requestToken &&
                state.configurationKey === request.configurationKey
            );
        sendResponse({id: request.id, requestToken: request.requestToken, active});
        return true;
    }
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
    if (bigWalletWire.isConfigurationChanged(request)) {
        const identity = bigWalletCurrentIdentity();
        if (identity?.configurationKey === request.configurationKey &&
            typeof bigWalletProviderGeneration === "string") {
            const delivery = bigWalletConfigurationDelivery(
                bigWalletWire.decodePageResponse({kind: "configuration", state: request.state}),
                identity.configurationKey,
                bigWalletProviderGeneration,
                false
            );
            if (delivery?.response) {
                window.postMessage({
                    direction: bigWalletContentDirection,
                    kind: "response",
                    response: delivery.response,
                    id: bigWalletWire.genId(),
                    providerGeneration: bigWalletProviderGeneration,
                }, "*");
            }
        }
        sendResponse();
        return true;
    }
    const ids = bigWalletWire.responseReadyIds(request);
    if (ids) {
        for (const state of bigWalletRequests.values()) {
            if ((state.phase === "waiting" || state.phase === "completing") &&
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
        if (state.phase === "waiting" || state.phase === "completing") {
            bigWalletSchedule(state, 0);
        }
    }
    const generation = bigWalletProviderGeneration;
    if (!bigWalletMatchesGeneration(generation)) { return; }
    const identity = bigWalletCurrentIdentity();
    if (bigWalletFailedConfigurationGeneration === generation ||
        bigWalletHasAcceptedConfiguration(generation, identity?.configurationKey)) {
        void bigWalletLoadConfiguration(generation, 0);
    }
}
