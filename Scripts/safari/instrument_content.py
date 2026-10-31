from pathlib import Path
import sys


DIAGNOSTIC = r'''
var safariVMContentDiagnostic = safariVMContentDiagnostic || (() => {
    const records = [];
    let element;
    let sequence = 0;
    let dumpRequested = false;
    let workerDump = null;
    const dumpSubject = "safariVMConfigurationDiagnostics";
    const types = ["undefined", "null", "array", "object", "string", "boolean", "number", "bigint", "symbol", "function", "accessor"];
    const kinds = ["configuration", "configurationError", "result", "error", "other", "missing"];
    const privacy = ["private", "normal", "unknown"];
    const type = value => value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
    function property(value, key) {
        if (value === null || !["object", "function"].includes(typeof value)) { return {type: "missing"}; }
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (!descriptor) { return {type: "missing"}; }
        return Object.prototype.hasOwnProperty.call(descriptor, "value")
            ? {type: type(descriptor.value), value: descriptor.value} : {type: "accessor"};
    }
    function rawShape(value) {
        const kind = property(value, "kind");
        const error = property(value, "error");
        const code = property(error.value, "code");
        return {rawType: type(value), rawKind: kind.type === "missing" || kind.type === "accessor" ? kind.type
            : ["configuration", "configurationError", "result", "error"].includes(kind.value) ? kind.value : "other",
            rawStateType: property(value, "state").type, rawErrorType: error.type,
            rawErrorCode: Number.isSafeInteger(code.value) ? code.value : null,
            rawMessageType: property(error.value, "message").type};
    }
    function checkedObject(value, fields) {
        if (type(value) !== "object" || Reflect.ownKeys(value).length !== Object.keys(fields).length) { throw new Error(); }
        const result = {};
        for (const [key, validate] of Object.entries(fields)) {
            const entry = property(value, key);
            if (["missing", "accessor"].includes(entry.type) || !validate(entry.value)) { throw new Error(); }
            result[key] = entry.value;
        }
        return result;
    }
    const boolean = value => typeof value === "boolean";
    const timestamp = value => Number.isSafeInteger(value) && value >= 0;
    const nullableBoolean = value => value === null || boolean(value);
    function checkedDump(value) {
        try {
            const dump = checkedObject(value, {
                kind: value => value === dumpSubject, version: value => value === 1,
                status: value => ["ok", "rejected"].includes(value), startedAt: timestamp, dropped: boolean,
                query: value => type(value) === "object", records: Array.isArray,
            });
            dump.query = checkedObject(dump.query, {idMatches: boolean, tabIDValid: boolean,
                frameIDValid: boolean, documentIDValid: boolean});
            const count = property(dump.records, "length").value;
            if (!Number.isInteger(count) || count < 0 || count > 12 ||
                Reflect.ownKeys(dump.records).length !== count + 1 ||
                dump.status === "rejected" && count !== 0 ||
                dump.status === "ok" && Object.values(dump.query).some(value => !value)) { return null; }
            const checked = [];
            for (let index = 0; index < count; index++) {
                checked.push(checkedObject(property(dump.records, String(index)).value, {
                    sequence: value => Number.isSafeInteger(value) && value > 0, at: timestamp,
                    authorized: boolean, idMatches: boolean, idType: value => types.includes(value),
                    urlType: value => types.includes(value), tabType: value => types.includes(value),
                    tabIDValid: boolean, frameIDValid: boolean, topFrame: boolean, documentIDType: value => types.includes(value),
                    documentIDValid: boolean, originType: value => types.includes(value), originMatches: nullableBoolean,
                    senderPrivacyType: value => types.includes(value), tabPrivacyType: value => types.includes(value),
                    senderPrivacy: value => privacy.includes(value), tabPrivacy: value => privacy.includes(value),
                    requestValid: nullableBoolean,
                    contextPrivacy: value => ["private", "normal", "unavailable", "unobserved"].includes(value),
                    outcome: value => ["authorization-rejected", "pending", "response", "thrown"].includes(value),
                    responseArgumentCount: value => value === null || value === 0 || value === 1,
                    responseType: value => value === null || types.includes(value),
                    responseKind: value => value === null || kinds.includes(value),
                }));
            }
            dump.records = checked;
            return dump;
        } catch { return null; }
    }
    function render() {
        try {
            if (!element) { return; }
            const text = "Safari VM transport: " + JSON.stringify(records);
            const displayed = workerDump?.response ? {...workerDump, response: {...workerDump.response,
                records: [...workerDump.response.records]}} : workerDump;
            let workerText = displayed ? "\nSafari VM worker: " + JSON.stringify(displayed) : "";
            while (text.length + workerText.length > 10_000 && displayed?.response?.records.length) {
                displayed.response.records.shift();
                displayed.response.dropped = true;
                workerText = "\nSafari VM worker: " + JSON.stringify(displayed);
            }
            element.textContent = text + workerText;
        } catch {}
    }
    return {
        outcome(error, returned) {
            if (!returned) { return "sync-throw"; }
            try { return error?.name === "TimeoutError" ? "timeout" : "rejected"; }
            catch { return "rejected"; }
        },
        record(attempt, serial, startedAt, outcome, response, decoded, identityValid, generationValid) {
            try {
                records.push({sequence: ++sequence, attempt, serial, startedAt,
                    elapsed: Math.max(0, Date.now() - startedAt), outcome,
                    replyKind: decoded?.kind ?? "invalid",
                    errorCode: Number.isSafeInteger(decoded?.error?.code) ? decoded.error.code : null,
                    identityValid, generationValid, ...rawShape(response)});
                if (records.length > 12) { records.shift(); }
                render();
            } catch {}
        },
        fail() {
            try {
                if (!element) {
                    element = document.createElement("div");
                    element.id = "safari-vm-content-diagnostics";
                    element.setAttribute("role", "status");
                    element.style.cssText = "font:10px monospace;white-space:pre-wrap;overflow-wrap:anywhere";
                    (document.body || document.documentElement).appendChild(element);
                }
                render();
            } catch {}
        },
        dump() {
            if (dumpRequested) { return; }
            dumpRequested = true;
            workerDump = {status: "pending"};
            render();
            try {
                const pending = browser.runtime.sendMessage({subject: dumpSubject});
                Promise.resolve(pending).then(value => {
                    const response = checkedDump(value);
                    workerDump = response ? {status: "response", response} : {status: "invalid-response"};
                    if (!response) {
                        try { workerDump = {status: "invalid-response", ...rawShape(value)}; } catch {}
                    }
                    render();
                }, () => {
                    workerDump = {status: "transport-rejected"};
                    render();
                });
            } catch {
                workerDump = {status: "sync-throw"};
                render();
            }
        },
    };
})();
'''

REPLACEMENTS = [(
'''async function bigWalletReadConfiguration(generation, attempt, serial) {
    const identity = bigWalletCurrentIdentity();
    let response;
    try {
        response = await bigWalletWire.withTimeout(bigWalletSendRuntimeMessage({
            subject: "getLatestConfiguration", workflowVersion: bigWalletWorkflowVersion,
        }), bigWalletTransportTimeout);
    } catch {}
    if (!bigWalletMatchesGeneration(generation)) { return; }
    const decoded = bigWalletWire.decodePageResponse(response);''',
'''async function bigWalletReadConfiguration(generation, attempt, serial) {
    const identity = bigWalletCurrentIdentity();
    const diagnosticStartedAt = Date.now();
    let diagnosticOutcome = "response";
    let diagnosticReturned = false;
    let response;
    try {
        const pending = bigWalletSendRuntimeMessage({
            subject: "getLatestConfiguration", workflowVersion: bigWalletWorkflowVersion,
        });
        diagnosticReturned = true;
        response = await bigWalletWire.withTimeout(pending, bigWalletTransportTimeout);
    } catch (error) {
        diagnosticOutcome = safariVMContentDiagnostic.outcome(error, diagnosticReturned);
    }
    if (!bigWalletMatchesGeneration(generation)) {
        safariVMContentDiagnostic.record(attempt, serial, diagnosticStartedAt, diagnosticOutcome, response, null, !!identity, false);
        return;
    }
    const decoded = bigWalletWire.decodePageResponse(response);
    safariVMContentDiagnostic.record(attempt, serial, diagnosticStartedAt, diagnosticOutcome, response, decoded, !!identity, true);'''), (
'''    if (bigWalletHasAcceptedConfiguration(generation, identity?.configurationKey)) { return; }
    window.postMessage({direction: bigWalletContentDirection, kind: "response",
        response: unsupported ? decoded : {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}},
        providerGeneration: generation}, "*");''',
'''    if (bigWalletHasAcceptedConfiguration(generation, identity?.configurationKey)) { return; }
    window.postMessage({direction: bigWalletContentDirection, kind: "response",
        response: unsupported ? decoded : {kind: "configurationError", error: {code: 4900, message: "Failed to communicate with Big Wallet"}},
        providerGeneration: generation}, "*");
    safariVMContentDiagnostic.fail();
    if (!unsupported) { safariVMContentDiagnostic.dump(); }''')]


def instrument(source):
    if "safariVMContentDiagnostic" in source:
        raise ValueError("Content source already contains fixture diagnostics")
    for original, replacement in REPLACEMENTS:
        if source.count(original) != 1:
            raise ValueError("Content diagnostic source anchor changed")
        source = source.replace(original, replacement, 1)
    return DIAGNOSTIC + source


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("fixture", "ordinary"):
        raise ValueError("Expected content source, output, and fixture or ordinary mode")
    source, output = map(Path, sys.argv[1:3])
    if output.is_symlink() or not output.is_file() or source.resolve() == output.resolve():
        raise ValueError("Invalid bundled content output")
    text = source.read_text()
    output.write_text(instrument(text) if sys.argv[3] == "fixture" else text)


if __name__ == "__main__":
    main()
