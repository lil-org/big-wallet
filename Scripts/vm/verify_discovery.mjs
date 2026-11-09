import {readFileSync} from "node:fs";
import {dirname, isAbsolute, join} from "node:path";
import {pathToFileURL} from "node:url";

const [manifestPath, artifacts, ...extra] = process.argv.slice(2);
if (!isAbsolute(manifestPath ?? "") || !isAbsolute(artifacts ?? "") || extra.length) { throw new Error("Expected absolute manifest and artifact paths"); }
const {createManifest, stagePlan} = await import(pathToFileURL(manifestPath).href);
const {auditDiscoveryStages, readDiscoveryFile, verifyArchivedTestRuns} = await import(pathToFileURL(join(dirname(manifestPath), "test_discovery.mjs")).href);
const job = JSON.parse(readFileSync(0, "utf8"));
const report = JSON.parse(readFileSync(join(artifacts, "result.json"), "utf8"));
if (job.kind !== "run" || report.kind !== job.kind || report.runId !== job.runId || report.vmId !== job.vmId ||
    report.profile !== job.profile || report.source?.sha256 !== job.source.sha256) {
    throw new Error("The XCTest report does not belong to the requested job and source");
}
if (report.status !== "passed" || !report.finishedAt || !Array.isArray(report.stages) || !report.stages.length ||
    !report.stages.every(stage => stage?.status === "passed")) {
    throw new Error("A passing XCTest report requires every stage to have passed");
}
const audit = await auditDiscoveryStages(createManifest(job), report.stages, {job, artifacts});
if (!audit.ok) { throw new Error(audit.issues.join("\n")); }
await verifyArchivedTestRuns(audit.stages, report, artifacts);
const expected = stagePlan(audit.stages);
const resolved = JSON.parse(await readDiscoveryFile(join(artifacts, "resolved-plan.json")));
if (JSON.stringify(expected) !== JSON.stringify(resolved)) { throw new Error("Archived resolved plan does not match independently resolved XCTest discovery"); }
process.stdout.write(JSON.stringify(expected) + "\n");
