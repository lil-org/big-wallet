// ∅ 2026 lil org

import assert from "node:assert/strict";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const resourceURL = name => new URL(`../Resources/${name}`, import.meta.url);
const [source, nativeSource] = await Promise.all([
    readFile(resourceURL("bridge_wire.js"), "utf8"),
    readFile(new URL("../ExtensionBridge.swift", import.meta.url), "utf8"),
]);
const context = vm.createContext({
    URL,
    clearTimeout,
    crypto: webcrypto,
    setTimeout,
});
new vm.Script(source).runInContext(context);
const wire = context.BigWalletBridgeWire;
const token = "123e4567-e89b-12d3-a456-426614174000";
const solanaPublicKey = "11111111111111111111111111111111";

test("publishes the small immutable workflow v3 contract", () => {
    assert.equal(Object.isFrozen(wire), true);
    assert.equal(wire.WORKFLOW_VERSION, 3);
    assert.equal(wire.PAGE_TO_CONTENT_DIRECTION, "big-wallet-provider-v1");
    assert.equal(wire.CONTENT_TO_PAGE_DIRECTION, "big-wallet-content-v1");
    assert.equal(wire.IDLE_SWITCH_ATTEMPT_KEY, undefined);
    assert.equal(wire.IDLE_SWITCH_MARKER_REGISTRY_SUBJECT, undefined);
    assert.equal(wire.SUPPRESS_PROVIDER_UPDATE_KEY, undefined);
    assert.equal(wire.isResponseAcknowledgement, undefined);
});

test("keeps workflow policy aligned with the native request authority", () => {
    const nativeNumber = name => Number(nativeSource.match(
        new RegExp(`static let ${name}(?:: [^=]+)? = ([0-9]+)`)
    )[1]);
    assert.equal(wire.WORKFLOW_VERSION,
        nativeNumber("workflowVersion"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRequests,
        nativeNumber("maximumRequests"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRequestsPerHost,
        nativeNumber("maximumRequestsPerHost"));
    assert.equal(wire.WORKFLOW_POLICY.maximumRetainedRequests,
        nativeNumber("maximumRetainedRequests"));
    assert.equal(wire.WORKFLOW_POLICY.requestTTLMilliseconds, 15 * 60 * 1000);
    assert.equal(wire.WORKFLOW_POLICY.responseExpiryMilliseconds, 60 * 60 * 1000);
    assert.equal(wire.APPROVAL_COMMITTED_KEY, nativeSource.match(
        /static let approvalCommittedKey = "([^"]+)"/
    )[1]);
});

test("validates enqueue and response correlations", () => {
    const native = {
        id: 7,
        requestToken: token,
        approvalRequired: true,
        revisions: {ethereum: 2, solana: 3},
    };
    assert.equal(wire.isNativeEnqueueAcknowledgement(native, 7), true);
    assert.equal(wire.isNativeEnqueueAcknowledgement({...native, extra: true}, 7), false);
    assert.equal(wire.isNativeEnqueueAcknowledgement({
        ...native,
        revisions: {ethereum: 2, solana: -1},
    }, 7), false);
    assert.equal(wire.isCorrelatedDappResponse({
        id: 7,
        name: "signMessage",
        provider: "ethereum",
        result: "ok",
    }, 7), true);
});

test("parses plain and wrapped configuration arrays without workflow metadata", () => {
    const configurations = [{provider: "ethereum", chainId: "0x1", results: []}];
    assert.deepEqual(
        JSON.parse(JSON.stringify(wire.parseLatestConfigurations(configurations))),
        {valid: true, latestConfigurations: configurations}
    );
    assert.equal(wire.parseLatestConfigurations({
        latestConfigurations: configurations,
        bridgeState: {admittedAttempts: {}},
    }).valid, true);
    assert.equal(wire.parseLatestConfigurations([
        ...configurations,
        {...configurations[0]},
    ]).valid, false);
});

test("validates canonical Ethereum chains and 32-byte Solana keys", () => {
    assert.equal(wire.isCanonicalEthereumChainId("0x1"), true);
    assert.equal(wire.isCanonicalEthereumChainId("0x7fffffffffffffff"), true);
    assert.equal(wire.isCanonicalEthereumChainId("0x0"), false);
    assert.equal(wire.isCanonicalEthereumChainId("0x01"), false);
    assert.equal(wire.isCanonicalEthereumChainId("0x8000000000000000"), false);
    assert.equal(wire.isConfiguration({
        provider: "solana",
        publicKey: solanaPublicKey,
    }), true);
    assert.equal(wire.isConfiguration({
        provider: "solana",
        publicKey: "public-key",
    }), false);
    assert.equal(wire.isConfiguration({
        provider: "solana",
        publicKey: `${solanaPublicKey}1`,
    }), false);
});

test("derives stable web and file configuration identities", () => {
    assert.deepEqual(
        JSON.parse(JSON.stringify(wire.configurationIdentityForURL(
            "https://wallet.example/path#fragment"
        ))),
        {
            host: "wallet.example",
            configurationKey: "https://wallet.example",
            legacyConfigurationKey: "wallet.example",
        }
    );
    assert.notEqual(
        wire.configurationIdentityForURL("http://wallet.example").configurationKey,
        wire.configurationIdentityForURL("https://wallet.example").configurationKey
    );
    assert.deepEqual(
        JSON.parse(JSON.stringify(wire.configurationIdentityForURL(
            "file:///tmp/dapp.html?profile=one#fragment"
        ))),
        {
            host: "file:///tmp/dapp.html",
            configurationKey: "file:///tmp/dapp.html",
            legacyConfigurationKey: null,
        }
    );
    assert.equal(wire.isLowercaseUUID(token), true);
});

test("normalizes bounded response-ready wake hints", () => {
    assert.deepEqual(
        [...wire.responseReadyIds({
            subject: "responseReady",
            ids: [1, 1, 2],
            workflowVersion: 3,
        })],
        [1, 2]
    );
    assert.equal(wire.responseReadyIds({
        subject: "responseReady",
        ids: [],
        workflowVersion: 3,
    }), null);
});

test("validates exact passive configuration notifications", () => {
    const notification = {
        subject: "configurationChanged",
        configurationKey: "https://wallet.example",
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x1",
            results: [],
        }],
        revisions: {ethereum: 1, solana: 0},
        workflowVersion: 3,
    };
    assert.equal(wire.isConfigurationChanged(notification), true);
    assert.equal(wire.isConfigurationChanged({...notification, extra: true}), false);
    assert.equal(wire.isConfigurationChanged({
        ...notification,
        latestConfigurations: undefined,
    }), false);
    assert.equal(wire.isConfigurationChanged({
        ...notification,
        latestConfigurations: [
            ...notification.latestConfigurations,
            {...notification.latestConfigurations[0]},
        ],
    }), false);
});

test("stamps private context on the real first native message", async () => {
    const messages = [];
    const send = wire.createTrustedNativeMessageSender({
        sendRawNativeMessage(message) {
            messages.push(JSON.parse(JSON.stringify(message)));
            return {id: message.id, result: true};
        },
    });
    await send({subject: "rpc", id: 1}, false);
    await send({subject: "rpc", id: 2}, true);
    assert.equal(messages.length, 2);
    assert.equal(messages[0].subject, "rpc");
    assert.equal(messages[0].__bwPrivateBrowsing, false);
    assert.equal(messages[1].__bwPrivateBrowsing, true);
});

test("loads the shared contract before each browser consumer", async () => {
    const [contentManifest, backgroundManifest] = await Promise.all([
        readFile(resourceURL("manifest.json"), "utf8"),
        readFile(resourceURL("manifest-mv3.json"), "utf8").catch(() => ""),
    ]);
    assert.match(contentManifest, /bridge_wire\.js/);
    if (backgroundManifest) { assert.match(backgroundManifest, /service_worker\.js/); }
});
