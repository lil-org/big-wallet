import {createRequire} from "node:module";
import {LifecycleFailure} from "./scheduler.mjs";

const require = createRequire(new URL("../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {keccak_256} = require("@noble/hashes/sha3");
const {secp256k1} = require("@noble/curves/secp256k1");
const {ed25519} = require("@noble/curves/ed25519");
const base58Module = require("bs58");
const base58 = base58Module.default || base58Module;

const failure = (message, details) => { throw new LifecycleFailure("payload", message, details); };
const hex = value => "0x" + Buffer.from(value).toString("hex");
const quantity = value => value.length ? BigInt(hex(value)) : 0n;
const quantityBytes = value => {
    if (value === 0n) { return Buffer.alloc(0); }
    const encoded = value.toString(16);
    return Buffer.from(encoded.length % 2 ? "0" + encoded : encoded, "hex");
};

function rlpLength(prefix, length) {
    if (length < 56) { return Buffer.from([prefix + length]); }
    const bytes = quantityBytes(BigInt(length));
    return Buffer.concat([Buffer.from([prefix + 55 + bytes.length]), bytes]);
}
function encodeRLP(value) {
    if (Array.isArray(value)) {
        const bytes = Buffer.concat(value.map(encodeRLP));
        return Buffer.concat([rlpLength(0xc0, bytes.length), bytes]);
    }
    const bytes = Buffer.from(value);
    if (bytes.length === 1 && bytes[0] < 0x80) { return bytes; }
    return Buffer.concat([rlpLength(0x80, bytes.length), bytes]);
}
function decodeRLP(bytes, start = 0) {
    if (start >= bytes.length) { return failure("Truncated Ethereum transaction"); }
    const prefix = bytes[start];
    if (prefix < 0x80) { return {value: bytes.subarray(start, start + 1), end: start + 1}; }
    const list = prefix >= 0xc0;
    const base = list ? 0xc0 : 0x80;
    let offset = start + 1;
    let length = prefix - base;
    if (length > 55) {
        const width = length - 55;
        if (offset + width > bytes.length) { return failure("Truncated Ethereum RLP length"); }
        const integer = quantity(bytes.subarray(offset, offset + width));
        if (bytes[offset] === 0 || integer < 56n) { return failure("Non-canonical Ethereum RLP length"); }
        if (integer > BigInt(bytes.length)) { return failure("Ethereum RLP length exceeds transaction"); }
        length = Number(integer);
        offset += width;
    }
    const end = offset + length;
    if (end > bytes.length) { return failure("Truncated Ethereum RLP value"); }
    if (!list && length === 1 && bytes[offset] < 0x80) { return failure("Non-canonical Ethereum RLP byte"); }
    if (!list) { return {value: bytes.subarray(offset, end), end}; }
    const value = [];
    while (offset < end) {
        const item = decodeRLP(bytes, offset);
        value.push(item.value);
        offset = item.end;
    }
    if (offset !== end) { return failure("Ethereum RLP list has an invalid boundary"); }
    return {value, end};
}
function ethereumAddress(hash, signature, recovery) {
    try {
        const key = secp256k1.Signature.fromCompact(signature).addRecoveryBit(Number(recovery)).recoverPublicKey(hash).toRawBytes(false);
        return hex(keccak_256(key.subarray(1)).subarray(12)).toLowerCase();
    } catch { return failure("Ethereum signature is not recoverable"); }
}
function compactSignature(r, s) {
    if (r.length > 32 || s.length > 32) { return failure("Ethereum signature scalar exceeds 32 bytes"); }
    return Buffer.concat([Buffer.alloc(32 - r.length), r, Buffer.alloc(32 - s.length), s]);
}

export function assertEthereumSignature(signature, message, address) {
    if (typeof signature !== "string" || !/^0x[0-9a-f]{130}$/i.test(signature)) { return failure("Ethereum message returned malformed signature bytes"); }
    const bytes = Buffer.from(signature.slice(2), "hex");
    const payload = typeof message === "string" && /^0x(?:[0-9a-f]{2})*$/i.test(message)
        ? Buffer.from(message.slice(2), "hex") : Buffer.from(message);
    const prefixed = Buffer.concat([Buffer.from(`\x19Ethereum Signed Message:\n${payload.length}`), payload]);
    const recovery = bytes[64] >= 27 ? bytes[64] - 27 : bytes[64];
    if (ethereumAddress(keccak_256(prefixed), bytes.subarray(0, 64), recovery) !== address.toLowerCase()) {
        failure("Ethereum signature does not match the approved account and message");
    }
}

export function assertEthereumTransaction(bytes, body) {
    const typed = bytes[0] === 2;
    const decoded = decodeRLP(bytes, typed ? 1 : 0);
    const fields = decoded.value;
    if (!Array.isArray(fields) || decoded.end !== bytes.length || fields.length !== (typed ? 12 : 9) ||
        fields.some((field, index) => typed && index === 8 ? !Array.isArray(field) : !Buffer.isBuffer(field))) {
        return failure("Unexpected signed Ethereum transaction structure");
    }
    const integers = typed ? [0, 1, 2, 3, 4, 6, 9, 10, 11] : [0, 1, 2, 4, 6, 7, 8];
    if (integers.some(index => fields[index][0] === 0)) { return failure("Non-canonical Ethereum transaction integer"); }
    const object = body.object || {};
    if (object.type !== undefined && BigInt(object.type) !== (typed ? 2n : 0n)) {
        failure("Signed transaction changed its reviewed type");
    }
    const hasDynamicFees = object.maxFeePerGas !== undefined || object.maxPriorityFeePerGas !== undefined;
    if (hasDynamicFees && !typed || object.gasPrice !== undefined && typed) {
        failure("Signed transaction changed its reviewed fee format");
    }
    let chain, recovery, signable, r, s, to, value, data;
    if (typed) {
        chain = quantity(fields[0]);
        recovery = quantity(fields[9]);
        signable = Buffer.concat([Buffer.from([2]), encodeRLP(fields.slice(0, 9))]);
        [r, s] = fields.slice(10);
        [to, value, data] = fields.slice(5, 8);
    } else {
        const v = quantity(fields[6]);
        if (v < 35n) { return failure("Ethereum broadcast is missing replay protection"); }
        chain = (v - 35n) / 2n;
        recovery = (v - 35n) % 2n;
        signable = encodeRLP([...fields.slice(0, 6), quantityBytes(chain), Buffer.alloc(0), Buffer.alloc(0)]);
        [r, s] = fields.slice(7);
        [to, value, data] = fields.slice(3, 6);
    }
    if (quantity(s) > secp256k1.CURVE.n / 2n) { failure("Ethereum transaction signature is not low-S"); }
    const expectedAddress = object.from || body.address;
    if (expectedAddress && ethereumAddress(keccak_256(signable), compactSignature(r, s), recovery) !== expectedAddress.toLowerCase()) {
        failure("Signed transaction account differs from the submitted account");
    }
    if (chain !== BigInt(object.chainId || body.chainId)) { failure("Signed transaction changed its chain"); }
    if (hex(to).toLowerCase() !== (object.to || "0x").toLowerCase() || quantity(value) !== BigInt(object.value || "0x0") ||
        hex(data).toLowerCase() !== (object.data || object.input || "0x").toLowerCase()) {
        failure("Signed transaction changed recipient, value, or calldata");
    }
    const quantities = typed ? {nonce: 1, maxPriorityFeePerGas: 2, maxFeePerGas: 3, gas: 4} : {nonce: 0, gasPrice: 1, gas: 2};
    for (const [name, index] of Object.entries(quantities)) {
        const expected = object[name] ?? (name === "gas" ? object.gasLimit : undefined);
        if (expected !== undefined && quantity(fields[index]) !== BigInt(expected)) { failure(`Signed transaction changed reviewed ${name}`); }
    }
    const actualAccessList = typed ? fields[8].map(([address, keys]) => ({address: hex(address).toLowerCase(), storageKeys: keys.map(key => hex(key).toLowerCase())})) : [];
    const expectedAccessList = (object.accessList ?? []).map(entry => ({address: (Array.isArray(entry) ? entry[0] : entry.address).toLowerCase(),
        storageKeys: (Array.isArray(entry) ? entry[1] : entry.storageKeys).map(value => value.toLowerCase())}));
    if (JSON.stringify(actualAccessList) !== JSON.stringify(expectedAccessList)) { failure("Signed transaction changed reviewed access list"); }
}

function shortVector(bytes, offset) {
    let value = 0;
    for (let index = 0; offset < bytes.length && index < 3; index += 1) {
        const byte = bytes[offset++];
        if (index === 2 && byte > 3) { return failure("Invalid Solana transaction length"); }
        value += (byte & 127) * 2 ** (index * 7);
        if (!(byte & 128)) {
            if (index > 0 && byte === 0) { return failure("Non-canonical Solana transaction length"); }
            return {value, offset};
        }
    }
    return failure("Invalid Solana transaction length");
}
export function solanaMessage(bytes) {
    const count = shortVector(bytes, 0);
    const offset = count.offset + count.value * 64;
    if (count.value === 0 || offset >= bytes.length) { return failure("Solana transaction omitted signatures or message"); }
    return {message: bytes.subarray(offset), signatureCount: count.value, signaturesOffset: count.offset};
}
export function assertSolanaSignature(signature, message, publicKey) {
    try {
        const key = base58.decode(publicKey);
        const signatureBytes = typeof signature === "string" ? (/^[0-9a-f]{128}$/i.test(signature) ? Buffer.from(signature, "hex") : base58.decode(signature)) : signature;
        if (!ed25519.verify(signatureBytes, message, key)) { failure("Solana signature does not match the approved account and message"); }
    } catch (error) {
        if (error instanceof LifecycleFailure) { throw error; }
        failure("Solana returned malformed signature or public key bytes");
    }
}
export function assertSolanaTransaction(bytes, body) {
    const params = body.object?.params || {};
    const parsed = solanaMessage(bytes);
    const expectedMessage = params.transaction ? solanaMessage(Buffer.from(base58.decode(params.transaction))).message : Buffer.from(base58.decode(params.message));
    if (!parsed.message.equals(expectedMessage)) { failure("Signed Solana transaction changed its approved message"); }
    const headerStart = parsed.message[0] & 128 ? 1 : 0;
    if (headerStart && parsed.message[0] !== 128 || parsed.message.length < headerStart + 3) {
        failure("Invalid Solana transaction message header");
    }
    const requiredSignatures = parsed.message[headerStart];
    if (parsed.signatureCount !== requiredSignatures) { failure("Solana transaction signature count does not match its message"); }
    const keyCount = shortVector(parsed.message, headerStart + 3);
    if (keyCount.value < requiredSignatures || parsed.message.length < keyCount.offset + keyCount.value * 32 + 32) {
        failure("Solana transaction omitted required account keys or blockhash");
    }
    const expectedKey = Buffer.from(base58.decode(body.publicKey));
    let signer = -1;
    for (let index = 0; index < parsed.signatureCount; index += 1) {
        const key = parsed.message.subarray(keyCount.offset + index * 32, keyCount.offset + (index + 1) * 32);
        if (key.equals(expectedKey)) { signer = index; }
        assertSolanaSignature(bytes.subarray(parsed.signaturesOffset + index * 64, parsed.signaturesOffset + (index + 1) * 64), parsed.message, base58.encode(key));
    }
    if (signer < 0) { failure("Approved Solana account is not a transaction signer"); }
}
