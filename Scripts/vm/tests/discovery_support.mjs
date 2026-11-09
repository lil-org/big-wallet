import {ASAN_RUNTIME_TESTS, createManifest, PERFORMANCE_TESTS, stagePlan} from "../test_manifest.mjs";
import {APP_TEST_CLASS_PLATFORMS, APP_TEST_TARGETS, RUNTIME_TEST_TARGETS, TSAN_FOCUS} from "../test_policy.mjs";
import {auditDiscoveryStages, stagesAfterDiscovery} from "../test_discovery.mjs";

const focused = [...ASAN_RUNTIME_TESTS, ...Object.values(TSAN_FOCUS).flatMap(focus => focus.runtime)];
const runtime = [
    ...RUNTIME_TEST_TARGETS.map(target => `${target}/RuntimeFixtureTests/testOrdinary`),
    ...focused.map(selector => selector.split("/").length === 3 ? selector : `${selector}/testFixture`),
    ...PERFORMANCE_TESTS.map(name => `WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/${name}`),
    "WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/testPerformanceGateThresholdResolutionSkipsUnlessBaselineIsConfigured",
    "WalletAuthorityTests/SecretBytesTests/testInvalidationRetiresEveryAliasAndWipesExactlyOnce",
    "WalletAuthorityTests/WalletSigningSessionTests/testMismatchedSourceAccountDoesNotConsumePermit",
];

export function fixtureIdentifiers(policy) {
    if (policy.runtime) {
        return [...new Set([...runtime, ...(policy.mutationWitnesses ?? [])])].sort();
    }
    const target = APP_TEST_TARGETS[policy.platform];
    const suites = Object.entries(APP_TEST_CLASS_PLATFORMS).filter(([, platforms]) => platforms.includes(policy.platform)).map(([name]) => name);
    const names = suites.flatMap(suite => ["testFixture", "testOther"].map(method => `${target}/${suite}/${method}`));
    names.push(`${target}/UnregisteredTests/testSpecific`, `${target}/FixtureTests/testFixture`);
    if (policy.platform === "macos") {
        names.push(`${target}/AccountPreviewStateTests/testDisablingAndRestoringTheLastSelection`,
            `${target}/SecretHandlingTests/testInvalidationRejectsLateSecretResultsAndCallbacks`);
    }
    names.push(`${target}/WalletAccessControllerTests/testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock`);
    return names.sort();
}

export function fixtureEvidence(stage) {
    return {plan: {path: `/fixture/DerivedData/Wallet/Build/Products/${stage.id}.xctestrun`}, identifiers: fixtureIdentifiers(stage.nativeDiscovery)};
}

export function resolvedFixtureManifest(job) {
    const queue = createManifest(job);
    for (let index = 0; index < queue.length; index++) {
        const stage = queue[index];
        if (!stage.nativeDiscovery) { continue; }
        const evidence = fixtureEvidence(stage);
        queue.splice(index + 1, 0, ...stagesAfterDiscovery(stage, evidence.identifiers, evidence, new Set(queue.map(value => value.id))));
    }
    return queue;
}

export async function auditFixtureSelection(job, {changeRecords = () => {}, identifiers = fixtureIdentifiers} = {}) {
    const manifest = resolvedFixtureManifest(job);
    const records = stagePlan(manifest).map(record => ({...record, status: "passed", productsVerified: true, audit: {ok: true}}));
    changeRecords(records);
    return auditDiscoveryStages(createManifest(job), records, {job, artifacts: "/fixture", load: async stage => ({
        identifiers: identifiers(stage.nativeDiscovery), evidence: fixtureEvidence(stage),
    })});
}
