import {readFileSync} from "node:fs";
import {isAbsolute} from "node:path";
import {pathToFileURL} from "node:url";

const [manifestPath, ...extra] = process.argv.slice(2);
if (!manifestPath || !isAbsolute(manifestPath) || extra.length) { throw new Error("Expected one absolute test manifest path"); }
const {createManifest} = await import(pathToFileURL(manifestPath).href);
const job = JSON.parse(readFileSync(0, "utf8"));
if (job.kind !== "run") { throw new Error("Only test runs have a planned stage inventory"); }
const stages = createManifest(job).map(stage => ({id: stage.id, group: stage.group, status: "pending",
    ...(stage.nativeAudit ? {nativeAudit: stage.nativeAudit} : {}),
    ...(stage.preparationResult ? {preparationResult: true} : {})}));
process.stdout.write(JSON.stringify(stages) + "\n");
