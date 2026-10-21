import {createServer} from "node:http";
import {randomBytes} from "node:crypto";
import {writeFile, unlink, realpath, readFile} from "node:fs/promises";
import {join} from "node:path";
import {isDeepStrictEqual} from "node:util";

const page = `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Prepare Wallet for Safari tests</title>
<style>body{font:17px system-ui;max-width:720px;margin:64px auto;padding:0 24px;line-height:1.55;color:#202124}h1{font-size:30px}button{font:inherit;padding:10px 16px;margin:8px 8px 8px 0}#status{padding:16px;background:#eef1f5;border-radius:8px}li{margin:12px 0}</style>
<h1>Prepare Wallet for Safari tests</h1>
<p>This window belongs to the isolated test VM. XCTest is not running.</p>
<ol><li>In Safari Settings → Advanced, turn on “Show features for web developers”. Return here and copy the guest password immediately before enabling “Allow unsigned extensions” in Developer settings. The clipboard expires after 30 seconds. Paste into Safari’s password field if asked.</li>
<li>Return here and rebuild the extension while Safari stays open.</li>
<li>In Safari Settings → Extensions, select the checkbox beside Wallet. Leave the extension enabled. Preparation finishes automatically only after the containing app reports that Safari enabled it.</li></ol>
<button id="password">Copy guest password</button><button id="refresh">Rebuild and open extension settings</button>
<p id="status" role="status">Connecting to the preparation controller…</p>
<script>
const token=location.hash.slice(1);history.replaceState(null,"",location.pathname);
const status=document.getElementById("status");const buttons=[...document.querySelectorAll("button")];
async function call(path){const response=await fetch(path,{method:path==="/status"?"GET":"POST",headers:{"X-Wallet-Preparation":token},cache:"no-store"});const value=await response.json();if(!response.ok)throw new Error(value.error||"Preparation request failed");return value}
document.getElementById("password").onclick=()=>call("/password").then(()=>status.textContent="The guest password is on the guest clipboard for 30 seconds. Paste it into Safari’s authorization sheet.").catch(error=>status.textContent=error.message);
document.getElementById("refresh").onclick=()=>{buttons.forEach(button=>button.disabled=true);status.textContent="Rebuilding the current extension. Keep Safari open.";call("/refresh").then(()=>status.textContent="Now enable Wallet in Safari Settings → Extensions.").catch(error=>status.textContent=error.message).finally(()=>buttons.forEach(button=>button.disabled=false))};
let timer=setInterval(async()=>{try{const value=await call("/status");if(value.complete){clearInterval(timer);buttons.forEach(button=>button.disabled=true);status.textContent="Safari reported Wallet enabled. Verifying the prepared installation and stopping its native processes…"}else if(!value.busy){status.textContent=value.message}}catch(error){clearInterval(timer);status.textContent="The preparation controller is no longer available. Check the runner result."}},1000);
</script></html>`;

function preparationLaunches(events, {offset, runID, executablePath, notBefore}) {
    return events.slice(offset).filter(record => record.kind === "processStarted" && record.runID === runID &&
        Number.isSafeInteger(record.processID) && record.processID > 1 && typeof record.incarnation === "string" &&
        record.role === "app" && record.bundleID === "org.lil.wallet" && record.executablePath === executablePath &&
        Number.isFinite(record.time) && record.time * 1000 >= notBefore);
}

function findPreparationState(events, options) {
    const {offset, runID, nonce, notBefore} = options;
    const current = events.slice(offset);
    const launches = preparationLaunches(events, options);
    for (const event of [...current].reverse()) {
        if (event.kind !== "safariExtensionState" || event.runID !== runID || event.preparationNonce !== nonce ||
            !Number.isSafeInteger(event.processID) || event.processID <= 1 ||
            !Number.isFinite(event.time) || event.time * 1000 < notBefore) { continue; }
        if (launches.some(record => record.processID === event.processID && record.incarnation === event.incarnation &&
            record.time <= event.time)) { return event; }
    }
    return null;
}

export function findPreparationObservation(events, options) {
    const event = findPreparationState(events, options);
    if (!event || event.enabled !== true || event.errorDomain !== null || event.errorCode !== null) { return null; }
    return {enabled: true, processID: event.processID, executablePath: options.executablePath, preparationNonce: options.nonce,
        observedAt: new Date(event.time * 1000).toISOString()};
}

async function requireLivePreparationProbe(server, processID, executablePath, canonicalPath = realpath) {
    const livePath = await server.processInspector(processID);
    if (livePath === null) { throw new Error("The Safari preparation app terminated before activation completed"); }
    if (!server.allowedExecutables.has(executablePath) || await canonicalPath(livePath) !== await canonicalPath(executablePath)) {
        throw new Error("The Safari preparation app process identity changed");
    }
}

export async function waitForPreparationProbe({server, observation, check, deadline, now = Date.now,
    wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)), canonicalPath = realpath}) {
    while (now() < deadline) {
        check();
        const events = await server.nativeEvents();
        const launches = preparationLaunches(events, observation);
        const identities = new Map(launches.map(record => [`${record.processID}:${record.incarnation}`, record]));
        if (identities.size > 1) { throw new Error("More than one Safari preparation app started for the current launch"); }
        const launched = [...identities.values()][0];
        if (launched) {
            await requireLivePreparationProbe(server, launched.processID, observation.executablePath, canonicalPath);
            const state = findPreparationState(events, observation);
            if (state) {
                const success = typeof state.enabled === "boolean" && state.errorDomain === null && state.errorCode === null;
                const failure = state.enabled === null && typeof state.errorDomain === "string" && state.errorDomain.length > 0 &&
                    state.errorDomain.length <= 128 && Number.isSafeInteger(state.errorCode);
                if (!success && !failure) { throw new Error("The Safari preparation app returned an invalid public state response"); }
                check();
                if (now() >= deadline) { break; }
                return {processID: launched.processID, incarnation: launched.incarnation};
            }
        }
        await wait(250);
    }
    throw new Error("The Safari preparation app did not return a fresh public state response within 15 seconds");
}

export function preparationRequestAllowed(request, origin, token) {
    return request.headers.host === new URL(origin).host &&
        request.headers["x-wallet-preparation"] === token &&
        (request.method === "GET" || request.method === "POST" && request.headers.origin === origin) &&
        (request.headers["sec-fetch-site"] === undefined || request.headers["sec-fetch-site"] === "same-origin");
}

export async function runSafariPreparation({server, descriptor, nonce, paths, command, refresh, signatures,
    requireRunning, progress = async () => {}, deadline = Date.now() + 900000, now = Date.now,
    wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))}) {
    if (!Number.isFinite(deadline) || deadline <= now() || deadline > now() + 900000 ||
        server.preparationNonce !== nonce || descriptor.platform !== "macos" || descriptor.signingMode !== "local") {
        throw new Error("Invalid Safari activation preparation session");
    }
    const marker = join(descriptor.root, "activation-preparation.json");
    const markerBytes = JSON.stringify({version: 1, runID: descriptor.runID, nonce, showPreferences: true});
    let markerCreated = false;
    const token = randomBytes(32).toString("hex");
    const appExecutable = join(paths.app, "Contents/MacOS/Big Wallet");
    let offset = (await server.nativeEvents()).length;
    let notBefore = now();
    let expectedSignatures;
    let probe;
    let nextProbeCheck = 0;
    let refreshCount = 0;
    let busy = false;
    let complete = false;
    let failure;
    let origin;
    let pendingAction = Promise.resolve();
    const send = (response, status, value, html = false) => {
        response.writeHead(status, {"Content-Type": html ? "text/html; charset=utf-8" : "application/json",
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
            "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"});
        response.end(html ? value : JSON.stringify(value));
    };
    const check = () => {
        requireRunning();
        if (now() >= deadline) { throw new Error("Safari activation preparation timed out after 15 minutes"); }
        if (failure) { throw failure; }
    };
    const launchApp = async () => {
        check();
        probe = null;
        offset = (await server.nativeEvents()).length;
        notBefore = now();
        await command("/usr/bin/open", ["-n", paths.app], {capture: true, captureStderr: true, timeoutSeconds: 15});
        probe = await waitForPreparationProbe({server, observation: {offset, runID: descriptor.runID, nonce,
            executablePath: appExecutable, notBefore}, check, deadline: Math.min(deadline, now() + 15000), now, wait});
        nextProbeCheck = now() + 1000;
    };
    const http = createServer((request, response) => {
        const handle = async () => {
            if (request.method === "GET" && request.url === "/" && request.headers.host === new URL(origin).host) {
                send(response, 200, page, true); return;
            }
            if (!preparationRequestAllowed(request, origin, token)) { send(response, 403, {error: "Preparation control authentication required"}); return; }
            check();
            if (request.method === "GET" && request.url === "/status") {
                send(response, 200, {complete, busy, message: refreshCount
                    ? "Enable Wallet in Safari Settings → Extensions. Waiting for Safari’s public enabled-state report."
                    : "Enable Allow unsigned extensions in Safari’s Developer settings, then rebuild here."}); return;
            }
            if (request.method !== "POST" || !["/refresh", "/password"].includes(request.url) ||
                request.headers["content-length"] && request.headers["content-length"] !== "0" || request.headers["transfer-encoding"]) {
                send(response, 400, {error: "Invalid preparation action"}); return;
            }
            if (busy || complete) { send(response, 409, {error: "Preparation is busy or already complete"}); return; }
            if (request.url === "/password") {
                busy = true;
                pendingAction = server.stagePreparationGuestCredential(nonce);
            } else {
                if (refreshCount >= 6) { send(response, 409, {error: "Preparation rebuild limit reached"}); return; }
                busy = true;
                pendingAction = (async () => {
                    await server.clearGuestCredential();
                    await refresh(Math.min(deadline, now() + 150000));
                    check();
                    expectedSignatures = await signatures(paths);
                    refreshCount += 1;
                    await launchApp();
                    await progress({phase: "refreshed", refreshCount});
                })();
            }
            try { await pendingAction; send(response, 200, {completed: true}); }
            catch (error) { failure = error; send(response, 400, {error: "Preparation action failed; inspect the runner diagnostics"}); }
            finally { busy = false; }
        };
        handle().catch(error => {
            failure ??= error;
            if (!response.headersSent) { send(response, 400, {error: "Preparation controller failed"}); }
            else { response.destroy(); }
        });
    });
    try {
        await writeFile(marker, markerBytes, {mode: 0o600, flag: "wx"});
        markerCreated = true;
        await new Promise((resolve, reject) => { http.once("error", reject); http.listen(0, "127.0.0.1", resolve); });
        origin = `http://127.0.0.1:${http.address().port}`;
        await command("/usr/bin/open", ["-a", "/Applications/Safari.app", `${origin}/#${token}`],
            {capture: true, captureStderr: true, timeoutSeconds: 15});
        busy = true;
        await launchApp();
        busy = false;
        await progress({phase: "ready-for-user", refreshCount});
        process.stdout.write("Safari preparation is ready in the guest browser. Enable Allow unsigned extensions, use the local preparation page to rebuild, then enable Wallet. No XCTest session is running.\n");
        while (!complete) {
            check();
            if (probe && !busy && now() >= nextProbeCheck) {
                await requireLivePreparationProbe(server, probe.processID, appExecutable);
                nextProbeCheck = now() + 1000;
            }
            if (refreshCount && !busy) {
                let observation = findPreparationObservation(await server.nativeEvents(), {
                    offset, runID: descriptor.runID, nonce, executablePath: appExecutable, notBefore,
                });
                if (observation) {
                    const livePath = await server.processInspector(observation.processID);
                    if (livePath !== null && await realpath(livePath) === await realpath(appExecutable) &&
                        server.allowedExecutables.has(appExecutable)) {
                        const currentSignatures = await signatures(paths);
                        check();
                        if (!isDeepStrictEqual(currentSignatures, expectedSignatures)) { throw new Error("Safari products changed after the preparation rebuild"); }
                        const latest = findPreparationObservation(await server.nativeEvents(), {
                            offset, runID: descriptor.runID, nonce, executablePath: appExecutable, notBefore,
                        });
                        if (!latest || latest.processID !== observation.processID) { continue; }
                        observation = latest;
                        complete = true;
                        await progress({phase: "enabled", refreshCount, enabledObservation: observation});
                        await command("/usr/bin/osascript", ["-e", 'tell application id "com.apple.Safari" to quit'],
                            {capture: true, captureStderr: true, timeoutSeconds: 15});
                        check();
                        return {enabledObservation: observation, signatures: currentSignatures};
                    }
                }
            }
            await wait(250);
        }
        throw new Error("Safari activation preparation ended without observation");
    } catch (error) {
        error.message = String(error.message).replaceAll(token, "<redacted>");
        throw error;
    } finally {
        try { await pendingAction; } catch {}
        http.closeAllConnections();
        await new Promise(resolve => http.close(resolve));
        if (markerCreated) {
            if (await readFile(marker, "utf8") !== markerBytes) { throw new Error("Safari activation preparation marker changed"); }
            await unlink(marker);
        }
    }
}
