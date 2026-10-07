#!/usr/bin/env node

import {readFileSync, writeFileSync, mkdirSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const arguments_ = process.argv.slice(2);
let mode = null;
let root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
let definitionPath;
for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--write" || argument === "--check") {
        if (mode) { throw new Error("Choose exactly one of --write and --check"); }
        mode = argument;
    } else if (argument === "--root" || argument === "--definition") {
        const value = arguments_[++index];
        if (!value || value.startsWith("--")) { throw new Error(`Missing value for ${argument}`); }
        if (argument === "--root") { root = resolve(value); }
        else { definitionPath = resolve(value); }
    } else { throw new Error(`Unknown argument: ${argument}`); }
}
if (!mode) { throw new Error("Usage: generate_wire_protocol.mjs --write|--check [--root path] [--definition path]"); }
definitionPath ??= resolve(root, "Safari Shared/Protocol/wire-protocol.json");
const definition = JSON.parse(readFileSync(definitionPath, "utf8"));
const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
function keys(value, allowed, required = allowed) {
    if (!object(value) || Object.keys(value).some(key => !allowed.includes(key)) ||
        required.some(key => !Object.hasOwn(value, key))) { throw new Error("Invalid definition keys"); }
}
keys(definition, ["definitionVersion", "constants", "types", "depthReservations"]);
if (definition.definitionVersion !== 1 || !object(definition.constants) || !object(definition.types)) {
    throw new Error("Unsupported protocol definition");
}
const constants = definition.constants;
const numericConstants = ["WORKFLOW_VERSION", "PROVIDER_REPLACED_ERROR_CODE", "MAX_RESPONSE_READY_IDS", "MAX_MANUAL_SWITCH_JSON_LENGTH", "MAX_PAYLOAD_BYTES", "MAX_POPUP_RESPONSE_BYTES", "MAX_JSON_DEPTH"];
const stringConstants = ["PAGE_TO_CONTENT_DIRECTION", "CONTENT_TO_PAGE_DIRECTION", "PROVIDER_REPLACED_MESSAGE", "PRIVATE_BROWSING_KEY", "MANUAL_SWITCH_INTENT_SUBJECT", "MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT"];
keys(constants, [...numericConstants, ...stringConstants, "WORKFLOW_POLICY", "RUNTIME_MESSAGE_SUBJECTS"]);
for (const key of numericConstants) { if (!Number.isSafeInteger(constants[key]) || constants[key] <= 0) { throw new Error(`Invalid constant ${key}`); } }
for (const key of stringConstants) { if (typeof constants[key] !== "string" || constants[key].length === 0) { throw new Error(`Invalid constant ${key}`); } }
const policy = constants.WORKFLOW_POLICY;
const policyNumbers = ["maximumRequests", "maximumRequestsPerHost", "maximumRetainedRequests", "requestTTLMilliseconds", "responseExpiryMilliseconds"];
keys(policy, ["maximumNativeChainIdHex", ...policyNumbers, "selectionAccountCoins", "solanaClusterValues"]);
for (const key of policyNumbers) { if (!Number.isSafeInteger(policy[key]) || policy[key] <= 0) { throw new Error(`Invalid workflow policy ${key}`); } }
if (typeof policy.maximumNativeChainIdHex !== "string" || !/^[1-9a-f][0-9a-f]{0,15}$/.test(policy.maximumNativeChainIdHex) || policy.maximumNativeChainIdHex.length === 16 && policy.maximumNativeChainIdHex > "7fffffffffffffff") { throw new Error("Invalid native chain bound"); }
function stringList(value) {
    return Array.isArray(value) && value.length > 0 && value.every(item => typeof item === "string" && item.length > 0) && new Set(value).size === value.length;
}
for (const key of ["selectionAccountCoins", "solanaClusterValues"]) { if (!stringList(policy[key])) { throw new Error(`Invalid workflow policy ${key}`); } }
const routes = constants.RUNTIME_MESSAGE_SUBJECTS;
keys(routes, ["worker", "content", "popup"]);
keys(routes.worker, ["content", "popup"]);
keys(routes.content, ["worker", "popup"]);
keys(routes.popup, ["worker"]);
for (const receivers of Object.values(routes)) { for (const subjects of Object.values(receivers)) { if (!stringList(subjects)) { throw new Error("Invalid runtime routes"); } } }
const types = definition.types;
const depthReservations = definition.depthReservations;
if (!object(depthReservations)) { throw new Error("Invalid depth reservations"); }
for (const [name, reserved] of Object.entries(depthReservations)) {
    if (!Object.hasOwn(types, name) || !Number.isSafeInteger(reserved) || reserved < 0 || reserved >= constants.MAX_JSON_DEPTH) {
        throw new Error(`Invalid depth reservation ${name}`);
    }
}
const formats = ["privateToken", "uuid", "authorityContext", "ethereumChain", "solanaPublicKey"];
function validateRule(rule) {
    if (!object(rule)) { throw new Error("Invalid rule"); }
    if (Object.hasOwn(rule, "constant")) {
        keys(rule, ["constant"]);
        if (!Object.hasOwn(definition.constants, rule.constant) || !["string", "boolean", "number"].includes(typeof definition.constants[rule.constant])) { throw new Error(`Unknown scalar constant ${rule.constant}`); }
    } else if (Object.hasOwn(rule, "ref")) {
        keys(rule, ["ref"]);
        if (!Object.hasOwn(types, rule.ref)) { throw new Error(`Unknown reference ${rule.ref}`); }
    } else if (Object.hasOwn(rule, "const")) {
        keys(rule, ["const"]);
        if (!["string", "boolean", "number"].includes(typeof rule.const) && rule.const !== null) { throw new Error("Invalid constant"); }
        if (typeof rule.const === "number" && !Number.isFinite(rule.const)) { throw new Error("Nonfinite constant"); }
    } else if (Object.hasOwn(rule, "enum")) {
        keys(rule, ["enum"]);
        if (!Array.isArray(rule.enum) || rule.enum.length === 0 || rule.enum.some(value => typeof value !== "string") || new Set(rule.enum).size !== rule.enum.length) { throw new Error("Invalid enum"); }
    } else if (Object.hasOwn(rule, "oneOf")) {
        keys(rule, ["oneOf"]);
        if (!Array.isArray(rule.oneOf) || rule.oneOf.length < 2) { throw new Error("Invalid union"); }
        rule.oneOf.forEach(validateRule);
    } else {
        switch (rule.type) {
        case "object":
            keys(rule, ["type", "required", "optional"]);
            if (!object(rule.required) || !object(rule.optional) || Object.keys(rule.required).some(key => Object.hasOwn(rule.optional, key))) { throw new Error("Invalid fields"); }
            for (const [name, child] of Object.entries({...rule.required, ...rule.optional})) {
                if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(name)) { throw new Error(`Invalid field ${name}`); }
                validateRule(child);
            }
            break;
        case "array":
            keys(rule, ["type", "items", "minItems", "maxItems"], ["type", "items"]);
            validateRule(rule.items);
            for (const bound of [rule.minItems, rule.maxItems]) { if (bound !== undefined && (!Number.isSafeInteger(bound) || bound < 0)) { throw new Error("Invalid array bound"); } }
            if (rule.minItems > rule.maxItems) { throw new Error("Inverted array bounds"); }
            break;
        case "dictionary":
            keys(rule, ["type", "values"]); validateRule(rule.values); break;
        case "string":
            keys(rule, ["type", "minLength", "maxLength", "format", "excluding"], ["type"]);
            for (const bound of [rule.minLength, rule.maxLength]) { if (bound !== undefined && (!Number.isSafeInteger(bound) || bound < 0)) { throw new Error("Invalid string bound"); } }
            if (rule.minLength > rule.maxLength || rule.format !== undefined && !formats.includes(rule.format)) { throw new Error("Invalid string constraint"); }
            if (rule.excluding !== undefined && (!Array.isArray(rule.excluding) || rule.excluding.some(value => typeof value !== "string"))) { throw new Error("Invalid string exclusion"); }
            break;
        case "integer":
            keys(rule, ["type", "minimum", "maximum"]);
            if (!Number.isSafeInteger(rule.minimum) || !Number.isSafeInteger(rule.maximum) || rule.minimum > rule.maximum) { throw new Error("Invalid integer bounds"); }
            break;
        case "wholeNumber":
            keys(rule, ["type", "minimum", "maximum"]);
            if (!Number.isInteger(rule.minimum) || !Number.isInteger(rule.maximum) || rule.minimum > rule.maximum) { throw new Error("Invalid whole number bounds"); }
            break;
        case "boolean": case "number": case "null": case "json": keys(rule, ["type"]); break;
        default: throw new Error(`Unsupported rule ${rule.type}`);
        }
    }
}
for (const [name, rule] of Object.entries(types)) {
    if (!/^[A-Z][A-Za-z0-9]*$/.test(name)) { throw new Error(`Invalid type name ${name}`); }
    validateRule(rule);
}
function checkReferences(name, active = new Set()) {
    if (active.has(name)) { throw new Error(`Recursive schema reference ${name}`); }
    const next = new Set(active).add(name);
    function visit(rule) {
        if (rule.ref) { checkReferences(rule.ref, next); }
        else if (rule.oneOf) { rule.oneOf.forEach(visit); }
        else if (rule.type === "object") { Object.values({...rule.required, ...rule.optional}).forEach(visit); }
        else if (rule.type === "array") { visit(rule.items); }
        else if (rule.type === "dictionary") { visit(rule.values); }
    }
    visit(types[name]);
}
Object.keys(types).forEach(name => checkReferences(name));

const nodes = [];
const nodeIDs = new Map();
function node(rule) {
    const serialized = JSON.stringify(rule);
    if (nodeIDs.has(serialized)) { return nodeIDs.get(serialized); }
    const id = nodes.length;
    nodes.push(rule); nodeIDs.set(serialized, id);
    if (rule.oneOf) { rule.oneOf.forEach(node); }
    if (rule.type === "object") { Object.values({...rule.required, ...rule.optional}).forEach(node); }
    if (rule.items) { node(rule.items); }
    if (rule.values) { node(rule.values); }
    return id;
}
Object.values(types).forEach(node);
const quote = JSON.stringify;
const lowerCamel = name => name.replace(/^[A-Z]+(?=[A-Z][a-z]|$)/, value => value.toLowerCase()).replace(/^[A-Z]/, value => value.toLowerCase());
const reservedNames = new Set(["Message", "JSONValue", "Key", "WireProtocol", "String", "Double", "Bool", "Int", "Int64", "UInt64", "Decimal", "NSNumber", "NSDecimalNumber", "NSNull", "Set", "Any", "Decoder", "Encoder", "CodingKey", "Codable", "DecodingError", "EncodingError", "ProtocolJSONValue", "ProtocolTypeName"]);
const swiftCases = new Set();
const swiftKeywords = new Set(["class", "struct", "enum", "protocol", "extension", "func", "var", "let", "import", "case", "default", "switch", "if", "else", "guard", "return", "throw", "throws", "try", "catch", "do", "for", "in", "while", "repeat", "break", "continue", "defer", "where", "as", "is", "nil", "true", "false", "self", "super", "associatedtype", "typealias", "init", "deinit", "subscript", "operator", "precedencegroup", "inout", "Any", "Self"]);
for (const name of Object.keys(types)) {
    const caseName = lowerCamel(name);
    if (reservedNames.has(name) || swiftCases.has(caseName) || swiftKeywords.has(caseName)) { throw new Error(`Conflicting generated type name ${name}`); }
    swiftCases.add(caseName);
}
const jsCall = (rule, value) => `n${node(rule)}(${value}, context)`;
function jsNode(rule, id) {
    if (rule.constant) { rule = {const: definition.constants[rule.constant]}; }
    let body;
    if (rule.ref) { body = `return ${jsCall(types[rule.ref], "value")};`; }
    else if (Object.hasOwn(rule, "const")) { body = `if (value !== ${quote(rule.const)}) { invalid(); } return value;`; }
    else if (rule.enum) { body = `if (${rule.enum.map(value => `value !== ${quote(value)}`).join(" && ")}) { invalid(); } return value;`; }
    else if (rule.oneOf) { body = rule.oneOf.map(child => `try { return ${jsCall(child, "value")}; } catch {}`).join("\n        ") + "\n        return invalid();"; }
    else switch (rule.type) {
    case "string": body = `if (typeof value !== "string"${rule.minLength !== undefined ? ` || value.length < ${rule.minLength}` : ""}${rule.maxLength !== undefined ? ` || value.length > ${rule.maxLength}` : ""}${rule.format ? ` || !format${rule.format}(value)` : ""}${(rule.excluding || []).map(value => ` || value === ${quote(value)}`).join("")}) { invalid(); } return value;`; break;
    case "integer": body = `if (!integer(value) || value < ${rule.minimum} || value > ${rule.maximum}) { invalid(); } return value;`; break;
    case "wholeNumber": body = `if (!wholeNumber(value) || value < ${rule.minimum} || value > ${rule.maximum}) { invalid(); } return value;`; break;
    case "number": body = `if (typeof value !== "number" || !finite(value)) { invalid(); } return value;`; break;
    case "boolean": body = `if (typeof value !== "boolean") { invalid(); } return value;`; break;
    case "null": body = `if (value !== null) { invalid(); } return null;`; break;
    case "json": body = "return json(value, context);"; break;
    case "array": body = `return array(value, context, n${node(rule.items)}, ${rule.minItems ?? 0}, ${rule.maxItems ?? "Infinity"});`; break;
    case "dictionary": body = `return dictionary(value, context, n${node(rule.values)});`; break;
    case "object": {
        const required = Object.keys(rule.required), optional = Object.keys(rule.optional);
        const lines = [`record(value, ${quote(required)}, ${quote(optional)});`, "const previous = enter(value, context);", "try {", "    const result = create(null);"];
        for (const [key, child] of Object.entries(rule.required)) { lines.push(`    put(result, ${quote(key)}, ${jsCall(child, `read(value, ${quote(key)})`)});`); }
        for (const [key, child] of Object.entries(rule.optional)) { lines.push(`    if (descriptor(value, ${quote(key)})) { put(result, ${quote(key)}, ${jsCall(child, `read(value, ${quote(key)})`)}); }`); }
        lines.push("    return freeze(result);", "} finally { context.path = previous; }");
        body = lines.join("\n        "); break;
    }
    }
    return `    function n${id}(value, context) {\n        ${body}\n    }`;
}

const jsRuntime = String.raw`
    const descriptor = Object.getOwnPropertyDescriptor;
    const ownKeys = Reflect.ownKeys;
    const create = Object.create;
    const define = Object.defineProperty;
    const freeze = Object.freeze;
    const isArray = Array.isArray;
    const integer = Number.isSafeInteger;
    const wholeNumber = Number.isInteger;
    const finite = Number.isFinite;
    const apply = Reflect.apply;
    const hasOwn = Object.prototype.hasOwnProperty;
    const string = String;
    const regexpExec = RegExp.prototype.exec;
    const indexOf = String.prototype.indexOf;
    const slice = String.prototype.slice;
    const normalize = String.prototype.normalize;
    const ErrorType = TypeError;
    const patterns = freeze({
        privateToken: /^[0-9a-f]{32}$/,
        uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
        authorityContext: /^[0-9a-f]{64}$/,
        ethereumChain: /^0x[1-9a-f][0-9a-f]*$/,
    });
    function invalid() { throw new ErrorType("Invalid Big Wallet protocol value"); }
    function read(value, key) {
        const property = descriptor(value, key);
        if (!property || !apply(hasOwn, property, ["value"])) { return invalid(); }
        return property.value;
    }
    function put(value, key, item) {
        define(value, key, {__proto__: null, enumerable: true, value: item});
    }
    function maximumJSONDepth(typeName) {
        switch (typeName) {
${Object.entries(depthReservations).map(([name, reserved]) => `        case ${quote(name)}: return ${constants.MAX_JSON_DEPTH - reserved};`).join("\n")}
        default: return ${constants.MAX_JSON_DEPTH};
        }
    }
    function enter(value, context) {
        const previous = context.path;
        const depth = previous ? previous.depth + 1 : 1;
        if (depth > context.maximumDepth) { invalid(); }
        for (let path = previous; path; path = path.parent) {
            if (path.value === value) { invalid(); }
        }
        context.path = {__proto__: null, value, parent: previous, depth};
        return previous;
    }
    function record(value, required, optional) {
        if (!value || typeof value !== "object" || isArray(value)) { invalid(); }
        const names = ownKeys(value);
        if (names.length < required.length || names.length > required.length + optional.length) { invalid(); }
        for (let index = 0; index < names.length; index += 1) {
            const name = names[index];
            let allowed = false;
            for (let i = 0; i < required.length; i += 1) { if (name === required[i]) { allowed = true; } }
            for (let i = 0; i < optional.length; i += 1) { if (name === optional[i]) { allowed = true; } }
            if (!allowed) { invalid(); }
            read(value, name);
        }
        for (let index = 0; index < required.length; index += 1) { read(value, required[index]); }
    }
    function array(value, context, decodeItem, minimum, maximum) {
        if (!isArray(value)) { return invalid(); }
        const length = read(value, "length");
        if (!integer(length) || length < minimum || length > maximum) { invalid(); }
        const names = ownKeys(value);
        let hasToJSON = false;
        for (let index = 0; index < names.length; index += 1) {
            const name = names[index];
            if (name === "length") { continue; }
            if (name === "toJSON") {
                const property = descriptor(value, name);
                if (property.enumerable || !apply(hasOwn, property, ["value"]) || property.value !== undefined) { invalid(); }
                hasToJSON = true;
                continue;
            }
            if (typeof name !== "string" || !integer(+name) || +name < 0 || +name >= length || string(+name) !== name) { invalid(); }
        }
        if (names.length !== length + 1 + (hasToJSON ? 1 : 0)) { invalid(); }
        const previous = enter(value, context);
        try {
            const result = [];
            for (let index = 0; index < length; index += 1) { put(result, index, decodeItem(read(value, string(index)), context)); }
            define(result, "toJSON", {__proto__: null, value: undefined});
            return freeze(result);
        } finally { context.path = previous; }
    }
    function dictionary(value, context, decodeItem) {
        if (!value || typeof value !== "object" || isArray(value)) { return invalid(); }
        const previous = enter(value, context);
        try {
            const names = ownKeys(value);
            const canonicalNames = create(null);
            for (let index = 0; index < names.length; index += 1) {
                if (typeof names[index] !== "string") { invalid(); }
                const canonicalName = apply(normalize, names[index], ["NFC"]);
                if (apply(hasOwn, canonicalNames, [canonicalName])) { invalid(); }
                put(canonicalNames, canonicalName, true);
            }
            const result = create(null);
            for (let index = 0; index < names.length; index += 1) {
                put(result, names[index], decodeItem(read(value, names[index]), context));
            }
            return freeze(result);
        } finally { context.path = previous; }
    }
    function json(value, context) {
        if (value === null || typeof value === "string" || typeof value === "boolean" || typeof value === "number" && finite(value)) { return value; }
        return isArray(value) ? array(value, context, json, 0, Infinity) : dictionary(value, context, json);
    }
    function matches(pattern, value) {
        const match = apply(regexpExec, pattern, [value]);
        return match !== null && read(match, "0").length === value.length;
    }
    function formatprivateToken(value) { return matches(patterns.privateToken, value); }
    function formatuuid(value) { return matches(patterns.uuid, value); }
    function formatauthorityContext(value) { return matches(patterns.authorityContext, value); }
    function formatethereumChain(value) {
        if (!matches(patterns.ethereumChain, value)) { return false; }
        const digits = apply(slice, value, [2]);
        return digits.length < ${policy.maximumNativeChainIdHex.length} || digits.length === ${policy.maximumNativeChainIdHex.length} && digits <= ${quote(policy.maximumNativeChainIdHex)};
    }
    function formatsolanaPublicKey(value) {
        if (value.length < 32 || value.length > 44) { return false; }
        const bytes = create(null);
        bytes[0] = 0;
        let count = 1;
        for (let index = 0; index < value.length; index += 1) {
            let carry = apply(indexOf, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz", [value[index]]);
            if (carry < 0) { return false; }
            for (let byte = 0; byte < count; byte += 1) { carry += bytes[byte] * 58; bytes[byte] = carry & 255; carry >>= 8; }
            while (carry > 0) { bytes[count++] = carry & 255; carry >>= 8; }
        }
        let zeros = 0;
        while (zeros < value.length && value[zeros] === "1") { zeros += 1; }
        return zeros + (count === 1 && bytes[0] === 0 ? 0 : count) === 32;
    }
`;

function jsType(rule) {
    if (rule.ref) { return rule.ref; }
    if (rule.constant) { return quote(definition.constants[rule.constant]); }
    if (Object.hasOwn(rule, "const")) { return quote(rule.const); }
    if (rule.enum) { return `(${rule.enum.map(quote).join("|")})`; }
    if (rule.oneOf) { return `(${rule.oneOf.map(jsType).join("|")})`; }
    switch (rule.type) {
    case "string": case "number": case "boolean": case "null": return rule.type;
    case "integer": case "wholeNumber": return "number";
    case "json": return "ProtocolJSONValue";
    case "array": return `Array<${jsType(rule.items)}>`;
    case "dictionary": return `Object<string, ${jsType(rule.values)}>`;
    case "object": return `{${[
        ...Object.entries(rule.required).map(([name, child]) => `${name}: ${jsType(child)}`),
        ...Object.entries(rule.optional).map(([name, child]) => `${name}?: ${jsType(child)}`),
    ].join(", ")}}`;
    }
}

function javascript() {
    return `// Generated by Scripts/generate_wire_protocol.mjs.\n(function (root, factory) {\n    const protocol = factory();\n    if (typeof module === "object" && module.exports) { module.exports = protocol; }\n    else { root.BigWalletProtocol = protocol; }\n})(typeof globalThis !== "undefined" ? globalThis : this, function () {\n    "use strict";\n${jsRuntime}\n${nodes.map(jsNode).join("\n\n")}\n\n    const constants = json(${quote(definition.constants)}, {path: null, nodes: 0, maximumDepth: ${constants.MAX_JSON_DEPTH}});\n    /** @typedef {null|boolean|number|string|Array<ProtocolJSONValue>|Object<string, ProtocolJSONValue>} ProtocolJSONValue */\n${Object.entries(types).map(([name, rule]) => `    /** @typedef {${jsType(rule).replaceAll("*/", "*\\/")}} ${name} */`).join("\n")}\n    /** @typedef {${Object.keys(types).map(quote).join("|")}} ProtocolTypeName */\n\n    /**\n     * @param {ProtocolTypeName} typeName\n     * @param {unknown} value\n     * @returns {ProtocolJSONValue|null}\n     */\n    function decode(typeName, value) {\n        try {\n            const context = {__proto__: null, path: null, nodes: 0, maximumDepth: maximumJSONDepth(typeName)};\n            switch (typeName) {\n${Object.entries(types).map(([name, rule]) => `            case ${quote(name)}: return ${jsCall(rule, "value")};`).join("\n")}\n            default: return null;\n            }\n        } catch { return null; }\n    }\n    /** @param {ProtocolTypeName} typeName @param {unknown} value @returns {boolean} */\n    function isValid(typeName, value) {\n        if (value === null) {\n            try {\n                const context = {__proto__: null, path: null, nodes: 0, maximumDepth: maximumJSONDepth(typeName)};\n                switch (typeName) {\n${Object.entries(types).map(([name, rule]) => `                case ${quote(name)}: ${jsCall(rule, "value")}; return true;`).join("\n")}\n                default: return false;\n                }\n            } catch { return false; }\n        }\n        return decode(typeName, value) !== null;\n    }\n    /**\n     * @param {ProtocolTypeName} typeName\n     * @param {unknown} value\n     * @returns {ProtocolJSONValue}\n     * @throws {TypeError} When the value does not match the named contract.\n     */\n    function build(typeName, value) {\n        const result = decode(typeName, value);\n        if (result === null && !isValid(typeName, value)) { invalid(); }\n        return result;\n    }\n    return freeze({constants, maximumJSONDepth, decode, isValid, build});\n});\n`;
}

function swiftLiteral(value) {
    if (typeof value === "string") {
        let result = '"';
        for (const character of value) {
            const code = character.codePointAt(0);
            if (character === '"' || character === "\\") { result += "\\" + character; }
            else if (code < 32 || code === 0x7f || code === 0x2028 || code === 0x2029) { result += `\\u{${code.toString(16)}}`; }
            else { result += character; }
        }
        return result + '"';
    }
    if (value === null) { return "NSNull()"; }
    return String(value);
}
const swiftCall = (rule, value) => `n${node(rule)}(${value})`;
function swiftNode(rule, id) {
    if (rule.constant) { rule = {const: definition.constants[rule.constant]}; }
    let body;
    if (rule.ref) { body = `return ${swiftCall(types[rule.ref], "value")}`; }
    else if (Object.hasOwn(rule, "const")) {
        body = typeof rule.const === "boolean" ? `return boolean(value) == ${rule.const}` : typeof rule.const === "number" ? `return number(value) == ${rule.const}` : rule.const === null ? "return value is NSNull" : `guard let value = value as? String else { return false }\n        return exactString(value, ${swiftLiteral(rule.const)})`;
    } else if (rule.enum) { body = `guard let value = value as? String else { return false }\n        return ${rule.enum.map(item => `exactString(value, ${swiftLiteral(item)})`).join(" || ")}`; }
    else if (rule.oneOf) { body = `return ${rule.oneOf.map(child => swiftCall(child, "value")).join(" || ")}`; }
    else switch (rule.type) {
    case "string": {
        const checks = [rule.minLength !== undefined ? `value.utf16.count >= ${rule.minLength}` : null, rule.maxLength !== undefined ? `value.utf16.count <= ${rule.maxLength}` : null, rule.format ? `format${rule.format}(value)` : null, ...(rule.excluding || []).map(value => `!exactString(value, ${swiftLiteral(value)})`)].filter(Boolean);
        body = checks.length ? `guard let value = value as? String else { return false }\n        return ${checks.join(" && ")}` : "return value is String";
        break;
    }
    case "integer": body = `guard let value = number(value), value.rounded(.towardZero) == value else { return false }\n        return value >= ${rule.minimum}.0 && value <= ${rule.maximum}.0`; break;
    case "wholeNumber": body = `guard let value = number(value), value.rounded(.towardZero) == value else { return false }\n        return value >= ${rule.minimum}.0 && value <= ${rule.maximum}.0`; break;
    case "number": body = "return number(value) != nil"; break;
    case "boolean": body = "return boolean(value) != nil"; break;
    case "null": body = "return value is NSNull"; break;
    case "json": body = "return true"; break;
    case "array": body = `guard let values = value as? [Any], values.count >= ${rule.minItems ?? 0}${rule.maxItems === undefined ? "" : `, values.count <= ${rule.maxItems}`} else { return false }\n        return values.allSatisfy { ${swiftCall(rule.items, "$0")} }`; break;
    case "dictionary": body = `guard let values = value as? [String: Any] else { return false }\n        return values.values.allSatisfy { ${swiftCall(rule.values, "$0")} }`; break;
    case "object": {
        const required = Object.keys(rule.required), optional = Object.keys(rule.optional);
        const list = values => `[${values.map(quote).join(", ")}]`;
        const lines = [`guard let value = value as? [String: Any], exactKeys(value, required: ${list(required)}, optional: ${list(optional)}) else { return false }`];
        for (const [key, child] of Object.entries(rule.required)) { lines.push(`guard let field${required.indexOf(key)} = value[${quote(key)}], ${swiftCall(child, `field${required.indexOf(key)}`)} else { return false }`); }
        for (const [key, child] of Object.entries(rule.optional)) { lines.push(`if let field = value[${quote(key)}], !${swiftCall(child, "field")} { return false }`); }
        lines.push("return true"); body = lines.join("\n        "); break;
    }
    }
    return `    private static func n${id}(_ value: Any) -> Bool {\n        ${body}\n    }`;
}

const swiftRuntime = String.raw`
    private static func exactKeys(_ value: [String: Any], required: [String], optional: [String]) -> Bool {
        let keys = Set(value.keys.map { Data($0.utf8) })
        let requiredKeys = Set(required.map { Data($0.utf8) })
        let optionalKeys = Set(optional.map { Data($0.utf8) })
        return requiredKeys.isSubset(of: keys) && keys.isSubset(of: requiredKeys.union(optionalKeys))
    }

    private static func exactString(_ value: String, _ expected: String) -> Bool {
        value.utf8.elementsEqual(expected.utf8)
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }

    private static func formatprivateToken(_ value: String) -> Bool { matches(value, "^[0-9a-f]{32}$") }
    private static func formatuuid(_ value: String) -> Bool { matches(value, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") }
    private static func formatauthorityContext(_ value: String) -> Bool { matches(value, "^[0-9a-f]{64}$") }
    private static func formatethereumChain(_ value: String) -> Bool {
        guard matches(value, "^0x[1-9a-f][0-9a-f]*$") else { return false }
        let digits = String(value.dropFirst(2))
        return digits.count < ${policy.maximumNativeChainIdHex.length} || digits.count == ${policy.maximumNativeChainIdHex.length} && digits <= ${swiftLiteral(policy.maximumNativeChainIdHex)}
    }

    private static func formatsolanaPublicKey(_ value: String) -> Bool {
        guard (32...44).contains(value.utf8.count) else { return false }
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
        var bytes = [Int](repeating: 0, count: 1)
        for character in value.utf8 {
            guard let digit = alphabet.firstIndex(of: character) else { return false }
            var carry = digit
            for index in bytes.indices { carry += bytes[index] * 58; bytes[index] = carry & 255; carry >>= 8 }
            while carry > 0 { bytes.append(carry & 255); carry >>= 8 }
        }
        let zeros = value.utf8.prefix(while: { $0 == 49 }).count
        return zeros + (bytes.count == 1 && bytes[0] == 0 ? 0 : bytes.count) == 32
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    indirect enum JSONValue: Decodable, Sendable {
        case null, boolean(Bool), integer(Int64), unsignedInteger(UInt64), decimal(Decimal), number(Double), string(String)
        case array([JSONValue]), object([String: JSONValue])

        init?(_ value: Any, depth: Int = 0, maximumDepth: Int = WireProtocol.maximumJSONDepth) {
            if value is NSNull { self = .null }
            else if let boolean = WireProtocol.boolean(value) { self = .boolean(boolean) }
            else if let number = value as? NSNumber, WireProtocol.number(value) != nil {
                let kind = String(cString: number.objCType)
                if let decimal = number as? NSDecimalNumber { self = .decimal(decimal.decimalValue) }
                else if kind == "f" || kind == "d" { self = .number(number.doubleValue) }
                else if kind == "Q" { self = .unsignedInteger(number.uint64Value) }
                else { self = .integer(number.int64Value) }
            }
            else if let string = value as? String { self = .string(string) }
            else if let array = value as? [Any] {
                guard depth < maximumDepth else { return nil }
                var result = [JSONValue]()
                for item in array { guard let item = JSONValue(item, depth: depth + 1, maximumDepth: maximumDepth) else { return nil }; result.append(item) }
                self = .array(result)
            } else if let object = value as? NSDictionary {
                guard depth < maximumDepth,
                      let keys = object.allKeys as? [String],
                      Set(keys).count == object.count else { return nil }
                var result = [String: JSONValue]()
                for key in keys {
                    guard let raw = object.object(forKey: key),
                          let item = JSONValue(raw, depth: depth + 1, maximumDepth: maximumDepth) else { return nil }
                    result[key] = item
                }
                self = .object(result)
            } else { return nil }
        }

        var json: Any {
            switch self {
            case .null: return NSNull()
            case .boolean(let value): return value
            case .integer(let value): return NSNumber(value: value)
            case .unsignedInteger(let value): return NSNumber(value: value)
            case .decimal(let value): return NSDecimalNumber(decimal: value)
            case .number(let value): return NSNumber(value: value)
            case .string(let value): return value
            case .array(let value): return value.map(\.json)
            case .object(let value): return value.mapValues(\.json)
            }
        }

        init(from decoder: Decoder) throws {
            let scalar = try decoder.singleValueContainer()
            if scalar.decodeNil() { self = .null }
            else if let value = try? scalar.decode(Bool.self) { self = .boolean(value) }
            else if let value = try? scalar.decode(String.self) { self = .string(value) }
            else if let value = try? scalar.decode(Int64.self) { self = .integer(value) }
            else if let value = try? scalar.decode(UInt64.self) { self = .unsignedInteger(value) }
            else if let value = try? scalar.decode(Double.self), value.isFinite {
                if let decimal = try? scalar.decode(Decimal.self), !decimal.isNaN { self = .decimal(decimal) }
                else { self = .number(value) }
            }
            else if var array = try? decoder.unkeyedContainer() {
                guard decoder.codingPath.count < WireProtocol.maximumJSONDepth else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON nesting limit exceeded"))
                }
                var value = [JSONValue]()
                while !array.isAtEnd {
                    value.append(try array.decode(JSONValue.self))
                }
                self = .array(value)
            } else {
                guard decoder.codingPath.count < WireProtocol.maximumJSONDepth else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "JSON nesting limit exceeded"))
                }
                let object = try decoder.container(keyedBy: Key.self)
                var value = [String: JSONValue]()
                for key in object.allKeys { value[key.stringValue] = try object.decode(JSONValue.self, forKey: key) }
                self = .object(value)
            }
        }

    }
`;

function swift() {
    const objectAdapter = String.raw`    struct JSONObject: Sendable {
        private let values: [String: JSONValue]

        init?(_ json: Any, maximumDepth: Int = WireProtocol.maximumJSONDepth) {
            guard case .object(let values) = JSONValue(json, maximumDepth: maximumDepth) else { return nil }
            self.values = values
        }

        var json: [String: Any] { values.mapValues(\.json) }
        subscript(_ key: String) -> Any? { values[key]?.json }
    }

    struct ValidatedObject: Sendable {
        let contract: Message
        private let object: JSONObject
        var json: [String: Any] { object.json }

        fileprivate init(contract: Message, object: JSONObject) {
            self.contract = contract
            self.object = object
        }
    }

    static func object(_ contract: Message, value: Any) -> ValidatedObject? {
        guard let object = JSONObject(value, maximumDepth: maximumJSONDepth(for: contract)),
              validShape(contract, value: object.json) else { return nil }
        return ValidatedObject(contract: contract, object: object)
    }

    static func decode(_ message: Message, from data: Data) -> Any? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return decode(message, value: value)
    }

    static func object(_ contract: Message, from data: Data) -> ValidatedObject? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return object(contract, value: value)
    }

    static func object(_ contract: Message, from decoder: Decoder) throws -> ValidatedObject {
        let value = try JSONValue(from: decoder).json
        guard let object = object(contract, value: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid \(contract.rawValue)"))
        }
        return object
    }
`;
    const c = definition.constants;
    return `// Generated by Scripts/generate_wire_protocol.mjs.\n\nimport Foundation\nimport CoreFoundation\n\nenum WireProtocol {\n    static let workflowVersion = ${c.WORKFLOW_VERSION}\n    static let maximumPayloadBytes = ${c.MAX_PAYLOAD_BYTES}\n    static let maximumJSONDepth = ${c.MAX_JSON_DEPTH}\n    static let maximumPopupResponseBytes = ${c.MAX_POPUP_RESPONSE_BYTES}\n    static let maximumRequests = ${c.WORKFLOW_POLICY.maximumRequests}\n    static let maximumRequestsPerHost = ${c.WORKFLOW_POLICY.maximumRequestsPerHost}\n    static let maximumRetainedRequests = ${c.WORKFLOW_POLICY.maximumRetainedRequests}\n    static let requestTTLMilliseconds = ${c.WORKFLOW_POLICY.requestTTLMilliseconds}\n    static let responseExpiryMilliseconds = ${c.WORKFLOW_POLICY.responseExpiryMilliseconds}\n    static let privateBrowsingKey = ${swiftLiteral(c.PRIVATE_BROWSING_KEY)}\n\n    enum Message: String, CaseIterable, Sendable {\n${Object.keys(types).map(name => `        case ${lowerCamel(name)} = ${quote(name)}`).join("\n")}\n    }\n\n    static func maximumJSONDepth(for message: Message) -> Int {\n        switch message {\n${Object.entries(depthReservations).map(([name, reserved]) => `        case .${lowerCamel(name)}: return maximumJSONDepth - ${reserved}`).join("\n")}\n        default: return maximumJSONDepth\n        }\n    }\n\n    private static func validShape(_ message: Message, value: Any) -> Bool {\n        switch message {\n${Object.entries(types).map(([name, rule]) => `        case .${lowerCamel(name)}: return ${swiftCall(rule, "value")}`).join("\n")}\n        }\n    }\n\n    static func validate(_ message: Message, value: Any) -> Bool {\n        decode(message, value: value) != nil\n    }\n\n    static func decode(_ message: Message, value: Any) -> Any? {\n        guard let snapshot = JSONValue(value, maximumDepth: maximumJSONDepth(for: message))?.json, validShape(message, value: snapshot) else { return nil }\n        return snapshot\n    }\n\n${objectAdapter}\n${swiftRuntime}\n${nodes.map(swiftNode).join("\n\n")}\n}\n`;
}

const outputs = [
    ["Safari Shared/Resources/protocol.generated.js", javascript()],
    ["Safari Shared/Protocol/WireProtocol.generated.swift", swift()],
];
let stale = false;
for (const [relativePath, contents] of outputs) {
    const path = resolve(root, relativePath);
    let existing;
    try { existing = readFileSync(path, "utf8"); } catch (error) { if (error.code !== "ENOENT") { throw error; } }
    if (existing === contents) { continue; }
    if (mode === "--check") { console.error(`Stale generated protocol: ${relativePath}`); stale = true; }
    else { mkdirSync(dirname(path), {recursive: true}); writeFileSync(path, contents); console.log(`Generated ${relativePath}`); }
}
if (stale) {
    console.error("Regenerate with: node Scripts/generate_wire_protocol.mjs --write");
    process.exitCode = 1;
}
