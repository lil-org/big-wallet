import {constants} from "node:fs";
import {lstat, open} from "node:fs/promises";

const chunkBytes = 64 * 1024;

export class NativeEvidenceReader {
    constructor(path, {runID, maximumBytes = 128 * 1024 * 1024, maximumEvents = 200000} = {}) {
        if (typeof path !== "string" || !path.length || path.includes("\0") ||
            typeof runID !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runID) || runID.includes("..") ||
            !Number.isSafeInteger(maximumBytes) || maximumBytes < 1 ||
            !Number.isSafeInteger(maximumEvents) || maximumEvents < 1) {
            throw new Error("Invalid native evidence reader configuration");
        }
        this.path = path;
        this.runID = runID;
        this.maximumBytes = maximumBytes;
        this.maximumEvents = maximumEvents;
        this.records = [];
        this.offset = 0;
        this.observedSize = 0n;
        this.identity = null;
        this.pending = [];
        this.pendingBytes = 0;
        this.decoder = new TextDecoder("utf-8", {fatal: true});
        this.inflight = null;
        this.failure = null;
    }

    read() {
        if (this.inflight) { return this.inflight; }
        if (this.failure) { return Promise.reject(this.failure); }
        this.inflight = this.readAvailable().catch(error => {
            this.failure = error;
            throw error;
        }).finally(() => { this.inflight = null; });
        return this.inflight;
    }

    async finish() {
        const records = await this.read();
        if (this.pendingBytes) {
            this.failure = new Error("Native evidence ended with an incomplete record");
            throw this.failure;
        }
        return records;
    }

    verify(info) {
        if (!info.isFile() || info.isSymbolicLink()) { throw new Error("Native evidence must remain a regular file without symlinks"); }
        if (this.identity && (info.dev !== this.identity.dev || info.ino !== this.identity.ino)) {
            throw new Error("Native evidence file identity changed");
        }
        if (info.size < this.observedSize || info.size < BigInt(this.offset)) { throw new Error("Native evidence file shrank"); }
        if (info.size > BigInt(this.maximumBytes)) { throw new Error("Native evidence exceeded its byte budget"); }
        this.identity ??= {dev: info.dev, ino: info.ino};
        this.observedSize = info.size;
    }

    append(bytes) {
        let offset = 0;
        while (offset < bytes.length) {
            let part = this.pending.at(-1);
            if (!part || part.used === part.buffer.length) {
                part = {buffer: Buffer.allocUnsafe(Math.min(chunkBytes, this.maximumBytes)), used: 0};
                this.pending.push(part);
            }
            const count = Math.min(bytes.length - offset, part.buffer.length - part.used);
            bytes.copy(part.buffer, part.used, offset, offset + count);
            part.used += count;
            this.pendingBytes += count;
            offset += count;
        }
    }

    complete(bytes) {
        if (this.records.length >= this.maximumEvents) { throw new Error("Native evidence exceeded its event budget"); }
        let data = bytes;
        if (this.pendingBytes) {
            this.append(bytes);
            data = this.pending.length === 1 ? this.pending[0].buffer.subarray(0, this.pending[0].used)
                : Buffer.concat(this.pending.map(part => part.buffer.subarray(0, part.used)), this.pendingBytes);
        }
        let record;
        try { record = JSON.parse(this.decoder.decode(data)); }
        catch { throw new Error(`Malformed complete native evidence record at index ${this.records.length}`); }
        if (!record || typeof record !== "object" || Array.isArray(record)) {
            throw new Error(`Invalid native evidence record at index ${this.records.length}`);
        }
        if (record.runID !== this.runID) { throw new Error("Native evidence belongs to a different VM run"); }
        this.records.push(record);
        this.pending = [];
        this.pendingBytes = 0;
    }

    consume(bytes) {
        let offset = 0;
        while (offset < bytes.length) {
            const newline = bytes.indexOf(10, offset);
            if (newline < 0) { this.append(bytes.subarray(offset)); return; }
            this.complete(bytes.subarray(offset, newline));
            offset = newline + 1;
        }
    }

    async readAvailable() {
        let file;
        try { file = await open(this.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK); }
        catch (error) {
            if (error.code === "ENOENT" && !this.identity) { return this.records; }
            if (error.code === "ENOENT") { throw new Error("Native evidence disappeared after reading began"); }
            throw error;
        }
        try {
            const initial = await file.stat({bigint: true});
            this.verify(initial);
            const end = Number(initial.size);
            const buffer = Buffer.allocUnsafe(Math.min(chunkBytes, Math.max(1, end - this.offset)));
            while (this.offset < end) {
                const {bytesRead} = await file.read(buffer, 0, Math.min(buffer.length, end - this.offset), this.offset);
                if (!bytesRead) { throw new Error("Native evidence shrank during reading"); }
                this.offset += bytesRead;
                this.consume(buffer.subarray(0, bytesRead));
            }
            this.verify(await file.stat({bigint: true}));
            try { this.verify(await lstat(this.path, {bigint: true})); }
            catch (error) {
                if (error.code === "ENOENT") { throw new Error("Native evidence disappeared during reading"); }
                throw error;
            }
            return this.records;
        } finally { await file.close(); }
    }
}
