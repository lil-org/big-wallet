import {isDeepStrictEqual} from "node:util";
import {validateSourceIdentity} from "../approval_lifecycle/source_identity.mjs";
import {ARCHIVE_SHA256, BASELINE, FAILURE_CASES, FIXTURE_ID, PHASES} from "./contract.mjs";

const digest = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const positive = value => Number.isSafeInteger(value) && value > 0;
const nonnegative = value => Number.isSafeInteger(value) && value >= 0;
const hashPair = value => value && ["keychainSHA256", "preferencesSHA256"].every(key => value[key] === null || digest(value[key]));
const equalSet = (actual, expected) => Array.isArray(actual) && actual.length === expected.length &&
    new Set(actual).size === actual.length && expected.every(value => actual.includes(value));
const binaryIdentity = value => value && digest(value.sha256) && positive(value.bytes);

export function auditConsumerReport(report, phase, fixtureHashes) {
    const issues = [];
    if (!report || report.version !== 1 || report.status !== "passed" || report.mode !== phase.mode ||
        report.fixtureID !== FIXTURE_ID || !isDeepStrictEqual(report.baseline, BASELINE) || !positive(report.processID)) {
        return {ok: false, issues: [`${phase.mode}: invalid consumer identity or unsuccessful result`]};
    }
    if (!equalSet(report.checks, phase.checks)) { issues.push(`${phase.mode}: incomplete or unexpected check inventory`); }
    if (!isDeepStrictEqual(report.counts, phase.counts)) { issues.push(`${phase.mode}: incomplete wallet, export, or signature coverage`); }
    if (report.networkAttempts !== 0 || !nonnegative(report.keychainWrites) || !nonnegative(report.preferenceWrites)) {
        issues.push(`${phase.mode}: missing isolation or storage-write evidence`);
    }
    if (!hashPair(report.storage?.before) || !hashPair(report.storage?.after)) {
        issues.push(`${phase.mode}: missing storage fingerprints`);
    } else {
        if (phase.mode.startsWith("verify-")) {
            if (!isDeepStrictEqual(report.storage.before, report.storage.after) ||
                !digest(report.storage.before.keychainSHA256) || !digest(report.storage.before.preferencesSHA256) ||
                report.keychainWrites !== 0 || report.preferenceWrites !== 0) {
                issues.push(`${phase.mode}: verification mutated storage`);
            }
        }
        if (phase.mode === "verify-existing" && !isDeepStrictEqual(report.storage.before, fixtureHashes)) {
            issues.push("verify-existing: predecessor bytes were not loaded unchanged");
        }
        if (phase.mode === "mutate-existing" && (report.keychainWrites < 1 || report.preferenceWrites < 1 ||
            report.storage.before.keychainSHA256 === report.storage.after.keychainSHA256 ||
            report.storage.before.preferencesSHA256 === report.storage.after.preferencesSHA256)) {
            issues.push("mutate-existing: no persisted wallet and metadata mutation");
        }
        if (phase.mode === "restore" && (report.storage.before.keychainSHA256 !== null || report.storage.before.preferencesSHA256 !== null ||
            !digest(report.storage.after.keychainSHA256) || !digest(report.storage.after.preferencesSHA256) || report.keychainWrites < 4)) {
            issues.push("restore: missing fresh-store restoration evidence");
        }
    }
    if (phase.mode === "failures") {
        if (!Array.isArray(report.failureCases) || !equalSet(report.failureCases.map(value => value?.name), FAILURE_CASES)) {
            issues.push("failures: missing negative cases");
        } else {
            for (const value of report.failureCases) {
                if (value.rejected !== true || !isDeepStrictEqual(value.before, fixtureHashes) ||
                    !isDeepStrictEqual(value.before, value.after) || value.keychainWrites !== 0 || value.preferenceWrites !== 0) {
                    issues.push(`failures: ${value.name} did not reject without changing predecessor storage`);
                }
            }
        }
    }
    return {ok: issues.length === 0, issues};
}

export function auditUpgradeResult(report, policy, {runId, sourceSHA256} = {}) {
    const issues = [];
    if (report?.version === 1 && report.status === "failed" && typeof report.error === "string") {
        return {ok: false, issues: [`Upgrade verification failed: ${report.error.slice(0, 1000)}`], phaseCount: report.phases?.length ?? 0};
    }
    if (!report || report.version !== 1 || report.status !== "passed" || report.fixtureID !== FIXTURE_ID ||
        !isDeepStrictEqual(report.baseline, BASELINE) || !["Debug", "Release"].includes(report.configuration) ||
        report.configuration !== policy?.configuration || !isDeepStrictEqual(policy?.baseline, BASELINE) ||
        typeof runId !== "string" || report.runId !== runId) {
        return {ok: false, issues: ["Invalid upgrade report identity, configuration, or outcome"], phaseCount: 0};
    }
    try {
        validateSourceIdentity(report.sourceIdentity);
        if (!digest(sourceSHA256) || report.sourceIdentity.source.sha256 !== sourceSHA256) {
            issues.push("Upgrade consumer does not match the captured VM source");
        }
    } catch { issues.push("Missing upgrade consumer source identity"); }
    const provenance = report.provenance;
    if (!provenance || provenance.archiveSHA256 !== ARCHIVE_SHA256 || !digest(provenance.manifestSHA256) ||
        !digest(provenance.driverSHA256) || !digest(provenance.adaptersSHA256) || !binaryIdentity(provenance.producerBinary) ||
        provenance.archivedFileCount !== 95 || provenance.archivedSwiftCount !== 30 || provenance.archivedCUnitCount !== 5 ||
        provenance.commitTreeProofVerified !== true || provenance.producerExitCode !== 0 || !positive(provenance.producerProcessID) ||
        !Array.isArray(provenance.undefinedSecurityStorageSymbols) || provenance.undefinedSecurityStorageSymbols.length !== 0 || provenance.undefinedSymbolsAuditExitCode !== 0 ||
        !digest(provenance.undefinedSymbolsSHA256) || !Array.isArray(provenance.commands) || provenance.commands.length < 8 ||
        provenance.commands.some(command => !Array.isArray(command?.argv) || !command.argv.length ||
            command.argv.some(argument => typeof argument !== "string") || command.exitCode !== 0 || !positive(command.processID)) ||
        typeof provenance.swiftVersion !== "string" || !provenance.swiftVersion.trim() ||
        typeof provenance.clangVersion !== "string" || !provenance.clangVersion.trim()) {
        issues.push("Missing historical producer, compilation, or isolated-storage provenance");
    }
    const fixture = report.fixture;
    if (!fixture || !digest(fixture.keychainSHA256) || !digest(fixture.preferencesSHA256) || !digest(fixture.expectationsSHA256) ||
        fixture.walletCount !== 3 || fixture.accountCount !== 4 || fixture.networkCount !== 1) {
        issues.push("Incomplete historical storage and backup fixture");
    }
    const fixtureHashes = {keychainSHA256: fixture?.keychainSHA256, preferencesSHA256: fixture?.preferencesSHA256};
    if (!Array.isArray(report.phases) || !isDeepStrictEqual(report.phases.map(value => value?.mode), PHASES.map(value => value.mode))) {
        issues.push("Missing, reordered, or duplicate upgrade/recovery phases");
    } else {
        const processIDs = new Set([provenance?.producerProcessID]);
        for (const [index, phase] of PHASES.entries()) {
            const result = report.phases[index];
            issues.push(...auditConsumerReport(result, phase, fixtureHashes).issues);
            if (processIDs.has(result.processID)) { issues.push(`${phase.mode}: verification did not use a fresh process`); }
            processIDs.add(result.processID);
        }
        for (const [previous, next] of [[0, 1], [1, 2], [3, 4]]) {
            if (!isDeepStrictEqual(report.phases[previous].storage?.after, report.phases[next].storage?.before)) {
                issues.push(`${PHASES[next].mode}: persisted state was not reopened unchanged`);
            }
        }
    }
    if (!isDeepStrictEqual(report.fixtureAfter, fixtureHashes)) { issues.push("Historical fixture changed during verification"); }
    return {ok: issues.length === 0, issues, phaseCount: report.phases?.length ?? 0,
        baseline: BASELINE, counts: {total: PHASES.length + FAILURE_CASES.length,
            passed: issues.length ? 0 : PHASES.length + FAILURE_CASES.length, failed: issues.length ? 1 : 0, skipped: 0}};
}
