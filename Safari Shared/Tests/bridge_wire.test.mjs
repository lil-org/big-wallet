// ∅ 2026 lil org

import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import vm from "node:vm";
import {nativeResult, nativeError, normalized} from "./test_helpers.mjs";

const resourceURL = name => new URL(`../Resources/${name}`, import.meta.url);
const [source, nativeSource] = await Promise.all([
    readFile(resourceURL("bridge_wire.js"), "utf8"),
    readFile(new URL("../ExtensionBridge.swift", import.meta.url), "utf8"),
]);
const context = vm.createContext({
    URL,
    clearTimeout,
    crypto: webcrypto,
    setTimeout,
});
new vm.Script(source).runInContext(context);
const wire = context.BigWalletBridgeWire;
const token = "123e4567-e89b-12d3-a456-426614174000";
const attempt = "00000001000000020000000300000004";
const solanaPublicKey = "11111111111111111111111111111111";
const execFileAsync = promisify(execFile);

const pageState = {
    context: "a".repeat(64),
    revisions: {ethereum: 2, solana: 3},
    ethereum: {
        address: "0x0000000000000000000000000000000000000001",
        chainId: "0x1",
    },
    solana: {publicKey: solanaPublicKey},
};

test("decodes one canonical page contract without native response aliases", () => {
    const terminal = {
        id: 7, provider: "ethereum", name: "requestAccounts",
        state: pageState,
    };
    const responses = [
        {kind: "configuration", state: pageState},
        {kind: "configurationError", error: {code: 4900, message: "Unavailable"}},
        {...terminal, kind: "result", result: [pageState.ethereum.address], approvalCommitted: true},
        {...terminal, kind: "error", error: {code: 4100, message: "Changed", data: {reason: [1, null]}}},
        {...terminal, id: 8, provider: "solana", name: "signAllTransactions", state: null,
            kind: "result", result: ["signature"], approvalCommitted: false},
        {...terminal, name: null, state: null, kind: "result", result: {blocks: [1, 2]}, approvalCommitted: false},
    ];
    for (const response of responses) {
        const decoded = wire.decodePageResponse(response);
        assert.deepEqual(JSON.parse(JSON.stringify(decoded)), response);
        assert.notEqual(decoded, response);
        assert.equal(Object.isFrozen(decoded), true);
    }
    for (const response of [
        {id: 7, name: "requestAccounts", provider: "ethereum", results: []},
        {kind: "batchResult", ...terminal, results: []},
        {...responses[2], results: []},
        {...responses[2], approvalCommitted: undefined},
        {...responses[2], configurationMatch: true},
        {...responses[2], state: undefined},
        {...responses[3], authorizationFailure: false},
        {kind: "configuration", state: {...pageState, ethereum: null}},
        {kind: "configuration", state: {...pageState, solana: {...pageState.solana, isConnected: true}}},
        {...responses[3], error: {code: 4100, message: "Changed", errorCode: 4100}},
        {kind: "configuration", state: {...pageState, revisions: {ethereum: -1, solana: 3}}},
    ]) {
        assert.equal(wire.decodePageResponse(response), null);
    }
    assert.equal(wire.decodePageResponse(responses[2], 9), null);
    assert.ok(wire.decodePageResponse(responses[2], 7));
});

test("page decoding snapshots data and rejects accessors without invoking them", () => {
    const raw = {
        id: 7, provider: "ethereum", name: null, state: null,
        kind: "result", result: {items: [1, 2]}, approvalCommitted: false,
    };
    const decoded = wire.decodePageResponse(raw);
    raw.result.items[0] = 99;
    assert.equal(decoded.result.items[0], 1);
    let calls = 0;
    Object.defineProperty(raw.result, "items", {get() { calls += 1; return []; }});
    assert.equal(wire.decodePageResponse(raw), null);
    assert.equal(calls, 0);
    const cyclic = {};
    cyclic.self = cyclic;
    assert.equal(wire.decodePageResponse({...raw, result: cyclic}), null);
    assert.equal(wire.decodeConfigurationSnapshot({...pageState, ethereum: {...pageState.ethereum, results: []}}), null);
    assert.ok(wire.decodeConfigurationSnapshot(pageState));
});

test("page decoding retains captured reflection and avoids mutable array helpers", () => {
    const local = vm.createContext({URL, clearTimeout, crypto: webcrypto, setTimeout});
    new vm.Script(source).runInContext(local);
    local.input = {
        kind: "result", id: 7, provider: "ethereum", name: null, state: null,
        result: {values: [1, 2]}, approvalCommitted: false,
    };
    const decoded = vm.runInContext(`
        const fail = () => { throw new Error("mutated intrinsic"); };
        Object.keys = Object.getOwnPropertyDescriptor = Object.freeze = fail;
        Array.isArray = Array.from = Number.isSafeInteger = fail;
        Array.prototype.some = Array.prototype.includes = fail;
        Array.prototype[Symbol.iterator] = fail;
        BigWalletBridgeWire.decodePageResponse(input);
    `, local);
    assert.deepEqual(JSON.parse(JSON.stringify(decoded)), local.input);
});

test("combined page snapshots survive later Solana validator builtin changes", () => {
    for (const method of ["Array.prototype.push", "String.prototype.indexOf"]) {
        const local = vm.createContext({URL, clearTimeout, crypto: webcrypto, setTimeout});
        new vm.Script(source).runInContext(local);
        local.input = {kind: "configuration", state: {
            ...pageState,
            solana: {...pageState.solana, publicKey: "So11111111111111111111111111111111111111112"},
        }};
        const decoded = vm.runInContext(`
            ${method} = () => { throw new Error("mutated intrinsic"); };
            BigWalletBridgeWire.decodePageResponse(input);
        `, local);
        assert.deepEqual(JSON.parse(JSON.stringify(decoded)), local.input, method);
    }
});

const manifestPathForTarget = (project, targetName) => {
    const objects = project.objects;
    const targets = Object.values(objects).filter(object =>
        object.isa === "PBXNativeTarget" && object.name === targetName
    );
    assert.equal(targets.length, 1, `missing Xcode target ${targetName}`);
    const resourcePhaseIDs = targets[0].buildPhases.filter(id =>
        objects[id]?.isa === "PBXResourcesBuildPhase"
    );
    assert.equal(resourcePhaseIDs.length, 1,
        `${targetName} must have exactly one resource phase`);
    const manifestReferenceIDs = objects[resourcePhaseIDs[0]].files
        .map(buildFileID => objects[buildFileID]?.fileRef)
        .filter(fileReferenceID => objects[fileReferenceID]?.path === "manifest.json");
    assert.equal(manifestReferenceIDs.length, 1,
        `${targetName} must contain exactly one manifest.json`);
    const segments = [];
    let childID = manifestReferenceIDs[0];
    const visited = new Set();
    while (!visited.has(childID)) {
        visited.add(childID);
        const parents = Object.entries(objects).filter(([, object]) =>
            object.isa === "PBXGroup" && object.children?.includes(childID)
        );
        assert.ok(parents.length <= 1, `ambiguous Xcode group for ${childID}`);
        if (parents.length === 0) {
            break;
        }
        const [parentID, parent] = parents[0];
        const segment = parent.path ?? parent.name;
        if (segment) {
            segments.unshift(segment);
        }
        childID = parentID;
    }
    return [...segments, "manifest.json"].join("/");
};

test("publishes the small immutable workflow v4 contract", () => {
    assert.equal(Object.isFrozen(wire), true);
    assert.match(wire.BUILD_VERSION, /^.+\+[0-9]+$/);
    assert.equal(source.match(/const BUILD_VERSION = "[^"\n]+";/g)?.length, 1);
    assert.equal(wire.WORKFLOW_VERSION, 4);
    assert.equal(wire.PAGE_TO_CONTENT_DIRECTION, "big-wallet-provider-v1");
    assert.equal(wire.CONTENT_TO_PAGE_DIRECTION, "big-wallet-content-v1");
    assert.equal(wire.MANUAL_SWITCH_INTENT_SUBJECT, "manualSwitchIntent");
});

test("validates exact manual-switch acknowledgements", () => {
    const configurationKey = "https://wallet.example";
    const acknowledged = {
        approvalRequired: true,
        configurationKey,
        id: 31,
        requestToken: token,
        state: pageState,
        subject: wire.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
        workflowVersion: 4,
    };

    assert.equal(wire.isManualSwitchAcknowledgement(
        acknowledged, 31, configurationKey
    ), true);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, id: 32}, 31, configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, extra: true}, 31, configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, id: "31"}, "31", configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement({
        ...acknowledged,
        configurationKey: "invalid",
    }, 31, "invalid"), false);
});

test("requires substantive bounded manual-switch terminals", () => {
    const success = nativeResult({
        id: 31, name: "switchAccount", provider: "multiple", result: null,
        mutation: {kind: "accounts", updates: {
            ethereum: {address: "0x0000000000000000000000000000000000000001", chainId: "0x1"},
            solana: null,
        }},
    });
    const rejected = nativeError({
        id: 31, name: "switchAccount", provider: "multiple", error: {code: 4001, message: "Canceled"},
    });
    const empty = {...success};
    for (const response of [success, empty, rejected]) {
        assert.equal(wire.isManualSwitchTerminalResponse(response, 31), true);
    }
    for (const response of [
        {id: 31, name: "switchAccount"}, {...success, id: 32},
        {...success, name: "requestAccounts"}, {...success, provider: "unknown"},
        {...success, error: {code: 4001, message: "Canceled"}},
        {...success, mutation: null}, {...success, result: "invalid"},
        {...success, extra: true},
        {...success, mutation: {kind: "accounts", updates: {unknown: null}}},
        {...success, mutation: {kind: "accounts", updates: {ethereum: {address: "x", chainId: "invalid"}}}},
        {...rejected, error: {code: 1.5, message: "Canceled"}},
        {...rejected, error: {code: 4001, message: ""}},
        {...rejected, error: {code: 4001, message: "x".repeat(256 * 1024)}},
    ]) {
        assert.equal(wire.isManualSwitchTerminalResponse(response, 31), false);
    }
    assert.equal(wire.isManualSwitchTerminalResponse({...success, id: "31"}, "31"), false);
});

test("keeps workflow policy aligned with the native request authority", () => {
    const nativeNumber = name => Number(nativeSource.match(
        new RegExp(`static let ${name}(?:: [^=]+)? = ([0-9]+)`)
    )[1]);
    assert.equal(wire.WORKFLOW_VERSION,
        nativeNumber("workflowVersion"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRequests,
        nativeNumber("maximumRequests"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRequestsPerHost,
        nativeNumber("maximumRequestsPerHost"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRetainedRequests,
        nativeNumber("maximumRetainedRequests"));
    assert.equal(wire.WORKFLOW_POLICY.requestTTLMilliseconds, 15 * 60 * 1000);
    assert.equal(wire.WORKFLOW_POLICY.responseExpiryMilliseconds, 60 * 60 * 1000);

});

test("validates enqueue and response correlations", () => {
    const native = {
        id: 7,
        requestToken: token,
        admissionKind: "new",
        approvalRequired: true,
        state: pageState,
    };
    assert.equal(wire.isNativeEnqueueAcknowledgement(native, 7), true);
    for (const admissionKind of ["new", "replay", "coalesced"]) {
        assert.equal(wire.isNativeEnqueueAcknowledgement({...native, admissionKind}, 7), true);
    }
    for (const admissionKind of [undefined, null, "", "unknown", true]) {
        assert.equal(wire.isNativeEnqueueAcknowledgement({...native, admissionKind}, 7), false);
    }
    const missingKind = {...native};
    delete missingKind.admissionKind;
    assert.equal(wire.isNativeEnqueueAcknowledgement(missingKind, 7), false);
    assert.equal(wire.isNativeEnqueueAcknowledgement({...native, extra: true}, 7), false);
    assert.equal(wire.isNativeEnqueueAcknowledgement({
        ...native,
        revisions: {ethereum: 2, solana: -1},
    }, 7), false);
    const response = nativeResult({id: 7, name: "signMessage", provider: "ethereum", result: "ok"});
    assert.notEqual(wire.decodeNativeResponse(response, 7), null);
    assert.equal(wire.decodeNativeResponse(response, 8), null);
});

test("native authority versions require an exact context and nonnegative revisions", () => {
    const version = {context: "a".repeat(64), revisions: {ethereum: 1, solana: 2}};
    assert.equal(wire.isAuthorityVersion(version), true);
    for (const value of [{...version, context: "a".repeat(63)}, {...version, context: "A".repeat(64)},
        {...version, revisions: {ethereum: -1, solana: 0}}, {...version, profileIdentifier: "forged"},
        {...version, revisions: {ethereum: 1.5, solana: 0}}]) {
        assert.equal(wire.isAuthorityVersion(value), false);
    }
});

test("validates canonical Ethereum chains and 32-byte Solana keys", () => {
    assert.equal(wire.isCanonicalEthereumChainId("0x1"), true);
    assert.equal(wire.isCanonicalEthereumChainId("0x7fffffffffffffff"), true);
    assert.equal(wire.isCanonicalEthereumChainId("0x0"), false);
    assert.equal(wire.isCanonicalEthereumChainId("0x01"), false);
    assert.equal(wire.isCanonicalEthereumChainId("0x8000000000000000"), false);
    for (const publicKey of [solanaPublicKey, "public-key", `${solanaPublicKey}1`]) {
        assert.equal(wire.decodeConfigurationSnapshot({...pageState, solana: {publicKey}}) !== null, publicKey === solanaPublicKey);
    }
});

test("derives stable web and file configuration identities", () => {
    assert.deepEqual(
        JSON.parse(JSON.stringify(wire.configurationIdentityForURL(
            "https://wallet.example/path#fragment"
        ))),
        {
            host: "wallet.example",
            configurationKey: "https://wallet.example"
        }
    );
    assert.notEqual(
        wire.configurationIdentityForURL("http://wallet.example").configurationKey,
        wire.configurationIdentityForURL("https://wallet.example").configurationKey
    );
    assert.deepEqual(
        JSON.parse(JSON.stringify(wire.configurationIdentityForURL(
            "file:///tmp/dapp.html?profile=one#fragment"
        ))),
        {
            host: "file:///tmp/dapp.html",
            configurationKey: "file:///tmp/dapp.html"
        }
    );
});

const runtime = {
    id: "test-extension",
    getURL: path => `safari-web-extension://test-extension/${path}`,
};
const runtimeSenders = {
    content: {
        id: runtime.id,
        url: "https://wallet.example/path",
        frameId: 0,
        tab: {id: 4, url: "https://other.example", favIconUrl: "https://wallet.example/icon.png"},
    },
    popup: {id: runtime.id, url: runtime.getURL("popup.html")},
    worker: {id: runtime.id, url: runtime.getURL("")},
};

test("runtime sender policy permits only the complete sender receiver subject matrix", () => {
    const allowed = new Set([
        "content:worker:rpc",
        "content:worker:message-to-wallet",
        "content:worker:manualSwitchIntent",
        "content:worker:getResponse",
        "content:worker:consumeResponse",
        "content:worker:getLatestConfiguration",
        "content:worker:disconnect",

        "popup:worker:applyCompletedResponse",
        "popup:worker:getLatestConfiguration",
        "popup:worker:updatePendingRequestBadge",
        "popup:worker:responseReady",
        "worker:content:workflowProbe",
        "worker:content:manualSwitchIntent",
        "worker:content:configurationInvalidated",
        "worker:content:responseReady",

        "popup:content:workflowProbe",
        "popup:content:manualSwitchIntent",
        "worker:popup:pendingRequestAvailable",
    ]);
    const subjects = new Set([
        ...[...allowed].map(entry => entry.split(":")[2]),
        "executeNativeApproval", "getExecutionStatus", "maintainRequest", "prepareResponseDelivery",
        "unknown", "constructor", "__proto__", "toString", "hasOwnProperty", "",
    ]);
    for (const [kind, sender] of Object.entries(runtimeSenders)) {
        for (const receiver of ["worker", "content", "popup", "unknown", "__proto__", "constructor", "toString"]) {
            for (const subject of subjects) {
                const key = `${kind}:${receiver}:${subject}`;
                const result = wire.authorizeRuntimeMessage(receiver, {subject}, sender, runtime);
                assert.equal(result !== null, allowed.has(key), key);
                if (result) { assert.equal(result.kind, kind, key); }
            }
        }
    }
});

test("runtime authorization recognizes Safari worker roots without widening sender authority", () => {
    const root = runtime.getURL("");
    const commands = [
        ["content", "workflowProbe"],
        ["content", "manualSwitchIntent"],
        ["content", "configurationInvalidated"],
        ["content", "responseReady"],

        ["popup", "pendingRequestAvailable"],
    ];
    for (const url of [root, root.replace(/\/$/, ""), runtime.getURL("service_worker.js")]) {
        const sender = {id: runtime.id, url};
        for (const [receiver, subject] of commands) {
            assert.equal(wire.authorizeRuntimeMessage(receiver, {subject}, sender, runtime)?.kind, "worker", url);
            assert.equal(wire.authorizeRuntimeMessage(receiver, {subject}, {...sender, id: "foreign"}, runtime), null);
            assert.equal(wire.authorizeRuntimeMessage(receiver, {subject}, {...sender, tab: {id: 1}, frameId: 0}, runtime), null);
        }
        assert.equal(wire.authorizeRuntimeMessage("worker", {subject: "approveRequestWithCurrentRevisions"}, sender, runtime), null);
        assert.equal(wire.authorizeRuntimeMessage("content", {subject: "rpc"}, sender, runtime), null);
    }
    for (const url of [
        `${root}?`, `${root}#`, `${root}?query=1`, `${root}#fragment`,
        `${root}/`, `${root}other.html`, `${root}service_worker.js?query=1`,
        root.replace(/\/$/, "?"), root.replace(/\/$/, "#"),
        root.replace("test-extension", "foreign-extension"),
        root.replace("://", "://user@"),
        root.replace("safari-web-extension:", "https:"),
    ]) {
        for (const [receiver, subject] of commands) {
            assert.equal(wire.authorizeRuntimeMessage(receiver, {subject}, {id: runtime.id, url}, runtime), null, url);
        }
    }
});

test("runtime authorization snapshots identity exclusively from the content sender URL", () => {
    for (const [url, expected] of [
        ["https://Wallet.Example:443/path?query=1#fragment", {
            host: "wallet.example", configurationKey: "https://wallet.example"
        }],
        ["http://wallet.example:8080/path", {
            host: "wallet.example:8080", configurationKey: "http://wallet.example:8080"
        }],
        ["file:///tmp/dapp.html?query=1#fragment", {
            host: "file:///tmp/dapp.html", configurationKey: "file:///tmp/dapp.html"
        }],
    ]) {
        const sender = {...runtimeSenders.content, url, tab: {...runtimeSenders.content.tab}};
        const request = {subject: "getResponse", origin: "https://spoofed.example", configurationKey: "https://spoofed.example"};
        const result = wire.authorizeRuntimeMessage("worker", request, sender, runtime);
        assert.deepEqual(normalized(result), {
            kind: "content", identity: expected, privateBrowsing: false, tabId: 4,
            favicon: "https://wallet.example/icon.png",
        });
        assert.equal(Object.isFrozen(result), true);
        assert.equal(Object.isFrozen(result.identity), true);
        sender.url = "https://changed.example";
        sender.tab.id = 99;
        sender.tab.favIconUrl = "changed";
        request.origin = "https://changed.example";
        assert.deepEqual(normalized(result.identity), expected);
        assert.equal(result.tabId, 4);
        assert.equal(result.favicon, "https://wallet.example/icon.png");
    }
});

test("runtime authorization retains only browser supplied privacy and optional favicon", () => {
    for (const tabIncognito of [undefined, false, true, "true"]) {
        for (const incognito of [undefined, false, true, "true"]) {
            const sender = {...runtimeSenders.content, incognito, tab: {id: 0, incognito: tabIncognito}};
            const result = wire.authorizeRuntimeMessage("worker", {
                subject: "getLatestConfiguration", incognito: true, __bwPrivateBrowsing: true,
            }, sender, runtime);
            assert.equal(result.privateBrowsing, tabIncognito === true || incognito === true);
            assert.equal(result.tabId, 0);
            assert.equal(result.favicon, null);
        }
    }
    for (const kind of ["popup", "worker"]) {
        const receiver = kind === "popup" ? "worker" : "content";
        const subject = kind === "popup" ? "getLatestConfiguration" : "workflowProbe";
        const result = wire.authorizeRuntimeMessage(receiver, {subject}, {
            ...runtimeSenders[kind], incognito: true,
        }, runtime);
        assert.deepEqual(normalized(result), {kind, identity: null, privateBrowsing: true, tabId: null, favicon: null});
        assert.equal(Object.isFrozen(result), true);
    }
});

test("runtime authorization rejects missing foreign or malformed sender metadata", () => {
    const valid = runtimeSenders.content;
    for (const sender of [
        null, undefined, [], "content", {},
        {...valid, id: undefined}, {...valid, id: ""}, {...valid, id: "foreign-extension"},
        {...valid, url: undefined}, {...valid, url: null}, {...valid, url: ""},
        {...valid, url: "not a URL"}, {...valid, url: "data:text/html,hello"},
        {...valid, url: "javascript:void(0)"}, {...valid, url: "about:blank"},
        {...valid, url: "blob:https://wallet.example/token"},
        {...valid, url: "ftp://wallet.example"}, {...valid, url: runtime.getURL("popup.html")},
        {...valid, frameId: undefined}, {...valid, frameId: null}, {...valid, frameId: 1},
        {...valid, frameId: -1}, {...valid, frameId: "0"},
        {...valid, tab: undefined}, {...valid, tab: null}, {...valid, tab: []},
        {...valid, tab: {}}, {...valid, tab: {id: -1}}, {...valid, tab: {id: "4"}},
        {...valid, tab: {id: 0.5}}, {...valid, tab: {id: Infinity}},
        {...valid, tab: {id: Number.MAX_SAFE_INTEGER + 1}},
        Object.create(valid),
        Object.assign(Object.create({tab: valid.tab}), {id: valid.id, url: valid.url, frameId: 0}),
        {...valid, tab: Object.create({id: 4})},
    ]) {
        assert.equal(wire.authorizeRuntimeMessage("worker", {subject: "getResponse"}, sender, runtime), null);
    }
    for (const kind of ["popup", "worker"]) {
        const receiver = kind === "popup" ? "worker" : "popup";
        const subject = kind === "popup" ? "responseReady" : "pendingRequestAvailable";
        for (const sender of [
            {...runtimeSenders[kind], url: `${runtimeSenders[kind].url}?query=1`},
            {...runtimeSenders[kind], url: `${runtimeSenders[kind].url}#fragment`},
            {...runtimeSenders[kind], url: `${runtimeSenders[kind].url}/extra`},
            {...runtimeSenders[kind], url: runtime.getURL("unknown.html")},
            {...runtimeSenders[kind], url: runtimeSenders[kind].url.replace("test-extension", "foreign-extension")},
            {...runtimeSenders[kind], url: `https://wallet.example/${kind === "popup" ? "popup.html" : "service_worker.js"}`},
            {...runtimeSenders[kind], tab: {id: 4}, frameId: 0},
            {...runtimeSenders[kind], tab: null},
        ]) {
            assert.equal(wire.authorizeRuntimeMessage(receiver, {subject}, sender, runtime), null);
        }
    }
});

test("runtime authorization denies malformed requests and unavailable runtime identity", () => {
    for (const request of [null, undefined, [], "rpc", {}, {subject: null}, {subject: 1}, Object.create({subject: "rpc"})]) {
        assert.equal(wire.authorizeRuntimeMessage("worker", request, runtimeSenders.content, runtime), null);
    }
    for (const receiver of [null, undefined, [], {}, 1]) {
        assert.equal(wire.authorizeRuntimeMessage(receiver, {subject: "rpc"}, runtimeSenders.content, runtime), null);
    }
    for (const invalidRuntime of [null, undefined, {}, {...runtime, id: ""}, {...runtime, id: 1}, {...runtime, id: "foreign-extension"}]) {
        assert.equal(wire.authorizeRuntimeMessage("worker", {subject: "rpc"}, runtimeSenders.content, invalidRuntime), null);
    }
    assert.equal(wire.authorizeRuntimeMessage("worker", {subject: "responseReady"}, runtimeSenders.popup, {id: runtime.id}), null);
});

test("runtime authorization fails closed on accessors and runtime failures", () => {
    const fail = () => { throw new Error("unavailable metadata"); };
    const request = {subject: "rpc"};
    const sender = runtimeSenders.content;
    for (const field of ["id", "url", "tab", "frameId", "incognito"]) {
        const hostileSender = {...sender};
        Object.defineProperty(hostileSender, field, {get: fail});
        assert.equal(wire.authorizeRuntimeMessage("worker", request, hostileSender, runtime), null);
    }
    for (const field of ["id", "incognito", "favIconUrl"]) {
        const tab = {...sender.tab};
        Object.defineProperty(tab, field, {get: fail});
        assert.equal(wire.authorizeRuntimeMessage("worker", request, {...sender, tab}, runtime), null);
    }
    const hostileRequest = Object.defineProperty({}, "subject", {get: fail});
    assert.equal(wire.authorizeRuntimeMessage("worker", hostileRequest, sender, runtime), null);
    assert.equal(wire.authorizeRuntimeMessage("worker", request, sender, {get id() { throw new Error("unavailable"); }}), null);
    assert.equal(wire.authorizeRuntimeMessage("worker", {subject: "responseReady"}, runtimeSenders.popup, {...runtime, getURL: fail}), null);
    assert.equal(wire.authorizeRuntimeMessage("worker", request, new Proxy(sender, {getOwnPropertyDescriptor: fail}), runtime), null);
});

test("normalizes bounded response-ready wake hints", () => {
    assert.deepEqual(
        [...wire.responseReadyIds({
            subject: "responseReady",
            ids: [1, 1, 2],
            workflowVersion: 4,
        })],
        [1, 2]
    );
    assert.equal(wire.responseReadyIds({
        subject: "responseReady",
        ids: [],
        workflowVersion: 4,
    }), null);
});

test("validates exact passive configuration notifications", () => {
    const notification = {
        subject: "configurationInvalidated", configurationKey: "https://wallet.example",
        workflowVersion: 4,
    };
    assert.equal(wire.isConfigurationInvalidated(notification), true);
    assert.equal(wire.isConfigurationInvalidated({...notification, extra: true}), false);
    assert.equal(wire.isConfigurationInvalidated({...notification, state: undefined}), false);
    assert.equal(wire.isConfigurationInvalidated({
        ...notification, state: {...pageState, revisions: {ethereum: -1, solana: 0}},
    }), false);
});

test("stamps private context on the real first native message", async () => {
    const messages = [];
    const send = wire.createTrustedNativeMessageSender({
        sendRawNativeMessage(message) {
            messages.push(JSON.parse(JSON.stringify(message)));
            return {id: message.id, result: true};
        },
    });
    await send({subject: "rpc", id: 1}, false);
    await send({subject: "rpc", id: 2}, true);
    assert.equal(messages.length, 2);
    assert.equal(messages[0].subject, "rpc");
    assert.equal(messages[0].__bwPrivateBrowsing, false);
    assert.equal(messages[1].__bwPrivateBrowsing, true);
});

test("keeps the real platform manifests on their intended MV3 routes", async () => {
    const projectPath = fileURLToPath(
        new URL("../../Wallet.xcodeproj/project.pbxproj", import.meta.url)
    );
    const [sharedManifest, macManifest, projectResult] = await Promise.all([
        readFile(resourceURL("manifest.json"), "utf8").then(JSON.parse),
        readFile(new URL("../../Safari macOS/Resources/manifest.json", import.meta.url), "utf8")
            .then(JSON.parse),
        execFileAsync("/usr/bin/plutil", ["-convert", "json", "-o", "-", projectPath], {
            encoding: "utf8",
        }),
    ]);
    const project = JSON.parse(projectResult.stdout);
    for (const manifest of [sharedManifest, macManifest]) {
        assert.equal(manifest.manifest_version, 3);
        assert.deepEqual(manifest.content_security_policy, {
            extension_pages: "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; worker-src 'self'; img-src 'self' data:; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        });
        assert.equal(manifest.background.service_worker, "service_worker.js");
        assert.deepEqual(manifest.content_scripts[0].js, ["bridge_wire.js", "content.js"]);
        assert.equal(manifest.action.default_icon["16"], "images/toolbar-icon-16.png");
    }
    assert.equal(sharedManifest.action.default_popup, "popup.html");
    assert.equal(Object.hasOwn(macManifest.action, "default_popup"), false);
    assert.equal(manifestPathForTarget(project, "Safari macOS"),
        "Safari macOS/Resources/manifest.json");
    assert.equal(manifestPathForTarget(project, "Safari iOS"),
        "Safari Shared/Resources/manifest.json");
    assert.equal(manifestPathForTarget(project, "Safari visionOS"),
        "Safari Shared/Resources/manifest.json");
});

test("native responses match the shared Swift contract", async () => {
    const fixtures = JSON.parse(await readFile(new URL("./fixtures/native_response_contract.json", import.meta.url), "utf8"));
    for (const {name, response} of fixtures.valid) {
        assert.deepEqual(normalized(wire.decodeNativeResponse(response, response.id)), response, name);
    }
    for (const {name, response} of fixtures.invalid) {
        assert.equal(wire.decodeNativeResponse(response), null, name);
    }
});
