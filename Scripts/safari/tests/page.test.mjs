import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import vm from "node:vm";

const pageSource = await readFile(new URL("../page.js", import.meta.url), "utf8");

async function page(initialProviders = {}) {
    let now = 0;
    let nextTimer = 0;
    const timers = new Map();
    const reports = [];
    const window = {...initialProviders};
    const elements = new Map(["result", "actions", "provider-status"].map(id =>
        [id, {textContent: "Waiting for providers", append() {}}]));
    const config = {pageToken: "fixture-token", documentId: "fixture-document",
        scenario: {id: "nonce-editor", iteration: 1}};
    const origin = "http://127.0.0.1:12345";
    const schedule = (callback, delay, interval = 0) => {
        assert.ok(Number.isFinite(delay) && delay > 0);
        const id = ++nextTimer;
        timers.set(id, {callback, due: now + delay, interval});
        return id;
    };
    await vm.runInNewContext(pageSource, {
        window, location: {origin}, TextEncoder,
        document: {
            getElementById: id => elements.get(id),
            createElement: () => ({style: {}, setAttribute() {}, addEventListener() {}}),
        },
        setInterval: (callback, interval) => schedule(callback, interval, interval),
        clearInterval: id => timers.delete(id),
        setTimeout: (callback, delay) => schedule(callback, delay),
        fetch: async (url, options) => {
            if (url === "/page-config") { return {json: async () => config}; }
            assert.equal(url, "/page-result");
            assert.equal(options.method, "POST");
            assert.equal(options.headers["X-Page-Token"], config.pageToken);
            reports.push({time: now, value: JSON.parse(options.body)});
            return {ok: true};
        },
    });
    return {
        window,
        reports,
        status: () => elements.get("provider-status").textContent,
        async advanceTo(target) {
            assert.ok(target >= now);
            while (true) {
                const next = [...timers].sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
                if (!next || next[1].due > target) { break; }
                const [id, timer] = next;
                now = timer.due;
                if (timer.interval) { timer.due += timer.interval; }
                else { timers.delete(id); }
                timer.callback();
                await Promise.resolve();
            }
            now = target;
        },
        assertReadyAt(time) {
            assert.equal(this.status(), "Providers ready");
            assert.deepEqual(reports, [{time, value: {
                phase: "provider-ready", origin, documentId: config.documentId, scenario: config.scenario,
            }}]);
        },
    };
}

test("providers injected after the five-second diagnostic still report readiness within the controller deadline", async () => {
    const fixture = await page();
    await fixture.advanceTo(5000);
    assert.equal(fixture.status(), "provider-unavailable");
    assert.deepEqual(fixture.reports, []);
    await fixture.advanceTo(8500);
    fixture.window.ethereum = {};
    fixture.window.solana = {};
    await fixture.advanceTo(8600);
    fixture.assertReadyAt(8600);
    await fixture.advanceTo(20000);
    fixture.assertReadyAt(8600);
});

test("absent providers remain unavailable without manufacturing readiness", async () => {
    const fixture = await page();
    await fixture.advanceTo(5000);
    assert.equal(fixture.status(), "provider-unavailable");
    await fixture.advanceTo(20000);
    assert.equal(fixture.status(), "provider-unavailable");
    assert.deepEqual(fixture.reports, []);
});

test("one provider remains partial until the second provider arrives, then reports exactly once", async () => {
    const fixture = await page({ethereum: {}});
    await fixture.advanceTo(5000);
    assert.equal(fixture.status(), "provider-partial");
    assert.deepEqual(fixture.reports, []);
    await fixture.advanceTo(8500);
    fixture.window.bigwallet = {solana: {}};
    await fixture.advanceTo(8600);
    fixture.assertReadyAt(8600);
    await fixture.advanceTo(20000);
    fixture.assertReadyAt(8600);
});

test("providers ready before the diagnostic report once and retain their ready state", async () => {
    const fixture = await page({ethereum: {}, bigwallet: {solana: {}}});
    await fixture.advanceTo(100);
    fixture.assertReadyAt(100);
    await fixture.advanceTo(20000);
    fixture.assertReadyAt(100);
});
