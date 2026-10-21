import test from "node:test";
import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {webcrypto} from "node:crypto";
import {mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import vm from "node:vm";

const execute = promisify(execFile);
const instrumenter = fileURLToPath(new URL("../instrument_popup.py", import.meta.url));
const resources = new URL("../../../Safari Shared/Resources/", import.meta.url);
const source = await readFile(new URL("popup.js", resources), "utf8");
const dependencies = await Promise.all(["protocol.generated.js", "bridge_wire.js", "popup_wire.js"].map(async name =>
    new vm.Script(await readFile(new URL(name, resources), "utf8"), {filename: name})));
const normalized = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));

async function fixture(context, text = source) {
    const root = await mkdtemp(join(tmpdir(), "safari-popup-diagnostic-"));
    context.after(() => rm(root, {recursive: true, force: true}));
    const input = join(root, "source.js"), output = join(root, "popup.js");
    await writeFile(input, text);
    await writeFile(output, "unchanged");
    const run = mode => execute("/usr/bin/python3", [instrumenter, input, output, mode]);
    return {input, output, run};
}

function harness(text, query, {privateContext = false, native = () => Promise.resolve({requests: [], completedResponses: []})} = {}) {
    const queries = [], messages = [], elements = [], timers = new Map();
    let timerID = 0;
    const context = vm.createContext({URL, crypto: webcrypto,
        setTimeout(callback, delay) { timers.set(++timerID, {callback, delay}); return timerID; },
        clearTimeout(id) { timers.delete(id); },
        document: {
            addEventListener() {},
            createElement() { return {setAttribute() {}}; },
            body: {appendChild(element) { elements.push(element); }},
            documentElement: {},
        },
        browser: {
            extension: {inIncognitoContext: privateContext},
            tabs: {query(options) { queries.push(normalized(options)); return query(); }},
            runtime: {sendNativeMessage(application, message) {
                messages.push({application, message: normalized(message)});
                return native();
            }},
        },
    });
    for (const script of dependencies) { script.runInContext(context); }
    new vm.Script(text).runInContext(context);
    return {queries, messages, elements, timers, call: code => vm.runInContext(code, context),
        diagnostics() {
            assert.equal(elements.length, 1);
            assert.equal(elements[0].id, "safari-vm-popup-diagnostics");
            return JSON.parse(elements[0].textContent.replace(/^Safari VM popup: /, ""));
        }};
}

test("fixture popup diagnostics preserve actual query outcomes and fail-closed privacy decisions", async context => {
    const built = await fixture(context);
    await built.run("fixture");
    const instrumented = await readFile(built.output, "utf8");
    const sensitive = "https://secret.invalid/?token=DO_NOT_CAPTURE";
    for (const [query, outcome] of [
        [() => Promise.resolve([]), "response"],
        [() => Promise.resolve({url: sensitive}), "response"],
        [() => Promise.resolve([{id: 3, windowId: 9, url: sensitive}]), "response"],
        [() => Promise.reject(new Error(sensitive)), "failure"],
        [() => { throw new Error(sensitive); }, "sync-throw"],
        [() => undefined, "no-promise"],
    ]) {
        const original = harness(source, query), diagnostic = harness(instrumented, query);
        assert.equal(await original.call("captureNativeContext()"), null);
        assert.equal(await diagnostic.call("captureNativeContext()"), null);
        assert.deepEqual(diagnostic.queries, original.queries);
        assert.deepEqual(diagnostic.messages, []);
        const records = diagnostic.diagnostics();
        assert.equal(records[0].kind, "tabs");
        assert.equal(records[0].outcome, outcome);
        assert.deepEqual(records[1], {sequence: 2, kind: "context", valid: false, extensionPrivacy: false, privacy: null});
        assert.doesNotMatch(diagnostic.elements[0].textContent, /secret|token|DO_NOT_CAPTURE/);
    }
});

test("fixture popup diagnostics preserve queue responses without extra calls or visible output on success", async context => {
    const built = await fixture(context);
    await built.run("fixture");
    const instrumented = await readFile(built.output, "utf8");
    for (const incognito of [false, true]) {
        const query = () => Promise.resolve([{id: 3, windowId: 9, incognito, url: "https://fixture.invalid"}]);
        const original = harness(source, query), diagnostic = harness(instrumented, query);
        assert.deepEqual(normalized(await diagnostic.call("fetchPendingResponse()")),
            normalized(await original.call("fetchPendingResponse()")));
        assert.deepEqual(diagnostic.queries, original.queries);
        assert.equal(diagnostic.messages.length, 1);
        assert.equal(diagnostic.messages[0].message.__bwContext.privateBrowsing, incognito);
        assert.equal(diagnostic.elements.length, 0);
        assert.equal(diagnostic.timers.size, 0);
    }
});

test("fixture popup diagnostics preserve the existing query timeout and bound retained metadata", async context => {
    const built = await fixture(context);
    await built.run("fixture");
    const instrumented = await readFile(built.output, "utf8");
    for (const text of [source, instrumented]) {
        const instance = harness(text, () => new Promise(() => {}));
        const pending = instance.call("captureNativeContext()");
        assert.equal(instance.timers.size, 1);
        const timer = [...instance.timers.values()][0];
        assert.equal(timer.delay, 5000);
        timer.callback();
        assert.equal(await pending, null);
        assert.equal(instance.queries.length, 1);
        assert.equal(instance.messages.length, 0);
        if (text === instrumented) { assert.equal(instance.diagnostics()[0].outcome, "timeout"); }
    }
    const instance = harness(instrumented, () => Promise.resolve([{id: 3, windowId: 9, incognito: "unknown", url: "invalid"}]));
    for (let index = 0; index < 20; index++) { assert.equal(await instance.call("captureNativeContext()"), null); }
    const records = instance.diagnostics();
    assert.equal(records.length, 8);
    assert.equal(records[0].sequence, 33);
    assert.deepEqual(records[6], {sequence: 39, kind: "tabs", outcome: "response", resultType: "array",
        count: 1, tabID: 3, windowID: 9, incognito: "string", urlType: "string", urlValid: false});
    assert.ok(instance.elements[0].textContent.length < 2000);
});

test("popup instrumentation rejects source drift and ordinary restoration removes every diagnostic", async context => {
    const built = await fixture(context);
    await built.run("fixture");
    assert.match(await readFile(built.output, "utf8"), /safariVMPopupDiagnostic/);
    await built.run("ordinary");
    assert.equal(await readFile(built.output, "utf8"), source);
    for (const changed of [source.replace("async function readActiveTab()", "async function changedReadActiveTab()"),
        source.replace("async function captureNativeContext()", "async function changedCaptureNativeContext()")]) {
        await writeFile(built.input, changed);
        await assert.rejects(built.run("fixture"), error => /source anchor changed/.test(error.stderr));
        assert.equal(await readFile(built.output, "utf8"), source);
    }
});
