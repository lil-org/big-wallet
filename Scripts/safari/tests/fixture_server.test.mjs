import test from "node:test";
import assert from "node:assert/strict";
import {mkdtemp, rm, readFile, appendFile, writeFile, chmod, realpath, readdir, unlink, symlink, mkdir, rename} from "node:fs/promises";
import {createServer, request as httpRequest} from "node:http";
import {tmpdir, userInfo} from "node:os";
import {join} from "node:path";
import {createRequire} from "node:module";
import {SafariFixtureServer, inspectProcess} from "../fixture_server.mjs";
import {extensionEntitlements, parseArguments} from "../run.mjs";

const fixtureRequire = createRequire(new URL("../../../Safari Shared/Inpage Provider/package.json", import.meta.url));
const {ed25519} = fixtureRequire("@noble/curves/ed25519");
const {secp256k1} = fixtureRequire("@noble/curves/secp256k1");
const {keccak_256} = fixtureRequire("@noble/hashes/sha3");
const {Keypair, Transaction} = fixtureRequire("@solana/web3.js");
const base58Module = fixtureRequire("bs58");
const base58 = base58Module.default || base58Module;

async function harness(context, scenario = "install-native-roundtrip", options = {}) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-fixtures-")));
    const descriptor = {version: 1, runID: "run-test", root, platform: "macos", signingMode: "local", configuration: "Debug"};
    const server = await new SafariFixtureServer({descriptor, stageId: "safari.macos.debug", artifacts: join(root, "artifacts"), guestCredentialPath: join(root, "guest-credential.json"), ...options}).start();
    context.after(async () => { await server.close(); await rm(root, {recursive: true, force: true}); });
    const control = (path, value = {}) => fetch(`${server.url}/control/${path}`, {
        method: "POST", headers: {Authorization: `Bearer ${server.token}`, "Content-Type": "application/json"}, body: JSON.stringify(value),
    });
    assert.equal((await control("start", {scenario, iteration: 1})).status, 200);
    const document = await (await fetch(`${server.dappURL}/page-config`)).json();
    const report = value => fetch(`${server.dappURL}/page-result`, {method: "POST", headers: {"X-Page-Token": server.pageToken, "Content-Type": "application/json"}, body: JSON.stringify({origin: server.dappURL, documentId: document.documentId, ...value, scenario: {id: scenario, iteration: 1}})});
    return {server, root, control, report, document};
}

test("interactive activation is opt-in and records ordered observed states without completing a scenario", async context => {
    const {server, control, root} = await harness(context, "extension-toggle", {interactiveActivation: true});
    assert.equal((await (await control("config")).json()).interactiveActivation, true);
    assert.equal((await control("interactive-activation", {phase: "observed", enabled: true})).status, 409);
    assert.equal((await control("interactive-activation", {phase: "waiting", enabled: true})).status, 200);
    assert.equal((await control("interactive-activation", {phase: "waiting", enabled: true})).status, 409);
    assert.equal((await control("interactive-activation", {phase: "observed", enabled: false})).status, 409);
    assert.equal((await control("interactive-activation", {phase: "observed", enabled: true})).status, 200);
    assert.equal((await control("interactive-activation", {phase: "observed", enabled: true})).status, 409);
    assert.equal((await control("interactive-activation", {phase: "waiting", enabled: false})).status, 200);
    assert.equal((await control("interactive-activation", {phase: "observed", enabled: false})).status, 200);
    const ledger = JSON.parse(await readFile(join(root, "artifacts/safari.macos.debug.safari-activation.json"), "utf8"));
    assert.equal(ledger.activationMode, "interactive");
    assert.deepEqual(ledger.requests.map(request => request.enabled), [true, false]);
    assert.ok(ledger.requests.every(request => request.scenario.id === "extension-toggle" &&
        request.scenario.iteration === 1 && Date.parse(request.observedAt) >= Date.parse(request.requestedAt)));
    assert.equal(server.scenarios.length, 0);
    assert.equal(server.providerReady, false);
    await server.persist();
    const evidence = JSON.parse(await readFile(join(root, "artifacts/safari.macos.debug.safari.json"), "utf8"));
    assert.equal(evidence.activationMode, "interactive");
    assert.deepEqual(evidence.activationRequests, ledger.requests);
});

test("interactive activation rejects unrequested, malformed, unauthenticated and completed-scenario checkpoints", async context => {
    const ordinary = await harness(context);
    assert.equal((await (await ordinary.control("config")).json()).interactiveActivation, false);
    assert.equal((await ordinary.control("interactive-activation", {phase: "waiting", enabled: true})).status, 403);
    const {server, control} = await harness(context, "install-native-roundtrip", {interactiveActivation: true});
    for (const value of [null, [], {}, {phase: "waiting", enabled: "yes"}, {phase: "approved", enabled: true},
        {phase: "waiting", enabled: true, consent: true}]) {
        assert.equal((await control("interactive-activation", value)).status, 400);
    }
    assert.equal((await fetch(`${server.url}/control/interactive-activation`, {
        method: "POST", body: JSON.stringify({phase: "waiting", enabled: true}),
    })).status, 403);
    server.scenarios.push({id: server.current.id, iteration: server.current.iteration, status: "failed"});
    assert.equal((await control("interactive-activation", {phase: "waiting", enabled: true})).status, 403);
    assert.throws(() => new SafariFixtureServer({descriptor: {...server.descriptor, platform: "ios"}, interactiveActivation: true}), /macOS Safari/);
});

test("prepared activation preserves verified preparation provenance without enabling interactive checkpoints", async context => {
    const preparation = {preparationRunID: "run-preparation", receiptSHA256: "a".repeat(64)};
    const {server, control, root} = await harness(context, "install-native-roundtrip", {preparedActivation: true, preparation});
    const config = await (await control("config")).json();
    assert.equal(config.activationMode, "prepared");
    assert.equal(config.interactiveActivation, false);
    assert.equal((await control("interactive-activation", {phase: "waiting", enabled: true})).status, 403);
    preparation.receiptSHA256 = "b".repeat(64);
    await server.persist();
    const evidence = JSON.parse(await readFile(join(root, "artifacts/safari.macos.debug.safari.json"), "utf8"));
    assert.deepEqual(evidence.preparation, {preparationRunID: "run-preparation", receiptSHA256: "a".repeat(64)});
    assert.equal(evidence.activationMode, "prepared");
    for (const options of [
        {preparedActivation: true},
        {preparedActivation: true, preparation: {...preparation, receiptSHA256: "invalid"}},
        {preparedActivation: true, preparation, interactiveActivation: true},
        {preparedActivation: true, preparation, preparationNonce: "eacfab5b-bbdd-4824-9e3c-582e9b68a865"},
        {preparedActivation: true, preparation, descriptor: {...server.descriptor, platform: "ios"}},
        {preparedActivation: true, preparation, descriptor: {...server.descriptor, signingMode: "apple"}},
        {preparation},
    ]) {
        assert.throws(() => new SafariFixtureServer({descriptor: server.descriptor, ...options}), /Prepared activation/);
    }
});

test("preparation credential staging requires a matching private owned marker without opening the HTTP control endpoint", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-preparation-")));
    const descriptor = {version: 1, runID: "run-preparation", root, platform: "macos", signingMode: "local", configuration: "Debug"};
    const nonce = "eacfab5b-bbdd-4824-9e3c-582e9b68a865";
    const writes = [];
    const server = await new SafariFixtureServer({descriptor, preparationNonce: nonce, stageId: "activation.macos.debug",
        artifacts: join(root, "artifacts"), guestCredentialPath: join(root, "guest-credential.json"),
        clipboardWriter: async value => { writes.push(value); }}).start();
    context.after(async () => { await server.close(); await rm(root, {recursive: true, force: true}); });
    await writeFile(join(root, "guest-credential.json"), JSON.stringify({
        version: 1, runID: descriptor.runID, consoleUser: userInfo().username, password: "fixture-guest-password",
    }), {mode: 0o600});
    const markerPath = join(root, "activation-preparation.json");
    const marker = {version: 1, runID: descriptor.runID, nonce, showPreferences: true};
    await assert.rejects(server.stagePreparationGuestCredential(nonce), /marker/);
    await writeFile(markerPath, JSON.stringify(marker), {mode: 0o600});
    await assert.rejects(server.stagePreparationGuestCredential("another-nonce"), /owned Safari/);
    await chmod(markerPath, 0o640);
    await assert.rejects(server.stagePreparationGuestCredential(nonce), /marker/);
    await chmod(markerPath, 0o600);
    for (const invalid of [{...marker, runID: "another-run"}, {...marker, extra: true}, {...marker, showPreferences: "true"}]) {
        await writeFile(markerPath, JSON.stringify(invalid));
        await assert.rejects(server.stagePreparationGuestCredential(nonce), /marker/);
    }
    await unlink(markerPath);
    await writeFile(join(root, "marker-target.json"), JSON.stringify(marker), {mode: 0o600});
    await symlink(join(root, "marker-target.json"), markerPath);
    await assert.rejects(server.stagePreparationGuestCredential(nonce), /marker/);
    await unlink(markerPath);
    await writeFile(markerPath, JSON.stringify(marker), {mode: 0o600});
    assert.deepEqual(writes, []);
    const response = await fetch(`${server.url}/control/stage-guest-credential`, {
        method: "POST", headers: {Authorization: `Bearer ${server.token}`}, body: "{}",
    });
    assert.equal(response.status, 403);
    await server.stagePreparationGuestCredential(nonce);
    assert.deepEqual(writes, ["fixture-guest-password"]);
    await server.clearGuestCredential();
    assert.deepEqual(writes, ["fixture-guest-password", ""]);
    server.current = {id: "install-native-roundtrip", iteration: 1};
    await assert.rejects(server.stagePreparationGuestCredential(nonce), /owned Safari/);
    server.current = null;
});

test("preparation state evidence requires typed success or failure and native process identity", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-preparation-evidence-")));
    context.after(async () => { await rm(root, {recursive: true, force: true}); });
    const descriptor = {runID: "run-preparation", root, platform: "macos"};
    const valid = {kind: "safariExtensionState", runID: descriptor.runID,
        preparationNonce: "eacfab5b-bbdd-4824-9e3c-582e9b68a865",
        incarnation: "2ce1ac39-6d81-4fe5-a3cb-797a068f7949", processID: 123,
        time: 100, scenario: null, iteration: null, requestID: null,
        enabled: true, errorDomain: null, errorCode: null};
    const cases = [
        [valid, true],
        [{...valid, enabled: null, errorDomain: "SFErrorDomain", errorCode: 1}, true],
        [{...valid, preparationNonce: "invalid"}, false],
        [{...valid, enabled: "true"}, false],
        [{...valid, enabled: null}, false],
        [{...valid, errorDomain: "SFErrorDomain", errorCode: 1}, false],
        [{...valid, processID: 0}, false],
        [{...valid, incarnation: "unverified"}, false],
        [{...valid, scenario: "install-native-roundtrip", iteration: 1}, false],
    ];
    for (let index = 0; index < cases.length; index += 1) {
        const [record, accepted] = cases[index];
        const fixtureRoot = join(root, String(index));
        await mkdir(fixtureRoot);
        await writeFile(join(fixtureRoot, "native-events.ndjson"), JSON.stringify(record) + "\n");
        const server = new SafariFixtureServer({descriptor: {...descriptor, root: fixtureRoot}, stageId: "activation.macos.debug"});
        if (accepted) { assert.deepEqual(await server.nativeEvents(), [record]); }
        else { await assert.rejects(server.nativeEvents(), /preparation native state evidence/); }
    }
});

function correlatedSigningEvents(requestID, configurationKey) {
    const identity = {requestID, requestToken: `request-${requestID}`, profileIdentifier: null,
        configurationKey, consentID: `consent-${requestID}`};
    const executionID = `execution-${requestID}`;
    return [{kind: "consentAccepted", ...identity}, {kind: "authorization", ...identity, executionID},
        {kind: "signingStarted", requestID, executionID}];
}

function siteIngress(server, overrides = {}) {
    return {kind: "nativeIngress", source: "site", configurationKey: server.dappURL,
        host: new URL(server.dappURL).host, privateBrowsing: false, tabID: 1, frameID: 0,
        documentID: "native-safari-document", profileIdentifier: null, ...overrides};
}

function signedEthereumTransaction(transaction) {
    const quantity = value => {
        const number = BigInt(value);
        const hex = number.toString(16);
        return number === 0n ? Buffer.alloc(0) : Buffer.from(hex.padStart(hex.length + hex.length % 2, "0"), "hex");
    };
    const rlp = value => {
        const list = Array.isArray(value);
        const bytes = list ? Buffer.concat(value.map(rlp)) : value;
        assert.ok(bytes.length < 256);
        if (!list && bytes.length === 1 && bytes[0] < 128) { return bytes; }
        const prefix = list ? 192 : 128;
        return Buffer.concat([Buffer.from(bytes.length < 56 ? [prefix + bytes.length] : [prefix + 56, bytes.length]), bytes]);
    };
    const fields = [quantity(transaction.nonce), quantity(transaction.gasPrice), quantity(transaction.gas),
        Buffer.from(transaction.to.slice(2), "hex"), quantity(transaction.value), Buffer.from(transaction.data.slice(2), "hex")];
    const chain = BigInt(transaction.chainId);
    const signature = secp256k1.sign(keccak_256(rlp([...fields, quantity(chain), Buffer.alloc(0), Buffer.alloc(0)])), Buffer.alloc(32, 1));
    return rlp([...fields, quantity(2n * chain + 35n + BigInt(signature.recovery)), quantity(signature.r), quantity(signature.s)]);
}

async function broadcastHarness(context, action, scenario = action === "solana-send" ? "solana-broadcast" : "ethereum-broadcast") {
    const fixture = await harness(context, scenario);
    const {server, root, control, report, document} = fixture;
    const chain = action === "solana-send" ? "solana" : "ethereum";
    const append = records => appendFile(join(root, "native-events.ndjson"), records.map(record => JSON.stringify({
        ...record, runID: server.descriptor.runID, scenario, iteration: 1,
    }) + "\n").join(""));
    await append([siteIngress(server), ...correlatedSigningEvents(1, server.dappURL)]);
    assert.equal((await report({phase: "provider-ready"})).status, 200);
    let sequence = 0;
    const start = async () => {
        const requestId = `broadcast-request-${++sequence}`;
        assert.equal((await report({phase: "started", action, requestId})).status, 200);
        return requestId;
    };
    const broadcast = async (requestId, {route = chain, ambiguous = false} = {}) => {
        let method, params;
        if (chain === "solana") {
            const response = await fetch(`${server.dappURL}/page-solana-transaction`, {method: "POST",
                headers: {"X-Page-Token": server.pageToken, "Content-Type": "application/json"},
                body: JSON.stringify({requestId, origin: server.dappURL, documentId: document.documentId, scenario: {id: scenario, iteration: 1}})});
            assert.equal(response.status, 200);
            const transaction = Transaction.from(base58.decode((await response.json()).transaction));
            transaction.sign(Keypair.fromSeed(Buffer.alloc(32, 2)));
            method = "sendTransaction";
            params = [transaction.serialize().toString("base64"), {encoding: "base64"}];
        } else {
            const transaction = {...server.fixture.ethereumTransaction, from: server.fixture.addresses.ethereum,
                data: "0x" + Buffer.from(requestId).toString("hex"),
                chainId: action === "ethereum-send-custom" ? "0x" + server.fixture.customNetwork.chainId.toString(16) : "0x1"};
            await append([{kind: "authorizedTransaction", transaction}]);
            method = "eth_sendRawTransaction";
            params = ["0x" + signedEthereumTransaction(transaction).toString("hex")];
        }
        const submit = () => fetch(`${server.url}/rpc/${route}`, {method: "POST",
            headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 1, method, params})});
        if (ambiguous) { await assert.rejects(submit()); return; }
        const response = await submit();
        assert.equal(response.status, 200, await response.clone().text());
        const hash = (await response.json()).result;
        return {hash, result: chain === "ethereum" ? hash : {publicKey: server.fixture.addresses.solana, signature: hash}, submit};
    };
    const settle = (requestId, result) => report({phase: "settled", action, requestId, result, ok: true, settlements: 1});
    const finish = () => control("finish", {scenario, iteration: 1, status: "passed"});
    return {...fixture, chain, start, broadcast, settle, finish};
}

function lockProof(server, scenario = server.current.id) {
    const lockProbe = server.lockProbe ?? {version: 1, id: "61307791-3e7b-48a2-b198-e91207fda08a", scenario: {id: scenario, iteration: 1}};
    const holder = {processID: 10101, incarnation: "extension-incarnation"};
    const contender = {processID: 20202, incarnation: "app-incarnation"};
    const events = ["fixtureLockHeld", "fixtureLockExcluded", "fixtureLockReleased", "fixtureLockAcquired"].map((kind, index) => ({
        kind, probeID: lockProbe.id, lockName: "safari-lock-probe.lock", scenario, iteration: lockProbe.scenario.iteration,
        role: index === 0 || index === 2 ? "extension" : "app", ...(index === 0 || index === 2 ? holder : contender),
        holderProcessID: holder.processID, holderIncarnation: holder.incarnation,
        ...(index > 0 ? {contenderProcessID: contender.processID, contenderIncarnation: contender.incarnation} : {}),
    }));
    return {lockProbe, events};
}

test("control API is unavailable to pages without the controller token", async context => {
    const {server} = await harness(context);
    assert.equal((await fetch(`${server.url}/control/state`)).status, 403);
    assert.equal((await fetch(`${server.url}/rpc/ethereum`, {method: "POST", body: JSON.stringify({id: 1, method: "eth_chainId", params: []})})).status, 403);
});

test("guest authorization transfers privately without returning or recording the credential", async context => {
    let clipboard = "";
    const {server, control} = await harness(context, "install-native-roundtrip", {clipboardWriter: async value => { clipboard = value; }});
    const password = "test-only-guest-secret-value";
    await writeFile(server.guestCredentialPath, JSON.stringify({version: 1, runID: "run-test", consoleUser: userInfo().username, password}), {mode: 0o600});
    const response = await control("stage-guest-credential");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {staged: true});
    assert.equal(clipboard, password);
    assert.ok(!JSON.stringify(await server.state()).includes(password));
    await control("clear-guest-credential");
    assert.equal(clipboard, "");
    await chmod(server.guestCredentialPath, 0o644);
    assert.equal((await control("stage-guest-credential")).status, 400);
    assert.ok(!JSON.stringify(await server.state()).includes(password));
});

test("guest credential transfer is unavailable to website origins and other signing modes", async context => {
    const {server, control} = await harness(context, "install-native-roundtrip", {clipboardWriter: async () => { assert.fail("Inapplicable authorization must not access the clipboard"); }});
    assert.equal((await fetch(`${server.dappURL}/control/stage-guest-credential`, {method: "POST", headers: {Authorization: `Bearer ${server.token}`}})).status, 403);
    server.descriptor.signingMode = "apple";
    assert.equal((await control("stage-guest-credential")).status, 403);
    server.descriptor.signingMode = "local";
    server.descriptor.platform = "ios";
    assert.equal((await control("stage-guest-credential")).status, 403);
});

test("credential clearing waits for an in-flight transfer and ignores obsolete expiry", async context => {
    let release, started;
    const hold = new Promise(resolve => { release = resolve; });
    const writing = new Promise(resolve => { started = resolve; });
    let clipboard = "";
    const {server} = await harness(context, "install-native-roundtrip", {clipboardWriter: async value => {
        if (value) { started(); await hold; }
        clipboard = value;
    }});
    const password = "test-only-guest-secret-value";
    await writeFile(server.guestCredentialPath, JSON.stringify({version: 1, runID: "run-test", consoleUser: userInfo().username, password}), {mode: 0o600});
    const staged = server.stageGuestCredential();
    await writing;
    const cleared = server.clearGuestCredential();
    release();
    await Promise.all([staged, cleared]);
    assert.equal(clipboard, "");
    assert.equal(server.guestCredentialStaged, false);
    const previous = server.guestCredentialGeneration;
    await server.stageGuestCredential();
    await server.clearGuestCredential(previous);
    assert.equal(clipboard, password);
    await server.clearGuestCredential();
    assert.equal(clipboard, "");
});

test("UI success alone cannot pass without real native ingress", async context => {
    const {control} = await harness(context);
    const response = await control("finish", {scenario: "install-native-roundtrip", iteration: 1, status: "passed"});
    assert.equal(response.status, 422);
    assert.match(JSON.stringify(await response.json()), /Missing real provider\/native handshake/);
});

test("native handshake requires Safari website metadata for the exact scenario origin", async context => {
    const {server, root} = await harness(context);
    const contextRecord = {runID: "run-test", scenario: "install-native-roundtrip", iteration: 1};
    const path = join(root, "native-events.ndjson");
    for (const overrides of [{source: "worker"}, {source: "popup"}, {configurationKey: "http://127.0.0.1:1"},
        {host: "another-host"}, {tabID: -1}, {frameID: null}, {documentID: null},
        {profileIdentifier: undefined}, {profileIdentifier: "invalid-profile"}, {privateBrowsing: undefined}]) {
        await appendFile(path, JSON.stringify({...contextRecord, ...siteIngress(server, overrides)}) + "\n");
        assert.equal((await server.state()).handshake.native, false);
        assert.equal(server.nativeReady, false);
    }
    await appendFile(path, JSON.stringify({...contextRecord, ...siteIngress(server)}) + "\n");
    assert.equal((await server.state()).handshake.native, true);
    assert.equal(server.nativeReady, true);
    assert.equal(server.isSiteIngress({...contextRecord, ...siteIngress(server, {
        configurationKey: server.secondURL, host: new URL(server.secondURL).host,
        profileIdentifier: "a729f65c-d95b-4a9d-baa2-f6a83b8266b5"})}), true);
});

test("fixture lock exclusion requires ordered acknowledgments from distinct app and extension processes", async context => {
    const {server, control, root} = await harness(context);
    assert.equal((await fetch(`${server.dappURL}/control/lock-probe`, {method: "POST", headers: {Authorization: `Bearer ${server.token}`}})).status, 403);
    assert.equal((await control("lock-probe")).status, 200);
    const armed = JSON.parse(await readFile(join(root, "lock-probe.json"), "utf8"));
    assert.deepEqual(armed, server.lockProbe);
    assert.equal((await control("lock-probe")).status, 400);
    const proof = lockProof(server);
    const state = {errors: [], handshake: {provider: true, native: true}, results: [], broadcasts: [], ...proof};
    assert.deepEqual(server.check(state), []);
    const invalidProofs = [[], proof.events.slice(1), [...proof.events].reverse(),
        proof.events.map(event => ({...event, probeID: "another-probe"})),
        proof.events.map(event => ({...event, iteration: 2})),
        proof.events.map(event => ({...event, lockName: "unrelated.lock"})),
        proof.events.map(event => ({...event, processID: 10101, contenderProcessID: 10101})),
        proof.events.map(event => ({...event, role: "app"})),
        [...proof.events, {kind: "fixtureLockFailed"}]];
    for (const events of invalidProofs) {
        assert.ok(server.check({...state, events}).includes("Missing acknowledged app/extension lock exclusion on the shared fixture path"));
    }
    assert.ok(server.check({...state, lockProbe: null}).includes("Missing acknowledged app/extension lock exclusion on the shared fixture path"));
});

test("registration refresh is available only to an active local macOS controller", async context => {
    const {control, server} = await harness(context);
    let calls = 0;
    server.refreshExtensionRegistration = async () => { calls += 1; return {registeredAt: new Date().toISOString(), extension: "/fixture/Safari macOS.appex"}; };
    assert.equal((await fetch(`${server.dappURL}/control/refresh-extension-registration`, {method: "POST", headers: {Authorization: `Bearer ${server.token}`}})).status, 403);
    server.descriptor.platform = "ios";
    assert.equal((await control("refresh-extension-registration")).status, 403);
    server.descriptor.platform = "macos";
    server.descriptor.signingMode = "apple";
    assert.equal((await control("refresh-extension-registration")).status, 403);
    server.descriptor.signingMode = "local";
    assert.equal(calls, 0);
    assert.equal((await control("refresh-extension-registration")).status, 200);
    assert.equal(calls, 1);
    assert.deepEqual((await server.state()).registrationRefreshes[0].scenario, {id: "install-native-roundtrip", iteration: 1});
    await control("finish", {scenario: "install-native-roundtrip", iteration: 1, status: "failed"});
    assert.equal((await control("refresh-extension-registration")).status, 403);
    assert.equal(calls, 1);
});

test("an aborted XCTest case stays failed while later scenarios can run", async context => {
    const {control, server, root} = await harness(context);
    const originalOrigin = server.dappURL;
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, false);
    assert.equal((await control("start", {scenario: "install-native-roundtrip", iteration: 1})).status, 400);
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 200);
    assert.equal(server.current.id, "ethereum-signing");
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, true);
    assert.equal(server.scenarios.length, 1);
    assert.equal(server.scenarios[0].status, "failed");
    assert.deepEqual(server.scenarios[0].evidence, {abandoned: true});
    assert.ok(server.scenarios[0].issues.includes("XCTest ended without finishing this scenario"));
    assert.equal((await fetch(originalOrigin)).status, 409);
    await server.persist();
    const report = JSON.parse(await readFile(join(root, "artifacts/safari.macos.debug.safari.json"), "utf8"));
    assert.equal(report.scenarios[0].status, "failed");
    assert.ok(report.scenarios[0].issues.includes("XCTest ended without finishing this scenario"));
    assert.equal((await control("start", {scenario: "install-native-roundtrip", iteration: 1})).status, 400);
});

test("an aborted case must complete native cleanup before any later scenario starts", async context => {
    const {control, server} = await harness(context);
    let calls = 0;
    const cleanup = server.stopOwnedProcesses.bind(server);
    server.stopOwnedProcesses = async () => {
        calls += 1;
        if (calls <= 2) { throw new Error("Owned fixture process is still running"); }
        return cleanup();
    };
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 400);
    assert.equal((await control("start", {scenario: "solana-signing", iteration: 1})).status, 400);
    assert.equal(server.current.id, "install-native-roundtrip");
    assert.equal(server.scenarios.length, 1);
    assert.equal(server.scenarios[0].status, "failed");
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 200);
    assert.equal(calls, 3);
    assert.equal(server.current.id, "ethereum-signing");
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, true);
});

test("approval draining follows failed cleanup and clears after the next successful scenario", async context => {
    const {control, server, root} = await harness(context, "extension-toggle");
    let cleanups = 0;
    const cleanup = server.stopOwnedProcesses.bind(server);
    server.stopOwnedProcesses = async () => { cleanups += 1; return cleanup(); };
    const makeHandshake = async () => {
        await appendFile(join(root, "native-events.ndjson"), JSON.stringify({runID: "run-test",
            scenario: server.current.id, iteration: server.current.iteration, ...siteIngress(server)}) + "\n");
        server.providerReady = true;
    };
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, false);
    await makeHandshake();
    assert.equal((await control("finish", {scenario: "extension-toggle", iteration: 1, status: "passed"})).status, 200);
    assert.equal((await control("start", {scenario: "profiles-private", iteration: 1})).status, 200);
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, false);
    assert.equal(cleanups, 0);
    const evidence = {error: "XCTest operation failed", cleanupError: "Popup queue was not drained"};
    assert.equal((await control("finish", {scenario: "profiles-private", iteration: 1, status: "failed", evidence})).status, 422);
    assert.equal((await control("start", {scenario: "authority-revocation", iteration: 1})).status, 200);
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, true);
    assert.equal(cleanups, 1);
    assert.equal(server.scenarios[1].status, "failed");
    assert.deepEqual(server.scenarios[1].evidence, evidence);
    await makeHandshake();
    assert.equal((await control("finish", {scenario: "authority-revocation", iteration: 1, status: "passed"})).status, 200);
    assert.equal((await control("start", {scenario: "malformed-requests", iteration: 1})).status, 200);
    assert.equal((await (await control("config")).json()).requiresApprovalDrain, false);
    assert.equal(cleanups, 1);
    const saved = JSON.parse(await readFile(join(root, "artifacts/safari.macos.debug.safari.json"), "utf8"));
    assert.equal(saved.scenarios[1].status, "failed");
    assert.deepEqual(saved.scenarios[1].evidence, evidence);
});

test("page settlements are correlated and may occur only once", async context => {
    const {report} = await harness(context);
    const value = {requestId: "document-1", action: "ethereum-connect", ok: true, result: [], settlements: 1};
    assert.equal((await report({...value, phase: "settled"})).status, 400);
    assert.equal((await report({...value, phase: "started"})).status, 200);
    assert.equal((await report({...value, phase: "settled"})).status, 200);
    assert.equal((await report({...value, phase: "settled"})).status, 400);
});

test("a settlement cannot be attributed to another origin or document", async context => {
    const {report, server, document} = await harness(context);
    const value = {requestId: "document-1", documentId: document.documentId, origin: server.dappURL, action: "ethereum-connect", ok: true, result: [], settlements: 1};
    assert.equal((await report({...value, phase: "started"})).status, 200);
    assert.equal((await report({...value, phase: "settled", origin: server.secondURL})).status, 400);
    assert.equal((await report({...value, phase: "settled", documentId: "another-document"})).status, 400);
    assert.equal(server.results.length, 0);
});

test("invalid signature cannot be accepted as a successful page result", async context => {
    const {report, server} = await harness(context, "ethereum-signing");
    const value = {requestId: "sign-1", action: "ethereum-sign", ok: true, result: "0x" + "00".repeat(65), settlements: 1};
    await report({...value, phase: "started"});
    assert.equal((await report({...value, phase: "settled"})).status, 400);
    assert.equal(server.results.length, 0);
});

test("native evidence from another iteration cannot satisfy a scenario", async context => {
    const {root, server} = await harness(context);
    await appendFile(join(root, "native-events.ndjson"), JSON.stringify({kind: "nativeIngress", runID: "run-test", scenario: "install-native-roundtrip", iteration: 2}) + "\n");
    assert.equal((await server.state()).events.length, 0);
});

test("controller cancellation updates a native gate rather than manufacturing a result", async context => {
    const {control, root, server} = await harness(context);
    assert.equal((await control("gate", {point: "authentication", value: "cancel"})).status, 200);
    assert.deepEqual(JSON.parse(await readFile(join(root, "gates.json"), "utf8")), {beforeAuthentication: "fail"});
    assert.equal(server.results.length, 0);
    assert.equal((await control("fault", {kind: "authority", action: "revoke"})).status, 400);
});

test("process faults terminate the verified role pool and leave other roles untouched", async context => {
    const processes = new Map(), signals = [];
    const {server, root} = await harness(context, "install-native-roundtrip", {
        processInspector: async pid => processes.get(pid) ?? null,
        processTerminator: (pid, signal) => { signals.push({pid, signal}); processes.delete(pid); },
    });
    server.descriptor.platform = "ios";
    const extension = join(root, "extension"), app = join(root, "app");
    await writeFile(extension, "fixture"); await writeFile(app, "fixture");
    server.allowedExecutables = new Set([extension, app]);
    const first = process.pid + 1000, second = first + 1, containing = first + 2, exited = first + 3;
    processes.set(first, extension); processes.set(second, extension); processes.set(containing, app);
    const events = [[first, "extension", extension, "old"], [first, "extension", extension, "current"],
        [second, "extension", extension, "second"], [containing, "app", app, "app"], [exited, "extension", extension, "exited"]];
    for (const [processID, role, executablePath, incarnation] of events) {
        await appendFile(join(root, "native-events.ndjson"), JSON.stringify({kind: "processStarted", runID: "run-test", processID, role, executablePath, incarnation}) + "\n");
    }
    const fault = await server.fault({kind: "native-process", action: "terminate"});
    assert.deepEqual(signals, [{pid: first, signal: "SIGKILL"}, {pid: second, signal: "SIGKILL"}]);
    assert.deepEqual(fault.killed.map(event => event.incarnation), ["current", "second"]);
    assert.equal(processes.has(containing), true);
    assert.equal(fault.scope, "role-pool");
});

test("process inspection distinguishes explicit zombies and absence from unavailable live executable paths", async () => {
    const processID = 12345;
    const inspect = outputs => inspectProcess(processID, async (command, args, options) => {
        assert.equal(command, "/bin/ps");
        assert.deepEqual(args, ["-ww", "-p", String(processID), "-o", "stat=", "-o", "comm="]);
        assert.equal(options.timeout, 5000);
        const result = outputs.shift();
        if (result instanceof Error) { throw result; }
        return {stdout: result};
    });
    const absent = () => Object.assign(new Error("No matching process"), {code: 1, killed: false, signal: null, stdout: "", stderr: ""});
    assert.equal(await inspect(["Z    (Big Wallet)\n"]), null);
    assert.equal(await inspect(["Z+   <defunct>\n"]), null);
    assert.equal(await inspect([absent()]), null);
    assert.equal(await inspect(["S    (Big Wallet)\n", absent()]), null);
    assert.equal(await inspect(["S    (Big Wallet)\n", "S    /Applications/Big Wallet.app/Contents/MacOS/Big Wallet\n"]),
        "/Applications/Big Wallet.app/Contents/MacOS/Big Wallet");
    const unknown = ["S    (Big Wallet)\n", "S    (Big Wallet)\n"];
    await assert.rejects(inspect(unknown), /Live process executable identity is unavailable/);
    assert.equal(unknown.length, 0);
    await assert.rejects(inspect(["(Big Wallet)\n", "(Big Wallet)\n"]), /identity is unavailable/);
    await assert.rejects(inspect(["\n", "\n"]), /identity is unavailable/);
    await assert.rejects(inspect([Object.assign(absent(), {stderr: "ps: inspection failed"})]), /No matching process/);
});

test("unresolved process inspection waits once and preserves bounded stat/comm diagnostics in its message", async () => {
    const sequence = [];
    const output = ["SE (Big Wallet)\n", "? (Big Wallet)\n"];
    await assert.rejects(inspectProcess(12345, async () => {
        sequence.push("inspect");
        return {stdout: output.shift()};
    }, async milliseconds => { sequence.push(milliseconds); }), error => {
        const encoded = JSON.parse(JSON.stringify({error: error.message})).error;
        const details = JSON.parse(encoded.slice(encoded.indexOf("{")));
        assert.deepEqual(details, {processID: 12345, attempts: [
            {attempt: 1, stat: "SE", comm: "(Big Wallet)", truncated: false},
            {attempt: 2, stat: "?", comm: "(Big Wallet)", truncated: false},
        ]});
        return true;
    });
    assert.deepEqual(sequence, ["inspect", 100, "inspect"]);
    const unavailable = "S " + "é".repeat(3000) + "\n";
    await assert.rejects(inspectProcess(12345, async () => ({stdout: unavailable}), async () => {}), error => {
        const details = JSON.parse(error.message.slice(error.message.indexOf("{")));
        assert.equal(details.attempts.length, 2);
        for (const attempt of details.attempts) {
            assert.equal(attempt.stat, "S");
            assert.ok(Buffer.byteLength(attempt.comm) <= 512);
            assert.ok(!attempt.comm.includes("\uFFFD"));
            assert.equal(attempt.truncated, true);
        }
        return true;
    });
});

test("cleanup never signals a process with an unresolved live executable identity", async context => {
    const {server, root} = await harness(context, "extension-toggle", {
        processInspector: pid => inspectProcess(pid, async () => ({stdout: "S (Big Wallet)\n"})),
        processTerminator: () => assert.fail("Unknown live processes must not receive a signal"),
    });
    const executablePath = join(root, "Big Wallet");
    await writeFile(executablePath, "fixture");
    server.allowedExecutables.add(executablePath);
    await appendFile(join(root, "native-events.ndjson"), JSON.stringify({kind: "processStarted", runID: "run-test",
        processID: process.pid + 1000, role: "app", executablePath, incarnation: "recorded"}) + "\n");
    try { await assert.rejects(server.stopOwnedProcesses(), /Live process executable identity is unavailable/); }
    finally { server.processInspector = async () => null; }
});

test("cleanup accepts a verified process that becomes a zombie after termination without signaling it again", async context => {
    let terminated = false;
    const signals = [];
    const {server, root} = await harness(context, "extension-toggle", {
        processInspector: pid => inspectProcess(pid, async () => ({stdout: terminated ? "Z (Big Wallet)\n" : `S ${executablePath}\n`})),
        processTerminator: (pid, signal) => { signals.push({pid, signal}); terminated = true; },
    });
    const executablePath = join(root, "Big Wallet");
    await writeFile(executablePath, "fixture");
    server.allowedExecutables.add(executablePath);
    const processID = process.pid + 1000;
    await appendFile(join(root, "native-events.ndjson"), JSON.stringify({kind: "processStarted", runID: "run-test",
        processID, role: "app", executablePath, incarnation: "recorded"}) + "\n");
    await server.stopOwnedProcesses();
    assert.deepEqual(signals, [{pid: processID, signal: "SIGTERM"}]);
});

for (const [name, corrupt] of [
    ["a malformed complete record", path => appendFile(path, "{malformed}\n")],
    ["a changed file identity", async path => {
        await writeFile(`${path}.replacement`, "");
        await rename(`${path}.replacement`, path);
    }],
    ["a shrunken evidence file", path => writeFile(path, "")],
]) {
    test(`cleanup stops cached verified processes after ${name} and preserves the audit failure`, async context => {
        const root = await realpath(await mkdtemp(join(tmpdir(), "safari-cleanup-evidence-")));
        const executablePath = join(root, "helper"), unrelatedPath = join(root, "unrelated");
        await writeFile(executablePath, "fixture");
        await writeFile(unrelatedPath, "unrelated");
        const processID = process.pid + 1000, reusedPID = processID + 1;
        const processes = new Map([[processID, executablePath], [reusedPID, unrelatedPath]]);
        const signals = [];
        const server = await new SafariFixtureServer({
            descriptor: {version: 1, runID: "run-test", root, platform: "macos", signingMode: "local", configuration: "Debug"},
            stageId: "safari.macos.debug", artifacts: join(root, "artifacts"),
            processInspector: async pid => processes.get(pid) ?? null,
            processTerminator: (pid, signal) => { signals.push({pid, signal}); processes.delete(pid); },
        }).start();
        context.after(async () => { await server.close().catch(() => {}); await rm(root, {recursive: true, force: true}); });
        server.allowedExecutables.add(executablePath);
        const path = join(root, "native-events.ndjson");
        await writeFile(path, [processID, reusedPID].map(pid => JSON.stringify({kind: "processStarted", runID: "run-test",
            processID: pid, role: "helper", executablePath, incarnation: `recorded-${pid}`})).join("\n") + "\n");
        await server.nativeEvents();
        await corrupt(path);
        const auditFailure = await server.nativeEvents().then(() => assert.fail("Corrupt evidence was accepted"), error => error);
        await assert.rejects(server.close(), error => error === auditFailure);
        assert.deepEqual(signals, [{pid: processID, signal: "SIGTERM"}]);
        assert.equal(processes.get(reusedPID), unrelatedPath);
        assert.equal(server.cleanup.status, "failed");
        const evidence = JSON.parse(await readFile(join(server.artifacts, "safari.macos.debug.safari.json"), "utf8"));
        assert.deepEqual(evidence.cleanup, {status: "failed", reason: auditFailure.message});
    });
}

test("a changed executable cannot be terminated as the recorded fixture process", async context => {
    const {server, root} = await harness(context, "install-native-roundtrip", {
        processInspector: async () => join(root, "unrelated"),
        processTerminator: () => assert.fail("An unrelated process must never receive a signal"),
    });
    const expected = join(root, "helper");
    await writeFile(expected, "fixture"); await writeFile(join(root, "unrelated"), "unrelated");
    server.allowedExecutables.add(expected);
    await appendFile(join(root, "native-events.ndjson"), JSON.stringify({kind: "processStarted", runID: "run-test", processID: process.pid + 1000, role: "helper", executablePath: expected, incarnation: "old"}) + "\n");
    await assert.rejects(server.fault({kind: "native-process", action: "terminate"}), /identity changed/);
    assert.deepEqual(server.processFaults[0].killed, []);
});

test("cleanup rescans and terminates an owned replacement recorded during the first termination", async context => {
    const processes = new Map(), events = [], signals = [];
    let nextPID = process.pid + 1000;
    const {server, root} = await harness(context, "install-native-roundtrip", {
        processInspector: async pid => processes.get(pid) ?? null,
        processTerminator: pid => {
            signals.push(pid);
            const executablePath = processes.get(pid);
            processes.delete(pid);
            if (signals.length === 1) {
                const processID = ++nextPID;
                processes.set(processID, executablePath);
                events.push({kind: "processStarted", processID, executablePath, role: "extension", incarnation: "replacement"});
            }
        },
    });
    const executablePath = join(root, "extension");
    await writeFile(executablePath, "fixture");
    server.allowedExecutables.add(executablePath);
    processes.set(nextPID, executablePath);
    events.push({kind: "processStarted", processID: nextPID, executablePath, role: "extension", incarnation: "original"});
    server.nativeEvents = async () => events;
    await server.stopOwnedProcesses();
    assert.equal(signals.length, 2);
    assert.equal(processes.size, 0);
});

test("repeated process replacement fails final cleanup within its bounded pass count", async context => {
    const processes = new Map(), events = [], signals = [];
    let nextPID = process.pid + 1000;
    let respawn = true;
    const {server, root} = await harness(context, "install-native-roundtrip", {
        processInspector: async pid => processes.get(pid) ?? null,
        processTerminator: pid => {
            signals.push(pid);
            const executablePath = processes.get(pid);
            processes.delete(pid);
            if (respawn) {
                const processID = ++nextPID;
                processes.set(processID, executablePath);
                events.push({kind: "processStarted", processID, executablePath, role: "extension", incarnation: "generation-" + processID});
            }
        },
    });
    const executablePath = join(root, "extension");
    await writeFile(executablePath, "fixture");
    server.allowedExecutables.add(executablePath);
    processes.set(nextPID, executablePath);
    events.push({kind: "processStarted", processID: nextPID, executablePath, role: "extension", incarnation: "original"});
    server.nativeEvents = async () => events;
    try { await assert.rejects(server.close(), /kept restarting during cleanup/); }
    finally { respawn = false; }
    assert.equal(signals.length, 4);
    assert.equal(processes.size, 1);
    assert.equal(server.cleanup.status, "failed");
    const evidence = JSON.parse(await readFile(join(server.artifacts, "safari.macos.debug.safari.json"), "utf8"));
    assert.equal(evidence.cleanup.status, "failed");
});

test("cleanup does not accept an empty pass when a new process is recorded during its inspection", async context => {
    const events = [], live = new Set(), signals = [];
    const first = process.pid + 1000, replacement = first + 1;
    let executablePath;
    let discovered = false;
    const {server, root} = await harness(context, "install-native-roundtrip", {
        processInspector: async pid => {
            if (!discovered && pid === first) {
                discovered = true;
                live.add(replacement);
                events.push({kind: "processStarted", processID: replacement, executablePath, incarnation: "replacement"});
            }
            return live.has(pid) ? executablePath : null;
        },
        processTerminator: pid => { signals.push(pid); live.delete(pid); },
    });
    executablePath = join(root, "extension");
    await writeFile(executablePath, "fixture");
    server.allowedExecutables.add(executablePath);
    events.push({kind: "processStarted", processID: first, executablePath, incarnation: "already-exited"});
    server.nativeEvents = async () => events;
    await server.stopOwnedProcesses();
    assert.deepEqual(signals, [replacement]);
    assert.equal(live.size, 0);
});

test("each scenario receives fresh website origins without changing native RPC identity", async context => {
    const {server, control} = await harness(context);
    const first = await (await control("config")).json();
    await control("finish", {scenario: "install-native-roundtrip", iteration: 1, status: "failed"});
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 200);
    const second = await (await control("config")).json();
    assert.equal(new Set([first.dappURL, first.secondOriginURL, second.dappURL, second.secondOriginURL, server.url]).size, 5);
    assert.equal((await fetch(`${first.dappURL}/page-config`)).status, 409);
    assert.equal((await fetch(`${server.url}/page-config`)).status, 404);
    assert.equal((await fetch(`${second.dappURL}/control/config`, {method: "POST", headers: {Authorization: `Bearer ${server.token}`}})).status, 403);
    const rpc = await fetch(`${server.url}/rpc/ethereum`, {method: "POST", headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 1, method: "eth_gasPrice", params: []})});
    assert.equal((await rpc.json()).result, "0x77359400");
});

test("a later stage rejects a reoffered website port before serving any scenario content", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-origin-stages-")));
    const descriptor = {version: 1, runID: "origin-stage-test", root, platform: "macos", signingMode: "local", configuration: "Release"};
    const servers = [];
    context.after(async () => {
        for (const server of servers) { if (!server.closing) { await server.close(); } }
        await rm(root, {recursive: true, force: true});
    });
    const make = async (stageId, options = {}) => {
        const server = new SafariFixtureServer({descriptor, stageId, artifacts: join(root, "artifacts", stageId), ...options});
        servers.push(server);
        return server.start();
    };
    const startScenario = server => fetch(server.url + "/control/start", {method: "POST",
        headers: {Authorization: "Bearer " + server.token, "Content-Type": "application/json"},
        body: JSON.stringify({scenario: "install-native-roundtrip", iteration: 1})});
    const first = await make("safari.macos.release");
    assert.equal((await startScenario(first)).status, 200);
    const priorOrigins = [first.dappURL, first.secondURL];
    const controlPort = Number(new URL(first.url).port);
    const priorPort = Number(new URL(first.dappURL).port);
    const retainedStore = join(root, "preferences.plist");
    await writeFile(retainedStore, "unchanged fixture grant storage", {mode: 0o600});
    await first.close();
    let created = 0, offered;
    const offeredPort = new Promise(resolve => { offered = resolve; });
    const second = await make("safari.soak-macos.release", {httpServerFactory: handler => {
        const server = createServer(handler);
        const index = ++created;
        if (index <= 2) {
            const listen = server.listen.bind(server);
            server.listen = (_port, ...args) => listen(index === 1 ? controlPort : priorPort, ...args);
        }
        if (index === 2) { server.once("listening", offered); }
        return server;
    }});
    const lock = join(root, ".website-origins.lock");
    await writeFile(lock, "", {mode: 0o600, flag: "wx"});
    const starting = startScenario(second);
    try {
        await offeredPort;
        const pending = await fetch(priorOrigins[0] + "/page-config");
        assert.equal(pending.status, 503);
        assert.deepEqual(await pending.json(), {error: "Website origin reservation is pending"});
    } finally { await unlink(lock); }
    assert.equal((await starting).status, 200);
    assert.ok(!priorOrigins.includes(second.dappURL));
    assert.ok(!priorOrigins.includes(second.secondURL));
    assert.equal((await fetch(second.dappURL + "/page-config")).status, 200);
    const registry = JSON.parse(await readFile(join(root, "website-origins.json"), "utf8"));
    assert.equal(registry.origins.length, 4);
    assert.equal(new Set(registry.origins).size, 4);
    assert.ok(!registry.origins.includes(first.url) && !registry.origins.includes(second.url));
    assert.equal(await readFile(retainedStore, "utf8"), "unchanged fixture grant storage");
    assert.equal(second.candidateServers.size, 0);
    assert.ok(!(await readdir(root)).includes(".website-origins.lock"));
});

test("Apple-signed Debug and Release share website origin reservations", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-origin-configurations-")));
    context.after(() => rm(root, {recursive: true, force: true}));
    const make = async configuration => {
        const directory = join(root, configuration);
        await mkdir(directory, {mode: 0o700});
        return new SafariFixtureServer({
            descriptor: {version: 1, runID: "origin-configuration-test", root: directory,
                platform: "macos", signingMode: "apple", configuration},
            stageId: `safari.macos.${configuration.toLowerCase()}`, artifacts: join(directory, "artifacts"),
        });
    };
    const debug = await make("Debug");
    const release = await make("Release");
    const origins = [54321, 54322, 54323].map(port => `http://127.0.0.1:${port}`);
    assert.equal(await debug.reserveWebsiteOrigin(origins[0]), true);
    assert.equal(await release.reserveWebsiteOrigin(origins[0]), false);
    assert.deepEqual(await Promise.all([
        debug.reserveWebsiteOrigin(origins[1]), release.reserveWebsiteOrigin(origins[2]),
    ]), [true, true]);
    assert.deepEqual(new Set((await release.readOriginRegistry()).origins), new Set(origins));
    assert.equal(await debug.reserveWebsiteOrigin(origins[2]), false);
});

test("concurrent controller reservations retain both website origins in one private registry", async context => {
    const {server, root} = await harness(context);
    const other = new SafariFixtureServer({descriptor: server.descriptor, stageId: "safari.macos.second",
        artifacts: join(root, "other-artifacts")});
    await other.start();
    try {
        const before = JSON.parse(await readFile(join(root, "website-origins.json"), "utf8")).origins;
        const origins = await Promise.all([server.listen({...server.current}), other.listen({...server.current})]);
        const after = JSON.parse(await readFile(join(root, "website-origins.json"), "utf8")).origins;
        assert.equal(new Set(after).size, before.length + 2);
        assert.ok(origins.every(origin => after.includes(origin)));
    } finally { await other.close(); }
});

test("a removed origin registry cannot silently reset already-observed reservations", async context => {
    const {server, root} = await harness(context);
    await unlink(join(root, "website-origins.json"));
    await assert.rejects(server.listen({...server.current}), /registry disappeared/);
    assert.equal(server.candidateServers.size, 0);
});

test("native startup evidence alone does not prevent the first website origin reservation", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-origin-startup-")));
    const descriptor = {version: 1, runID: "origin-startup-test", root, platform: "macos", signingMode: "local", configuration: "Release"};
    await writeFile(join(root, "native-events.ndjson"), JSON.stringify({runID: descriptor.runID, kind: "processStarted",
        processID: process.pid + 1000, role: "extension", executablePath: "/fixture/prestage-extension"}) + "\n");
    const server = new SafariFixtureServer({descriptor, stageId: "safari.macos.release", artifacts: join(root, "artifacts"),
        processInspector: async () => assert.fail("Prestage startup must not trigger a native process inspection")});
    context.after(async () => { await server.close(); await rm(root, {recursive: true, force: true}); });
    await server.start();
    assert.equal(server.stageEventOffset, 1);
    await assert.rejects(readFile(join(root, "website-origins.json")), {code: "ENOENT"});
    const origin = await server.listen({id: "install-native-roundtrip", iteration: 1});
    assert.deepEqual(JSON.parse(await readFile(join(root, "website-origins.json"), "utf8")).origins, [origin]);
});

test("website origin allocation bounds retries without leaking rejected listeners", async context => {
    const {server, root} = await harness(context);
    const priorOrigin = server.dappURL;
    const controlPort = Number(new URL(server.url).port);
    const priorPort = Number(new URL(priorOrigin).port);
    await server.close();
    let created = 0;
    const other = new SafariFixtureServer({descriptor: server.descriptor, stageId: "safari.macos.next",
        artifacts: join(root, "other-artifacts"), httpServerFactory: handler => {
            const candidate = createServer(handler);
            const port = ++created === 1 ? controlPort : priorPort;
            const listen = candidate.listen.bind(candidate);
            candidate.listen = (_port, ...args) => listen(port, ...args);
            return candidate;
        }});
    await other.start();
    try {
        await assert.rejects(other.listen({...server.current}), /retry limit/);
        assert.equal(created, 33);
        assert.equal(other.servers.length, 1);
        assert.equal(other.candidateServers.size, 0);
    } finally { await other.close(); }
});

test("malformed, mismatched, oversized, and unsafe origin registries fail before any listener opens", async context => {
    const identity = {version: 1, runID: "origin-validation-test", platform: "macos", configuration: "Release"};
    const valid = {...identity, origins: ["http://127.0.0.1:12345"]};
    const cases = [
        {data: "{"}, {value: {...valid, runID: "another-run"}}, {value: {...valid, platform: "ios"}},
        {value: {...valid, configuration: "Debug"}}, {value: {...valid, extra: true}},
        {value: {...valid, origins: [valid.origins[0], valid.origins[0]]}},
        {value: {...valid, origins: ["https://example.com"]}}, {value: {...valid, origins: ["http://127.0.0.1:65536"]}},
        {value: {...valid, origins: Array.from({length: 2000}, (_, index) => "http://127.0.0.1:" + (20000 + index))}},
        {data: "x".repeat(64 * 1024 + 1)}, {value: valid, mode: 0o644}, {value: valid, symlink: true}, {directory: true},
        {missing: true, stageId: "safari.soak-macos.release"},
    ];
    for (const fixture of cases) {
        const root = await realpath(await mkdtemp(join(tmpdir(), "safari-origin-invalid-")));
        context.after(() => rm(root, {recursive: true, force: true}));
        const path = join(root, "website-origins.json");
        if (fixture.directory) { await mkdir(path); }
        else if (!fixture.missing) {
            const destination = fixture.symlink ? join(root, "other.json") : path;
            await writeFile(destination, fixture.data ?? JSON.stringify(fixture.value), {mode: 0o600});
            if (fixture.mode) { await chmod(destination, fixture.mode); }
            if (fixture.symlink) { await symlink(destination, path); }
        }
        let listeners = 0;
        const server = new SafariFixtureServer({descriptor: {...identity, root, signingMode: "local"},
            stageId: fixture.stageId ?? "safari.macos.release", artifacts: join(root, "artifacts"), httpServerFactory: () => {
                listeners += 1;
                throw new Error("Registry validation must precede listener creation");
            }});
        await assert.rejects(server.start());
        assert.equal(listeners, 0);
        assert.ok(!(await readdir(root)).includes(".website-origins.lock"));
    }
});

test("fee changes affect actual RPC responses and reset at the next scenario", async context => {
    const {server, control} = await harness(context);
    const gasPrice = async () => (await (await fetch(`${server.url}/rpc/ethereum`, {method: "POST", headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 1, method: "eth_gasPrice", params: []})})).json()).result;
    assert.equal((await control("fault", {kind: "rpc-fees", multiplier: 3})).status, 200);
    assert.equal(await gasPrice(), "0x165a0bc00");
    await control("finish", {scenario: "install-native-roundtrip", iteration: 1, status: "failed"});
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 200);
    assert.equal(await gasPrice(), "0x77359400");
});

test("fee history matches requested block ranges and percentile columns without changing fee magnitudes", async context => {
    const {server, control} = await harness(context);
    const history = async params => (await (await fetch(`${server.url}/rpc/ethereum`, {method: "POST",
        headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 7, method: "eth_feeHistory", params})})).json()).result;
    const requested = ["0xa", "0x100", [50, 95]];
    const expected = fee => ({oldestBlock: "0xf7", baseFeePerGas: Array(11).fill(fee),
        reward: Array.from({length: 10}, () => [fee, fee]), gasUsedRatio: Array(10).fill(0.5)});
    assert.deepEqual(await history(requested), expected("0x3b9aca00"));
    assert.deepEqual(await history(["0xa", "latest", [50, 95]]), expected("0x3b9aca00"));
    assert.deepEqual(await history(["0xa", "0x2", [0, 50, 100]]), {oldestBlock: "0x0",
        baseFeePerGas: Array(4).fill("0x3b9aca00"), reward: Array.from({length: 3}, () => Array(3).fill("0x3b9aca00")),
        gasUsedRatio: [0.5, 0.5, 0.5]});
    assert.deepEqual(await history(["0x1", "earliest", []]), {oldestBlock: "0x0",
        baseFeePerGas: ["0x3b9aca00", "0x3b9aca00"], reward: [[]], gasUsedRatio: [0.5]});
    assert.equal((await control("fault", {kind: "rpc-fees", multiplier: 3})).status, 200);
    assert.deepEqual(await history(requested), expected("0xb2d05e00"));
    await control("finish", {scenario: "install-native-roundtrip", iteration: 1, status: "failed"});
    assert.equal((await control("start", {scenario: "ethereum-signing", iteration: 1})).status, 200);
    assert.deepEqual(await history(requested), expected("0x3b9aca00"));
});

test("fee history rejects malformed and excessive ranges or percentile requests with invalid params", async context => {
    const {server} = await harness(context);
    for (const params of [["0xa", "0x100"], ["0x0", "0x100", [50, 95]], ["0x401", "0x100", [50, 95]],
        ["0x000a", "0x100", [50, 95]], [10, "0x100", [50, 95]], ["0xa", "0x101", [50, 95]],
        ["0xa", "invalid", [50, 95]], ["0xa", "0x100", [95, 50]], ["0xa", "0x100", [50, 50]],
        ["0xa", "0x100", [-1, 95]], ["0xa", "0x100", [50, 101]], ["0xa", "0x100", ["50", 95]],
        ["0xa", "0x100", null], ["0xa", "0x100", Array.from({length: 101}, (_, index) => index)]]) {
        const response = await fetch(`${server.url}/rpc/ethereum`, {method: "POST",
            headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 7, method: "eth_feeHistory", params})});
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), {jsonrpc: "2.0", id: 7,
            error: {code: -32602, message: "Invalid fixture fee history parameters"}});
    }
});

test("an omitted-params block number request reaches the real hold boundary and settles after release", async context => {
    const {server, control} = await harness(context);
    await control("fault", {kind: "rpc", mode: "hold"});
    let settled = false;
    const pending = fetch(`${server.url}/rpc/ethereum`, {method: "POST",
        headers: {"X-Big-Wallet-Test-Token": server.token, "X-Big-Wallet-Test-Process": "12345"},
        body: JSON.stringify({jsonrpc: "2.0", id: 7, method: "eth_blockNumber"})
    }).then(async response => { settled = true; return {status: response.status, body: await response.json()}; });
    try {
        const deadline = Date.now() + 3000;
        while (server.rpcWaiters.size === 0 && Date.now() < deadline) { await new Promise(resolve => setTimeout(resolve, 10)); }
        assert.equal(server.rpcWaiters.size, 1);
        assert.equal(server.rpcPeak, 1);
        assert.equal(settled, false);
    } finally { await control("fault", {kind: "rpc", mode: "normal"}); }
    assert.deepEqual(await pending, {status: 200, body: {jsonrpc: "2.0", id: 7, result: "0x100"}});
    assert.equal(server.rpcWaiters.size, 0);
    assert.deepEqual(server.errors, []);
});

test("no-argument RPC omission does not permit malformed or excessive parameters", async context => {
    const {server} = await harness(context);
    const request = payload => fetch(`${server.url}/rpc/ethereum`, {method: "POST",
        headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({jsonrpc: "2.0", id: 7, ...payload})});
    for (const method of ["eth_chainId", "eth_blockNumber", "eth_gasPrice", "eth_maxPriorityFeePerGas"]) {
        assert.equal((await request({method})).status, 200);
        assert.equal((await request({method, params: []})).status, 200);
        for (const params of [null, {}, "", 0, [1], Array(1025).fill(0)]) {
            assert.equal((await request({method, params})).status, 400);
        }
    }
    assert.equal((await request({method: "eth_getBalance"})).status, 400);
    assert.equal((await request({method: "eth_feeHistory"})).status, 400);
});

test("preparation faults hold a real estimate response until explicitly released", async context => {
    const {server, control} = await harness(context);
    await control("fault", {kind: "rpc-preparation", mode: "hold"});
    let settled = false;
    const pending = fetch(`${server.url}/rpc/ethereum`, {method: "POST", headers: {"X-Big-Wallet-Test-Token": server.token}, body: JSON.stringify({id: 1, method: "eth_estimateGas", params: [{}]})}).then(response => { settled = true; return response.json(); });
    const deadline = Date.now() + 3000;
    while (server.preparationWaiters.size === 0 && Date.now() < deadline) { await new Promise(resolve => setTimeout(resolve, 10)); }
    assert.equal(server.preparationWaiters.size, 1);
    assert.equal(settled, false);
    await control("fault", {kind: "rpc-preparation", mode: "normal"});
    assert.equal((await pending).result, "0xc350");
    assert.equal(server.preparationWaiters.size, 0);
});

test("custom network identity survives a controller restart with a new transport port", async context => {
    const first = await harness(context);
    const second = await new SafariFixtureServer({descriptor: first.server.descriptor, stageId: "safari.macos.debug",
        artifacts: join(first.root, "restarted-artifacts")}).start();
    try {
        assert.notEqual(first.server.url, second.url);
        assert.deepEqual(first.server.fixture.customNetwork, second.fixture.customNetwork);
        assert.notEqual(first.server.fixture.customNetwork.rpcURL, first.server.fixture.customNetwork.replacementRPCURL);
    } finally { await second.close(); }
});

test("mutation commands bind only known fixture changes to the active scenario", async context => {
    const {control, root, server} = await harness(context);
    assert.equal((await control("mutation", {operation: "replaceCustomNetwork", chainId: 1, rpcURL: "https://example.com"})).status, 400);
    const response = await control("mutation", {operation: "replaceCustomNetwork", chainId: server.fixture.customNetwork.chainId, rpcURL: server.fixture.customNetwork.replacementRPCURL});
    assert.equal(response.status, 200);
    const {mutationID} = await response.json();
    const mutation = JSON.parse(await readFile(join(root, "mutation.json"), "utf8"));
    assert.equal(mutation.id, mutationID);
    assert.deepEqual(mutation.scenario, {id: "install-native-roundtrip", iteration: 1});
    assert.equal(mutation.rpcURL, server.fixture.customNetwork.replacementRPCURL);
});

test("Solana transactions are bound to unique requests and stable across allocation retries", async context => {
    const {server, report, document} = await harness(context, "solana-broadcast");
    const allocate = requestId => fetch(`${server.dappURL}/page-solana-transaction`, {method: "POST", headers: {"X-Page-Token": server.pageToken, "Content-Type": "application/json"}, body: JSON.stringify({requestId, origin: server.dappURL, documentId: document.documentId, scenario: {id: "solana-broadcast", iteration: 1}})});
    assert.equal((await allocate("missing")).status, 400);
    await report({phase: "started", action: "solana-send", requestId: "solana-1"});
    const first = await (await allocate("solana-1")).json();
    assert.deepEqual(await (await allocate("solana-1")).json(), first);
    await report({phase: "started", action: "solana-send", requestId: "solana-2"});
    assert.notEqual((await (await allocate("solana-2")).json()).transaction, first.transaction);
    const other = new SafariFixtureServer({descriptor: server.descriptor, stageId: "safari.soak-macos.release", artifacts: server.artifacts});
    assert.notEqual(other.fixture.solanaBlockhash, server.fixture.solanaBlockhash);
});

for (const action of ["ethereum-send", "ethereum-send-custom", "ethereum-send-estimated", "solana-send"]) {
    test(`${action} accepts its verified broadcast result`, async context => {
        const fixture = await broadcastHarness(context, action);
        const requestId = await fixture.start();
        const sent = await fixture.broadcast(requestId);
        const result = fixture.chain === "ethereum" ? "0x" + sent.hash.slice(2).toUpperCase() : sent.result;
        assert.equal((await fixture.settle(requestId, result)).status, 200);
        const response = await fixture.finish();
        assert.equal(response.status, 200);
        assert.deepEqual((await response.json()).issues, []);
    });

    const invalid = ["wrong-identifier", "missing-broadcast", "other-request", "other-chain",
        ...(action === "solana-send" ? ["wrong-account"] : [])];
    for (const kind of invalid) {
        test(`${action} rejects ${kind} broadcast results`, async context => {
            const fixture = await broadcastHarness(context, action);
            let requestId = await fixture.start();
            let result = fixture.chain === "ethereum" ? "0x" + "09".repeat(32)
                : {publicKey: fixture.server.fixture.addresses.solana, signature: base58.encode(Buffer.alloc(64, 9))};
            if (kind !== "missing-broadcast") {
                const sent = await fixture.broadcast(requestId, {route: kind === "other-chain"
                    ? fixture.chain === "ethereum" ? "solana" : "ethereum" : fixture.chain});
                if (kind === "wrong-identifier") { assert.notDeepEqual(result, sent.result); }
                else { result = sent.result; }
            }
            if (kind === "other-request") { requestId = await fixture.start(); }
            if (kind === "wrong-account") { result.publicKey = fixture.server.fixture.alternateAddresses.solana; }
            assert.equal((await fixture.settle(requestId, result)).status, 400);
            assert.equal(fixture.server.results.length, 0);
            const response = await fixture.finish();
            assert.equal(response.status, 422);
            assert.equal((await response.json()).status, "failed");
        });
    }
}

for (const action of ["ethereum-send", "solana-send"]) {
    test(`${action} duplicate broadcasts still fail with the matching result`, async context => {
        const fixture = await broadcastHarness(context, action);
        const requestId = await fixture.start();
        const sent = await fixture.broadcast(requestId);
        const duplicate = await sent.submit();
        assert.equal(duplicate.status, 200);
        assert.equal((await duplicate.json()).result, sent.hash);
        await fixture.settle(requestId, sent.result);
        const response = await fixture.finish();
        assert.equal(response.status, 422);
        assert.ok((await response.json()).issues.includes("Transaction submitted more than once"));
    });
}

test("ambiguous broadcast errors remain valid after a verified dispatch", async context => {
    const fixture = await broadcastHarness(context, "ethereum-send", "ambiguous-broadcast");
    const requestId = await fixture.start();
    assert.equal((await fixture.control("fault", {kind: "broadcast", mode: "ambiguous"})).status, 200);
    await fixture.broadcast(requestId, {ambiguous: true});
    assert.equal((await fixture.report({phase: "settled", action: "ethereum-send", requestId,
        ok: false, error: {code: -32603, message: "Broadcast outcome is unknown"}, settlements: 1})).status, 200);
    const response = await fixture.finish();
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).issues, []);
});

test("shutdown persists an accepted RPC request's body-abort failure before final evidence", {timeout: 10000}, async context => {
    const fixture = await broadcastHarness(context, "solana-send");
    const {server} = fixture;
    const requestId = await fixture.start();
    const sent = await fixture.broadcast(requestId);
    assert.equal((await fixture.settle(requestId, sent.result)).status, 200);
    assert.equal((await fixture.finish()).status, 200);
    const payload = JSON.stringify({id: 2, method: "sendTransaction",
        params: [Buffer.from(server.broadcasts[0].bytes, "hex").toString("base64"), {encoding: "base64"}]});
    const accepted = new Promise(resolve => server.servers[0].once("request", resolve));
    const pending = httpRequest(`${server.url}/rpc/solana`, {method: "POST",
        headers: {"X-Big-Wallet-Test-Token": server.token, "Content-Length": Buffer.byteLength(payload)}});
    const clientError = new Promise(resolve => pending.once("error", resolve));
    context.after(() => pending.destroy());
    pending.write(payload.slice(0, -1));
    const incoming = await accepted;
    assert.equal(incoming.complete, false);
    assert.equal(incoming.destroyed, false);

    await server.close();
    assert.equal((await clientError).code, "ECONNRESET");
    const summary = JSON.parse(await readFile(join(server.artifacts, `${server.stageId}.safari.json`), "utf8"));
    const [evidence] = JSON.parse(await readFile(join(server.artifacts, `${server.stageId}.safari-evidence.json`), "utf8"));
    assert.equal(summary.scenarios[0].status, "failed");
    assert.ok(summary.scenarios[0].issues.includes("aborted"));
    assert.ok(evidence.errors.includes("aborted"));
    assert.equal(evidence.broadcasts[0].count, 1);
});

test("shutdown awaits accepted broadcast processing after its HTTP connection closes", {timeout: 10000}, async context => {
    const fixture = await broadcastHarness(context, "ethereum-send");
    const {server} = fixture;
    const requestId = await fixture.start();
    const sent = await fixture.broadcast(requestId);
    assert.equal((await fixture.settle(requestId, sent.result)).status, 200);
    assert.equal((await fixture.finish()).status, 200);
    let entered, release;
    const reading = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    const state = server.state.bind(server);
    server.state = async () => {
        const result = await state();
        entered();
        await held;
        return result;
    };
    const outcome = sent.submit().then(response => ({response}), error => ({error}));
    try {
        await reading;
        assert.equal(server.broadcasts[0].count, 1);
        const disconnected = new Promise(resolve => server.servers[0].once("close", resolve));
        const closing = server.close();
        await disconnected;
        release();
        await closing;
    } finally {
        release();
        server.state = state;
    }
    assert.ok((await outcome).error instanceof Error);
    assert.equal(server.broadcasts[0].count, 2);
    const summary = JSON.parse(await readFile(join(server.artifacts, `${server.stageId}.safari.json`), "utf8"));
    const [evidence] = JSON.parse(await readFile(join(server.artifacts, `${server.stageId}.safari-evidence.json`), "utf8"));
    assert.equal(summary.scenarios[0].status, "failed");
    assert.ok(summary.scenarios[0].issues.includes("Transaction submitted more than once"));
    assert.equal(evidence.broadcasts[0].count, 2);
});

test("RPC outcomes reject unrelated failures and oversized evidence", async context => {
    const {server, report, document} = await harness(context, "rpc-failure-capacity");
    await report({phase: "started", action: "rpc-burst", requestId: "burst-1"});
    const outcome = value => fetch(`${server.dappURL}/rpc-outcome`, {method: "POST", headers: {"X-Page-Token": server.pageToken, "Content-Type": "application/json"}, body: JSON.stringify({requestId: "burst-1", index: 0, origin: server.dappURL, documentId: document.documentId, scenario: {id: "rpc-failure-capacity", iteration: 1}, ...value})});
    assert.equal((await outcome({ok: false, error: {code: -32603, data: {reason: "unexpected"}}})).status, 400);
    assert.equal((await outcome({ok: false, error: {code: -32005, data: {reason: "queue-full"}, message: "x".repeat(3000)}})).status, 400);
    assert.equal((await outcome({ok: true, result: "0x100"})).status, 200);
    assert.deepEqual(server.rpcOutcomes, [{index: 0, ok: true, result: "0x100"}]);
});

test("Solana batch signatures bind ordered distinct messages without broadcast authority", async context => {
    const {server, report, document} = await harness(context, "solana-transaction-signing");
    const requestId = "batch-sign-1";
    await report({phase: "started", action: "solana-batch-sign", requestId});
    const allocate = () => fetch(`${server.dappURL}/page-solana-signing-messages`, {method: "POST", headers: {"X-Page-Token": server.pageToken, "Content-Type": "application/json"},
        body: JSON.stringify({requestId, origin: server.dappURL, documentId: document.documentId, scenario: {id: "solana-transaction-signing", iteration: 1}})});
    const allocation = await (await allocate()).json();
    assert.equal(allocation.messages.length, 2);
    assert.notEqual(...allocation.messages);
    assert.deepEqual(await (await allocate()).json(), allocation);
    const signatures = allocation.messages.map(message => base58.encode(ed25519.sign(base58.decode(message), Buffer.alloc(32, 2))));
    const result = {publicKey: server.fixture.addresses.solana, signatures};
    const value = {ok: true, action: "solana-batch-sign", requestId, result};
    assert.doesNotThrow(() => server.verifyResult(value));
    assert.throws(() => server.verifyResult({...value, result: {...result, signatures: [...signatures].reverse()}}));
    assert.throws(() => server.verifyResult({...value, requestId: "unknown-request"}));
    assert.throws(() => server.verifyResult({...value, result: {...result, signatures: signatures.slice(1)}}));
    assert.throws(() => server.verifyResult({...value, result: {...result, publicKey: server.fixture.alternateAddresses.solana}}));
    const transaction = Buffer.concat([Buffer.from([1]), Buffer.from(base58.decode(signatures[0])), Buffer.from(base58.decode(allocation.messages[0]))]);
    const broadcast = await fetch(`${server.url}/rpc/solana`, {method: "POST", headers: {"X-Big-Wallet-Test-Token": server.token},
        body: JSON.stringify({id: 1, method: "sendTransaction", params: [transaction.toString("base64"), {encoding: "base64"}]})});
    assert.equal(broadcast.status, 400);
    assert.equal(server.broadcasts.length, 0);
});

test("entitlements cannot grant access outside one macOS fixture directory", () => {
    const root = "/Volumes/BigWalletBuild/Exchange/run-test/safari/macos/Debug";
    assert.match(extensionEntitlements(root), /run-test\/safari\/macos\/Debug\//);
    for (const invalid of ["/", root + "/../Release", root.replace("macos", "ios"), root + '"<string>/</string>']) {
        assert.throws(() => extensionEntitlements(invalid));
    }
});

test("wrapper rejects uncontrolled iteration counts and missing result locations", () => {
    const args = ["--phase", "test", "--platform", "macos", "--configuration", "Debug", "--signing", "local", "--destination", "platform=macOS,arch=arm64", "--scratch-dir", "/Volumes/BigWalletBuild/scratch"];
    assert.throws(() => parseArguments(args));
    assert.throws(() => parseArguments([...args, "-resultBundlePath", "/Volumes/BigWalletBuild/results/test.xcresult", "--iterations", "0"]));
    assert.equal(parseArguments([...args, "-resultBundlePath", "/Volumes/BigWalletBuild/results/test.xcresult"]).iterations, 1);
    const valid = [...args, "-resultBundlePath", "/Volumes/BigWalletBuild/results/test.xcresult"];
    assert.equal(parseArguments([...valid, "--interactive-safari"]).interactiveActivation, true);
    assert.throws(() => parseArguments([...valid, "--interactive-safari", "--interactive-safari"]));
    assert.throws(() => parseArguments([...valid.map(value => value === "macos" ? "ios" : value), "--interactive-safari"]));
    assert.throws(() => parseArguments([...valid.map(value => value === "test" ? "build" : value), "--interactive-safari"]));
});

test("one consent cannot authorize signing under two execution identities", async context => {
    const {server} = await harness(context);
    const identity = {requestID: 1, requestToken: "request-token", profileIdentifier: null, configurationKey: "http://127.0.0.1:1", consentID: "consent-1"};
    const state = {errors: [], handshake: {provider: true, native: true}, results: [], broadcasts: [], events: [
        {kind: "consentAccepted", ...identity},
        {kind: "authorization", ...identity, executionID: "execution-1"},
        {kind: "authorization", ...identity, executionID: "execution-2"},
        {kind: "signingStarted", requestID: 1, executionID: "execution-1"},
        {kind: "signingStarted", requestID: 1, executionID: "execution-2"},
    ]};
    assert.ok(server.check(state).some(issue => issue.includes("distinct fresh consent")));
});

test("Solana message results verify canonical byte arrays against the original challenge and account", async context => {
    const {server} = await harness(context, "solana-signing");
    const requestId = "message-signing-request";
    const message = Buffer.from(`${server.fixture.message} | ${requestId}`);
    const signature = Array.from(ed25519.sign(message, Buffer.alloc(32, 2)));
    const value = {action: "solana-sign", requestId, ok: true, result: {publicKey: server.fixture.addresses.solana, signature}};
    assert.doesNotThrow(() => server.verifyResult(value));
    assert.throws(() => server.verifyResult({...value, requestId: "another-message"}), /does not match the approved account and message/);
    for (const result of [
        {...value.result, publicKey: server.fixture.alternateAddresses.solana},
        {...value.result, signature: {type: "Buffer", data: signature}},
        {...value.result, signature: signature.slice(1)},
        {...value.result, signature: [signature[0] + 256, ...signature.slice(1)]},
    ]) {
        assert.throws(() => server.verifyResult({...value, result}), /unexpected account or signature byte array/);
    }
});

test("fresh consent objects cannot sign the same original request twice", async context => {
    const {server} = await harness(context);
    const request = {requestID: 1, requestToken: "original-token", profileIdentifier: null, configurationKey: "http://127.0.0.1:1"};
    const events = [1, 2].flatMap(index => [
        {kind: "consentAccepted", ...request, consentID: `consent-${index}`},
        {kind: "authorization", ...request, consentID: `consent-${index}`, executionID: `execution-${index}`},
        {kind: "signingStarted", requestID: 1, executionID: `execution-${index}`},
    ]);
    const issues = server.check({errors: [], handshake: {provider: true, native: true}, results: [], broadcasts: [], events});
    assert.ok(issues.includes("Original request used signing more than once"));
    assert.ok(!issues.some(issue => issue.includes("distinct fresh consent")));
});

test("scenarios that never approve signing reject every signing or dispatch path in their final oracle", async context => {
    const {server} = await harness(context);
    const identity = {requestID: 7, requestToken: "held-request", profileIdentifier: "fixture-profile",
        configurationKey: "http://127.0.0.1:7777", consentID: "held-consent"};
    const signing = [{kind: "consentAccepted", ...identity},
        {kind: "authorization", ...identity, executionID: "late-execution"},
        {kind: "signingStarted", requestID: 7, executionID: "late-execution"}];
    for (const scenario of ["install-native-roundtrip", "extension-toggle", "profiles-private", "authority-revocation", "malformed-requests"]) {
        const base = {errors: [], handshake: {provider: true, native: true}, results: [], broadcasts: [], ...lockProof(server, scenario)};
        assert.deepEqual(server.check(base, scenario), []);
        for (const change of [{events: signing}, {events: [{kind: "broadcastCheckpoint"}]},
            {events: [{kind: "broadcastDispatch"}]}, {broadcasts: [{chain: "ethereum", count: 1}]}]) {
            assert.ok(server.check({...base, ...change}, scenario).includes("Scenario must not sign or dispatch: " + scenario));
        }
    }
});

test("late signing downgrades a previously passed revocation scenario when final evidence is persisted", async context => {
    const {server, root, control, report} = await harness(context, "authority-revocation");
    const contextRecord = {runID: "run-test", scenario: "authority-revocation", iteration: 1};
    await appendFile(join(root, "native-events.ndjson"), JSON.stringify({...contextRecord, ...siteIngress(server)}) + "\n");
    assert.equal((await report({phase: "provider-ready"})).status, 200);
    assert.equal((await report({phase: "started", requestId: "revoked-request", action: "ethereum-sign"})).status, 200);
    assert.equal((await report({phase: "settled", requestId: "revoked-request", action: "ethereum-sign", ok: false, error: {code: 4100}})).status, 200);
    assert.equal((await control("finish", {scenario: "authority-revocation", iteration: 1, status: "passed"})).status, 200);
    const identity = {requestID: 7, requestToken: "held-request", profileIdentifier: "fixture-profile",
        configurationKey: server.dappURL, consentID: "held-consent"};
    for (const record of [{kind: "consentAccepted", ...identity},
        {kind: "authorization", ...identity, executionID: "late-execution"},
        {kind: "signingStarted", requestID: 7, executionID: "late-execution"}]) {
        await appendFile(join(root, "native-events.ndjson"), JSON.stringify({...contextRecord, ...record}) + "\n");
    }
    await server.persist();
    const evidence = JSON.parse(await readFile(join(server.artifacts, "safari.macos.debug.safari.json"), "utf8"));
    assert.equal(evidence.scenarios[0].status, "failed");
    assert.ok(evidence.scenarios[0].issues.includes("Scenario must not sign or dispatch: authority-revocation"));
});

test("mixed scenarios reject a second signing request even when each execution has distinct valid consent", async context => {
    const {server} = await harness(context);
    const first = correlatedSigningEvents(1, server.dappURL);
    const extra = correlatedSigningEvents(2, server.dappURL);
    const base = {errors: [], handshake: {provider: true, native: true}, results: [], broadcasts: [], events: first};
    for (const scenario of ["rejection-duplicate-approval", "macos-auth-isolation", "navigation-tab-closure", "browser-restart",
        "background-foreground", "document-reload", "account-removal", "vault-replacement", "custom-network-replacement"]) {
        assert.deepEqual(server.check(base, scenario), []);
        assert.deepEqual(server.check({...base, events: []}, scenario),
            [`Expected exactly one signing execution for ${scenario}; observed 0`]);
        assert.deepEqual(server.check({...base, events: [...first, ...extra]}, scenario),
            [`Expected exactly one signing execution for ${scenario}; observed 2`]);
    }
});

test("late distinct signing downgrades a passed mixed scenario when final evidence is persisted", async context => {
    const {server, root, control, report} = await harness(context, "account-removal");
    const contextRecord = {runID: "run-test", scenario: "account-removal", iteration: 1};
    const append = async records => {
        await appendFile(join(root, "native-events.ndjson"), records.map(record =>
            JSON.stringify({...contextRecord, ...record}) + "\n").join(""));
    };
    await append([siteIngress(server), ...correlatedSigningEvents(1, server.dappURL)]);
    assert.equal((await report({phase: "provider-ready"})).status, 200);
    assert.equal((await control("finish", {scenario: "account-removal", iteration: 1, status: "passed"})).status, 200);
    await append(correlatedSigningEvents(2, server.dappURL));
    await server.persist();
    const evidence = JSON.parse(await readFile(join(server.artifacts, "safari.macos.debug.safari.json"), "utf8"));
    assert.equal(evidence.scenarios[0].status, "failed");
    assert.deepEqual(evidence.scenarios[0].issues,
        ["Expected exactly one signing execution for account-removal; observed 2"]);
});
