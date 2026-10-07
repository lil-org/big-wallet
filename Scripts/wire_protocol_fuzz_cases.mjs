const maximumSafeInteger = Number.MAX_SAFE_INTEGER;
const scalarStrings = ["", "a", "é", "e\u0301", "🧪", "a\u0000b", "\u2028", "__proto__", "constructor"];
const scalarNumbers = [0, 1, -1, 0.5, -0.5, 1e-300, Number.MIN_VALUE,
    -Number.MIN_VALUE, maximumSafeInteger, -maximumSafeInteger, Number.MAX_VALUE];

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function put(object, key, value) {
    Object.defineProperty(object, key, {value, enumerable: true, configurable: true, writable: true});
    return object;
}

function randomSource(seed) {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6d2b79f5) >>> 0;
        let value = Math.imul(state ^ state >>> 15, state | 1);
        value ^= value + Math.imul(value ^ value >>> 7, value | 61);
        return ((value ^ value >>> 14) >>> 0) / 0x100000000;
    };
}

function choose(random, values) {
    return values[Math.floor(random() * values.length)];
}

function adjacentNumber(value, direction) {
    if (value === 0) { return direction * Number.MIN_VALUE; }
    const bytes = new DataView(new ArrayBuffer(8));
    bytes.setFloat64(0, value);
    const delta = (value > 0) === (direction > 0) ? 1n : -1n;
    bytes.setBigUint64(0, bytes.getBigUint64(0) + delta);
    return bytes.getFloat64(0);
}

function unicodeString(length, unit = "a") {
    return unit.repeat(Math.floor(length / unit.length)) + "a".repeat(length % unit.length);
}

function base58(bytes) {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    let number = 0n;
    for (const byte of bytes) { number = number * 256n + BigInt(byte); }
    let value = "";
    while (number > 0n) {
        value = alphabet[Number(number % 58n)] + value;
        number /= 58n;
    }
    let zeroes = 0;
    while (zeroes < bytes.length && bytes[zeroes] === 0) { zeroes += 1; }
    return "1".repeat(zeroes) + value;
}

function formattedString(format, random) {
    const hex = count => Array.from({length: count}, () => Math.floor(random() * 16).toString(16)).join("");
    switch (format) {
    case "privateToken": return hex(32);
    case "authorityContext": return hex(64);
    case "uuid": return [8, 4, 4, 4, 12].map(hex).join("-");
    case "ethereumChain": return `0x${(Math.floor(random() * 0xffffffff) + 1).toString(16)}`;
    case "solanaPublicKey": return base58(Array.from({length: 32}, () => Math.floor(random() * 256)));
    default: throw new TypeError(`Unsupported fuzz format: ${format}`);
    }
}

function arbitraryJSON(random, depth = 0) {
    const kind = Math.floor(random() * (depth < 3 ? 6 : 4));
    if (kind === 0) { return null; }
    if (kind === 1) { return random() < 0.5; }
    if (kind === 2) { return choose(random, scalarNumbers); }
    if (kind === 3) { return choose(random, scalarStrings); }
    if (kind === 4) {
        return Array.from({length: Math.floor(random() * 4)}, () => arbitraryJSON(random, depth + 1));
    }
    const object = {};
    for (let index = 0, count = Math.floor(random() * 4); index < count; index += 1) {
        put(object, choose(random, ["value", "__proto__", "constructor", "é", "e\u0301", "🧪"]), arbitraryJSON(random, depth + 1));
    }
    return object;
}

function sample(rule, definition, random) {
    if (rule.ref) { return sample(definition.types[rule.ref], definition, random); }
    if (rule.constant) { return clone(definition.constants[rule.constant]); }
    if (Object.hasOwn(rule, "const")) { return clone(rule.const); }
    if (rule.enum) { return clone(choose(random, rule.enum)); }
    if (rule.oneOf) { return sample(choose(random, rule.oneOf), definition, random); }
    switch (rule.type) {
    case "null": return null;
    case "boolean": return random() < 0.5;
    case "number": return choose(random, scalarNumbers);
    case "integer":
    case "wholeNumber": {
        const values = [rule.minimum, rule.maximum, 0, 1, -1, Math.floor(random() * 10000)]
            .filter(value => Number.isFinite(value) && Number.isInteger(value) &&
                value >= rule.minimum && value <= rule.maximum);
        return choose(random, values);
    }
    case "string": {
        if (rule.format) { return formattedString(rule.format, random); }
        const minimum = rule.minLength ?? 0;
        const maximum = rule.maxLength ?? Math.max(minimum, 32);
        const candidates = [...scalarStrings, unicodeString(minimum), unicodeString(Math.min(maximum, minimum + 3), "🧪")]
            .filter(value => value.length >= minimum && value.length <= maximum && !rule.excluding?.includes(value));
        if (candidates.length === 0) { throw new TypeError("Cannot sample string constraints"); }
        return choose(random, candidates);
    }
    case "array": {
        const minimum = rule.minItems ?? 0;
        const maximum = Math.min(rule.maxItems ?? minimum + 3, minimum + 3);
        const length = minimum + Math.floor(random() * (maximum - minimum + 1));
        return Array.from({length}, () => sample(rule.items, definition, random));
    }
    case "dictionary": {
        const value = {};
        for (let index = 0, count = Math.floor(random() * 4); index < count; index += 1) {
            put(value, choose(random, ["a", "__proto__", "constructor", "é", "e\u0301", "🧪"]), sample(rule.values, definition, random));
        }
        return value;
    }
    case "object": {
        const value = {};
        for (const [key, child] of Object.entries(rule.required)) { put(value, key, sample(child, definition, random)); }
        for (const [key, child] of Object.entries(rule.optional)) {
            if (random() < 0.5) { put(value, key, sample(child, definition, random)); }
        }
        return value;
    }
    case "json": return arbitraryJSON(random);
    default: throw new TypeError(`Unsupported fuzz rule: ${rule.type}`);
    }
}

function* inlineContexts(rule, definition, random, path = [], wrap = value => value) {
    if (rule.ref) { return; }
    if (rule.oneOf) {
        for (let index = 0; index < rule.oneOf.length; index += 1) {
            yield* inlineContexts(rule.oneOf[index], definition, random, [...path, `variant${index}`], wrap);
        }
        return;
    }
    yield {rule, path, wrap};
    if (rule.type === "object") {
        const baseline = sample(rule, definition, random);
        for (const [key, child] of Object.entries({...rule.required, ...rule.optional})) {
            yield* inlineContexts(child, definition, random, [...path, key], value => wrap(put(clone(baseline), key, value)));
        }
    }
}

function paths(value, path = [], result = []) {
    result.push(path);
    if (value && typeof value === "object") {
        for (const key of Object.keys(value)) { paths(value[key], [...path, key], result); }
    }
    return result;
}

function valueAt(value, path) {
    return path.reduce((current, key) => current[key], value);
}

function replaceAt(value, path, replacement) {
    if (path.length === 0) { return replacement; }
    put(valueAt(value, path.slice(0, -1)), path.at(-1), replacement);
    return value;
}

function mutate(value, random) {
    const path = choose(random, paths(value));
    const selected = valueAt(value, path);
    const action = Math.floor(random() * 5);
    if (action === 0 && path.length > 0) {
        const parent = valueAt(value, path.slice(0, -1));
        if (Array.isArray(parent)) { parent.splice(Number(path.at(-1)), 1); }
        else { delete parent[path.at(-1)]; }
        return value;
    }
    if (selected && typeof selected === "object" && !Array.isArray(selected) && action === 1) {
        put(selected, choose(random, ["__proto__", "constructor", "unexpected", "toJSON"]), arbitraryJSON(random));
        return value;
    }
    if (Array.isArray(selected) && action === 2) {
        selected.push(selected.length ? clone(choose(random, selected)) : arbitraryJSON(random));
        return value;
    }
    if (typeof selected === "string" && action === 3) {
        return replaceAt(value, path, selected + choose(random, ["\n", "\r\n", "\u2028", "\u0000", "🧪", "e\u0301"]));
    }
    return replaceAt(value, path, choose(random, [null, {}, [], ...scalarStrings, ...scalarNumbers, true, false]));
}

function nestedJSON(containers, kind) {
    let value = "leaf";
    for (let index = 0; index < containers; index += 1) {
        value = kind === "array" || kind === "mixed" && index % 2 === 0 ? [value] : {value};
    }
    return value;
}

export function generateCases({definition, fixtures, seed = 0xb16b00b5, iterations = 1000}) {
    if (!Number.isInteger(seed) || seed < 0 || seed > 0xffffffff ||
        !Number.isSafeInteger(iterations) || iterations < 0) {
        throw new TypeError("Fuzz seed must be uint32 and iterations a nonnegative safe integer");
    }
    if (!definition?.types || !Array.isArray(fixtures)) { throw new TypeError("Fuzz definition and fixtures are required"); }
    const cases = [];
    const add = (name, type, value, expectedValid) => {
        if (!Object.hasOwn(definition.types, type)) { return; }
        cases.push({name, type, value: clone(value), ...(expectedValid === undefined ? {} : {expectedValid})});
    };
    const validFixtures = fixtures.filter(fixture => fixture.valid === true);
    if (iterations > 0 && validFixtures.length === 0) { throw new TypeError("Random mutation requires valid fixtures"); }
    for (const fixture of fixtures) { add(`fixture:${fixture.name}`, fixture.type, fixture.value, fixture.valid); }

    for (const [type, minimum] of [["RequestID", -maximumSafeInteger], ["NonnegativeInteger", 0], ["PositiveInteger", 1]]) {
        for (const value of [...new Set([minimum - 1, minimum, minimum + 1, maximumSafeInteger - 1,
            maximumSafeInteger, maximumSafeInteger + 1, ...scalarNumbers])]) {
            add(`boundary:number:${type}:${value}`, type, value,
                Number.isSafeInteger(value) && value >= minimum && value <= maximumSafeInteger);
        }
    }
    const signed64Minimum = -(2 ** 63);
    const signed64Maximum = 2 ** 63;
    for (const value of [...new Set([adjacentNumber(signed64Minimum, -1), signed64Minimum,
        adjacentNumber(signed64Minimum, 1), adjacentNumber(signed64Maximum, -1), signed64Maximum,
        adjacentNumber(signed64Maximum, 1), ...scalarNumbers])]) {
        add(`boundary:number:ErrorCode:${value}`, "ErrorCode", value,
            Number.isInteger(value) && value >= signed64Minimum && value <= signed64Maximum);
    }

    const tokens = {
        PrivateToken: "0123456789abcdef".repeat(2),
        AuthorityContext: "0123456789abcdef".repeat(4),
        RequestToken: "01234567-89ab-cdef-0123-456789abcdef",
        EthereumChainID: "0x7fffffffffffffff",
        SolanaPublicKey: "1".repeat(32),
    };
    for (const [type, value] of Object.entries(tokens)) {
        add(`boundary:format:${type}:valid`, type, value, true);
        for (const suffix of ["\n", "\r\n", "\u2028", "\u2029", "\u0000", "🧪", "e\u0301"]) {
            add(`boundary:format:${type}:suffix:${JSON.stringify(suffix)}`, type, value + suffix, false);
        }
        add(`boundary:format:${type}:empty`, type, "", false);
        add(`boundary:format:${type}:short`, type, value.slice(1), false);
    }
    for (const value of ["0x0", "0x01", "0X1", "0x8000000000000000", "0x-1", "0x1.0"]) {
        add(`boundary:chain:${value}`, "EthereumChainID", value, false);
    }
    for (const value of ["0x1", "0xa", "0x7ffffffffffffffe"]) { add(`boundary:chain:${value}`, "EthereumChainID", value, true); }
    for (const type of ["PrivateToken", "AuthorityContext", "RequestToken"]) {
        add(`boundary:format:${type}:uppercase`, type, tokens[type].toUpperCase(), false);
    }
    for (const value of ["1".repeat(31), "1".repeat(33), "0".repeat(32), "z".repeat(44)]) {
        add(`boundary:solana:${value}`, "SolanaPublicKey", value, false);
    }

    const equivalentKeys = [
        ["latin", "é", "e\u0301"],
        ["hangul", "가", "\u1100\u1161"],
        ["kelvin", "K", "K"],
    ];
    for (const type of ["RPCResponse", "NativeResponse"]) {
        const wrap = data => type === "RPCResponse"
            ? {id: 1, result: {nested: [data]}}
            : {id: 1, name: "requestAccounts", provider: "ethereum", kind: "error",
                approvalCommitted: false, authorizationFailure: false,
                error: {code: -32603, message: "fuzz", data: {nested: [data]}}};
        for (const [label, canonical, equivalent] of equivalentKeys) {
            const collision = put(put({}, canonical, "first"), equivalent, "second");
            add(`boundary:unicode-keys:${type}:${label}:collision`, type, wrap(collision), false);
            const noncolliding = put({unrelated: "first"}, equivalent, "second");
            add(`boundary:unicode-keys:${type}:${label}:noncanonical`, type, wrap(noncolliding), true);
        }
    }
    for (const [type, key, equivalent] of [
        ["SolanaConfiguration", "publicKey", "publicKey"],
        ["RuntimeResponseRequest", "configurationKey", "configurationKey"],
    ]) {
        const fixture = validFixtures.find(value => value.type === type);
        if (!fixture) { continue; }
        const renamed = clone(fixture.value);
        delete renamed[key];
        put(renamed, equivalent, clone(fixture.value[key]));
        add(`boundary:unicode-field:${type}:${key}:renamed`, type, renamed, false);
        add(`boundary:unicode-field:${type}:${key}:collision`, type,
            put(clone(fixture.value), equivalent, clone(fixture.value[key])), false);
    }

    const boundaryRandom = randomSource(0x51a7e);
    for (const [type, root] of Object.entries(definition.types)) {
        for (const {rule, path, wrap} of inlineContexts(root, definition, boundaryRandom)) {
            const name = [type, ...path].join(".");
            if (rule.type === "array") {
                const minimum = rule.minItems ?? 0;
                const lengths = [...new Set([0, Math.max(0, minimum - 1), minimum, minimum + 1,
                    ...(rule.maxItems === undefined ? [] : [Math.max(0, rule.maxItems - 1), rule.maxItems, rule.maxItems + 1])])];
                for (const length of lengths) {
                    add(`boundary:array:${name}:${length}`, type,
                        wrap(Array.from({length}, () => sample(rule.items, definition, boundaryRandom))));
                }
            }
            if (rule.type === "string" && !rule.format && (rule.minLength !== undefined || rule.maxLength !== undefined)) {
                const minimum = rule.minLength ?? 0;
                const lengths = [...new Set([0, Math.max(0, minimum - 1), minimum, minimum + 1, minimum + 2,
                    ...(rule.maxLength === undefined ? [] : [Math.max(0, rule.maxLength - 1), rule.maxLength, rule.maxLength + 1])])];
                for (const length of lengths) {
                    for (const unit of ["a", "e\u0301", "🧪"]) {
                        add(`boundary:string:${name}:${JSON.stringify(unit)}:${length}`, type, wrap(unicodeString(length, unit)));
                    }
                }
            }
        }
    }

    const firstFixtures = new Map;
    for (const fixture of validFixtures) {
        if (!firstFixtures.has(fixture.type)) { firstFixtures.set(fixture.type, fixture); }
    }
    for (const [type, fixture] of firstFixtures) {
        for (const [label, value] of [["null", null], ["empty-object", {}], ["empty-array", []]]) {
            add(`boundary:shape:${type}:${label}`, type, value);
        }
        if (!fixture.value || typeof fixture.value !== "object" || Array.isArray(fixture.value)) { continue; }
        for (const key of Object.keys(fixture.value)) {
            const missing = clone(fixture.value);
            delete missing[key];
            add(`boundary:field:${type}:${key}:missing`, type, missing);
            add(`boundary:field:${type}:${key}:null`, type, put(clone(fixture.value), key, null));
        }
        for (const key of ["__proto__", "constructor", "unexpected"]) {
            add(`boundary:field:${type}:${key}:unknown`, type, put(clone(fixture.value), key, {polluted: true}));
        }
    }
    for (const length of [0, 1, 15, 16, 17]) {
        add(`boundary:response-ready:${length}`, "ResponseReady", {
            subject: "responseReady", ids: Array.from({length}, (_, index) => index + 1),
            workflowVersion: definition.constants.WORKFLOW_VERSION,
        }, length > 0 && length <= 16);
    }
    for (const type of ["RPCResponse", "NativeResponse", "PageResponse"]) {
        if (!Object.hasOwn(definition.types, type)) { continue; }
        const limit = definition.constants.MAX_JSON_DEPTH - (definition.depthReservations?.[type] ?? 0);
        for (const depth of [limit - 1, limit, limit + 1]) {
            for (const kind of ["object", "array", "mixed"]) {
                let value;
                if (type === "NativeResponse") {
                    value = {id: 1, name: "requestAccounts", provider: "ethereum", kind: "error",
                        approvalCommitted: false, authorizationFailure: false,
                        error: {code: -32603, message: "fuzz", data: nestedJSON(depth - 2, kind)}};
                } else {
                    value = {id: 1, result: nestedJSON(depth - 1, kind)};
                    if (type === "PageResponse") {
                        Object.assign(value, {name: null, provider: "ethereum", kind: "result", state: null, approvalCommitted: false});
                    }
                }
                add(`boundary:depth:${type}:${kind}:${depth}`, type, value, depth <= limit);
            }
        }
    }

    const random = randomSource(seed);
    const typeNames = Object.keys(definition.types);
    for (let index = 0; index < iterations; index += 1) {
        if (index % 3 === 0) {
            const type = choose(random, typeNames);
            add(`random:${index}:schema:${type}`, type, sample(definition.types[type], definition, random));
        } else {
            const fixture = choose(random, validFixtures);
            let value = clone(fixture.value);
            const count = index % 3 === 1 ? 1 : 2 + Math.floor(random() * 3);
            for (let mutation = 0; mutation < count; mutation += 1) { value = mutate(value, random); }
            add(`random:${index}:mutation:${fixture.name}:${count}`, fixture.type, value);
        }
    }
    return cases;
}
