import test from "node:test";
import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, readFile, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import vm from "node:vm";

const execute = promisify(execFile);
const instrumenter = fileURLToPath(new URL("../instrument_worker.py", import.meta.url));
const resources = new URL("../../../Safari Shared/Resources/", import.meta.url);
const source = await readFile(new URL("service_worker.js", resources), "utf8");
const dependencies = Object.fromEntries(await Promise.all(["protocol.generated.js", "bridge_wire.js"].map(async name =>
    [name, new vm.Script(await readFile(new URL(name, resources), "utf8"), {filename: name})])));
const normalized = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const secret = "DO_NOT_CAPTURE";
const extensionID = `extension-${secret}`;
const origin = `https://private-${secret.toLowerCase()}.invalid`;
const now = 1_700_000_000_000;
const state = {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0},
    ethereum: {address: "", chainId: "0x1"}, solana: null};
const diagnosticRequest = () => ({subject: "safariVMConfigurationDiagnostics"});
const configurationRequest = () => ({subject: "getLatestConfiguration", workflowVersion: 4, documentSession: "0123456789abcdef0123456789abcdef"});
const sender = overrides => ({id: extensionID, url: `${origin}/?token=${secret}`, origin,
    tab: {id: 39, incognito: false}, frameId: 0, documentId: `document-${secret}`, ...overrides});

async function fixture(context) {
    const root = await mkdtemp(join(tmpdir(), "safari-worker-diagnostic-"));
    context.after(() => rm(root, {recursive: true, force: true}));
    const input = join(root, "source.js"), output = join(root, "service_worker.js");
    await writeFile(input, source);
    await writeFile(output, "unchanged");
    const run = mode => execute("/usr/bin/python3", [instrumenter, input, output, mode]);
    await run("fixture");
    return {root, input, output, run, instrumented: await readFile(output, "utf8")};
}

async function settle() {
    for (let index = 0; index < 40; index++) { await Promise.resolve(); }
}

function harness(text, {native = message => ({id: message.id, state}), decode, nativeContext,
    authorize, dateNow = () => now} = {}) {
    const calls = {authorize: 0, decode: 0, context: 0, runtime: [], native: [], tabs: [], timers: []};
    let listener;
    const browser = {
        extension: {},
        runtime: {
            id: extensionID,
            getManifest() { return {action: {default_popup: "popup.html"}}; },
            getURL(path) { return `safari-web-extension://${extensionID}/${path}`; },
            onMessage: {addListener(value) { listener = value; }},
            sendNativeMessage(application, message) {
                calls.native.push({application, message: normalized(message)});
                return native(message);
            },
            sendMessage(message) { calls.runtime.push(normalized(message)); return Promise.resolve(); },
        },
        tabs: {query(value) { calls.tabs.push(normalized(value)); return Promise.resolve([]); }},
        i18n: {getMessage() { return ""; }},
    };
    class FixedDate extends Date { static now() { return dateNow(); } }
    const context = vm.createContext({browser, URL, Date: FixedDate,
        Math: Object.assign(Object.create(Math), {random: () => 0}),
        importScripts(...names) {
            for (const name of names) { dependencies[name].runInContext(context); }
            const wire = context.BigWalletBridgeWire;
            context.BigWalletBridgeWire = {...wire,
                authorizeRuntimeMessage(...args) {
                    calls.authorize++;
                    return authorize ? authorize(...args) : wire.authorizeRuntimeMessage(...args);
                },
                decodeMessage(...args) {
                    calls.decode++;
                    return decode ? decode(...args) : wire.decodeMessage(...args);
                },
                runtimeNativeContext(...args) {
                    calls.context++;
                    return nativeContext ? nativeContext(...args) : wire.runtimeNativeContext(...args);
                },
            };
        },
        setTimeout(callback, delay) {
            const timer = {callback, delay, cancelled: false};
            calls.timers.push(timer);
            return timer;
        },
        clearTimeout(timer) { timer.cancelled = true; },
    });
    new vm.Script(text).runInContext(context);
    return {
        context, calls, browser,
        call: code => vm.runInContext(code, context),
        start(request = configurationRequest(), from = sender()) {
            const callbacks = [];
            const returned = listener(request, from, function (...args) { callbacks.push(args); });
            return {returned, callbacks};
        },
        async dispatch(request = configurationRequest(), from = sender()) {
            const result = this.start(request, from);
            await settle();
            return result;
        },
        dump(from = sender(), request = diagnosticRequest()) {
            const result = this.start(request, from);
            assert.equal(result.returned, false);
            assert.equal(result.callbacks.length, 1);
            assert.equal(result.callbacks[0].length, 1);
            return normalized(result.callbacks[0][0]);
        },
        snapshot() {
            return {...calls, timers: calls.timers.map(({delay, cancelled}) => ({delay, cancelled}))};
        },
    };
}

function assertRecord(record, changes = {}) {
    assert.deepEqual(record, {sequence: 1, at: now, authorized: true, idMatches: true,
        idType: "string", urlType: "string", tabType: "object", tabIDValid: true, frameIDValid: true, topFrame: true,
        documentIDType: "string", documentIDValid: true, originType: "string", originMatches: true,
        senderPrivacyType: "undefined", senderPrivacy: "unknown", tabPrivacyType: "boolean", tabPrivacy: "normal",
        requestValid: true, contextPrivacy: "normal",
        outcome: "response", responseArgumentCount: 1, responseType: "object", responseKind: "configuration", ...changes});
}

test("worker diagnostics preserve configuration authority, privacy, decode, native calls, and timers", async context => {
    const {instrumented} = await fixture(context);
    const cases = [
        {name: "normal", response: {kind: "configuration", state}, native: 1},
        {name: "private tab", from: sender({tab: {id: 39, incognito: true}}), error: 4200,
            record: {tabPrivacy: "private", contextPrivacy: "private", responseKind: "configurationError"}},
        {name: "private sender", from: sender({incognito: true}), error: 4200,
            record: {senderPrivacyType: "boolean", senderPrivacy: "private", contextPrivacy: "private", responseKind: "configurationError"}},
        {name: "explicit normal", from: sender({incognito: false}), response: {kind: "configuration", state}, native: 1,
            record: {senderPrivacyType: "boolean", senderPrivacy: "normal"}},
        {name: "unknown privacy", from: sender({tab: {id: 39}}), error: 4900,
            record: {tabPrivacyType: "undefined", tabPrivacy: "unknown", contextPrivacy: "unavailable", responseKind: "configurationError"}},
        {name: "invalid tab privacy", from: sender({tab: {id: 39, incognito: secret}}), error: 4900,
            record: {tabPrivacyType: "string", tabPrivacy: "unknown", contextPrivacy: "unavailable", responseKind: "configurationError"}},
        {name: "invalid sender privacy", from: sender({incognito: secret}), rejected: true,
            record: {authorized: false, senderPrivacyType: "string", requestValid: null, contextPrivacy: "unobserved",
                outcome: "authorization-rejected", responseArgumentCount: null, responseType: null, responseKind: null}},
        {name: "authorization rejected", from: sender({origin: "https://different.invalid"}), rejected: true,
            record: {authorized: false, originMatches: false, requestValid: null, contextPrivacy: "unobserved",
                outcome: "authorization-rejected", responseArgumentCount: null, responseType: null, responseKind: null}},
        {name: "decode null", request: {...configurationRequest(), workflowVersion: -1, payload: secret},
            record: {requestValid: false, contextPrivacy: "unobserved", responseType: "undefined", responseKind: "missing"}},
        {name: "context unavailable", options: {nativeContext: () => null}, error: 4900,
            record: {contextPrivacy: "unavailable", responseKind: "configurationError"}},
        {name: "decode throws", options: {decode: () => { throw new Error(secret); }}, thrown: true,
            record: {requestValid: null, contextPrivacy: "unobserved", outcome: "thrown",
                responseArgumentCount: 0, responseType: null, responseKind: null}},
        {name: "context throws", options: {nativeContext: () => { throw new Error(secret); }}, thrown: true,
            record: {contextPrivacy: "unobserved", outcome: "thrown", responseArgumentCount: 0, responseType: null, responseKind: null}},
        {name: "native throws", options: {native: () => { throw new Error(secret); }}, error: 4900, native: 1,
            record: {responseKind: "configurationError"}},
        {name: "native rejects", options: {native: () => Promise.reject(new Error(secret))}, error: 4900, native: 1,
            record: {responseKind: "configurationError"}},
    ];
    for (const value of cases) {
        const original = harness(source, value.options), diagnostic = harness(instrumented, value.options);
        const expected = await original.dispatch(value.request, value.from);
        const actual = await diagnostic.dispatch(value.request, value.from);
        assert.deepEqual(normalized(actual), normalized(expected), value.name);
        assert.deepEqual(diagnostic.snapshot(), original.snapshot(), value.name);
        assert.equal(actual.returned, !value.rejected, value.name);
        assert.equal(actual.callbacks.length, value.rejected ? 0 : 1, value.name);
        if (!value.rejected) { assert.equal(actual.callbacks[0].length, value.thrown ? 0 : 1, value.name); }
        if (value.response) { assert.deepEqual(normalized(actual.callbacks[0][0]), value.response, value.name); }
        if (value.error) { assert.equal(actual.callbacks[0][0].error.code, value.error, value.name); }
        assert.equal(diagnostic.calls.authorize, 1, value.name);
        assert.equal(diagnostic.calls.native.length, value.native ?? 0, value.name);
        const beforeDump = diagnostic.snapshot();
        const dump = diagnostic.dump();
        assert.deepEqual(diagnostic.snapshot(), beforeDump);
        assert.deepEqual({...dump, records: []}, {kind: "safariVMConfigurationDiagnostics", version: 1,
            status: "ok", startedAt: now, dropped: false,
            query: {idMatches: true, tabIDValid: true, frameIDValid: true, documentIDValid: true}, records: []});
        assert.equal(dump.records.length, 1, value.name);
        assertRecord(dump.records[0], value.record);
        assert.doesNotMatch(JSON.stringify(dump), /DO_NOT_CAPTURE|https:|document-|extension-|token|payload/);
    }
});

test("pending reads and nonconfiguration requests preserve listener claims and callbacks", async context => {
    const {instrumented} = await fixture(context);
    const original = harness(source, {native: () => new Promise(() => {})});
    const diagnostic = harness(instrumented, {native: () => new Promise(() => {})});
    assert.deepEqual(diagnostic.start(), original.start());
    assert.deepEqual(diagnostic.snapshot(), original.snapshot());
    assertRecord(diagnostic.dump().records[0], {outcome: "pending", responseArgumentCount: null,
        responseType: null, responseKind: null});
    for (const instance of [original, diagnostic]) {
        instance.calls.timers[0].callback();
        await settle();
    }
    assert.deepEqual(diagnostic.snapshot(), original.snapshot());
    assert.equal(diagnostic.dump().records[0].responseKind, "configurationError");

    const clean = harness(instrumented);
    for (const request of [null, {}, {subject: "unknown"}, {subject: "getResponse", id: 1}]) {
        const original = harness(source);
        assert.deepEqual(normalized(await clean.dispatch(request)), normalized(await original.dispatch(request)));
        assert.deepEqual(clean.dump().records, []);
    }
    const direct = harness(instrumented);
    const response = await direct.call(`handleMessage({subject: 'getLatestConfiguration', workflowVersion: 4, documentSession: '0123456789abcdef0123456789abcdef'},
        {kind: 'content', privacy: 'private', identity: {host: 'fixture.invalid', configurationKey: 'https://fixture.invalid'},
        document: {tabId: 39, frameId: 0}})`);
    assert.equal(response.error.code, 4200);
    assert.deepEqual(direct.dump().records, []);
});

test("worker diagnostic queries are synchronous, scope exact, and never use runtime authorization or transport", async context => {
    const {instrumented} = await fixture(context);
    const instance = harness(instrumented);
    for (const from of [sender(), sender({documentId: "different-document"}),
        sender({tab: {id: 40, incognito: false}}), sender({frameId: 1})]) {
        await instance.dispatch(configurationRequest(), from);
    }
    const calls = instance.snapshot();
    for (const [from, sequence, authorized] of [[sender(), 1, true], [sender({documentId: "different-document"}), 2, true],
        [sender({tab: {id: 40, incognito: false}}), 3, true], [sender({frameId: 1}), 4, false]]) {
        const dump = instance.dump(from);
        assert.equal(dump.status, "ok");
        assert.equal(dump.records.length, 1);
        assert.equal(dump.records[0].sequence, sequence);
        assert.equal(dump.records[0].authorized, authorized);
        assert.equal(dump.records[0].topFrame, from.frameId === 0);
    }
    assert.deepEqual(instance.dump(sender({documentId: "unobserved-document"})).records, []);
    const malformed = [
        sender({id: "wrong-extension"}), sender({id: ""}), sender({id: undefined}),
        sender({tab: undefined}), sender({tab: {id: -1}}), sender({tab: {id: 1.5}}),
        sender({tab: {id: Number.MAX_SAFE_INTEGER + 1}}),
        sender({frameId: undefined}), sender({frameId: -1}), sender({frameId: NaN}), sender({frameId: 0.5}),
        sender({documentId: undefined}), sender({documentId: ""}), sender({documentId: "x".repeat(129)}),
        sender({documentId: 3}), Object.create(sender()),
    ];
    for (const from of malformed) {
        const dump = instance.dump(from);
        assert.equal(dump.status, "rejected");
        assert.deepEqual(dump.records, []);
    }
    assert.deepEqual(instance.snapshot(), calls);
    for (const request of [{...diagnosticRequest(), extra: true},
        {...diagnosticRequest(), [Symbol(secret)]: true}, Object.create(diagnosticRequest()),
        ["safariVMConfigurationDiagnostics"]]) {
        const result = await instance.dispatch(request);
        assert.equal(result.returned, false);
        assert.deepEqual(result.callbacks, []);
    }
    const unavailable = harness(instrumented);
    delete unavailable.browser.runtime.id;
    assert.equal(unavailable.dump().status, "rejected");
});

test("worker diagnostic scope supports Safari runtime ID accessors and does not require configuration authority", async context => {
    const {instrumented} = await fixture(context);
    for (const text of [source, instrumented]) {
        const instance = harness(text);
        let runtimeIDReads = 0;
        Object.defineProperty(instance.browser.runtime, "id", {get() { runtimeIDReads++; return extensionID; }});
        const result = await instance.dispatch();
        assert.equal(result.returned, true);
        assert.deepEqual(normalized(result.callbacks[0][0]), {kind: "configuration", state});
        assert.equal(instance.calls.authorize, 1);
        assert.equal(instance.calls.native.length, 1);
        if (text === instrumented) {
            assert.equal(instance.dump().status, "ok");
            const scoped = sender({url: undefined, origin: undefined, incognito: secret});
            assert.equal(instance.dump(scoped).records.length, 1);
            const rejected = await instance.dispatch(configurationRequest(), scoped);
            assert.equal(rejected.returned, false);
            assert.equal(instance.dump(scoped).records.at(-1).authorized, false);
            assert.equal(instance.calls.native.length, 1);
        }
        assert.ok(runtimeIDReads > 0);
    }
    for (const documentId of [undefined, "", "x".repeat(129)]) {
        const original = harness(source), diagnostic = harness(instrumented);
        const from = sender({documentId});
        assert.deepEqual(normalized(await diagnostic.dispatch(configurationRequest(), from)),
            normalized(await original.dispatch(configurationRequest(), from)));
        assert.deepEqual(diagnostic.snapshot(), original.snapshot());
        assert.equal(diagnostic.dump(from).status, "rejected");
        assert.deepEqual(diagnostic.dump().records, []);
    }
    const unavailable = harness(instrumented);
    Object.defineProperty(unavailable.browser.runtime, "id", {get() { throw new Error(secret); }});
    assert.equal(unavailable.dump().status, "rejected");
    assert.deepEqual(unavailable.dump().records, []);
});

test("worker diagnostics retain at most twelve records and report eviction without retaining raw metadata", async context => {
    const {instrumented} = await fixture(context);
    const instance = harness(instrumented);
    for (let index = 0; index < 30; index++) { await instance.dispatch(); }
    const dump = instance.dump();
    assert.equal(dump.dropped, true);
    assert.equal(dump.records.length, 12);
    assert.equal(dump.records[0].sequence, 19);
    assert.equal(dump.records.at(-1).sequence, 30);
    assert.ok(JSON.stringify(dump).length < 8000);
    assert.doesNotMatch(JSON.stringify(dump), /DO_NOT_CAPTURE|private-|document-|extension-|token|payload/);
    assert.deepEqual(instance.dump(), dump);
    assert.deepEqual(harness(instrumented).dump().records, []);
    for (const invalidTime of [-1, Infinity, NaN, 1.1, Number.MAX_SAFE_INTEGER + 1]) {
        const invalidClock = harness(instrumented, {dateNow: () => invalidTime});
        await invalidClock.dispatch(configurationRequest(), sender({origin: "invalid"}));
        assert.equal(invalidClock.dump().startedAt, 0);
        assert.equal(invalidClock.dump().records[0].at, 0);
    }
});

test("worker diagnostics read data descriptors without invoking getters or retaining arbitrary response kinds", async context => {
    const {instrumented} = await fixture(context);
    let reads = 0;
    const accessor = {get() { reads++; throw new Error(secret); }, enumerable: true, configurable: true};
    for (const property of ["id", "url", "origin", "incognito", "tab", "frameId", "documentId"]) {
        const from = sender();
        Object.defineProperty(from, property, accessor);
        const original = harness(source), diagnostic = harness(instrumented);
        assert.deepEqual(normalized(await diagnostic.dispatch(configurationRequest(), from)),
            normalized(await original.dispatch(configurationRequest(), from)));
        assert.deepEqual(diagnostic.snapshot(), original.snapshot());
        diagnostic.dump(from);
        assert.equal(reads, 0);
    }
    for (const property of ["id", "incognito"]) {
        const from = sender();
        Object.defineProperty(from.tab, property, accessor);
        const instance = harness(instrumented);
        await instance.dispatch(configurationRequest(), from);
        instance.dump(from);
        assert.equal(reads, 0);
    }
    const request = Object.defineProperty({}, "subject", accessor);
    const instance = harness(instrumented);
    assert.deepEqual((await instance.dispatch(request)).callbacks, []);
    const payload = Object.defineProperty(configurationRequest(), "payload", accessor);
    assert.equal((await instance.dispatch(payload)).callbacks[0].length, 1);
    assert.equal(instance.dump().records[0].requestValid, false);
    assert.equal(reads, 0);
    for (const [response, responseType, responseKind] of [[undefined, "undefined", "missing"], [null, "null", "missing"],
        [42, "number", "missing"], [[], "array", "missing"], [{kind: secret, payload: secret}, "object", "other"],
        [Object.defineProperty({}, "kind", accessor), "object", "other"], [{kind: "result"}, "object", "result"]]) {
        const original = harness(source), diagnostic = harness(instrumented);
        for (const item of [original, diagnostic]) {
            item.context.injectedResponse = response;
            item.call("handleMessage = async () => injectedResponse");
        }
        const actual = await diagnostic.dispatch(), expected = await original.dispatch();
        assert.equal(actual.returned, expected.returned);
        assert.equal(actual.callbacks[0].length, 1);
        assert.equal(actual.callbacks[0][0], expected.callbacks[0][0]);
        assert.equal(actual.callbacks[0][0], response);
        assert.deepEqual(diagnostic.snapshot(), original.snapshot());
        assertRecord(diagnostic.dump().records[0], {requestValid: null, contextPrivacy: "unobserved", responseType, responseKind});
        assert.equal(reads, 0);
    }
    const metadata = harness(instrumented);
    await metadata.dispatch(configurationRequest(), Object.defineProperty(sender(), "origin", accessor));
    assertRecord(metadata.dump().records[0], {authorized: false, originType: "accessor", originMatches: null,
        requestValid: null, contextPrivacy: "unobserved", outcome: "authorization-rejected",
        responseArgumentCount: null, responseType: null, responseKind: null});
    await metadata.dispatch(configurationRequest(), Object.defineProperty(sender(), "incognito", accessor));
    assertRecord(metadata.dump().records[1], {sequence: 2, authorized: false, senderPrivacyType: "accessor",
        requestValid: null, contextPrivacy: "unobserved", outcome: "authorization-rejected",
        responseArgumentCount: null, responseType: null, responseKind: null});
    assert.equal(reads, 0);
});

test("diagnostic observer failures cannot change configuration callbacks or synchronous authorization exceptions", async context => {
    const {instrumented} = await fixture(context);
    for (const text of [source, instrumented]) {
        const instance = harness(text);
        instance.call("Object.getOwnPropertyDescriptor = () => { throw new Error('observer unavailable'); }");
        const result = await instance.dispatch();
        assert.equal(result.returned, true);
        assert.equal(result.callbacks[0].length, 1);
        assert.deepEqual(normalized(result.callbacks[0][0]), {kind: "configuration", state});
        assert.equal(instance.calls.authorize, 1);
        assert.equal(instance.calls.native.length, 1);
        const failure = new Error(secret);
        const rejected = harness(text, {authorize: () => { throw failure; }});
        assert.throws(() => rejected.start(), error => error === failure);
        assert.equal(rejected.calls.authorize, 1);
        assert.equal(rejected.calls.native.length, 0);
    }
    const response = new Proxy({}, {getOwnPropertyDescriptor() { throw new Error(secret); }});
    const instance = harness(instrumented);
    instance.context.injectedResponse = response;
    instance.call("handleMessage = async () => injectedResponse");
    const result = await instance.dispatch();
    assert.equal(result.returned, true);
    assert.equal(result.callbacks[0].length, 1);
    assert.equal(result.callbacks[0][0], response);
});

test("worker instrumentation rejects anchor drift, repeated instrumentation, and unsafe outputs; ordinary restores exact source", async context => {
    const built = await fixture(context);
    assert.equal((built.instrumented.match(/WIRE\.authorizeRuntimeMessage\("worker", request, sender, browser\.runtime\)/g) || []).length, 1);
    assert.equal((built.instrumented.match(/Promise\.resolve\(handleMessage\(/g) || []).length, 1);
    await built.run("ordinary");
    assert.equal(await readFile(built.output, "utf8"), source);
    for (const changed of [
        source.replace("async function handleMessage(request, context)", "async function renamedHandleMessage(request, context)"),
        source.replace('context.kind === "content" ? "ContentToWorker" : "PopupToWorker"', 'context.kind === "content" ? "Changed" : "PopupToWorker"'),
        source.replace("WIRE.runtimeNativeContext(context, request)", "WIRE.runtimeNativeContext(context, {...request})"),
        source.replace(".then(sendResponse, () => sendResponse())", ".then(sendResponse, () => sendResponse(undefined))"),
        source + '\nasync function handleMessage(request, context) {}', built.instrumented,
    ]) {
        await writeFile(built.input, changed);
        await assert.rejects(built.run("fixture"), error => /anchor changed|already contains/.test(error.stderr));
        assert.equal(await readFile(built.output, "utf8"), source);
    }
    const link = join(built.root, "linked.js");
    await symlink(built.output, link);
    await assert.rejects(execute("/usr/bin/python3", [instrumenter, built.input, link, "fixture"]), /Invalid bundled worker output/);
    await assert.rejects(execute("/usr/bin/python3", [instrumenter, built.input, built.input, "ordinary"]), /Invalid bundled worker output/);
});
