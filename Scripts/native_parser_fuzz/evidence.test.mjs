import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, open, realpath, rename, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {promisify} from "node:util";
import test from "node:test";
import {readStableFile} from "./evidence.mjs";

async function fixture(run) {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "parser-fuzz-evidence-test-")));
    try { await run(directory); }
    finally { await rm(directory, {recursive: true, force: true}); }
}

function changeOnRead(change) {
    return {openFile: async (...arguments_) => {
        const file = await open(...arguments_);
        let changed = false;
        return {stat: options => file.stat(options), close: () => file.close(), read: async (...args) => {
            if (!changed) { changed = true; await change(); }
            return await file.read(...args);
        }};
    }};
}

test("descriptor reader accepts exact bounds and empty files", async () => fixture(async directory => {
    const path = join(directory, "input");
    await writeFile(path, "abc"); assert.equal((await readStableFile(path, 3)).toString(), "abc");
    await assert.rejects(readStableFile(path, 2));
    await writeFile(path, ""); assert.equal((await readStableFile(path, 0)).length, 0);
}));

test("descriptor reader never follows a symlink substituted after opening", async () => fixture(async directory => {
    const path = join(directory, "input"), target = join(directory, "target");
    await writeFile(path, "original"); await writeFile(target, "other");
    await assert.rejects(readStableFile(path, 100, changeOnRead(async () => {
        await rename(path, join(directory, "original")); await symlink(target, path);
    })), /changed/);
    await assert.rejects(readStableFile(path, 100));
}));

test("descriptor reader rejects regular replacement and growth during reads", async () => fixture(async directory => {
    const path = join(directory, "input");
    await writeFile(path, "original");
    await assert.rejects(readStableFile(path, 100, changeOnRead(async () => {
        const replacement = join(directory, "replacement"); await writeFile(replacement, "original"); await rename(replacement, path);
    })), /changed/);
    await writeFile(path, "abc");
    await assert.rejects(readStableFile(path, 3, changeOnRead(() => writeFile(path, "abcdef"))), /bounded|changed/);
}));

test("FIFO evidence fails without waiting for a writer", {timeout: 5_000}, async () => fixture(async directory => {
    const path = join(directory, "fifo");
    await promisify(execFile)("/usr/bin/mkfifo", [path]);
    await assert.rejects(readStableFile(path, 100), /regular/);
}));
