import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {resolve} from "node:path";
import test from "node:test";
import {
    compareResults,
    evaluateJavaScript,
    minimizeCase,
    parseOptions,
    prepareFailure,
    replayCases,
    startOracle,
} from "../../Scripts/fuzz_wire_protocol.mjs";

const fixtures = JSON.parse(await readFile(new URL("fixtures/wire_protocol_contract.json", import.meta.url), "utf8"));
const candidateFor = fixture => ({type: fixture.type, json: JSON.stringify(fixture.value), expectedValid: fixture.valid});
const objectFixture = fixtures.find(fixture => fixture.valid && fixture.value !== null &&
    typeof fixture.value === "object" && !Array.isArray(fixture.value));
const request = {type: "RequestID", json: "7"};

function acceptedSwift(candidate) {
    const value = JSON.parse(candidate.json);
    const object = value !== null && typeof value === "object" && !Array.isArray(value);
    return {
        id: 0,
        parsed: true,
        valid: true,
        objectValid: object,
        decodedJSON: candidate.json,
        dataValid: true,
        dataJSON: candidate.json,
        dataObjectValid: object,
        ...(object ? {objectJSON: candidate.json, dataObjectJSON: candidate.json} : {}),
    };
}

function fakeOracle(context, script, timeout = 2000) {
    const oracle = startOracle(process.execPath, {args: ["-e", script], timeout});
    let closed = false;
    context.after(async () => {
        if (closed) { return; }
        oracle.terminate();
        await oracle.close().catch(() => {});
    });
    return {
        evaluate: candidate => oracle.evaluate(candidate),
        async close() {
            try { await oracle.close(); }
            finally { closed = true; }
        },
    };
}

function onInput(body) {
    return `
        const readline = require("node:readline");
        const lines = readline.createInterface({input: process.stdin});
        lines.on("line", line => {
            const input = JSON.parse(line);
            ${body}
        });
    `;
}

test("fuzz comparison accepts a valid null snapshot instead of treating null as decode failure", () => {
    const candidate = candidateFor(fixtures.find(fixture => fixture.valid && fixture.value === null));
    const javascript = evaluateJavaScript(candidate);
    assert.equal(javascript.valid, true);
    assert.equal(javascript.decodedJSON, "null");
    assert.equal(compareResults(candidate, javascript, acceptedSwift(candidate)), null);
});

test("independent positive fixtures detect two implementations that reject every value", () => {
    const candidate = candidateFor(objectFixture);
    const rejectEverything = {
        isValid: () => false,
        decode: () => null,
        build: () => { throw new TypeError("rejected"); },
    };
    const javascript = evaluateJavaScript(candidate, rejectEverything);
    const swift = {id: 0, parsed: true, valid: false, objectValid: false, dataValid: false, dataObjectValid: false};
    assert.equal(javascript.invariant, undefined);
    assert.match(compareResults(candidate, javascript, swift), /Independent expected validity/);
});

test("independent negative fixtures detect two implementations that accept every value", () => {
    const candidate = candidateFor(fixtures.find(fixture => !fixture.valid));
    const acceptEverything = {
        isValid: () => true,
        decode: (_type, value) => value,
        build: (_type, value) => value,
    };
    const javascript = evaluateJavaScript(candidate, acceptEverything);
    assert.equal(javascript.invariant, undefined);
    assert.match(compareResults(candidate, javascript, acceptedSwift(candidate)), /Independent expected validity/);
});

test("fuzz comparison checks every accepted Swift snapshot and raw-data decision", () => {
    const candidate = candidateFor(objectFixture);
    const javascript = evaluateJavaScript(candidate);
    const swift = acceptedSwift(candidate);
    assert.equal(compareResults(candidate, javascript, swift), null);
    for (const key of ["decodedJSON", "objectJSON", "dataJSON", "dataObjectJSON"]) {
        assert.match(compareResults(candidate, javascript, {...swift, [key]: "null"}), /snapshot differs/, key);
        assert.match(compareResults(candidate, javascript, {...swift, [key]: "{"}), /invalid .* snapshot/, key);
        const missing = {...swift};
        delete missing[key];
        assert.match(compareResults(candidate, javascript, missing), /Missing .* snapshot/, key);
    }
    assert.match(compareResults(candidate, javascript, {...swift, dataValid: false}), /raw-data decoding decisions differ/);
    assert.match(compareResults(candidate, javascript, {...swift, dataObjectValid: false}), /raw-data object decisions differ/);
    assert.match(compareResults(candidate, javascript, {...swift, objectValid: false}), /objectValid decisions differ/);
});

test("fuzz comparison surfaces JavaScript entry point disagreement even when Swift agrees with validation", () => {
    const candidate = candidateFor(objectFixture);
    const javascript = evaluateJavaScript(candidate, {
        isValid: () => true,
        decode: (_type, value) => value,
        build: () => { throw new Error("broken builder"); },
    });
    assert.match(compareResults(candidate, javascript, acceptedSwift(candidate)), /validate\/decode\/build disagree/);
});

test("fuzz evaluation compares snapshots under JSON number semantics and catches source mutation", () => {
    const candidate = {type: "RequestID", json: "-0", expectedValid: true};
    const javascript = evaluateJavaScript(candidate);
    assert.equal(javascript.invariant, undefined);
    const swift = acceptedSwift({...candidate, json: "0"});
    assert.equal(compareResults(candidate, javascript, swift), null);
    const mutated = evaluateJavaScript({type: "NativeResult", json: '{"value":1}'}, {
        isValid: () => true,
        decode: (_type, value) => { value.value = 2; return value; },
        build: (_type, value) => value,
    });
    assert.match(mutated.invariant, /snapshot changes the accepted input/);
});

test("JavaScript validator crashes become reportable invariants", () => {
    for (const broken of ["isValid", "decode"]) {
        const protocol = {isValid: () => true, decode: () => 7, build: () => 7};
        protocol[broken] = () => { throw new Error("intentional decoder failure"); };
        const result = evaluateJavaScript(request, protocol);
        assert.match(result.invariant, /JavaScript oracle failure: intentional decoder failure/);
    }
});

test("deeply nested rejected input never reaches snapshot serialization", () => {
    const candidate = {
        type: "NativeResult",
        json: '{"noise":0,"nested":' + "[".repeat(10000) + "0" + "]".repeat(10000) + "}",
        expectedValid: false,
    };
    assert.deepEqual(evaluateJavaScript(candidate), {parsed: true, valid: false, objectValid: false});
});

test("snapshot comparison normalizes nested signed zero without changing other numbers", () => {
    for (const candidate of [
        {type: "RequestID", json: "-0.0"},
        {type: "RPCResponse", json: '{"id":1,"result":-0.0}'},
        {type: "RPCResponse", json: '{"id":1,"result":[-0,0,{"value":-0.0}]}'},
    ]) {
        assert.equal(compareResults(candidate, evaluateJavaScript(candidate), acceptedSwift(candidate)), null);
    }
    const candidate = {type: "RPCResponse", json: '{"id":1,"result":null}'};
    const javascript = evaluateJavaScript(candidate);
    for (const key of ["decodedJSON", "dataJSON", "objectJSON", "dataObjectJSON"]) {
        for (const number of ["1e999", "-1e999", "1"]) {
            const swift = {...acceptedSwift(candidate), [key]: `{"id":1,"result":${number}}`};
            assert.match(compareResults(candidate, javascript, swift), /snapshot differs/);
        }
    }
});

test("matching rejections tolerate parser differences without hiding acceptance mismatches", () => {
    for (const json of ["1e999", "-1e999"]) {
        const candidate = {type: "NativeResult", json, expectedValid: false};
        const javascript = evaluateJavaScript(candidate);
        const swift = {parsed: false, valid: false, objectValid: false, dataValid: false, dataObjectValid: false};
        assert.equal(javascript.parsed, true);
        assert.equal(javascript.valid, false);
        assert.equal(compareResults(candidate, javascript, swift), null);
        assert.match(compareResults({...candidate, expectedValid: true}, javascript, swift), /expected validity/);
        for (const key of ["valid", "objectValid", "dataValid", "dataObjectValid"]) {
            assert.notEqual(compareResults(candidate, javascript, {...swift, [key]: true}), null, key);
        }
    }
});

test("failure artifacts fall back to the original when a reduction stops reproducing", async () => {
    const candidate = {type: "NativeResult", json: '{"noise":123}'};
    const result = {message: "snapshot differs", javascript: {}, swift: {}};
    const evaluations = new Map();
    const failure = await prepareFailure(candidate, result, async value => {
        const count = (evaluations.get(value.json) ?? 0) + 1;
        evaluations.set(value.json, count);
        return value.json === candidate.json || count === 1 ? result : {...result, message: null};
    });
    assert.equal(failure.case.json, candidate.json);
    assert.equal(failure.message, result.message);
    assert.equal(failure.reproduced, true);
    const transient = await prepareFailure(candidate, result, async () => ({...result, message: null}), false);
    assert.equal(transient.case.json, candidate.json);
    assert.equal(transient.message, result.message);
    assert.equal(transient.reproduced, false);
});

test("reduction exceptions preserve the original failure and its expected validity", async () => {
    const candidate = {type: "NativeResult", json: '{"noise":123}', expectedValid: true};
    const result = {message: "snapshot differs", javascript: {}, swift: {}};
    const evaluated = [];
    const failure = await prepareFailure(candidate, result, async next => {
        evaluated.push(next.json);
        if (next.json !== candidate.json) { throw new Error("reduction failed"); }
        return result;
    });
    assert.deepEqual(evaluated, ["null", candidate.json]);
    assert.deepEqual(failure.case, candidate);
    assert.equal(failure.message, result.message);
    assert.equal(failure.reproduced, true);
});

test("fuzz options accept bounded integers and reject malformed CLI values", () => {
    assert.deepEqual(parseOptions([]), {seed: 0xc0ffee, iterations: 5000, timeout: 10000, minimize: true});
    assert.deepEqual(parseOptions([
        "--seed", "0xffffffff", "--iterations", "0", "--timeout-ms", "1", "--no-minimize",
        "--replay", "failure.json", "--failure-dir", "failures",
    ]), {
        seed: 0xffffffff, iterations: 0, timeout: 1, minimize: false,
        replay: resolve("failure.json"), failureDirectory: resolve("failures"),
    });
    for (const arguments_ of [
        ["--unknown"], ["500"], ["--seed"], ["--iterations", "--help"], ["--replay"],
        ["--seed", "-1"], ["--seed", "4294967296"], ["--seed", "0x100000000"],
        ["--iterations", "1.5"], ["--iterations", "1e3"], ["--iterations", "1000001"],
        ["--iterations", "+1"], ["--iterations", " 1"], ["--timeout-ms", "0"],
        ["--timeout-ms", "120001"], ["--timeout-ms", "NaN"], ["--timeout-ms", "Infinity"],
        ["--failure-dir", ""],
    ]) {
        assert.throws(() => parseOptions(arguments_), /Unknown argument|Missing value|Invalid value/, JSON.stringify(arguments_));
    }
});

test("replay retains exact candidate JSON bytes including whitespace, escaped Unicode, and numeric spelling", () => {
    const json = ' { "value": -0, "large": 18446744073709551615, "decimal": 1.000e+02, "text": "\\u0061", "duplicate": 1, "duplicate": 2 }\n';
    const candidate = {type: "NativeResult", json, expectedValid: true, name: "literal replay"};
    assert.equal(replayCases([candidate])[0].json, json);
    assert.equal(replayCases({version: 1, case: candidate, originalCase: {json: "unused"}})[0].json, json);
    assert.deepEqual(replayCases([candidate])[0], candidate);
    for (const artifact of [[], {}, null, [null], [{type: "NativeResult", json: {}}],
        [{type: "NativeResult", json: "null", expectedValid: "true"}]]) {
        assert.throws(() => replayCases(artifact));
    }
});

test("minimization preserves its failure predicate while removing unrelated data", async () => {
    const candidate = {
        type: "NativeResult", expectedValid: true, name: "minimize nested failure",
        json: JSON.stringify({noise: ["unrelated payload", 400], required: {value: 129}, discard: "extra"}),
    };
    const original = {...candidate};
    const remainsFailing = next => {
        const value = JSON.parse(next.json);
        return Number.isInteger(value?.required?.value) && value.required.value >= 7;
    };
    const minimized = await minimizeCase(candidate, remainsFailing);
    assert(minimized.json.length < candidate.json.length);
    assert(remainsFailing(minimized));
    assert.deepEqual(Object.keys(JSON.parse(minimized.json)), ["required"]);
    assert.equal(Object.hasOwn(minimized, "expectedValid"), false);
    assert.equal(minimized.type, candidate.type);
    assert.deepEqual(candidate, original);
});

test("minimization respects its attempt budget and retains unparsable JSON", async () => {
    const candidate = {type: "NativeResult", json: '{"left":[123,456],"right":"long string"}'};
    let calls = 0;
    const minimized = await minimizeCase(candidate, async () => { calls += 1; return false; }, 3);
    assert.equal(calls, 3);
    assert.equal(minimized.json, candidate.json);
    await minimizeCase(candidate, () => { assert.fail("Zero budget must not evaluate a candidate"); }, 0);
    const invalid = {type: "NativeResult", json: '{ "unfinished": ', expectedValid: false};
    assert.equal((await minimizeCase(invalid, () => { assert.fail("Invalid JSON must not be normalized"); })).json, invalid.json);
});

test("oracle exchanges multiple streaming requests with exact JSON strings and closes on EOF", async context => {
    const oracle = fakeOracle(context, onInput(`
        process.stdout.write(JSON.stringify({id: input.id, parsed: true, valid: true,
            objectValid: false, decodedJSON: input.json, dataValid: true, dataJSON: input.json,
            dataObjectValid: false, echoedJSON: input.json}) + "\\n");
    `));
    const firstJSON = "  9007199254740993  ";
    const first = await oracle.evaluate({...request, json: firstJSON});
    const second = await oracle.evaluate(request);
    assert.equal(first.echoedJSON, firstJSON);
    assert.equal(first.id, 0);
    assert.equal(second.id, 1);
    assert.equal(second.decodedJSON, request.json);
    await oracle.close();
});

test("oracle treats literal Unicode line and paragraph separators as JSON string content", async context => {
    const oracle = fakeOracle(context, onInput(`
        const text = "before" + String.fromCodePoint(0x2028) + "middle" + String.fromCodePoint(0x2029) + "after";
        process.stdout.write(JSON.stringify({id: input.id, parsed: true, valid: true,
            objectValid: false, decodedJSON: JSON.stringify(text), dataValid: true,
            dataJSON: JSON.stringify(text), dataObjectValid: false}) + "\\n");
    `));
    const result = await oracle.evaluate(request);
    assert.equal(result.decodedJSON, JSON.stringify("before\u2028middle\u2029after"));
    assert.equal(JSON.parse(result.decodedJSON), "before\u2028middle\u2029after");
    await oracle.close();
});

test("oracle preserves multibyte UTF-8 split between stdout chunks", async context => {
    const oracle = fakeOracle(context, onInput(`
        const text = "prefix" + String.fromCodePoint(0x1f9ea) + "suffix";
        const data = Buffer.from(JSON.stringify({id: input.id, parsed: true, valid: true,
            objectValid: false, decodedJSON: JSON.stringify(text), dataValid: true,
            dataJSON: JSON.stringify(text), dataObjectValid: false}) + "\\n");
        const boundary = data.indexOf(Buffer.from(String.fromCodePoint(0x1f9ea))) + 2;
        process.stdout.write(data.subarray(0, boundary), () => {
            setTimeout(() => process.stdout.write(data.subarray(boundary)), 25);
        });
    `));
    const result = await oracle.evaluate(request);
    assert.equal(JSON.parse(result.decodedJSON), "prefix🧪suffix");
    await oracle.close();
});

test("oracle rejects mismatched response IDs and remains failed", async context => {
    const oracle = fakeOracle(context, onInput(`
        process.stdout.write(JSON.stringify({id: input.id + 1, parsed: true, valid: true,
            objectValid: false, dataValid: true, dataObjectValid: false}) + "\\n");
    `));
    await assert.rejects(oracle.evaluate(request), /out-of-order/);
    await assert.rejects(oracle.evaluate(request), /out-of-order/);
    await assert.rejects(oracle.close(), /out-of-order/);
});

test("oracle rejects malformed output lines", async context => {
    const oracle = fakeOracle(context, onInput('process.stdout.write("{invalid JSON\\n");'));
    await assert.rejects(oracle.evaluate(request), /Invalid Swift oracle output/);
    await assert.rejects(oracle.close(), /Invalid Swift oracle output/);
});

test("oracle reports nonzero exits with stderr and rejects an early clean exit", async context => {
    for (const code of [0, 7]) {
        const oracle = fakeOracle(context, onInput(`
            process.stderr.write("intentional fixture exit\\n", () => process.exit(${code}));
        `));
        await assert.rejects(oracle.evaluate(request), error => {
            assert.match(error.message, new RegExp(`exited \\(${code}\\)`));
            assert.match(error.message, /intentional fixture exit/);
            return true;
        });
        await assert.rejects(oracle.close(), /exited/);
    }
});

test("oracle reports a child terminated by a signal", async context => {
    const oracle = fakeOracle(context, onInput('process.kill(process.pid, "SIGTERM");'));
    await assert.rejects(oracle.evaluate(request), /exited \(SIGTERM\)/);
    await assert.rejects(oracle.close(), /SIGTERM/);
});

test("oracle bounds a stalled request and cleans up the child", async context => {
    const oracle = fakeOracle(context, "setInterval(() => {}, 1000);", 200);
    await assert.rejects(oracle.evaluate(request), /timed out after 200 ms/);
    await assert.rejects(oracle.close(), /timed out after 200 ms/);
});

test("oracle bounds shutdown when a child ignores stdin EOF", async context => {
    const oracle = fakeOracle(context, "setInterval(() => {}, 1000);", 200);
    await assert.rejects(oracle.close(), /did not exit/);
});
