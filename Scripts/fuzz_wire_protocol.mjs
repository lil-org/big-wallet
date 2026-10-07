#!/usr/bin/env node

import assert from "node:assert/strict";
import {execFile, spawn} from "node:child_process";
import {mkdtemp, mkdir, readFile, rm, writeFile} from "node:fs/promises";
import {createRequire} from "node:module";
import {tmpdir} from "node:os";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {promisify, isDeepStrictEqual} from "node:util";
import {generateCases} from "./wire_protocol_fuzz_cases.mjs";

const execute = promisify(execFile);
const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const productionProtocol = require("../Safari Shared/Resources/protocol.generated.js");
const fixturePath = join(root, "Safari Shared/Tests/fixtures/wire_protocol_contract.json");
const regressionPath = join(root, "Safari Shared/Tests/fixtures/protocol_fuzz_regressions.json");

export function parseOptions(arguments_) {
    const options = {seed: 0xc0ffee, iterations: 5000, timeout: 10000, minimize: true};
    for (let index = 0; index < arguments_.length; index += 1) {
        const flag = arguments_[index];
        if (flag === "--help") { options.help = true; continue; }
        if (flag === "--no-minimize") { options.minimize = false; continue; }
        if (!["--seed", "--iterations", "--timeout-ms", "--replay", "--failure-dir"].includes(flag)) {
            throw new Error(`Unknown argument: ${flag}`);
        }
        const value = arguments_[++index];
        if (!value || value.startsWith("--")) { throw new Error(`Missing value for ${flag}`); }
        if (flag === "--replay") { options.replay = resolve(value); continue; }
        if (flag === "--failure-dir") { options.failureDirectory = resolve(value); continue; }
        const number = Number(value);
        const maximum = flag === "--seed" ? 0xffffffff : flag === "--iterations" ? 100000 : 120000;
        const minimum = flag === "--timeout-ms" ? 1 : 0;
        if (!/^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value) || !Number.isSafeInteger(number) || number < minimum || number > maximum) {
            throw new Error(`Invalid value for ${flag}: ${value}`);
        }
        options[flag === "--timeout-ms" ? "timeout" : flag.slice(2)] = number;
    }
    return options;
}

export function evaluateJavaScript(candidate, protocol = productionProtocol) {
    let value;
    try { value = JSON.parse(candidate.json); }
    catch { return {parsed: false, valid: false, objectValid: false}; }
    try { return evaluateParsedJavaScript(candidate, value, protocol); }
    catch (error) {
        return {parsed: true, valid: false, objectValid: false, invariant: `JavaScript oracle failure: ${error.message}`};
    }
}

function evaluateParsedJavaScript(candidate, value, protocol) {
    const valid = protocol.isValid(candidate.type, value);
    const decoded = protocol.decode(candidate.type, value);
    let built;
    let builtSuccessfully = false;
    try { built = protocol.build(candidate.type, value); builtSuccessfully = true; } catch {}
    const result = {parsed: true, valid, objectValid: valid && value !== null && typeof value === "object" && !Array.isArray(value)};
    if (valid !== builtSuccessfully || !valid && decoded !== null) {
        result.invariant = "JavaScript validate/decode/build disagree";
    } else if (valid) {
        const originalJSON = JSON.stringify(JSON.parse(candidate.json));
        result.decodedJSON = JSON.stringify(decoded);
        if (!isDeepStrictEqual(JSON.parse(result.decodedJSON), JSON.parse(originalJSON)) || !isDeepStrictEqual(built, decoded)) {
            result.invariant = "JavaScript snapshot changes the accepted input";
        }
        if (!protocol.isValid(candidate.type, decoded)) {
            result.invariant = "JavaScript snapshot fails revalidation";
        }
    }
    return result;
}

export function compareResults(candidate, javascript, swift) {
    if (javascript.invariant) { return javascript.invariant; }
    if (typeof candidate.expectedValid === "boolean" &&
        (javascript.valid !== candidate.expectedValid || swift.valid !== candidate.expectedValid)) {
        return "Independent expected validity does not match";
    }
    for (const key of ["valid", "objectValid"]) {
        if (javascript[key] !== swift[key]) { return `${key} decisions differ`; }
    }
    if (swift.dataValid !== javascript.valid) { return "Swift raw-data decoding decisions differ"; }
    if (swift.dataObjectValid !== javascript.objectValid) { return "Swift raw-data object decisions differ"; }
    if (javascript.valid) {
        const expected = JSON.parse(javascript.decodedJSON);
        for (const key of ["decodedJSON", "dataJSON", ...(javascript.objectValid ? ["objectJSON", "dataObjectJSON"] : [])]) {
            try {
                const actual = JSON.parse(swift[key], (_key, value) => Object.is(value, -0) ? 0 : value);
                if (!isDeepStrictEqual(actual, expected)) { return `${key} snapshot differs`; }
            } catch { return `Missing or invalid ${key} snapshot`; }
        }
    }
    return null;
}

export function startOracle(executable, {timeout = 10000, args = []} = {}) {
    const child = spawn(executable, args, {stdio: ["pipe", "pipe", "pipe"]});
    child.stdout.setEncoding("utf8");
    let output = "";
    let pending = null;
    let failure = null;
    let stderr = "";
    let nextID = 0;
    const fail = error => {
        failure ??= error;
        if (pending) {
            clearTimeout(pending.timer);
            pending.reject(failure);
            pending = null;
        }
        child.kill("SIGKILL");
    };
    child.stderr.on("data", data => { stderr = (stderr + data.toString()).slice(-16384); });
    child.on("error", fail);
    child.stdin.on("error", fail);
    const receive = line => {
        try {
            const result = JSON.parse(line);
            if (!pending || result.id !== pending.id ||
                !["parsed", "valid", "objectValid"].every(key => typeof result[key] === "boolean")) {
                throw new Error("Malformed, duplicate, or out-of-order Swift oracle response");
            }
            const current = pending;
            pending = null;
            clearTimeout(current.timer);
            current.resolve(result);
        } catch (error) { fail(new Error(`Invalid Swift oracle output: ${error.message}; line=${JSON.stringify(line.slice(0, 300))}`)); }
    };
    child.stdout.on("data", chunk => {
        output += chunk;
        if (output.length > 16 * 1024 * 1024) { fail(new Error("Swift oracle output exceeded 16 MiB")); return; }
        let boundary;
        while ((boundary = output.indexOf("\n")) !== -1) {
            const line = output.slice(0, boundary);
            output = output.slice(boundary + 1);
            receive(line);
        }
    });
    const completion = new Promise(resolveExit => {
        child.on("close", (code, signal) => {
            if (pending || code !== 0 || output.length > 0) {
                fail(new Error(`Swift oracle exited (${signal ?? code})${stderr ? `: ${stderr.trim()}` : ""}`));
            }
            resolveExit();
        });
    });
    return {
        evaluate(candidate) {
            if (failure) { return Promise.reject(failure); }
            if (pending) { return Promise.reject(new Error("Concurrent oracle requests are not supported")); }
            return new Promise((resolveResult, reject) => {
                const id = nextID++;
                const timer = setTimeout(() => fail(new Error(`Swift oracle timed out after ${timeout} ms`)), timeout);
                pending = {id, resolve: resolveResult, reject, timer};
                child.stdin.write(JSON.stringify({id, type: candidate.type, json: candidate.json}) + "\n");
            });
        },
        async close() {
            child.stdin.end();
            const timer = setTimeout(() => fail(new Error("Swift oracle did not exit")), timeout);
            await completion;
            clearTimeout(timer);
            if (failure) { throw failure; }
        },
        terminate() { child.kill("SIGKILL"); },
    };
}

export function* shrinkValues(value) {
    if (value !== null) { yield null; }
    if (typeof value === "number") {
        for (const number of [0, 1, -1, Math.trunc(value / 2)]) {
            if (number !== value) { yield number; }
        }
    } else if (typeof value === "string") {
        for (const string of ["", "a", Array.from(value).slice(0, Math.floor(Array.from(value).length / 2)).join("")]) {
            if (string !== value) { yield string; }
        }
    } else if (Array.isArray(value)) {
        if (value.length) { yield []; }
        for (let index = 0; index < value.length; index += 1) {
            yield value.filter((_, position) => position !== index);
            for (const child of shrinkValues(value[index])) {
                const result = value.slice();
                result[index] = child;
                yield result;
            }
        }
    } else if (value !== null && typeof value === "object") {
        const entries = Object.entries(value);
        if (entries.length) { yield {}; }
        for (const [key, child] of entries) {
            yield Object.fromEntries(entries.filter(([name]) => name !== key));
            for (const replacement of shrinkValues(child)) {
                yield Object.fromEntries(entries.map(([name, item]) => [name, name === key ? replacement : item]));
            }
        }
    }
}

export async function minimizeCase(candidate, stillFails, maximumAttempts = 200) {
    let current = {...candidate};
    delete current.expectedValid;
    let value;
    try { value = JSON.parse(current.json); } catch { return current; }
    let attempts = 0;
    while (attempts < maximumAttempts) {
        let changed = false;
        for (const smaller of shrinkValues(value)) {
            const json = JSON.stringify(smaller);
            if (json.length >= current.json.length) { continue; }
            if (++attempts > maximumAttempts) { break; }
            const next = {...current, json};
            if (await stillFails(next)) {
                current = next;
                value = smaller;
                changed = true;
                break;
            }
        }
        if (!changed) { break; }
    }
    return current;
}

export function replayCases(artifact) {
    const cases = Array.isArray(artifact) ? artifact : [artifact?.case];
    if (!cases.length || cases.some(value => !value || typeof value.type !== "string" || typeof value.json !== "string" ||
        Object.hasOwn(value, "expectedValid") && typeof value.expectedValid !== "boolean")) {
        throw new Error("Replay must contain {type, json, expectedValid?} cases or a saved failure artifact");
    }
    return cases;
}

export async function prepareFailure(candidate, result, evaluate, minimize = true) {
    let minimized = candidate;
    if (minimize && !result.message.startsWith("Independent") && !result.swift.failure) {
        try {
            minimized = await minimizeCase(candidate, async value => (await evaluate(value)).message === result.message);
        } catch {
            minimized = candidate;
        }
    }
    if (result.swift.failure) { return {case: candidate, ...result, reproduced: false}; }
    let checked = await evaluate(minimized);
    if (checked.message !== result.message) {
        minimized = candidate;
        checked = await evaluate(candidate);
    }
    const reproduced = checked.message === result.message;
    return {case: minimized, ...(reproduced ? checked : result), reproduced};
}

async function main() {
    const options = parseOptions(process.argv.slice(2));
    if (options.help) {
        console.log("Usage: node Scripts/fuzz_wire_protocol.mjs [--seed uint32] [--iterations count] [--replay file] [--failure-dir directory] [--timeout-ms milliseconds] [--no-minimize]");
        return;
    }
    await execute(process.execPath, [join(root, "Scripts/generate_wire_protocol.mjs"), "--check"], {timeout: 30000});
    const definition = JSON.parse(await readFile(join(root, "Safari Shared/Protocol/wire-protocol.json"), "utf8"));
    const fixtures = JSON.parse(await readFile(fixturePath, "utf8"));
    const contracts = Object.keys(definition.types).sort();
    assert.deepEqual([...new Set(fixtures.filter(fixture => fixture.valid).map(fixture => fixture.type))].sort(), contracts,
        "Every contract needs an independently labeled positive fixture");
    assert(fixtures.some(fixture => !fixture.valid), "Independent negative fixtures are required");
    const cases = options.replay
        ? replayCases(JSON.parse(await readFile(options.replay, "utf8")))
        : [...replayCases(JSON.parse(await readFile(regressionPath, "utf8"))),
            ...generateCases({...options, definition, fixtures}).map(({value, ...candidate}) => ({...candidate, json: JSON.stringify(value)}))];
    for (const candidate of cases) {
        assert(contracts.includes(candidate.type), `Unknown contract: ${candidate.type}`);
        assert.equal(typeof candidate.json, "string", "Candidate must be JSON serializable");
    }
    const directory = await mkdtemp(join(tmpdir(), "big-wallet-protocol-fuzz-"));
    let oracle;
    try {
        const executable = join(directory, "protocol-oracle");
        await execute("xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library",
            join(root, "Safari Shared/Protocol/WireProtocol.generated.swift"),
            join(root, "Scripts/ProtocolFuzzOracle.swift"), "-o", executable], {timeout: 120000, maxBuffer: 1024 * 1024});
        const {stdout} = await execute(executable, ["--list-types"], {timeout: options.timeout});
        assert.deepEqual(JSON.parse(stdout).sort(), contracts, "Swift and schema contract inventories differ");
        oracle = startOracle(executable, options);
        const evaluate = async candidate => {
            const javascript = evaluateJavaScript(candidate);
            let swift;
            try { swift = await oracle.evaluate(candidate); }
            catch (error) { return {message: `Swift oracle failure: ${error.message}`, javascript, swift: {failure: true}}; }
            return {message: compareResults(candidate, javascript, swift), javascript, swift};
        };
        let accepted = 0;
        for (const [index, candidate] of cases.entries()) {
            const result = await evaluate(candidate);
            if (!result.message) { accepted += Number(result.javascript.valid); continue; }
            const failure = await prepareFailure(candidate, result, evaluate, options.minimize);
            const failureDirectory = options.failureDirectory ?? await mkdtemp(join(tmpdir(), "big-wallet-protocol-failure-"));
            await mkdir(failureDirectory, {recursive: true});
            const runDirectory = await mkdtemp(join(failureDirectory, `seed-${options.seed}-case-${index}-`));
            const path = join(runDirectory, "failure.json");
            await writeFile(path, JSON.stringify({version: 1, seed: options.seed, index,
                originalCase: candidate, ...failure}, null, 2) + "\n", {flag: "wx"});
            const quotedPath = "'" + path.replaceAll("'", "'\\''") + "'";
            throw new Error(`${result.message}: ${candidate.name ?? candidate.type}\nSaved failure: ${path}\nReplay: node Scripts/fuzz_wire_protocol.mjs --replay ${quotedPath}`);
        }
        await oracle.close();
        oracle = null;
        console.log(`Protocol differential fuzz passed: ${cases.length} cases (${accepted} accepted, ${cases.length - accepted} rejected), ${contracts.length} contracts, seed ${options.seed}.`);
    } finally {
        if (oracle) {
            oracle.terminate();
            await oracle.close().catch(() => {});
        }
        await rm(directory, {recursive: true, force: true});
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch(error => {
        console.error(error.stderr || error.message);
        process.exitCode = 1;
    });
}
