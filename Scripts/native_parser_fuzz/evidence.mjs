import {constants} from "node:fs";
import {lstat, open, realpath} from "node:fs/promises";
import {dirname, resolve} from "node:path";

export async function readStableFile(path, maximumBytes, {openFile = open, inspectPath = lstat} = {}) {
    if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 0 || resolve(path) !== path ||
        await realpath(dirname(path)) !== dirname(path)) { throw new Error("Evidence requires a canonical path and finite byte bound"); }
    const file = await openFile(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const before = await file.stat({bigint: true});
        if (!before.isFile() || before.size > BigInt(maximumBytes)) { throw new Error("Evidence is not a bounded regular file"); }
        const chunks = [];
        let count = 0;
        const buffer = Buffer.allocUnsafe(Math.min(65_536, maximumBytes + 1));
        while (true) {
            const {bytesRead} = await file.read(buffer, 0, Math.min(buffer.length, maximumBytes - count + 1), count);
            if (!bytesRead) { break; }
            count += bytesRead;
            if (count > maximumBytes || BigInt(count) > before.size) { throw new Error("Evidence grew beyond its bounded snapshot"); }
            chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
        }
        const [after, named] = await Promise.all([file.stat({bigint: true}), inspectPath(path, {bigint: true})]);
        if (BigInt(count) !== before.size || !named.isFile() || named.isSymbolicLink() ||
            ["dev", "ino", "size", "mtimeNs", "ctimeNs"].some(key => before[key] !== after[key] || before[key] !== named[key])) {
            throw new Error("Evidence changed while reading");
        }
        return Buffer.concat(chunks, count);
    } finally { await file.close(); }
}
