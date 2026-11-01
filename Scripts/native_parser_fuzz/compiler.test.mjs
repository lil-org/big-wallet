import assert from "node:assert/strict";
import {mkdir, mkdtemp, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {addressInstrumentationEnabled, canaryCompileArguments, captureCompilerResponses, compilerArguments, expandCompilerArguments} from "./compiler.mjs";

const source = "/workspace/Sources/ParserFuzzCanaries/Canaries.c";

test("compiler argument decoding handles Xcode escapes and quoted response paths", () => {
    assert.deepEqual(compilerArguments(String.raw`clang -fsanitize\=address @"/cache/build arguments.resp" -c '/workspace path/Canaries.c'`),
        ["clang", "-fsanitize=address", "@/cache/build arguments.resp", "-c", "/workspace path/Canaries.c"]);
    assert.throws(() => compilerArguments('"unfinished'));
    const line = ` /usr/bin/clang -c ${source} @/cache/common.resp -o /cache/Canaries.o`;
    assert.deepEqual(canaryCompileArguments(`builtin-ScanDependencies --${line}\n${line}`),
        ["-c", source, "@/cache/common.resp", "-o", "/cache/Canaries.o"]);
    assert.throws(() => canaryCompileArguments(`${line}\n${line}`));
});

test("response expansion proves actual flags rather than an ASan-looking directory name", () => {
    const args = ["@/cache/Objects-normal-asan/common.resp", "-c", source];
    const responses = new Map([["Objects-normal-asan/common.resp", Buffer.from("-target arm64-apple-macos15.0 -O0")]]);
    assert.equal(addressInstrumentationEnabled(expandCompilerArguments(args, "/cache", responses)), false);
    responses.set("Objects-normal-asan/common.resp", Buffer.from(String.raw`-fsanitize\=address -O0`));
    assert.equal(addressInstrumentationEnabled(expandCompilerArguments(args, "/cache", responses)), true);
    assert.equal(addressInstrumentationEnabled(["-fsanitize=undefined,address", "-fno-sanitize=address"]), false);
    assert.equal(addressInstrumentationEnabled(["-fsanitize=address", "-fno-sanitize=all"]), false);
});

test("response expansion rejects missing unused escaping and recursive evidence", () => {
    assert.throws(() => expandCompilerArguments(["@/outside/args"], "/cache", new Map()));
    assert.throws(() => expandCompilerArguments(["@/cache/../args"], "/cache", new Map()));
    assert.throws(() => expandCompilerArguments(["@/cache/args"], "/cache", new Map()));
    assert.throws(() => expandCompilerArguments(["-fsanitize=address"], "/cache", new Map([["unused", Buffer.from("-O0")]])));
    assert.throws(() => expandCompilerArguments(["@/cache/args"], "/cache", new Map([["args", Buffer.from("@/cache/args")]])));
});

test("response capture retains only bounded direct cache files", async () => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "parser-compiler-response-test-")));
    const cache = join(directory, "cache space");
    try {
        await mkdir(cache);
        const path = join(cache, "args.resp");
        await writeFile(path, "-fsanitize=address -O0");
        const log = `/usr/bin/clang @"${path}" -c ${source}`;
        const captured = await captureCompilerResponses(log, cache);
        assert.equal(captured.get("args.resp").toString(), "-fsanitize=address -O0");
        await rm(path); await symlink(join(directory, "outside"), path); await writeFile(join(directory, "outside"), "-fsanitize=address");
        await assert.rejects(captureCompilerResponses(log, cache));
    } finally { await rm(directory, {recursive: true, force: true}); }
});
