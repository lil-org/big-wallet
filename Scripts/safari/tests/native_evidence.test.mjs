import test from "node:test";
import assert from "node:assert/strict";
import {appendFile, mkdtemp, mkdir, readFile, rename, rm, symlink, truncate, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {NativeEvidenceReader} from "../native_evidence.mjs";

const runID = "native-evidence-fixture";
const record = (sequence, extra = {}) => ({runID, sequence, ...extra});
const line = value => Buffer.from(JSON.stringify(value) + "\n");

async function fixture(context, options) {
    const directory = await mkdtemp(join(tmpdir(), "safari-native-evidence-"));
    context.after(() => rm(directory, {recursive: true, force: true}));
    const path = join(directory, "native-events.ndjson");
    return {directory, path, reader: new NativeEvidenceReader(path, {runID, ...options})};
}

test("Missing evidence remains empty until the first creation", async context => {
    const {path, reader} = await fixture(context);
    const initial = await reader.read();
    assert.deepEqual(initial, []);
    assert.equal(await reader.read(), initial);
    await writeFile(path, line(record(1)));
    assert.equal(await reader.read(), initial);
    assert.deepEqual(initial, [record(1)]);
});

test("Reads share one flight and return cached records without duplicating old lines", async context => {
    const {path, reader} = await fixture(context);
    await writeFile(path, line(record(1)));
    const first = reader.read();
    const simultaneous = reader.read();
    assert.equal(first, simultaneous);
    const records = await first;
    const original = records[0];
    assert.equal(await simultaneous, records);
    assert.equal(await reader.read(), records);
    await appendFile(path, line(record(2)));
    assert.equal(await reader.read(), records);
    assert.equal(records[0], original);
    assert.deepEqual(records, [record(1), record(2)]);
});

test("Partial JSON and split multibyte UTF-8 remain pending until newline", async context => {
    const {path, reader} = await fixture(context);
    const value = record(1, {message: "Safari 😀 evidence"});
    const bytes = line(value);
    const split = bytes.indexOf(0xf0) + 2;
    await writeFile(path, bytes.subarray(0, split));
    assert.deepEqual(await reader.read(), []);
    await appendFile(path, bytes.subarray(split, -1));
    assert.deepEqual(await reader.read(), []);
    await appendFile(path, bytes.subarray(-1));
    assert.deepEqual(await reader.read(), [value]);
});

test("Finalization rejects an unterminated trailing record after valid evidence", async context => {
    const {path, reader} = await fixture(context);
    await writeFile(path, Buffer.concat([line(record(1)), Buffer.from(JSON.stringify(record(2, {kind: "signingStarted"})))]));
    assert.deepEqual(await reader.read(), [record(1)]);
    await assert.rejects(reader.finish(), /incomplete record/);
    await appendFile(path, "\n");
    await assert.rejects(reader.read(), /incomplete record/);
});

test("Long partial lines and chunk-boundary newlines parse once after completion", async context => {
    const {path, reader} = await fixture(context);
    const value = record(1, {payload: "x".repeat(200000)});
    const bytes = line(value);
    await writeFile(path, "");
    for (let offset = 0; offset < bytes.length - 1; offset += 8191) {
        await appendFile(path, bytes.subarray(offset, Math.min(offset + 8191, bytes.length - 1)));
        assert.deepEqual(await reader.read(), []);
    }
    await appendFile(path, Buffer.concat([Buffer.from("\n"), line(record(2))]));
    assert.deepEqual(await reader.read(), [value, record(2)]);
});

test("A complete line may use CRLF without changing its record", async context => {
    const {path, reader} = await fixture(context);
    await writeFile(path, JSON.stringify(record(1)) + "\r\n");
    assert.deepEqual(await reader.read(), [record(1)]);
});

test("Malformed complete JSON, malformed UTF-8, and non-record values fail closed", async context => {
    for (const contents of [Buffer.from("{broken}\n"), Buffer.from([0xff, 0x0a]), Buffer.from("\n"), Buffer.from("null\n"), Buffer.from("[]\n")]) {
        const {path, reader} = await fixture(context);
        await writeFile(path, contents);
        await assert.rejects(reader.read(), /Malformed complete|Invalid native evidence/);
    }
});

test("Malformed trailing data remains pending but becomes a permanent error when completed", async context => {
    const {path, reader} = await fixture(context);
    await writeFile(path, "{malformed");
    assert.deepEqual(await reader.read(), []);
    await appendFile(path, "}\n");
    let failure;
    await assert.rejects(reader.read(), error => { failure = error; return /Malformed complete/.test(error.message); });
    await writeFile(path, line(record(1)));
    await assert.rejects(reader.read(), error => error === failure);
});

test("Evidence from another VM run is rejected", async context => {
    const {path, reader} = await fixture(context);
    await writeFile(path, line(record(1, {runID: "other-run"})));
    await assert.rejects(reader.read(), /different VM run/);
});

test("Byte limits include incomplete trailing data and event limits span reads", async context => {
    const first = line(record(1));
    const limitedBytes = await fixture(context, {maximumBytes: first.length});
    await writeFile(limitedBytes.path, first);
    assert.deepEqual(await limitedBytes.reader.read(), [record(1)]);
    await appendFile(limitedBytes.path, " ");
    await assert.rejects(limitedBytes.reader.read(), /byte budget/);
    const limitedEvents = await fixture(context, {maximumEvents: 2});
    await writeFile(limitedEvents.path, line(record(1)));
    await limitedEvents.reader.read();
    await appendFile(limitedEvents.path, line(record(2)));
    assert.deepEqual(await limitedEvents.reader.read(), [record(1), record(2)]);
    await appendFile(limitedEvents.path, line(record(3)));
    await assert.rejects(limitedEvents.reader.read(), /event budget/);
});

test("The default inventory accepts a ten-iteration-sized ledger above the old event cap", async context => {
    const {path, reader} = await fixture(context);
    const values = Array.from({length: 25000}, (_, index) => record(index));
    await writeFile(path, values.map(value => JSON.stringify(value)).join("\n") + "\n");
    const records = await reader.read();
    assert.equal(records.length, values.length);
    assert.deepEqual(records[0], values[0]);
    assert.deepEqual(records.at(-1), values.at(-1));
    assert.equal(await reader.read(), records);
});

test("Shrinking or replacing the inode cannot reset accumulated evidence", async context => {
    const shrunk = await fixture(context);
    await writeFile(shrunk.path, line(record(1)));
    await shrunk.reader.read();
    await truncate(shrunk.path, 0);
    await assert.rejects(shrunk.reader.read(), /shrank/);
    const replaced = await fixture(context);
    await writeFile(replaced.path, line(record(1)));
    await replaced.reader.read();
    await rename(replaced.path, replaced.path + ".previous");
    await writeFile(replaced.path, await readFile(replaced.path + ".previous"));
    await assert.rejects(replaced.reader.read(), /identity changed/);
});

test("Disappearance after an empty or nonempty file has been observed is an error", async context => {
    for (const contents of ["", line(record(1))]) {
        const {path, reader} = await fixture(context);
        await writeFile(path, contents);
        await reader.read();
        await rm(path);
        await assert.rejects(reader.read(), /disappeared/);
    }
});

test("Symlink and directory evidence paths are rejected before content parsing", async context => {
    const linked = await fixture(context);
    const target = join(linked.directory, "target");
    await writeFile(target, line(record(1)));
    await symlink(target, linked.path);
    await assert.rejects(linked.reader.read());
    const directory = await fixture(context);
    await mkdir(directory.path);
    await assert.rejects(directory.reader.read(), /regular file/);
});

test("Reader configuration requires bounded positive limits and a concrete run identity", () => {
    for (const options of [{}, {runID: "../escape"}, {runID, maximumBytes: 0}, {runID, maximumBytes: Infinity},
        {runID, maximumEvents: 0}, {runID, maximumEvents: 1.5}]) {
        assert.throws(() => new NativeEvidenceReader("/fixture/events", options), /configuration/);
    }
});
