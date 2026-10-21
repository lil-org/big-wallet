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
const instrumenter = fileURLToPath(new URL("../instrument_content.py", import.meta.url));
const resources = new URL("../../../Safari Shared/Resources/", import.meta.url);
const source = await readFile(new URL("content.js", resources), "utf8");
const dependencies = await Promise.all(["protocol.generated.js", "bridge_wire.js"].map(async name =>
    new vm.Script(await readFile(new URL(name, resources), "utf8"), {filename: name})));
const normalized = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
const configuration = {
    kind: "configuration",
    state: {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0},
        ethereum: {address: "", chainId: "0x1"}, solana: null},
};
const secret = "DO_NOT_CAPTURE";
const emptyShape = {rawType: "undefined", rawKind: "missing", rawStateType: "missing",
    rawErrorType: "missing", rawErrorCode: null, rawMessageType: "missing"};
const dumpSubject = "safariVMConfigurationDiagnostics";

function workerDump(records = []) {
    return {kind: dumpSubject, version: 1, status: "ok", startedAt: 1_700_000_000_000, dropped: false,
        query: {idMatches: true, tabIDValid: true, frameIDValid: true, documentIDValid: true}, records};
}

function workerRecord(sequence = 1) {
    return {sequence, at: 1_700_000_000_001, authorized: true, idMatches: true, idType: "string",
        urlType: "string", tabType: "object", tabIDValid: true, frameIDValid: true, topFrame: true,
        documentIDType: "string", documentIDValid: true, originType: "string", originMatches: true,
        senderPrivacyType: "undefined", tabPrivacyType: "boolean",
        senderPrivacy: "unknown", tabPrivacy: "private", requestValid: true, contextPrivacy: "private",
        outcome: "response", responseArgumentCount: 1, responseType: "object", responseKind: "configurationError"};
}

async function fixture(context) {
    const root = await mkdtemp(join(tmpdir(), "safari-content-diagnostic-"));
    context.after(() => rm(root, {recursive: true, force: true}));
    const input = join(root, "source.js"), output = join(root, "content.js");
    await writeFile(input, source);
    await writeFile(output, "unchanged");
    const run = mode => execute("/usr/bin/python3", [instrumenter, input, output, mode]);
    await run("fixture");
    return {root, input, output, run, instrumented: await readFile(output, "utf8")};
}

async function settle() {
    for (let index = 0; index < 40; index++) { await Promise.resolve(); }
}

function harness(text, send, {url = `https://private.invalid/?token=${secret}`, diagnosticResponse = () => undefined} = {}) {
    const messages = [], diagnosticMessages = [], responses = [], elements = [], timers = [], effects = [];
    let clock = 1_700_000_000_000;
    const pageURL = new URL(url);
    const generation = `fixture-generation-${secret}`;
    class FixedDate extends Date {
        static now() { return clock; }
    }
    const document = {
        addEventListener() {},
        createElement() {
            return {style: {}, attributes: {}, setAttribute(name, value) { this.attributes[name] = value; }};
        },
        body: {appendChild(element) { elements.push(element); }},
        documentElement: {appendChild(element) { elements.push(element); }},
    };
    const context = vm.createContext({URL, Date: FixedDate, document,
        Math: Object.assign(Object.create(Math), {random: () => 0}),
        bigWalletProviderGeneration: generation,
        window: {
            location: {href: pageURL.href, pathname: pageURL.pathname},
            addEventListener() {},
            postMessage(message, target) {
                effects.push({kind: "page", response: normalized(message.response)});
                responses.push({message: normalized(message), target});
            },
        },
        browser: {runtime: {
            onMessage: {addListener() {}},
            sendMessage(message) {
                if (message.subject === dumpSubject) {
                    effects.push({kind: "diagnostic"});
                    diagnosticMessages.push(normalized(message));
                    return diagnosticResponse();
                }
                effects.push({kind: "configuration"});
                messages.push(normalized(message));
                return send(messages.length);
            },
        }},
        setTimeout(callback, delay) {
            const timer = {callback, delay, due: clock + delay, cancelled: false, fired: false};
            timers.push(timer);
            return timer;
        },
        clearTimeout(timer) { timer.cancelled = true; },
    });
    for (const script of dependencies) { script.runInContext(context); }
    const script = new vm.Script(text);
    script.runInContext(context);
    return {
        context, messages, diagnosticMessages, responses, elements, effects,
        call: code => vm.runInContext(code, context),
        reinject() { script.runInContext(context); },
        snapshot() {
            return {messages, responses,
                timers: timers.map(({delay, due, cancelled, fired}) => ({delay, due, cancelled, fired}))};
        },
        async drain() {
            for (let count = 0; count < 12; count++) {
                await settle();
                const timer = timers.filter(value => !value.cancelled && !value.fired)
                    .sort((left, right) => left.due - right.due)[0];
                if (!timer) { return; }
                clock = timer.due;
                timer.fired = true;
                timer.callback();
            }
            throw Error("Unexpected unbounded configuration timer sequence");
        },
        diagnostics() {
            assert.equal(elements.length, 1);
            assert.equal(elements[0].id, "safari-vm-content-diagnostics");
            assert.equal(elements[0].attributes.role, "status");
            return JSON.parse(elements[0].textContent.split("\n")[0].replace(/^Safari VM transport: /, ""));
        },
        workerDiagnostics() {
            const line = elements[0]?.textContent.split("\n")[1];
            return line ? JSON.parse(line.replace(/^Safari VM worker: /, "")) : null;
        },
    };
}

test("content diagnostics preserve bootstrap calls, responses, and timer schedules", async context => {
    const {instrumented} = await fixture(context);
    const cases = [
        {name: "success", send: () => Promise.resolve(configuration), visible: false, count: 1},
        {name: "undefined", send: () => undefined, outcome: "response", kind: "invalid"},
        {name: "null", send: () => Promise.resolve(null), outcome: "response", kind: "invalid", raw: {...emptyShape, rawType: "null"}},
        {name: "array", send: () => Promise.resolve([]), outcome: "response", kind: "invalid", raw: {...emptyShape, rawType: "array"}},
        {name: "primitive", send: () => Promise.resolve(secret), outcome: "response", kind: "invalid", raw: {...emptyShape, rawType: "string"}},
        {name: "invalid", send: () => Promise.resolve({kind: secret, error: {message: secret}}), outcome: "response", kind: "invalid",
            raw: {...emptyShape, rawType: "object", rawKind: "other", rawErrorType: "object", rawMessageType: "string"}},
        {name: "rejection", send: () => Promise.reject(new Error(secret)), outcome: "rejected", kind: "invalid"},
        {name: "sync throw", send: () => { throw new Error(secret); }, outcome: "sync-throw", kind: "invalid"},
        {name: "timeout", send: () => new Promise(() => {}), outcome: "timeout", kind: "invalid", elapsed: 5000},
        {name: "worker failure", send: () => Promise.resolve({kind: "configurationError", error: {code: 4900, message: secret}}), outcome: "response", kind: "configurationError", code: 4900,
            raw: {...emptyShape, rawType: "object", rawKind: "configurationError", rawErrorType: "object", rawErrorCode: 4900, rawMessageType: "string"}},
        {name: "private rejection", send: () => Promise.resolve({kind: "configurationError", error: {code: 4200, message: secret}}), outcome: "response", kind: "configurationError", code: 4200, count: 1,
            raw: {...emptyShape, rawType: "object", rawKind: "configurationError", rawErrorType: "object", rawErrorCode: 4200, rawMessageType: "string"}},
    ];
    for (const value of cases) {
        const original = harness(source, value.send), diagnostic = harness(instrumented, value.send);
        original.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        diagnostic.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await original.drain();
        await diagnostic.drain();
        assert.deepEqual(diagnostic.snapshot(), original.snapshot(), value.name);
        assert.equal(diagnostic.messages.length, value.count ?? 3, value.name);
        assert.equal(original.elements.length, 0);
        if (value.visible === false) {
            assert.equal(diagnostic.elements.length, 0);
            assert.equal(diagnostic.diagnosticMessages.length, 0);
            continue;
        }
        assert.equal(diagnostic.diagnosticMessages.length, value.code === 4200 ? 0 : 1);
        if (value.code !== 4200) {
            const index = diagnostic.effects.findIndex(effect => effect.kind === "diagnostic");
            assert.equal(diagnostic.effects[index - 1].kind, "page");
            assert.equal(diagnostic.effects[index - 1].response.error.code, 4900);
        }
        const records = diagnostic.diagnostics();
        assert.equal(records.length, value.count ?? 3);
        for (const [attempt, record] of records.entries()) {
            assert.deepEqual(record, {sequence: attempt + 1, attempt, serial: 1,
                startedAt: 1_700_000_000_000 + (attempt ? attempt === 1 ? (value.elapsed ?? 0) + 1000 : (value.elapsed ?? 0) * 2 + 6000 : 0),
                elapsed: value.elapsed ?? 0, outcome: value.outcome, replyKind: value.kind,
                errorCode: value.code ?? null, identityValid: true, generationValid: true, ...(value.raw ?? emptyShape)});
        }
        assert.doesNotMatch(diagnostic.elements[0].textContent, /DO_NOT_CAPTURE|private\.invalid|fixture-generation/);
    }
});

test("content diagnostics remain invisible after recovered or already configured failures", async context => {
    const {instrumented} = await fixture(context);
    for (const text of [source, instrumented]) {
        const recovered = harness(text, count => count === 1 ? undefined : Promise.resolve(configuration));
        recovered.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await recovered.drain();
        assert.equal(recovered.messages.length, 2);
        assert.equal(recovered.responses[0].message.response.kind, "configuration");
        assert.equal(recovered.elements.length, 0);
        assert.equal(recovered.diagnosticMessages.length, 0);

        const configured = harness(text, count => count === 1 ? Promise.resolve(configuration) : undefined);
        configured.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await configured.drain();
        configured.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await configured.drain();
        assert.equal(configured.messages.length, 4);
        assert.equal(configured.responses.length, 1);
        assert.equal(configured.elements.length, 0);
        assert.equal(configured.diagnosticMessages.length, 0);
    }
});

test("content diagnostics bound retained metadata and preserve reinjection and stale generations", async context => {
    const {instrumented} = await fixture(context);
    const original = harness(source, () => undefined), diagnostic = harness(instrumented, () => undefined);
    for (const instance of [original, diagnostic]) {
        for (let index = 0; index < 6; index++) {
            instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
            await instance.drain();
            instance.reinject();
        }
        await instance.call("bigWalletReadConfiguration('stale-generation', 0, 7)");
    }
    assert.deepEqual(diagnostic.snapshot(), original.snapshot());
    const records = diagnostic.diagnostics();
    assert.equal(records.length, 12);
    assert.equal(records[0].sequence, 8);
    assert.equal(records.at(-1).generationValid, false);
    assert.equal(records.at(-1).serial, 7);
    assert.equal(diagnostic.diagnosticMessages.length, 1);
    assert.ok(diagnostic.elements[0].textContent.length <= 10_000);
    assert.doesNotMatch(diagnostic.elements[0].textContent, /DO_NOT_CAPTURE|stale-generation/);
});

test("content diagnostics record invalid identity without capturing its URL", async context => {
    const {instrumented} = await fixture(context);
    const original = harness(source, () => undefined, {url: `data:text/plain,${secret}`});
    const diagnostic = harness(instrumented, () => undefined, {url: `data:text/plain,${secret}`});
    for (const instance of [original, diagnostic]) {
        instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await instance.drain();
    }
    assert.deepEqual(diagnostic.snapshot(), original.snapshot());
    assert.ok(diagnostic.diagnostics().every(record => record.identityValid === false));
    assert.doesNotMatch(diagnostic.elements[0].textContent, /data:|DO_NOT_CAPTURE/);
});

test("content records raw reply shape without invoking accessors or exposing values", async context => {
    const {instrumented} = await fixture(context);
    let accessed = 0;
    const reply = {get kind() { accessed++; return secret; }, state: {account: secret},
        error: {get code() { accessed++; return 4900; }, get message() { accessed++; return secret; }}};
    const original = harness(source, () => Promise.resolve(reply));
    const diagnostic = harness(instrumented, () => Promise.resolve(reply));
    for (const instance of [original, diagnostic]) {
        instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await instance.drain();
    }
    assert.deepEqual(diagnostic.snapshot(), original.snapshot());
    assert.equal(accessed, 0);
    const record = diagnostic.diagnostics()[0];
    assert.equal(record.rawType, "object");
    assert.equal(record.rawKind, "accessor");
    assert.equal(record.rawStateType, "object");
    assert.equal(record.rawErrorType, "object");
    assert.equal(record.rawErrorCode, null);
    assert.equal(record.rawMessageType, "accessor");
    assert.doesNotMatch(diagnostic.elements[0].textContent, /DO_NOT_CAPTURE|account/);
});

test("worker dump is once per document after final failure and adds no timers or retries", async context => {
    const {instrumented} = await fixture(context);
    const outcomes = [
        {send: () => new Promise(() => {}), status: "pending"},
        {send: () => Promise.reject(new Error(secret)), status: "transport-rejected"},
        {send: () => { throw new Error(secret); }, status: "sync-throw"},
        {send: () => Promise.resolve(workerDump([workerRecord()])), status: "response"},
    ];
    for (const outcome of outcomes) {
        const original = harness(source, () => undefined);
        const diagnostic = harness(instrumented, () => undefined, {diagnosticResponse: outcome.send});
        for (const instance of [original, diagnostic]) {
            for (let index = 0; index < 2; index++) {
                instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
                await instance.drain();
                instance.reinject();
            }
        }
        assert.deepEqual(diagnostic.snapshot(), original.snapshot());
        assert.deepEqual(diagnostic.diagnosticMessages, [{subject: dumpSubject}]);
        assert.equal(diagnostic.workerDiagnostics().status, outcome.status);
        const queryIndex = diagnostic.effects.findIndex(effect => effect.kind === "diagnostic");
        assert.equal(diagnostic.effects[queryIndex - 1].response.error.code, 4900);
        assert.doesNotMatch(diagnostic.elements[0].textContent, /DO_NOT_CAPTURE/);
    }
});

test("content validates worker dumps before rendering and never reads response getters", async context => {
    const {instrumented} = await fixture(context);
    let accessed = 0;
    const accessor = workerDump();
    Object.defineProperty(accessor, "records", {get() { accessed++; return [secret]; }});
    const recordAccessor = workerRecord();
    Object.defineProperty(recordAccessor, "idType", {get() { accessed++; return secret; }});
    const malformedDumps = [{...workerDump(), extra: secret}, accessor,
        {...workerDump(), startedAt: Infinity}, workerDump(Array.from({length: 13}, () => workerRecord())),
        workerDump([recordAccessor]), workerDump([{...workerRecord(), responseKind: secret}]),
        {...workerDump([workerRecord()]), status: "rejected"},
        {...workerDump(), query: {...workerDump().query, idMatches: false}},
    ];
    const invalid = [
        [undefined, emptyShape],
        [null, {...emptyShape, rawType: "null"}],
        [secret, {...emptyShape, rawType: "string"}],
        [[], {...emptyShape, rawType: "array"}],
        ...malformedDumps.map(value => [value, {...emptyShape, rawType: "object", rawKind: "other"}]),
        [{kind: "configurationError", state: null, error: {code: 4900, message: secret}},
            {...emptyShape, rawType: "object", rawKind: "configurationError", rawStateType: "null",
                rawErrorType: "object", rawErrorCode: 4900, rawMessageType: "string"}],
        [{get kind() { accessed++; return secret; }, get state() { accessed++; return secret; },
            error: {get code() { accessed++; return 4900; }, get message() { accessed++; return secret; }}},
            {...emptyShape, rawType: "object", rawKind: "accessor", rawStateType: "accessor",
                rawErrorType: "object", rawMessageType: "accessor"}],
        [new Proxy({}, {getOwnPropertyDescriptor() { throw new Error(secret); }}), {}],
    ];
    for (const [response, shape] of invalid) {
        const instance = harness(instrumented, () => undefined, {diagnosticResponse: () => Promise.resolve(response)});
        instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await instance.drain();
        assert.deepEqual(instance.workerDiagnostics(), {status: "invalid-response", ...shape});
        assert.deepEqual(instance.diagnosticMessages, [{subject: dumpSubject}]);
        assert.doesNotMatch(instance.elements[0].textContent, /DO_NOT_CAPTURE/);
    }
    assert.equal(accessed, 0);

    const rejected = {...workerDump(), status: "rejected",
        query: {idMatches: true, tabIDValid: true, frameIDValid: true, documentIDValid: false}};
    const instance = harness(instrumented, () => undefined, {diagnosticResponse: () => rejected});
    instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
    await instance.drain();
    assert.deepEqual(instance.workerDiagnostics(), {status: "response", response: rejected});
});

test("combined diagnostic display stays within its bounded size", async context => {
    const {instrumented} = await fixture(context);
    const response = workerDump(Array.from({length: 12}, (_, index) => workerRecord(index + 1)));
    const instance = harness(instrumented, () => undefined, {diagnosticResponse: () => response});
    for (let index = 0; index < 6; index++) {
        instance.call("bigWalletLoadConfiguration(bigWalletProviderGeneration, 0)");
        await instance.drain();
    }
    assert.equal(instance.diagnostics().length, 12);
    assert.ok(instance.elements[0].textContent.length <= 10_000);
    assert.ok(instance.workerDiagnostics().response.records.length > 0);
    assert.equal(response.records.length, 12);
    assert.equal(response.dropped, false);
    if (instance.workerDiagnostics().response.records.length < 12) {
        assert.equal(instance.workerDiagnostics().response.dropped, true);
    }
});

test("content instrumentation rejects source drift and unsafe outputs and restores ordinary content", async context => {
    const built = await fixture(context);
    await built.run("ordinary");
    assert.equal(await readFile(built.output, "utf8"), source);
    for (const changed of [
        source.replace("async function bigWalletReadConfiguration(generation, attempt, serial)", "async function changedConfiguration(generation, attempt, serial)"),
        source.replace("    if (bigWalletHasAcceptedConfiguration(generation, identity?.configurationKey)) { return; }", "    if (false) { return; }"),
        built.instrumented,
    ]) {
        await writeFile(built.input, changed);
        await assert.rejects(built.run("fixture"), error => /anchor changed|already contains/.test(error.stderr));
        assert.equal(await readFile(built.output, "utf8"), source);
    }
    const link = join(built.root, "linked.js");
    await symlink(built.output, link);
    await assert.rejects(execute("/usr/bin/python3", [instrumenter, built.input, link, "fixture"]), /Invalid bundled content output/);
    await assert.rejects(execute("/usr/bin/python3", [instrumenter, built.input, built.input, "ordinary"]), /Invalid bundled content output/);
});
