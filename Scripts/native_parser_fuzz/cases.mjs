import {createHash} from "node:crypto";
import {DECRYPT_MUTATIONS, PARSERS, PROFILES, caseDigest, fixtureData, typedDataEntryPoint, validateCase} from "./contract.mjs";

const encoded = value => Buffer.from(value).toString("base64");
const jsonCase = (mode, name, object, expected) => ({name, mode, inputBase64: encoded(typeof object === "string" ? object : JSON.stringify(object)), ...(expected ? {expected} : {})});
const rawCase = (mode, name, bytes, expected, oracle) => ({name, mode, inputBase64: encoded(bytes), ...(expected ? {expected} : {}), ...(oracle ? {oracle} : {})});
const clone = value => JSON.parse(JSON.stringify(value));
export const EIP712_PRIMITIVE_FAMILIES = ["uint8", "int16", "bool", "string", "bytes4", "address", "uint256", "uint8[]"];
export const EIP712_BUDGET_FAMILIES = ["inputBytes", "jsonDepth", "jsonTokens", "types", "fieldsPerType", "totalFields", "dependencyDepth", "valueDepth", "arrayTypeDepth", "arrayElements", "work", "processingBytes"];
export const EIP712_STRUCTURE_FORMS = ["flat", "struct", "structArray"];

export function typedDataBudgetCases() {
    const document = (types, message = {}, primaryType = "Root") => ({types, primaryType, domain: {}, message});
    const single = (type, value) => document({EIP712Domain: [], Root: [{name: "value", type}]}, {value});
    const empty = JSON.stringify(document({EIP712Domain: [], Root: []}));
    const cases = [];
    const pair = (family, within, exceeded, rejection) => {
        cases.push({...jsonCase("eip712", `budget.${family}.within`, within, {accepted: true}), entryPoint: "checked"});
        cases.push({...jsonCase("eip712", `budget.${family}.exceeded`, exceeded, {accepted: false, rejection}), entryPoint: "checked"});
    };
    pair("inputBytes", empty + " ".repeat(262_144 - Buffer.byteLength(empty)), empty + " ".repeat(262_145 - Buffer.byteLength(empty)), "inputTooLarge");
    const nestedJSON = depth => empty.slice(0, -1) + ',"ignored":' + "[".repeat(depth) + "0" + "]".repeat(depth) + "}";
    pair("jsonDepth", nestedJSON(63), nestedJSON(64), "jsonTooDeep");
    const tokens = "0,".repeat(65_520) + "0", tokenPrefix = empty.slice(0, -1) + ',"ignored":[';
    pair("jsonTokens", tokenPrefix + tokens + "]}", tokenPrefix + tokens + ",0]}", "tooManyJSONTokens");
    const types = {EIP712Domain: [], Root: []};
    for (let index = 0; index < 254; index += 1) { types[`Unused${index}`] = []; }
    pair("types", document(types), document({...types, OneMore: []}), "tooManyTypes");
    const field = {name: "value", type: "uint8"};
    pair("fieldsPerType", document({EIP712Domain: [], Root: Array(128).fill(field)}, {value: 1}),
        document({EIP712Domain: [], Root: Array(129).fill(field)}, {value: 1}), "tooManyFields");
    const allFields = {EIP712Domain: [], Root: Array(128).fill(field)};
    for (let index = 0; index < 31; index += 1) { allFields[`Unused${index}`] = Array(128).fill(field); }
    pair("totalFields", document(allFields, {value: 1}), document({...allFields, Extra: [field]}, {value: 1}), "tooManyFields");
    const dependencyChain = count => {
        const declarations = {EIP712Domain: []};
        for (let index = 0; index < count; index += 1) { declarations[`T${index}`] = index + 1 < count ? [{name: "children", type: `T${index + 1}[]`}] : []; }
        return document(declarations, {children: []}, "T0");
    };
    pair("dependencyDepth", dependencyChain(32), dependencyChain(33), "dependencyTooDeep");
    const valueTypes = {EIP712Domain: [], T31: [{name: "children", type: "T31[]"}]};
    for (let index = 0; index < 31; index += 1) { valueTypes[`T${index}`] = [{name: "next", type: `T${index + 1}`}]; }
    const nestedValue = terminal => {
        let value = terminal;
        for (let index = 0; index < 31; index += 1) { value = {next: value}; }
        return document(valueTypes, value, "T0");
    };
    pair("valueDepth", nestedValue({children: []}), nestedValue({children: [{children: []}]}), "valueTooDeep");
    pair("arrayTypeDepth", single("uint256" + "[]".repeat(32), []), single("uint256" + "[]".repeat(33), []), "arrayTypeTooDeep");
    pair("arrayElements", single("uint8[]", Array(4096).fill(1)), single("uint8[]", Array(4097).fill(1)), "arrayTooLarge");
    const expansion = depth => {
        const declarations = {EIP712Domain: [], [`T${depth}`]: []};
        let value = {};
        for (let index = depth - 1; index >= 0; index -= 1) {
            const child = {name: "child", type: `T${index + 1}`};
            declarations[`T${index}`] = [child, child]; value = {child: value};
        }
        return document(declarations, value, "T0");
    };
    pair("work", expansion(13), expansion(14), "tooMuchWork");
    const repeatedStrings = {EIP712Domain: [], Root: Array(128).fill({name: "value", type: "string"})};
    pair("processingBytes", document(repeatedStrings, {value: "x".repeat(20_000)}),
        document(repeatedStrings, {value: "x".repeat(40_000)}), "tooManyProcessingBytes");
    return cases;
}

export function random(seed) {
    let state = seed >>> 0;
    return {
        next() { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state; },
        int(maximum) { return this.next() % maximum; },
        bytes(count) { return Buffer.from(Array.from({length: count}, () => this.next() >>> 24)); },
    };
}

export function shortvec(value) {
    if (!Number.isSafeInteger(value) || value < 0 || value > 65_535) { throw new Error("Invalid shortvec"); }
    const result = [];
    do { const low = value & 0x7f; value >>>= 7; result.push(low | (value ? 0x80 : 0)); } while (value);
    return Buffer.from(result);
}

export function solanaMessage(rng, {versioned = false, payloadBytes, lookups = versioned} = {}) {
    const count = payloadBytes === undefined ? 2 + rng.int(6) : 2;
    const signatures = payloadBytes === undefined ? 1 + rng.int(Math.min(3, count)) : 1;
    const header = Buffer.from([...(versioned ? [0x80] : []), signatures, rng.int(signatures), rng.int(count - signatures + 1)]);
    const keys = Array.from({length: count}, () => rng.bytes(32));
    const lookup = lookups ? [{key: rng.bytes(32), writable: [0, 2], readonly: [1]}] : [];
    const instructionCount = payloadBytes === undefined ? 1 + rng.int(3) : 1;
    const instructions = Array.from({length: instructionCount}, () => {
        const accounts = Buffer.from(Array.from({length: 1 + rng.int(4)}, () => rng.int(count + (lookups ? 3 : 0))));
        const data = rng.bytes(payloadBytes ?? rng.int(48));
        return Buffer.concat([Buffer.from([1 + rng.int(count - 1)]), shortvec(accounts.length), accounts, shortvec(data.length), data]);
    });
    return Buffer.concat([header, shortvec(count), ...keys, rng.bytes(32), shortvec(instructions.length), ...instructions,
        ...(versioned ? [shortvec(lookup.length), ...lookup.map(item => Buffer.concat([item.key, shortvec(item.writable.length), Buffer.from(item.writable), shortvec(item.readonly.length), Buffer.from(item.readonly)]))] : [])]);
}

export function solanaMessageAtWireBoundary(length) {
    if (![1_232, 1_233].includes(length)) { throw new Error("Wire boundary fixture requires its exact admitted or rejected size"); }
    const prefix = Buffer.concat([Buffer.from([1, 0, 1]), shortvec(2), Buffer.alloc(32, 1), Buffer.alloc(32, 2), Buffer.alloc(32, 3),
        shortvec(1), Buffer.from([1]), shortvec(1), Buffer.from([0])]);
    const payload = Buffer.alloc(length - prefix.length - 2, 0x7f);
    const bytes = Buffer.concat([prefix, shortvec(payload.length), payload]);
    if (bytes.length !== length) { throw new Error("Wire boundary fixture size drifted"); }
    return bytes;
}

export function corpus(mode) {
    const fixtures = fixtureData();
    if (mode === "keystore") {
        const cases = [rawCase(mode, "empty", Buffer.alloc(0), {accepted: false, strictAccepted: false}), rawCase(mode, "invalid-utf8", Buffer.from([0xff]), {accepted: false, strictAccepted: false}),
            jsonCase(mode, "non-object", "[]", {accepted: false, strictAccepted: false})];
        for (const fixture of fixtures.keystores) { cases.push(jsonCase(mode, fixture.id, fixture.document, {accepted: true, strictAccepted: fixture.id !== "ethereum-pbkdf2"})); }
        const storedDocument = {...clone(fixtures.keystores[0].document), activeAccounts: []};
        const base = JSON.stringify(storedDocument);
        cases.push(jsonCase(mode, "input-limit-inclusive", base + " ".repeat(1_048_576 - Buffer.byteLength(base)), {accepted: true, strictAccepted: true}));
        cases.push(jsonCase(mode, "input-limit-exceeded", base + " ".repeat(1_048_577 - Buffer.byteLength(base)), {accepted: false, strictAccepted: true, rejection: "limitExceeded"}));
        for (const [iterations, length] of [[2_000_000, 32], [1_000_000, 33], [62_500, 1024]]) {
            for (const extra of [0, 1]) {
                const value = clone(storedDocument);
                Object.assign(value.crypto.kdfparams, {c: iterations + extra, dklen: length});
                cases.push(jsonCase(mode, `pbkdf2-${iterations}-${length}-${extra}`, value, {accepted: extra === 0, strictAccepted: true, ...(extra ? {rejection: "limitExceeded"} : {})}));
            }
        }
        for (const value of [0, -1, "2147483648", true, 9_007_199_254_740_991]) {
            const changed = clone(fixtures.keystores[0].document);
            changed.crypto.kdfparams.c = value;
            cases.push(jsonCase(mode, `pbkdf2-invalid-${String(value)}`, changed));
        }
        const incomplete = clone(fixtures.keystores[2].document);
        incomplete.activeAccounts = [{address: incomplete.address}];
        cases.push(jsonCase(mode, "incomplete-account-metadata", incomplete, {accepted: true, strictAccepted: false}));
        const scrypt = clone(fixtures.keystores[1].document);
        for (const [n, r, p, accepted] of [[262_144, 1, 8, true], [262_144, 1, 9, false], [3, 1, 1, false]]) {
            const changed = clone(scrypt);
            Object.assign(changed.crypto.kdfparams, {n, r, p});
            cases.push(jsonCase(mode, `scrypt-admission-${n}-${r}-${p}`, changed, {accepted}));
        }
        return cases;
    }
    if (mode === "eip712") {
        const cases = fixtures.typedData.map(fixture => jsonCase(mode, fixture.id, fixture.document, {accepted: true, digest: fixture.digest}));
        const base = {types: {EIP712Domain: [], Root: [{name: "n", type: "uint8"}]}, primaryType: "Root", domain: {}, message: {n: 1}};
        cases.push(...typedDataBudgetCases());
        cases.push(rawCase(mode, "invalid-utf8", Buffer.from([0xff, 0xfe]), {accepted: false}));
        for (const value of [256, -1, 1.5, "0x", "9".repeat(79)]) {
            const changed = clone(base); changed.message.n = value;
            cases.push(jsonCase(mode, `uint8-invalid-${String(value).slice(0, 16)}`, changed, {accepted: false}));
        }
        cases.push(jsonCase(mode, "duplicate-member", '{"types":{},"types":{"EIP712Domain":[],"Root":[]},"primaryType":"Root","domain":{},"message":{}}'));
        return cases;
    }
    if (mode === "solana") {
        const legacy = solanaMessage(random(1)), versioned = solanaMessage(random(2), {versioned: true});
        const noncanonical = Buffer.concat([legacy.subarray(0, 3), Buffer.from([legacy[3] | 0x80, 0]), legacy.subarray(4)]);
        const zeroSigners = Buffer.from(legacy); zeroSigners[0] = 0;
        const unknownVersion = Buffer.from(versioned); unknownVersion[0] = 0x81;
        return [rawCase(mode, "legacy", legacy, {accepted: true}, "canonical"), rawCase(mode, "v0-lookups", versioned, {accepted: true}, "canonical"),
            rawCase(mode, "wire-size.within", solanaMessageAtWireBoundary(1_232), {accepted: true}, "canonical"),
            rawCase(mode, "wire-size.exceeded", solanaMessageAtWireBoundary(1_233), {accepted: false}, "malformed"),
            rawCase(mode, "empty", Buffer.alloc(0), {accepted: false}, "malformed"),
            rawCase(mode, "trailing-data", Buffer.concat([legacy, Buffer.from([0])]), {accepted: false}, "malformed"),
            rawCase(mode, "truncated", legacy.subarray(0, legacy.length - 1), {accepted: false}, "malformed"),
            rawCase(mode, "noncanonical-shortvec", noncanonical, {accepted: false}, "malformed"),
            rawCase(mode, "zero-signers", zeroSigners, {accepted: false}, "malformed"),
            rawCase(mode, "unknown-version", unknownVersion, {accepted: false}, "malformed"),
            rawCase(mode, "invalid-version-oversized", Buffer.alloc(1_233, 0xff), {accepted: false}, "malformed")];
    }
    throw new Error(`Unknown parser ${mode}`);
}

function mutateBytes(input, rng, limit) {
    let bytes = Buffer.from(input);
    const index = rng.int(Math.max(1, bytes.length));
    switch (rng.int(5)) {
    case 0: return bytes.subarray(0, index);
    case 1: if (bytes.length) { bytes[index] ^= 1 << rng.int(8); } break;
    case 2: bytes = Buffer.concat([bytes.subarray(0, index), rng.bytes(1 + rng.int(16)), bytes.subarray(index)]); break;
    case 3: if (bytes.length) { bytes[index] = rng.int(256); } break;
    default: bytes = Buffer.concat([bytes, rng.bytes(rng.int(32))]);
    }
    return bytes.subarray(0, limit);
}

function generatedTypedData(rng, index, familyOffset) {
    const type = EIP712_PRIMITIVE_FAMILIES[(Math.floor(index / 4) + familyOffset) % EIP712_PRIMITIVE_FAMILIES.length];
    const factories = {
        uint8: () => rng.int(256), int16: () => rng.int(65_536) - 32_768, bool: () => Boolean(rng.int(2)),
        string: () => `value-${rng.next()}-é-\u0000`, bytes4: () => `0x${rng.bytes(4).toString("hex")}`,
        address: () => `0x${rng.bytes(20).toString("hex")}`, uint256: () => String(rng.next()),
        "uint8[]": () => Array.from({length: rng.int(8)}, () => rng.int(256)),
    };
    const value = factories[type]();
    const document = {types: {EIP712Domain: [], Root: [{name: "value", type}, {name: "marker", type: "string"}]},
        primaryType: "Root", domain: {}, message: {value, marker: `marker-${index}`}};
    const form = EIP712_STRUCTURE_FORMS[Math.floor(index / 32) % EIP712_STRUCTURE_FORMS.length];
    if (form !== "flat") {
        document.types.Child = [{name: "number", type: "uint16"}, {name: "values", type: "uint8[]"}];
        const child = () => ({number: rng.int(65_536), values: Array.from({length: rng.int(5)}, () => rng.int(256))});
        document.types.Root.push({name: "detail", type: form === "struct" ? "Child" : "Child[]"});
        document.message.detail = form === "struct" ? child() : Array.from({length: 1 + rng.int(3)}, child);
    }
    if (index % 4 === 0) { return rawCase("eip712", `mutation-${index}`, mutateBytes(JSON.stringify(document), rng, 262_145)); }
    if (index % 4 === 1) {
        document.types.Root[0].type = "uint8"; document.message.value = 256 + rng.int(1000);
        return jsonCase("eip712", `invalid-width-${index}`, document, {accepted: false});
    }
    const candidate = jsonCase("eip712", `structured-${index}`, document, {accepted: true});
    const secondary = clone(document);
    if (index % 4 === 2) {
        switch (type) {
        case "uint8": secondary.message.value = (value + 1) % 256; break;
        case "int16": secondary.message.value = value === 32_767 ? -32_768 : value + 1; break;
        case "bool": secondary.message.value = !value; break;
        case "string": secondary.message.value = value + "-changed"; break;
        case "uint256": secondary.message.value = String(BigInt(value) + 1n); break;
        case "uint8[]": secondary.message.value = [...value, 1]; break;
        default: secondary.message.value = value.slice(0, -1) + (value.endsWith("0") ? "1" : "0");
        }
        candidate.relation = "differentDigest";
        candidate.secondaryBase64 = encoded(JSON.stringify(secondary));
    } else {
        candidate.relation = "equalDigest";
        candidate.secondaryBase64 = encoded(JSON.stringify({message: secondary.message, domain: secondary.domain,
            primaryType: secondary.primaryType, types: secondary.types}, null, 2));
    }
    return candidate;
}

export function* generatedCases(mode, seed, iterations) {
    const rng = random(seed);
    const familyOffset = mode === "eip712" ? rng.int(EIP712_PRIMITIVE_FAMILIES.length) : 0;
    const fixtures = fixtureData();
    for (let index = 0; index < iterations; index += 1) {
        if (mode === "eip712") { yield generatedTypedData(rng, index, familyOffset); continue; }
        if (mode === "solana") {
            const bytes = solanaMessage(rng, {versioned: Boolean(index % 2)});
            yield index % 3 === 0 ? rawCase(mode, `mutation-${index}`, mutateBytes(bytes, rng, 1_233), undefined, "malformed")
                : rawCase(mode, `structured-${index}`, bytes, {accepted: true}, "canonical");
            continue;
        }
        const value = clone(fixtures.keystores[rng.int(fixtures.keystores.length)].document);
        if (index % 3 === 0) { yield rawCase(mode, `mutation-${index}`, mutateBytes(JSON.stringify(value), rng, 1_048_577)); continue; }
        const crypto = value.crypto;
        switch (rng.int(9)) {
        case 0: crypto.ciphertext = rng.bytes(rng.int(128)).toString("hex"); break;
        case 1: crypto.mac = rng.bytes(rng.int(65)).toString("hex"); break;
        case 2: crypto.cipherparams.iv = rng.bytes(rng.int(33)).toString("hex"); break;
        case 3: crypto.kdfparams.dklen = [0, 1, 16, 31, 32, 33, 1024, 1025, -1][rng.int(9)]; break;
        case 4: crypto.kdfparams[crypto.kdf === "scrypt" ? "n" : "c"] = [0, -1, true, 1.5, 1, 2, 2_000_000, 4_294_967_295][rng.int(8)]; break;
        case 5: value.activeAccounts = [{coin: [60, 501, 0, 60.9, "60"][rng.int(5)], address: "0x" + rng.bytes(20).toString("hex"), derivationPath: `m/44'/60'/0'/0/${rng.int(100)}`}]; break;
        case 6: value.name = `wallet-${rng.next()}-é`; delete value.id; break;
        case 7: value.activeAccounts = [null, {}, [], "invalid", {address: 1}][rng.int(5)]; break;
        default: delete value.crypto; value.Crypto = crypto;
        }
        yield jsonCase(mode, `structured-${index}`, value);
    }
}

export function* plannedCases(profile, phase, replay) {
    const policy = PROFILES[profile];
    if (!policy) { throw new Error("Unknown fuzz profile"); }
    if (phase === "replay") { yield {id: "replay/0", source: "replay", candidate: validateCase(replay)}; return; }
    if (phase === "decrypt") {
        for (let round = 0; round < policy.decryptRounds; round += 1) {
            for (const fixture of fixtureData().keystores) {
                for (const mutation of DECRYPT_MUTATIONS) {
                    yield {id: `decrypt/${round}/${fixture.id}/${mutation}`, source: "fixture", candidate: {
                        name: `${fixture.id}-${mutation}-${round}`, mode: "decrypt", fixtureID: fixture.id, mutation, mutationIndex: round * 7,
                        expected: {accepted: ["original", "uppercaseCrypto"].includes(mutation)},
                    }};
                }
            }
        }
        return;
    }
    if (phase !== "parsers") { return; }
    for (const mode of PARSERS) {
        for (const [index, candidate] of corpus(mode).entries()) { yield {id: `${mode}/corpus/${index}`, source: "corpus", candidate}; }
        for (const seed of policy.seeds) {
            let index = 0;
            for (const candidate of generatedCases(mode, seed, policy.iterations)) { yield {id: `${mode}/${seed}/${index++}`, source: "generated", seed, candidate}; }
        }
    }
}

export function planSummary(profile, phase, replay) {
    const hash = createHash("sha256"), groups = new Map(), primitiveFamilies = new Map(), structureForms = new Map(), budgetBoundaries = new Map(), entryPoints = new Map(), solanaWireSizes = new Map();
    let count = 0;
    for (const entry of plannedCases(profile, phase, replay)) {
        validateCase(entry.candidate);
        hash.update(`${entry.id}\0${caseDigest(entry.candidate)}\n`);
        const key = `${entry.candidate.mode}/${entry.source}/${entry.seed ?? "fixed"}`;
        groups.set(key, (groups.get(key) ?? 0) + 1);
        if (entry.source === "corpus" && entry.candidate.mode === "solana" && entry.candidate.name.startsWith("wire-size.")) {
            const accepted = entry.candidate.name === "wire-size.within";
            const size = Buffer.from(entry.candidate.inputBase64, "base64").length;
            if (size !== (accepted ? 1_232 : 1_233) || entry.candidate.expected?.accepted !== accepted) { throw new Error("Solana wire boundary lost its labeled size contract"); }
            solanaWireSizes.set(String(size), (solanaWireSizes.get(String(size)) ?? 0) + 1);
        }
        if (entry.candidate.mode === "eip712") {
            const entryPoint = typedDataEntryPoint(entry.candidate);
            entryPoints.set(entryPoint, (entryPoints.get(entryPoint) ?? 0) + 1);
            const boundary = /^budget\.([A-Za-z]+)\.(within|exceeded)$/.exec(entry.candidate.name);
            if (entry.source === "corpus" && boundary) {
                if (!EIP712_BUDGET_FAMILIES.includes(boundary[1]) || entry.candidate.entryPoint !== "checked" ||
                    entry.candidate.expected?.accepted !== (boundary[2] === "within") || boundary[2] === "exceeded" && !entry.candidate.expected.rejection) {
                    throw new Error("Typed-data budget case is missing its independently labeled contract");
                }
                const label = `${boundary[1]}/${boundary[2]}`;
                budgetBoundaries.set(label, (budgetBoundaries.get(label) ?? 0) + 1);
            }
        }
        if (entry.source === "generated" && entry.candidate.mode === "eip712" && entry.candidate.expected?.accepted === true) {
            const document = JSON.parse(Buffer.from(entry.candidate.inputBase64, "base64"));
            const type = document.types?.[document.primaryType]?.find(field => field.name === "value")?.type;
            if (!EIP712_PRIMITIVE_FAMILIES.includes(type)) { throw new Error("Positive generated typed-data case has no declared primitive family"); }
            const family = `${entry.seed}/${type}`;
            primitiveFamilies.set(family, (primitiveFamilies.get(family) ?? 0) + 1);
            const detail = document.types[document.primaryType].find(field => field.name === "detail")?.type;
            const form = `${entry.seed}/${detail === "Child" ? "struct" : detail === "Child[]" ? "structArray" : "flat"}`;
            structureForms.set(form, (structureForms.get(form) ?? 0) + 1);
        }
        count += 1;
    }
    if (phase === "parsers" && PROFILES[profile].seeds.some(seed => EIP712_PRIMITIVE_FAMILIES.some(type => !primitiveFamilies.get(`${seed}/${type}`)))) {
        throw new Error("Every seed must exercise every typed-data primitive family with positive cases");
    }
    if (phase === "parsers" && (PROFILES[profile].seeds.some(seed => EIP712_STRUCTURE_FORMS.some(form => !structureForms.get(`${seed}/${form}`))) ||
        EIP712_BUDGET_FAMILIES.some(family => ["within", "exceeded"].some(edge => budgetBoundaries.get(`${family}/${edge}`) !== 1)) ||
        ["1232", "1233"].some(size => solanaWireSizes.get(size) !== 1))) {
        throw new Error("Typed-data structural or resource-boundary coverage is incomplete");
    }
    return {count, sha256: hash.digest("hex"), groups: Object.fromEntries(groups), primitiveFamilies: Object.fromEntries(primitiveFamilies),
        structureForms: Object.fromEntries(structureForms), budgetBoundaries: Object.fromEntries(budgetBoundaries), entryPoints: Object.fromEntries(entryPoints),
        solanaWireSizes: Object.fromEntries(solanaWireSizes)};
}
