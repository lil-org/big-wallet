// ∅ 2026 lil org

import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {webcrypto} from "node:crypto";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
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
const attempt = "00000001000000020000000300000004";
const solanaPublicKey = "11111111111111111111111111111111";
const execFileAsync = promisify(execFile);

const manifestPathForTarget = (project, targetName) => {
    const objects = project.objects;
    const targets = Object.values(objects).filter(object =>
        object.isa === "PBXNativeTarget" && object.name === targetName
    );
    assert.equal(targets.length, 1, `missing Xcode target ${targetName}`);
    const resourcePhaseIDs = targets[0].buildPhases.filter(id =>
        objects[id]?.isa === "PBXResourcesBuildPhase"
    );
    assert.equal(resourcePhaseIDs.length, 1,
        `${targetName} must have exactly one resource phase`);
    const manifestReferenceIDs = objects[resourcePhaseIDs[0]].files
        .map(buildFileID => objects[buildFileID]?.fileRef)
        .filter(fileReferenceID => objects[fileReferenceID]?.path === "manifest.json");
    assert.equal(manifestReferenceIDs.length, 1,
        `${targetName} must contain exactly one manifest.json`);
    const segments = [];
    let childID = manifestReferenceIDs[0];
    const visited = new Set();
    while (!visited.has(childID)) {
        visited.add(childID);
        const parents = Object.entries(objects).filter(([, object]) =>
            object.isa === "PBXGroup" && object.children?.includes(childID)
        );
        assert.ok(parents.length <= 1, `ambiguous Xcode group for ${childID}`);
        if (parents.length === 0) {
            break;
        }
        const [parentID, parent] = parents[0];
        const segment = parent.path ?? parent.name;
        if (segment) {
            segments.unshift(segment);
        }
        childID = parentID;
    }
    return [...segments, "manifest.json"].join("/");
};

test("publishes the small immutable workflow v3 contract", () => {
    assert.equal(Object.isFrozen(wire), true);
    assert.match(wire.BUILD_VERSION, /^.+\+[0-9]+$/);
    assert.equal(source.match(/const BUILD_VERSION = "[^"\n]+";/g)?.length, 1);
    assert.equal(wire.WORKFLOW_VERSION, 3);
    assert.equal(wire.PAGE_TO_CONTENT_DIRECTION, "big-wallet-provider-v1");
    assert.equal(wire.CONTENT_TO_PAGE_DIRECTION, "big-wallet-content-v1");
    assert.equal(wire.MANUAL_SWITCH_INTENT_SUBJECT, "manualSwitchIntent");
    assert.equal(wire.MANUAL_SWITCH_RESULT_SUBJECT, undefined);
    assert.equal(wire.IDLE_SWITCH_ATTEMPT_KEY, undefined);
    assert.equal(wire.IDLE_SWITCH_MARKER_REGISTRY_SUBJECT, undefined);
    assert.equal(wire.SUPPRESS_PROVIDER_UPDATE_KEY, undefined);
    assert.equal(wire.isResponseAcknowledgement, undefined);
});

test("validates exact manual-switch acknowledgements", () => {
    const configurationKey = "https://wallet.example";
    const acknowledged = {
        approvalRequired: true,
        configurationKey,
        id: 31,
        requestToken: token,
        revisions: {ethereum: 2, solana: 3},
        subject: wire.MANUAL_SWITCH_ACKNOWLEDGED_SUBJECT,
        workflowVersion: 3,
    };

    assert.equal(wire.isManualSwitchAcknowledgement(
        acknowledged, 31, configurationKey
    ), true);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, id: 32}, 31, configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, extra: true}, 31, configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement(
        {...acknowledged, id: "31"}, "31", configurationKey
    ), false);
    assert.equal(wire.isManualSwitchAcknowledgement({
        ...acknowledged,
        configurationKey: "invalid",
    }, 31, "invalid"), false);
});

test("requires substantive bounded manual-switch terminals", () => {
    const ethereum = {
        provider: "ethereum",
        chainId: "0x1",
        results: ["0x0000000000000000000000000000000000000001"],
    };
    const success = {
        id: 31,
        name: "switchAccount",
        provider: "multiple",
        bodies: [ethereum],
        providersToDisconnect: ["solana"],
        configurationToStore: [ethereum],
    };
    const applied = {
        id: 31,
        name: "switchAccount",
        provider: "multiple",
        latestConfigurations: [ethereum],
        revisions: {ethereum: 3, solana: 4},
    };
    const emptySuccess = {
        id: 31,
        name: "switchAccount",
        provider: "multiple",
        bodies: [],
        providersToDisconnect: [],
        configurationToStore: [],
    };
    const rejected = {
        id: 31,
        name: "switchAccount",
        provider: "unknown",
        error: "Canceled",
        errorCode: 4001,
    };
    const stale = {
        ...rejected,
        latestConfigurations: [ethereum],
        revisions: {ethereum: 3, solana: 4},
    };

    for (const response of [success, emptySuccess, applied, rejected, stale]) {
        assert.equal(wire.isManualSwitchTerminalResponse(response, 31), true);
    }
    for (const response of [
        {id: 31, name: "switchAccount"},
        {id: 31, name: "switchAccount", provider: "multiple"},
        {...success, id: 32},
        {...success, name: "requestAccounts"},
        {...success, provider: "unknown"},
        {...success, error: "Canceled", errorCode: 4001},
        {...success, error: 123},
        {...success, errorCode: 4001},
        {...success, __bwStale: true},
        {...success, extra: true},
        {...success, providersToDisconnect: ["solana", "solana"]},
        {...success, providersToDisconnect: ["ethereum"]},
        {
            ...success,
            bodies: [ethereum, {
                provider: "solana",
                publicKey: "11111111111111111111111111111111",
            }],
            configurationToStore: [ethereum, {
                provider: "solana",
                publicKey: "11111111111111111111111111111111",
            }],
            providersToDisconnect: ["solana"],
        },
        {...success, configurationToStore: "invalid"},
        {...success, configurationToStore: []},
        {
            ...success,
            latestConfigurations: [ethereum],
            revisions: {ethereum: 3, solana: 4},
        },
        {...applied, bodies: [], providersToDisconnect: []},
        {...applied, revisions: {ethereum: -1, solana: 4}},
        {...rejected, error: ""},
        {...rejected, errorCode: 1.5},
        {...rejected, error: "x".repeat(256 * 1024)},
    ]) {
        assert.equal(wire.isManualSwitchTerminalResponse(response, 31), false);
    }
    assert.equal(wire.isManualSwitchTerminalResponse(
        {...success, id: "31"},
        "31"
    ), false);
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

test("keeps the real platform manifests on their intended MV3 routes", async () => {
    const projectPath = fileURLToPath(
        new URL("../../Wallet.xcodeproj/project.pbxproj", import.meta.url)
    );
    const [sharedManifest, macManifest, projectResult] = await Promise.all([
        readFile(resourceURL("manifest.json"), "utf8").then(JSON.parse),
        readFile(new URL("../../Safari macOS/Resources/manifest.json", import.meta.url), "utf8")
            .then(JSON.parse),
        execFileAsync("/usr/bin/plutil", ["-convert", "json", "-o", "-", projectPath], {
            encoding: "utf8",
        }),
    ]);
    const project = JSON.parse(projectResult.stdout);
    for (const manifest of [sharedManifest, macManifest]) {
        assert.equal(manifest.manifest_version, 3);
        assert.equal(manifest.background.service_worker, "service_worker.js");
        assert.deepEqual(manifest.content_scripts[0].js, ["bridge_wire.js", "content.js"]);
        assert.equal(manifest.action.default_icon["16"], "images/toolbar-icon-16.png");
    }
    assert.equal(sharedManifest.action.default_popup, "popup.html");
    assert.equal(Object.hasOwn(macManifest.action, "default_popup"), false);
    assert.equal(manifestPathForTarget(project, "Safari macOS"),
        "Safari macOS/Resources/manifest.json");
    assert.equal(manifestPathForTarget(project, "Safari iOS"),
        "Safari Shared/Resources/manifest.json");
    assert.equal(manifestPathForTarget(project, "Safari visionOS"),
        "Safari Shared/Resources/manifest.json");
});
