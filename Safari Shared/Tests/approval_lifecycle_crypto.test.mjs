import assert from "node:assert/strict";
import {createRequire} from "node:module";
import test from "node:test";
import {assertEthereumSignature, assertEthereumTransaction, assertSolanaSignature, assertSolanaTransaction, solanaMessage} from "../../Scripts/approval_lifecycle/crypto_assertions.mjs";
import {FakeRPC, LifecycleOracle} from "../../Scripts/approval_lifecycle/oracle.mjs";

const require = createRequire(new URL("../Inpage Provider/package.json", import.meta.url));
const {keccak_256} = require("@noble/hashes/sha3");
const {secp256k1} = require("@noble/curves/secp256k1");
const {ed25519} = require("@noble/curves/ed25519");
const {Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction, TransactionMessage, VersionedTransaction} = require("@solana/web3.js");
const base58Module = require("bs58");
const base58 = base58Module.default || base58Module;
const hex = bytes => "0x" + Buffer.from(bytes).toString("hex");
const address = privateKey => hex(keccak_256(secp256k1.getPublicKey(privateKey, false).subarray(1)).subarray(12));
const rejectsPayload = operation => assert.throws(operation, error => error.invariant === "payload");
const transactionPrivateKey = Buffer.from("608dcb1742bb3fb7aec002074e3420e4fab7d00cced79ccdac53ed5b27138151", "hex");
const legacy = {
    bytes: Buffer.from("f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83", "hex"),
    body: {object: {from: "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f", to: "0x3535353535353535353535353535353535353535", chainId: "0x1", nonce: "0x9", gas: "0x5208", gasPrice: "0x4a817c800", value: "0xde0b6b3a7640000", data: "0x"}},
};
const typed = {
    bytes: Buffer.from("02f8646480018202658252089400000000000000000000000000000000000000018080c001a06d393ebea2b95f5ce970d3714e1373ee2540baf804b87a9e089ec0ebcdd910eba04b8e799a5477b8ac85e2551c3f36102d4d6130ae6d8f73db5a2ae55734284bcd", "hex"),
    body: {object: {from: address(transactionPrivateKey), to: "0x0000000000000000000000000000000000000001", chainId: "0x64", nonce: "0x0", gas: "0x5208", maxPriorityFeePerGas: "0x1", maxFeePerGas: "0x265", value: "0x0", data: "0x", accessList: []}},
};

test("Ethereum message oracle verifies recoverable signatures for binary and UTF-8 payloads", () => {
    const key = Buffer.alloc(32, 1);
    for (const message of ["0x010203", "", "Approve café 🌐"]) {
        const bytes = message.startsWith("0x") ? Buffer.from(message.slice(2), "hex") : Buffer.from(message);
        const signed = secp256k1.sign(keccak_256(Buffer.concat([Buffer.from(`\x19Ethereum Signed Message:\n${bytes.length}`), bytes])), key);
        for (const recovery of [signed.recovery, signed.recovery + 27]) {
            const signature = hex(Buffer.concat([signed.toCompactRawBytes(), Buffer.from([recovery])]));
            assertEthereumSignature(signature, message, address(key));
            rejectsPayload(() => assertEthereumSignature(signature, message + "changed", address(key)));
            rejectsPayload(() => assertEthereumSignature(signature, message, address(Buffer.alloc(32, 2))));
        }
    }
});

test("Ethereum signature failures retain the payload invariant for malformed bytes", () => {
    for (const signature of [null, "0x", "0x" + "00".repeat(64), "0x" + "00".repeat(65), "0x" + "gg".repeat(65)]) {
        rejectsPayload(() => assertEthereumSignature(signature, "0x010203", legacy.body.object.from));
    }
});

test("Ethereum transaction oracle accepts independent legacy and EIP-1559 fixtures", () => {
    for (const fixture of [legacy, typed]) { assertEthereumTransaction(fixture.bytes, fixture.body); }
});

test("Ethereum transaction oracle rejects high-S variants while message recovery remains valid", () => {
    for (const fixture of [legacy, typed]) {
        const bytes = Buffer.from(fixture.bytes);
        const highS = secp256k1.CURVE.n - BigInt(hex(bytes.subarray(-32)));
        Buffer.from(highS.toString(16).padStart(64, "0"), "hex").copy(bytes, bytes.length - 32);
        bytes[bytes.length - 67] = fixture === legacy ? 0x26 : 0x80;
        rejectsPayload(() => assertEthereumTransaction(bytes, fixture.body));
    }
    const key = Buffer.alloc(32, 1);
    const message = Buffer.from([1, 2, 3]);
    const signature = secp256k1.sign(keccak_256(Buffer.concat([Buffer.from("\x19Ethereum Signed Message:\n3"), message])), key);
    const compact = Buffer.from(signature.toCompactRawBytes());
    const highS = secp256k1.CURVE.n - BigInt(hex(compact.subarray(32)));
    Buffer.from(highS.toString(16).padStart(64, "0"), "hex").copy(compact, 32);
    assertEthereumSignature(hex(Buffer.concat([compact, Buffer.from([(signature.recovery ^ 1) + 27])])), "0x010203", address(key));
});

test("Ethereum transaction oracle rejects signer, chain and transfer payload substitutions", () => {
    for (const fixture of [legacy, typed]) {
        for (const changes of [{from: address(Buffer.alloc(32, 3))}, {chainId: "0x2"}, {to: "0x0000000000000000000000000000000000000002"}, {value: "0x42"}, {data: "0x010203"}]) {
            rejectsPayload(() => assertEthereumTransaction(fixture.bytes, {object: {...fixture.body.object, ...changes}}));
        }
        const corrupted = Buffer.from(fixture.bytes);
        corrupted[corrupted.length - 1] ^= 1;
        rejectsPayload(() => assertEthereumTransaction(corrupted, fixture.body));
    }
});

test("Ethereum transaction oracle binds reviewed nonce, gas, fees and access list", () => {
    for (const [fixture, changes] of [
        [legacy, {nonce: "0x8"}], [legacy, {gas: "0x5209"}], [legacy, {gasPrice: "0x4a817c801"}],
        [typed, {nonce: "0x1"}], [typed, {gas: "0x5209"}], [typed, {maxPriorityFeePerGas: "0x2"}],
        [typed, {maxFeePerGas: "0x266"}], [typed, {accessList: [{address: "0x0000000000000000000000000000000000000002", storageKeys: []}]}],
    ]) {
        rejectsPayload(() => assertEthereumTransaction(fixture.bytes, {object: {...fixture.body.object, ...changes}}));
    }
});

test("Ethereum transaction oracle rejects type and fee-format substitutions", () => {
    assertEthereumTransaction(legacy.bytes, {object: {...legacy.body.object, type: "0x0"}});
    assertEthereumTransaction(typed.bytes, {object: {...typed.body.object, type: "0x2"}});
    rejectsPayload(() => assertEthereumTransaction(legacy.bytes, {object: {...legacy.body.object, type: "0x2"}}));
    rejectsPayload(() => assertEthereumTransaction(typed.bytes, {object: {...typed.body.object, type: "0x0"}}));

    const dynamic = {...legacy.body.object, maxFeePerGas: "0x1", maxPriorityFeePerGas: "0x0"};
    delete dynamic.gasPrice;
    rejectsPayload(() => assertEthereumTransaction(legacy.bytes, {object: dynamic}));
    const fixed = {...typed.body.object, gasPrice: "0x1"};
    delete fixed.maxFeePerGas;
    delete fixed.maxPriorityFeePerGas;
    rejectsPayload(() => assertEthereumTransaction(typed.bytes, {object: fixed}));
});

test("Ethereum transaction oracle treats an omitted access list as empty and rejects dropped entries", () => {
    const bytes = Buffer.from("02f87b6480018202658252089400000000000000000000000000000000000000018080d7d6940000000000000000000000000000000000000002c001a00b2e09c54bccd426bb7e71268a8eba6d3e806f9136fb4865d7520d22d868cf9da00de57c8d25a62ca04147ac161ef88445615bb95884becdfbd0506e4ace3e4817", "hex");
    const accessList = [{address: "0x0000000000000000000000000000000000000002", storageKeys: []}];
    assertEthereumTransaction(bytes, {object: {...typed.body.object, accessList}});
    const omitted = {...typed.body.object};
    delete omitted.accessList;
    assertEthereumTransaction(typed.bytes, {object: omitted});
    rejectsPayload(() => assertEthereumTransaction(bytes, {object: omitted}));
    rejectsPayload(() => assertEthereumTransaction(bytes, typed.body));
    rejectsPayload(() => assertEthereumTransaction(legacy.bytes, {object: {...legacy.body.object, accessList}}));
});

test("Ethereum transaction oracle rejects malformed, truncated and appended envelopes", () => {
    for (const bytes of [Buffer.alloc(0), Buffer.from([0xc0]), Buffer.from([0xb9, 0xff, 0xff]), legacy.bytes.subarray(0, -1), Buffer.concat([typed.bytes, Buffer.from([0])])]) {
        rejectsPayload(() => assertEthereumTransaction(bytes, legacy.body));
    }
});

test("Ethereum transaction oracle rejects non-canonical RLP instead of verifying a normalized preimage", () => {
    const original = legacy.bytes.toString("hex");
    for (const encoded of [
        "f86d8109" + original.slice(6),
        "f86eb80109" + original.slice(6),
        "f9006c" + original.slice(4),
    ]) { rejectsPayload(() => assertEthereumTransaction(Buffer.from(encoded, "hex"), legacy.body)); }

    const withNonminimalList = typed.bytes.toString("hex").replace("02f864", "02f865").replace("8080c0", "8080f800");
    rejectsPayload(() => assertEthereumTransaction(Buffer.from(withNonminimalList, "hex"), typed.body));
    const signedZeroNonce = Buffer.from("02f8646400018202658252089400000000000000000000000000000000000000018080c001a0305cec0c5c805b0ec05ebc0560939bc170543cdae7afafdbd579761847b5c995a01ccc4357b2cced3e47fa4cc6afe12566d9b93e014163b5f5ab1364ab7c4e9840", "hex");
    rejectsPayload(() => assertEthereumTransaction(signedZeroNonce, typed.body));
});

const solanaSigner = Keypair.fromSeed(Buffer.alloc(32, 2));
const recipient = new PublicKey("11111111111111111111111111111111");
function solanaFixture(versioned = false, multiSigner = false) {
    const other = Keypair.fromSeed(Buffer.alloc(32, 3));
    const instructions = [SystemProgram.transfer({fromPubkey: solanaSigner.publicKey, toPubkey: recipient, lamports: 1})];
    if (multiSigner) {
        instructions.push(new TransactionInstruction({programId: recipient, data: Buffer.alloc(0), keys: [{pubkey: other.publicKey, isSigner: true, isWritable: false}]}));
    }
    const transaction = versioned
        ? new VersionedTransaction(new TransactionMessage({payerKey: solanaSigner.publicKey, recentBlockhash: recipient.toBase58(), instructions}).compileToV0Message())
        : new Transaction({feePayer: solanaSigner.publicKey, recentBlockhash: recipient.toBase58()}).add(...instructions);
    const signers = multiSigner ? [solanaSigner, other] : [solanaSigner];
    if (versioned) { transaction.sign(signers); } else { transaction.sign(...signers); }
    return {bytes: Buffer.from(transaction.serialize()), publicKey: solanaSigner.publicKey.toBase58(), other: other.publicKey.toBase58()};
}

test("Solana message oracle verifies binary, hexadecimal and base58 signatures", () => {
    const seed = Buffer.alloc(32, 2);
    for (const message of [Buffer.alloc(0), Buffer.from([0, 1, 2, 255]), Buffer.from("Approve café 🌐")]) {
        const signature = ed25519.sign(message, seed);
        for (const encoded of [signature, Buffer.from(signature).toString("hex"), base58.encode(signature)]) {
            assertSolanaSignature(encoded, message, solanaSigner.publicKey.toBase58());
            rejectsPayload(() => assertSolanaSignature(encoded, Buffer.concat([message, Buffer.from([0])]), solanaSigner.publicKey.toBase58()));
            rejectsPayload(() => assertSolanaSignature(encoded, message, Keypair.fromSeed(Buffer.alloc(32, 3)).publicKey.toBase58()));
        }
    }
});

test("Malformed Solana signatures and keys retain the payload invariant", () => {
    for (const signature of ["0", "", Buffer.alloc(63), Buffer.alloc(65)]) {
        rejectsPayload(() => assertSolanaSignature(signature, Buffer.from([1]), solanaSigner.publicKey.toBase58()));
    }
    rejectsPayload(() => assertSolanaSignature(Buffer.alloc(64), Buffer.from([1]), "not-a-base58-key"));
});

test("Solana transaction oracle validates legacy, v0 and each signer in multisignature transactions", () => {
    for (const versioned of [false, true]) {
        for (const multiSigner of [false, true]) {
            const fixture = solanaFixture(versioned, multiSigner);
            const message = solanaMessage(fixture.bytes);
            assert.equal(message.signatureCount, multiSigner ? 2 : 1);
            for (const publicKey of multiSigner ? [fixture.publicKey, fixture.other] : [fixture.publicKey]) {
                for (const params of [{transaction: base58.encode(fixture.bytes)}, {message: base58.encode(message.message)}]) {
                    assertSolanaTransaction(fixture.bytes, {publicKey, object: {params}});
                }
            }
        }
    }
});

test("Solana transaction oracle rejects changed messages, invalid signatures and unrelated signers", () => {
    const fixture = solanaFixture();
    const body = {publicKey: fixture.publicKey, object: {params: {transaction: base58.encode(fixture.bytes)}}};
    const messageChanged = Buffer.from(fixture.bytes);
    messageChanged[messageChanged.length - 1] ^= 1;
    rejectsPayload(() => assertSolanaTransaction(messageChanged, body));
    const signatureChanged = Buffer.from(fixture.bytes);
    signatureChanged[1] ^= 1;
    rejectsPayload(() => assertSolanaTransaction(signatureChanged, body));
    rejectsPayload(() => assertSolanaTransaction(fixture.bytes, {...body, publicKey: fixture.other}));
    for (const bytes of [Buffer.alloc(0), Buffer.from([0]), Buffer.from([1, 0]), Buffer.alloc(65), Buffer.from([0x80, 0x80, 0x80, 0x80, 0x80])]) {
        rejectsPayload(() => solanaMessage(bytes));
    }
});

test("Solana transaction oracle requires a canonical envelope with every required signature", () => {
    for (const versioned of [false, true]) {
        const fixture = solanaFixture(versioned, true);
        const body = {publicKey: fixture.publicKey, object: {params: {transaction: base58.encode(fixture.bytes)}}};
        const parsed = solanaMessage(fixture.bytes);
        const missing = Buffer.concat([Buffer.from([1]), fixture.bytes.subarray(1, 65), parsed.message]);
        const extra = Buffer.concat([Buffer.from([3]), fixture.bytes.subarray(1, 129), Buffer.alloc(64), parsed.message]);
        const overlong = Buffer.concat([Buffer.from([0x82, 0]), fixture.bytes.subarray(1)]);
        const zeroed = Buffer.from(fixture.bytes);
        zeroed.fill(0, 65, 129);
        const corrupted = Buffer.from(fixture.bytes);
        corrupted[65] ^= 1;
        for (const bytes of [missing, extra, overlong, zeroed, corrupted]) {
            rejectsPayload(() => assertSolanaTransaction(bytes, body));
        }
        rejectsPayload(() => solanaMessage(overlong));
    }
});

test("Solana transaction oracle rejects non-canonical account-key lengths even with a valid signature", () => {
    for (const versioned of [false, true]) {
        const fixture = solanaFixture(versioned);
        const original = solanaMessage(fixture.bytes).message;
        const countOffset = versioned ? 4 : 3;
        const message = Buffer.concat([original.subarray(0, countOffset), Buffer.from([original[countOffset] | 128, 0]), original.subarray(countOffset + 1)]);
        const signature = ed25519.sign(message, solanaSigner.secretKey.subarray(0, 32));
        const bytes = Buffer.concat([Buffer.from([1]), signature, message]);
        rejectsPayload(() => assertSolanaTransaction(bytes, {publicKey: fixture.publicKey, object: {params: {message: base58.encode(message)}}}));
    }
});

test("simulated Solana RPC accepts complete multisignature envelopes and rejects missing cosignatures", async () => {
    for (const malformed of [false, true]) {
        const fixture = solanaFixture(true, true);
        const body = {publicKey: fixture.publicKey, reviewedCluster: "devnet", object: {params: {transaction: base58.encode(fixture.bytes)}}};
        const bytes = malformed ? Buffer.concat([Buffer.from([1]), fixture.bytes.subarray(1, 65), solanaMessage(fixture.bytes).message]) : fixture.bytes;
        const handle = {id: 1, token: "multisignature", profileIdentifier: null};
        const oracle = new LifecycleOracle;
        oracle.register({handle, configurationKey: "https://one.example", provider: "solana", name: "signAndSendTransaction", account: fixture.publicKey});
        oracle.approvalIntent({handle, label: "approved"});
        oracle.acceptConsent({handle, label: "approved"});
        const execution = {handle, executionID: "execution", epoch: "approval-1"};
        oracle.execution(execution);
        oracle.signed(execution);
        oracle.checkpoint(execution);
        const events = [];
        const rpc = new FakeRPC({ledger: {append: event => events.push(event)}, oracle, requestBody: () => body});
        const reply = rpc.respond({...execution, endpoint: "https://solana.fixture.invalid/solana-devnet", cluster: "devnet",
            request: {id: 1, method: "sendTransaction", params: [bytes.toString("base64"), {encoding: "base64"}]}});
        if (malformed) {
            await assert.rejects(reply, error => error.invariant === "payload");
            assert.equal(events.length, 0);
        } else {
            assert.equal((await reply).result, base58.encode(fixture.bytes.subarray(1, 65)));
            assert.deepEqual(events.map(event => event.type), ["rpc.received", "rpc.accepted"]);
        }
    }
});

test("simulated RPC rejects broadcasts sent to a different reviewed network before recording receipt", async () => {
    const solana = solanaFixture();
    for (const [provider, body, request, targets] of [
        ["ethereum", legacy.body, {id: 1, method: "eth_sendRawTransaction", params: [hex(legacy.bytes)]}, [
            {endpoint: "https://rpc.fixture.invalid/10"},
            {endpoint: "https://rpc.fixture.invalid/1"},
        ]],
        ["solana", {publicKey: solana.publicKey, reviewedCluster: "devnet", object: {params: {transaction: base58.encode(solana.bytes)}}},
            {id: 1, method: "sendTransaction", params: [solana.bytes.toString("base64"), {encoding: "base64"}]}, [
                {endpoint: "https://solana.fixture.invalid/solana-mainnet", cluster: "devnet"},
                {endpoint: "https://solana.fixture.invalid/solana-devnet", cluster: "mainnetBeta"},
                {endpoint: "https://solana.fixture.invalid/solana-devnet", cluster: "devnet"},
            ]],
    ]) {
        const handle = {id: 1, token: provider, profileIdentifier: null};
        const oracle = new LifecycleOracle;
        oracle.register({handle, configurationKey: "https://one.example", provider, name: provider === "ethereum" ? "signTransaction" : "signAndSendTransaction"});
        oracle.approvalIntent({handle, label: "approved"});
        oracle.acceptConsent({handle, label: "approved"});
        const execution = {handle, executionID: provider, epoch: "approval-1"};
        oracle.execution(execution);
        oracle.signed(execution);
        oracle.checkpoint(execution);
        const events = [];
        const rpc = new FakeRPC({ledger: {append: event => events.push(event)}, oracle, requestBody: () => body});
        for (const target of targets.slice(0, -1)) {
            await assert.rejects(rpc.respond({...execution, ...target, request}), error => error.invariant === "broadcast");
            assert.equal(events.length, 0);
        }
        await rpc.respond({...execution, ...targets.at(-1), request});
        assert.deepEqual(events.map(event => event.type), ["rpc.received", "rpc.accepted"]);
    }
});
