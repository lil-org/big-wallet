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
var bigWalletTransportTimeout = 5000;

if (!(bigWalletRequests instanceof Map)) { bigWalletRequests = new Map; }
if (!Number.isSafeInteger(bigWalletProviderGenerationSerial)) {
    bigWalletProviderGenerationSerial = 0;
}

if (bigWalletContentInstalled !== true) {
    bigWalletContentInstalled = true;
    const manifest = browser.runtime.getManifest();
    const contentBuildVersion = typeof manifest?.version === "string"
        ? manifest.version
        : "";
    const runtimeMessage = bigWalletRuntimeMessage;
    browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
        return runtimeMessage(
            request,
            sender,
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
    response,
    configurationKey,
    providerGeneration,
    terminal
) {
    const hasConfigurations = bigWalletWire.isRecord(response) &&
        Object.prototype.hasOwnProperty.call(response, "latestConfigurations");
    if (!hasConfigurations) {
        if (!terminal) { return null; }
        return {response: {...response}, suppressProviderUpdate: false};
    }
    const parsed = bigWalletWire.parseLatestConfigurations(response);
    const revisions = response.revisions;
    const valid = parsed.valid && bigWalletWire.isProviderRevisions(revisions);
    const current = bigWalletConfigurationState?.configurationKey === configurationKey &&
        bigWalletConfigurationState.providerGeneration === providerGeneration
        ? bigWalletConfigurationState.revisions
        : null;
    const stale = valid && current && (
        revisions.ethereum < current.ethereum || revisions.solana < current.solana
    );
    if (!valid) {
        if (!terminal) { return null; }
        return {
            response: {
                id: response.id,
                name: response.name,
                provider: response.provider,
                error: "Failed to process provider response",
                errorCode: -32603,
            },
            suppressProviderUpdate: false,
        };
    }
    if (stale) {
        if (!terminal) { return {ignored: true}; }
        const prepared = {...response};
        delete prepared.latestConfigurations;
        delete prepared.revisions;
        return {response: prepared, suppressProviderUpdate: true};
    }
    bigWalletConfigurationState = {
        configurationKey,
        providerGeneration,
        revisions: {...revisions},
    };
    return {
        response: terminal
            ? {
                ...response,
                latestConfigurations: parsed.latestConfigurations,
                revisions: {...revisions},
            }
            : {
                latestConfigurations: parsed.latestConfigurations,
                revisions: {...revisions},
            },
        suppressProviderUpdate: false,
    };
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
    } else if (event.data.kind === "solanaAuthorizationEpoch") {
        return;
    }
}

function bigWalletRPC(message, generation) {
    if (!bigWalletWire.isRecord(message) || !bigWalletWire.isValidRequestId(message.id)) {
        return;
    }
    if (!bigWalletMatchesGeneration(generation)) {
        bigWalletPostRPC(message.id, bigWalletWire.rpcFailureResponse(message.id), generation);
        return;
    }
    let pending;
    try {
        pending = browser.runtime.sendMessage({
            subject: "rpc",
            id: message.id,
            chainId: message.chainId,
            body: message.body,
            workflowVersion: bigWalletWorkflowVersion,
        });
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
        response: bigWalletWire.isCorrelatedRPCResponse(response, id)
            ? response
            : bigWalletWire.rpcFailureResponse(id),
        id,
        providerGeneration: generation,
    }, "*");
}

function bigWalletEnqueue(message, generation, options = {}) {
    if (!bigWalletWire.isRecord(message) || !bigWalletWire.isRecord(message.body) ||
        !bigWalletWire.isValidRequestId(message.id) ||
        typeof message.name !== "string" ||
        !["ethereum", "solana", "unknown"].includes(message.provider)) {
        return Promise.resolve();
    }
    if (!bigWalletMatchesGeneration(generation)) {
        bigWalletDeliverFailure(message, generation);
        return Promise.resolve();
    }
    const identity = bigWalletCurrentIdentity();
    if (!identity) {
        bigWalletDeliverFailure(message, generation);
        return Promise.resolve();
    }
    const manualSwitch = options.manualSwitch === true;
    const hasEnqueueAttempt = Object.prototype.hasOwnProperty.call(
        options,
        "enqueueAttempt"
    );
    const hasAdmissionDeadline = Object.prototype.hasOwnProperty.call(
        options,
        "admissionDeadline"
    );
    const validManualAdmission = hasEnqueueAttempt && hasAdmissionDeadline &&
        bigWalletWire.isPrivateToken(options.enqueueAttempt) &&
        Number.isSafeInteger(options.admissionDeadline) &&
        options.admissionDeadline > 0;
    if ((manualSwitch && !validManualAdmission) ||
        (!manualSwitch && (hasEnqueueAttempt || hasAdmissionDeadline))) {
        return Promise.resolve();
    }
    const key = `${generation}:${message.provider}:${message.id}`;
    const existing = bigWalletRequests.get(key);
    if (existing) { return existing.initialResponse; }
    if (bigWalletRequests.size >=
        bigWalletWire.WORKFLOW_POLICY.maximumRequestsPerHost) {
        if (!manualSwitch) { bigWalletDeliverFailure(message, generation); }
        return Promise.resolve();
    }
    let resolveInitial;
    const state = {
        configurationKey: identity.configurationKey,
        admissionDeadline: manualSwitch
            ? options.admissionDeadline
            : Date.now() + bigWalletWire.WORKFLOW_POLICY.requestTTLMilliseconds,
        delivered: false,
        generation,
        host: identity.host,
        initialResponse: new Promise(resolve => { resolveInitial = resolve; }),
        key,
        manualSwitch,
        message: {
            body: {...message.body},
            id: message.id,
            name: message.name,
            provider: message.provider,
        },
        phase: "enqueuing",
        requestToken: null,
        resolveInitial,
        revisions: null,
        rerunRequested: false,
        retryDelay: 500,
        running: false,
        timer: null,
    };
    state.enqueueAttempt = manualSwitch
        ? options.enqueueAttempt
        : bigWalletWire.genPrivateToken();
    bigWalletRequests.set(key, state);
    bigWalletRun(state);
    return state.initialResponse;
}

function bigWalletRun(state) {
    if (state.delivered || bigWalletRequests.get(state.key) !== state) {
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
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            admissionDeadline: state.admissionDeadline,
            subject: "message-to-wallet",
            message: state.message,
            host: state.host,
            configurationKey: state.configurationKey,
            enqueueAttempt: state.enqueueAttempt,
            ...(state.manualSwitch ? {manualSwitch: true} : {}),
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletIsCurrent(state, "enqueuing")) { return; }
    if (bigWalletWire.isNativeEnqueueAcknowledgement(response, state.message.id)) {
        state.requestToken = response.requestToken;
        state.revisions = response.revisions;
        state.phase = "waiting";
        state.resolveInitial(response);
        bigWalletSchedule(state, response.approvalRequired ? 1000 : 0);
        return;
    }
    if (bigWalletWire.isCorrelatedDappResponse(response, state.message.id)) {
        state.resolveInitial(response);
        bigWalletDeliver(state, response);
        return;
    }
    bigWalletSchedule(state, state.retryDelay);
    state.retryDelay = Math.min(state.retryDelay * 2, 5000);
}

async function bigWalletReadResponse(state) {
    let response;
    try {
        response = await bigWalletWire.withTimeout(browser.runtime.sendMessage({
            subject: "getResponse",
            id: state.message.id,
            configurationKey: state.configurationKey,
            requestToken: state.requestToken,
            revisions: state.revisions,
            workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletIsCurrent(state, "waiting")) { return; }
    if (bigWalletWire.hasExactKeys(response, ["id", "missing"]) &&
        response.id === state.message.id && response.missing === true) {
        bigWalletFail(state);
        return;
    }
    if (bigWalletWire.isCorrelatedDappResponse(response, state.message.id)) {
        bigWalletDeliver(state, response);
        return;
    }
    bigWalletSchedule(state, document.visibilityState === "visible" ? 1000 : 5000);
}

function bigWalletSchedule(state, delay) {
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
    const generationMismatch = state.generation !== bigWalletProviderGeneration;
    let delivery;
    if (generationMismatch &&
        Object.prototype.hasOwnProperty.call(response, "latestConfigurations")) {
        const prepared = {...response};
        delete prepared.latestConfigurations;
        delete prepared.revisions;
        delivery = {response: prepared, suppressProviderUpdate: true};
    } else {
        delivery = bigWalletConfigurationDelivery(
            response,
            state.configurationKey,
            state.generation,
            true
        );
    }
    const prepared = delivery.response;
    const suppress = generationMismatch || delivery.suppressProviderUpdate;
    const envelope = {
        direction: bigWalletContentDirection,
        kind: "response",
        response: prepared,
        id: state.message.id,
        providerGeneration: state.generation,
    };
    if (suppress) { envelope.suppressProviderUpdate = true; }
    window.postMessage(envelope, "*");
    bigWalletRequests.delete(state.key);
}

function bigWalletFail(state) {
    state.resolveInitial();
    bigWalletDeliverFailure(state.message, state.generation);
    clearTimeout(state.timer);
    bigWalletRequests.delete(state.key);
    state.delivered = true;
}

function bigWalletDeliverFailure(message, generation) {
    const response = {
        id: message.id,
        name: message.name,
        provider: message.provider,
        error: "Failed to communicate with Big Wallet",
        errorCode: -32603,
    };
    window.postMessage({
        direction: bigWalletContentDirection,
        kind: "response",
        response,
        id: message.id,
        providerGeneration: generation,
        suppressProviderUpdate: generation !== bigWalletProviderGeneration,
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
        response => bigWalletPostDisconnect(message, response, generation),
        () => bigWalletPostDisconnect(message, undefined, generation)
    );
}

function bigWalletPostDisconnect(message, response, generation) {
    if (typeof message.id === "undefined") {
        bigWalletLoadConfiguration(bigWalletProviderGeneration, 0);
        return;
    }
    const valid = bigWalletWire.isCorrelatedDappResponse(response, message.id) &&
        response.name === "revokePermissions" &&
        response.provider === message.provider;
    window.postMessage({
        direction: bigWalletContentDirection,
        kind: "response",
        response: valid ? response : {
            id: message.id,
            name: "revokePermissions",
            provider: message.provider,
            error: "Failed to revoke permissions",
            errorCode: -32603,
            revokeLocally: true,
        },
        id: message.id,
        providerGeneration: generation,
        suppressProviderUpdate: generation !== bigWalletProviderGeneration,
    }, "*");
}

async function bigWalletLoadConfiguration(generation, attempt) {
    if (!bigWalletMatchesGeneration(generation)) { return; }
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
    const delivery = typeof response !== "undefined" &&
        !response?.configurationReadFailed && identity
        ? bigWalletConfigurationDelivery(
            response,
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
    } else if (delivery?.ignored || bigWalletHasAcceptedConfiguration(
        generation,
        identity?.configurationKey
    )) {
        return;
    } else if (attempt < 2) {
        setTimeout(() => bigWalletLoadConfiguration(generation, attempt + 1),
            attempt === 0 ? 1000 : 5000);
    } else {
        window.postMessage({
            direction: bigWalletContentDirection,
            kind: "configurationError",
            providerGeneration: generation,
        }, "*");
    }
}

function bigWalletRuntimeMessage(
    request,
    sender,
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
    if (bigWalletWire.isConfigurationChanged(request)) {
        const identity = bigWalletCurrentIdentity();
        if (identity?.configurationKey === request.configurationKey &&
            typeof bigWalletProviderGeneration === "string") {
            const delivery = bigWalletConfigurationDelivery(
                request,
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
            if (state.phase === "waiting" && ids.includes(state.message.id)) {
                bigWalletSchedule(state, 0);
            }
        }
        sendResponse();
        return true;
    }
    if (request?.name === "switchAccount") {
        const identity = bigWalletCurrentIdentity();
        const message = request.message || {
            id: request.id,
            name: "switchAccount",
            provider: "unknown",
            body: request.body || {latestConfigurations: request.latestConfigurations || []},
        };
        if (request.expectedConfigurationKey !== identity?.configurationKey) {
            sendResponse();
            return true;
        }
        bigWalletEnqueue(message, bigWalletProviderGeneration, {
            admissionDeadline: request.admissionDeadline,
            enqueueAttempt: request.enqueueAttempt,
            manualSwitch: true,
        }).then(sendResponse, () => sendResponse());
        return true;
    }
    sendResponse();
    return true;
}

function bigWalletVisibilityChanged(event) {
    if (event?.isTrusted === false) { return; }
    if (document.visibilityState !== "visible") { return; }
    for (const state of bigWalletRequests.values()) {
        if (state.phase === "waiting") { bigWalletSchedule(state, 0); }
    }
    const generation = bigWalletProviderGeneration;
    const identity = bigWalletCurrentIdentity();
    if (bigWalletHasAcceptedConfiguration(
        generation,
        identity?.configurationKey
    )) {
        void bigWalletLoadConfiguration(generation, 0);
    }
}
