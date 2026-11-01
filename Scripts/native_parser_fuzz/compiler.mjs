import {isAbsolute, relative, resolve} from "node:path";
import {readStableFile} from "./evidence.mjs";

export const COMPILER_RESPONSE_LIMITS = {files: 16, bytes: 1_048_576, depth: 4};

export function compilerArguments(text) {
    const words = [];
    let word = "", quote = null, escaped = false, active = false;
    for (const character of text) {
        if (escaped) { word += character; escaped = false; active = true; }
        else if (character === "\\" && quote !== "'") { escaped = true; active = true; }
        else if (quote) { if (character === quote) { quote = null; } else { word += character; } }
        else if (character === "'" || character === '"') { quote = character; active = true; }
        else if (/\s/.test(character)) { if (active) { words.push(word); word = ""; active = false; } }
        else { word += character; active = true; }
    }
    if (quote || escaped) { throw new Error("Incomplete compiler argument quoting"); }
    if (active) { words.push(word); }
    if (words.length > 16_384) { throw new Error("Compiler argument inventory exceeds its bound"); }
    return words;
}

export function canaryCompileArguments(log) {
    const candidates = [];
    for (const line of log.split(/\r?\n/)) {
        if (!line.includes("Canaries.c")) { continue; }
        const words = compilerArguments(line);
        if (!/(?:^|\/)clang(?:\+\+)?$/.test(words[0] ?? "")) { continue; }
        const source = words[words.indexOf("-c") + 1];
        if (!words.includes("-c") || !source?.endsWith("/Sources/ParserFuzzCanaries/Canaries.c")) { continue; }
        candidates.push(words.slice(1));
    }
    if (candidates.length !== 1) { throw new Error("Build must retain exactly one actual Clang canary compile command"); }
    return candidates[0];
}

function responsePath(argument, cache) {
    const path = argument.slice(1);
    if (!isAbsolute(path) || resolve(path) !== path || !path.startsWith(`${cache}/`) || path.includes("\0")) {
        throw new Error("Compiler response file escaped the isolated build cache");
    }
    return relative(cache, path);
}

export function expandCompilerArguments(arguments_, cache, responses) {
    const used = new Set();
    const expand = (values, stack = []) => values.flatMap(value => {
        if (!value.startsWith("@")) { return [value]; }
        const path = responsePath(value, cache);
        if (stack.length >= COMPILER_RESPONSE_LIMITS.depth || stack.includes(path)) { throw new Error("Compiler response nesting is excessive or cyclic"); }
        const bytes = responses.get(path);
        if (!Buffer.isBuffer(bytes) || bytes.length > COMPILER_RESPONSE_LIMITS.bytes) { throw new Error("Missing bounded compiler response evidence"); }
        used.add(path);
        return expand(compilerArguments(bytes.toString("utf8")), [...stack, path]);
    });
    const args = expand(arguments_);
    if (args.length > 16_384 || responses.size > COMPILER_RESPONSE_LIMITS.files || [...responses.values()].reduce((sum, bytes) => sum + bytes.length, 0) > COMPILER_RESPONSE_LIMITS.bytes ||
        used.size !== responses.size) { throw new Error("Compiler response evidence inventory is incomplete, unused, or oversized"); }
    return args;
}

export async function captureCompilerResponses(log, cache) {
    const args = canaryCompileArguments(log), responses = new Map();
    let bytes = 0;
    const collect = async (values, stack = []) => {
        for (const value of values) {
            if (!value.startsWith("@")) { continue; }
            const path = responsePath(value, cache);
            if (stack.length >= COMPILER_RESPONSE_LIMITS.depth || stack.includes(path)) { throw new Error("Compiler response nesting is excessive or cyclic"); }
            if (responses.has(path)) { continue; }
            if (responses.size >= COMPILER_RESPONSE_LIMITS.files) { throw new Error("Too many compiler response files"); }
            const contents = await readStableFile(resolve(cache, path), COMPILER_RESPONSE_LIMITS.bytes - bytes);
            bytes += contents.length;
            responses.set(path, contents);
            await collect(compilerArguments(contents.toString("utf8")), [...stack, path]);
        }
    };
    await collect(args);
    expandCompilerArguments(args, cache, responses);
    return responses;
}

export function addressInstrumentationEnabled(args) {
    let enabled = false;
    for (const argument of args) {
        if (argument.startsWith("-fsanitize=") && argument.slice(11).split(",").includes("address")) { enabled = true; }
        if (argument.startsWith("-fno-sanitize=") && argument.slice(14).split(",").some(value => value === "address" || value === "all")) { enabled = false; }
    }
    return enabled;
}
