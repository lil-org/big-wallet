import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, mkdir, readFile, rm, stat, writeFile} from "node:fs/promises";
import {createRequire} from "node:module";
import {tmpdir} from "node:os";
import {dirname, join} from "node:path";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const protocol = require("../Resources/protocol.generated.js");
const execute = promisify(execFile);
const root = fileURLToPath(new URL("../../", import.meta.url));
const generator = join(root, "Scripts/generate_wire_protocol.mjs");
const definitionPath = "Safari Shared/Protocol/wire-protocol.json";
const artifacts = ["Safari Shared/Resources/protocol.generated.js", "Safari Shared/Protocol/WireProtocol.generated.swift"];
const fixtures = JSON.parse(await readFile(new URL("fixtures/wire_protocol_contract.json", import.meta.url), "utf8"));
const source = await readFile(join(root, artifacts[0]), "utf8");
const normalize = value => JSON.parse(JSON.stringify(value));

for (const fixture of fixtures) {
    test(`shared protocol ${fixture.name}`, () => {
        assert.equal(protocol.isValid(fixture.type, fixture.value), fixture.valid);
        const decoded = protocol.decode(fixture.type, fixture.value);
        if (fixture.valid) {
            assert.deepEqual(normalize(decoded), fixture.value);
            assert.deepEqual(normalize(protocol.build(fixture.type, fixture.value)), fixture.value);
        } else {
            assert.equal(decoded, null);
            assert.throws(() => protocol.build(fixture.type, fixture.value), TypeError);
        }
    });
}

test("protocol snapshots reject getters, cycles and inherited required fields", () => {
    let calls = 0;
    const request = {subject: "openApp", id: 1, workflowVersion: 4};
    Object.defineProperty(request, "id", {get() { calls += 1; return 1; }});
    assert.equal(protocol.decode("NativeCommand", request), null);
    assert.equal(calls, 0);
    assert.equal(protocol.decode("NativeCommand", Object.create({subject: "openApp", id: 1, workflowVersion: 4})), null);
    const response = {kind: "result", id: 1, name: null, provider: "ethereum", state: null, approvalCommitted: false, result: {}};
    response.result.self = response.result;
    assert.equal(protocol.decode("PageResponse", response), null);
    const throwing = new Proxy({}, {ownKeys() { throw new Error("untrusted trap"); }});
    assert.equal(protocol.decode("NativeCommand", throwing), null);
});

test("protocol snapshots bound container nesting consistently", () => {
    const limit = protocol.maximumJSONDepth("RPCResponse");
    assert.equal(protocol.constants.MAX_JSON_DEPTH, 64);
    assert.equal(limit, 63);
    for (const wrap of [value => ({value}), value => [value]]) {
        for (const depth of [limit - 1, limit, limit + 1, 301]) {
            let result = 1;
            for (let level = 1; level < depth; level += 1) { result = wrap(result); }
            const response = {id: 1, result};
            assert.equal(protocol.isValid("RPCResponse", response), depth <= limit);
            if (depth <= limit) {
                assert.deepEqual(normalize(protocol.decode("RPCResponse", response)), response);
            } else {
                assert.equal(protocol.decode("RPCResponse", response), null);
                assert.throws(() => protocol.build("RPCResponse", response), TypeError);
            }
        }
    }
});

test("protocol snapshots retain captured builtins and isolate nested source mutations", () => {
    const context = vm.createContext({});
    new vm.Script(source).runInContext(context);
    context.input = {kind: "result", id: 1, name: null, provider: "ethereum", state: null,
        approvalCommitted: false, result: {items: [1, {value: "original"}]}};
    const decoded = vm.runInContext(`
        const fail = () => { throw new Error("mutated builtin"); };
        Object.keys = Object.getOwnPropertyDescriptor = Object.create = Object.freeze = fail;
        Object.defineProperty = Reflect.ownKeys = Reflect.apply = fail;
        Array.isArray = Number.isSafeInteger = Number.isFinite = String = fail;
        Array.prototype.map = Array.prototype[Symbol.iterator] = fail;
        RegExp.prototype.exec = RegExp.prototype.test = fail;
        BigWalletProtocol.decode("PageResponse", input);
    `, context);
    assert.deepEqual(normalize(decoded), context.input);
    assert.equal(Object.isFrozen(decoded), true);
    assert.equal(Object.isFrozen(decoded.result.items[1]), true);
    context.input.result.items[1].value = "changed";
    assert.equal(decoded.result.items[1].value, "original");
});

test("canonical identifiers reject trailing newlines and non-JSON numbers", () => {
    for (const [type, value] of [
        ["PrivateToken", "a".repeat(32)],
        ["RequestToken", "123e4567-e89b-12d3-a456-426614174000"],
        ["AuthorityContext", "a".repeat(64)],
        ["EthereumChainID", "0x1"],
    ]) {
        assert.equal(protocol.isValid(type, value), true);
        for (const suffix of ["\n", "\r\n", "\u2028"]) {
            assert.equal(protocol.isValid(type, value + suffix), false);
        }
    }
    for (const id of [true, 1.5, NaN, Infinity, -Infinity, 2 ** 53]) {
        assert.equal(protocol.isValid("RequestID", id), false);
    }
});

test("response polls exclude bare readiness without narrowing other native statuses", () => {
    const ready = {id: 91, ready: true};
    assert.equal(protocol.isValid("NativeStatus", ready), true);
    assert.equal(protocol.isValid("NativeOpenReply", ready), true);
    assert.equal(protocol.isValid("NativeResponsePollReply", ready), false);
    assert.equal(protocol.maximumJSONDepth("NativeResponsePollReply"), 64);
});

test("generator is deterministic, detects stale output without writes, and validates definitions first", async () => {
    const directory = await mkdtemp(join(tmpdir(), "big-wallet-protocol-"));
    try {
        const definition = await readFile(join(root, definitionPath), "utf8");
        await mkdir(dirname(join(directory, definitionPath)), {recursive: true});
        await writeFile(join(directory, definitionPath), definition);
        await execute(process.execPath, [generator, "--write", "--root", directory]);
        const originals = await Promise.all(artifacts.map(path => readFile(join(directory, path), "utf8")));
        for (const [index, path] of artifacts.entries()) {
            assert.equal(originals[index], await readFile(join(root, path), "utf8"));
            assert.equal(originals[index].includes(root), false);
        }
        const times = await Promise.all(artifacts.map(path => stat(join(directory, path)).then(value => value.mtimeMs)));
        await execute(process.execPath, [generator, "--write", "--root", directory]);
        assert.deepEqual(await Promise.all(artifacts.map(path => stat(join(directory, path)).then(value => value.mtimeMs))), times);
        await writeFile(join(directory, artifacts[0]), originals[0] + "\n");
        await assert.rejects(execute(process.execPath, [generator, "--check", "--root", directory]),
            error => error.code === 1 && /protocol\.generated\.js/.test(error.stderr) && /--write/.test(error.stderr));
        assert.equal(await readFile(join(directory, artifacts[0]), "utf8"), originals[0] + "\n");
        await execute(process.execPath, [generator, "--write", "--root", directory]);
        await execute(process.execPath, [generator, "--check", "--root", directory]);
        for (const mutate of [
            value => { value.extra = true; },
            value => { value.types.Broken = {type: "unsupported"}; },
            value => { value.types.Broken = {ref: "DoesNotExist"}; },
            value => { value.types.Broken = {ref: "Broken"}; },
            value => { value.types.Message = {type: "object", required: {}, optional: {}}; },
            value => { value.types.String = {type: "string"}; },
            value => { value.types.URL = {type: "string"}; value.types.Url = {type: "string"}; },
            value => { value.constants.WORKFLOW_VERSION = "invalid"; },
            value => { value.constants.WORKFLOW_POLICY.maximumRequests = -1; },
            value => { value.constants.unexpected = true; },
            value => { value.depthReservations.UnknownMessage = 1; },
            value => { value.depthReservations.RPCResponse = value.constants.MAX_JSON_DEPTH; },
            value => { value.depthReservations.RPCResponse = -1; },
        ]) {
            const invalid = JSON.parse(definition);
            mutate(invalid);
            await writeFile(join(directory, definitionPath), JSON.stringify(invalid));
            await assert.rejects(execute(process.execPath, [generator, "--write", "--root", directory]));
            for (const [index, path] of artifacts.entries()) {
                assert.equal(await readFile(join(directory, path), "utf8"), originals[index]);
            }
        }
    } finally {
        await rm(directory, {recursive: true, force: true});
    }
});
