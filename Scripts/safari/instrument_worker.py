from pathlib import Path
import sys


DIAGNOSTIC = r'''
const safariVMWorkerDiagnostic = (() => {
    const records = [];
    let sequence = 0;
    let dropped = false;
    function timestamp() {
        try {
            const value = Date.now();
            return Number.isSafeInteger(value) && value >= 0 ? value : 0;
        } catch { return 0; }
    }
    const startedAt = timestamp();
    function type(value) {
        return value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
    }
    function field(value, key) {
        if (value === null || !["object", "function"].includes(typeof value)) {
            return {type: "undefined", value: undefined};
        }
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        if (!descriptor) { return {type: "undefined", value: undefined}; }
        return Object.hasOwn(descriptor, "value") ? {type: type(descriptor.value), value: descriptor.value}
            : {type: "accessor", value: undefined};
    }
    function privacy(value) {
        return value === true ? "private" : value === false ? "normal" : "unknown";
    }
    function scope(sender, runtime) {
        const id = field(sender, "id"), extensionID = runtime.id;
        const tab = field(sender, "tab"), tabID = field(tab.value, "id");
        const frameID = field(sender, "frameId"), documentID = field(sender, "documentId");
        const query = {
            idMatches: typeof extensionID === "string" && extensionID.length > 0 &&
                id.type === "string" && id.value === extensionID,
            tabIDValid: Number.isSafeInteger(tabID.value) && tabID.value >= 0,
            frameIDValid: Number.isSafeInteger(frameID.value) && frameID.value >= 0,
            documentIDValid: documentID.type === "string" && documentID.value.length > 0 && documentID.value.length <= 128,
        };
        return {query, id, tab, frameID, documentID,
            key: query.idMatches && query.tabIDValid && query.frameIDValid && query.documentIDValid
                ? [id.value, tabID.value, frameID.value, documentID.value] : null};
    }
    function emptyQuery() {
        return {idMatches: false, tabIDValid: false, frameIDValid: false, documentIDValid: false};
    }
    return {
        isDump(request) {
            try {
                return type(request) === "object" && Reflect.ownKeys(request).length === 1 &&
                    field(request, "subject").value === "safariVMConfigurationDiagnostics";
            } catch { return false; }
        },
        dump(sender, runtime) {
            let query = emptyQuery();
            try {
                const observed = scope(sender, runtime);
                query = observed.query;
                return {kind: "safariVMConfigurationDiagnostics", version: 1,
                    status: observed.key ? "ok" : "rejected", startedAt, dropped, query,
                    records: observed.key ? records.filter(entry => entry.key &&
                        entry.key.every((value, index) => value === observed.key[index]))
                        .slice(-12).map(entry => ({...entry.record})) : []};
            } catch {
                return {kind: "safariVMConfigurationDiagnostics", version: 1,
                    status: "rejected", startedAt, dropped, query, records: []};
            }
        },
        begin(request, sender, context, runtime) {
            try {
                if (field(request, "subject").value !== "getLatestConfiguration") { return undefined; }
                const observed = scope(sender, runtime);
                const url = field(sender, "url"), origin = field(sender, "origin");
                const senderPrivacy = field(sender, "incognito"), tabPrivacy = field(observed.tab.value, "incognito");
                const identity = context ? field(context, "identity").value
                    : url.type === "string" ? WIRE.configurationIdentityForURL(url.value) : null;
                const configurationKey = field(identity, "configurationKey");
                sequence = Math.min(sequence + 1, Number.MAX_SAFE_INTEGER);
                const record = {sequence, at: timestamp(), authorized: !!context,
                    idMatches: observed.query.idMatches, idType: observed.id.type, urlType: url.type,
                    tabType: observed.tab.type, tabIDValid: observed.query.tabIDValid,
                    frameIDValid: observed.query.frameIDValid, topFrame: observed.frameID.value === 0,
                    documentIDType: observed.documentID.type,
                    documentIDValid: observed.query.documentIDValid, originType: origin.type,
                    originMatches: origin.type === "string" && configurationKey.type === "string"
                        ? origin.value === configurationKey.value : null,
                    senderPrivacyType: senderPrivacy.type, senderPrivacy: privacy(senderPrivacy.value),
                    tabPrivacyType: tabPrivacy.type, tabPrivacy: privacy(tabPrivacy.value),
                    requestValid: null, contextPrivacy: "unobserved",
                    outcome: context ? "pending" : "authorization-rejected",
                    responseArgumentCount: null, responseType: null, responseKind: null};
                records.push({key: observed.key, record});
                if (records.length > 12) { records.shift(); dropped = true; }
                return record;
            } catch { return undefined; }
        },
        decoded(record, value) {
            try { if (record) { record.requestValid = !!value; } } catch {}
        },
        context(record, value) {
            try {
                if (!record) { return; }
                const observed = field(value, "privateBrowsing").value;
                record.contextPrivacy = typeof observed === "boolean" ? privacy(observed) : "unavailable";
            } catch {}
        },
        response(record, response) {
            try {
                if (!record) { return; }
                const kind = field(response, "kind");
                record.outcome = "response";
                record.responseArgumentCount = 1;
                record.responseType = type(response);
                record.responseKind = kind.type === "undefined" ? "missing"
                    : ["configuration", "configurationError", "result", "error"].includes(kind.value) ? kind.value : "other";
            } catch {}
        },
        thrown(record) {
            try {
                if (!record) { return; }
                record.outcome = "thrown";
                record.responseArgumentCount = 0;
            } catch {}
        },
    };
})();
'''

REPLACEMENTS = [(
'''async function handleMessage(request, context) {''',
'''async function handleMessage(request, context, diagnosticRecord) {'''), (
'''    const decoded = WIRE.decodeMessage(context.kind === "content" ? "ContentToWorker" : "PopupToWorker", request);
    if (!decoded) {''',
'''    const decoded = WIRE.decodeMessage(context.kind === "content" ? "ContentToWorker" : "PopupToWorker", request);
    safariVMWorkerDiagnostic.decoded(diagnosticRecord, decoded);
    if (!decoded) {'''), (
'''    const nativeContext = WIRE.runtimeNativeContext(context, request);
    switch (request.subject) {''',
'''    const nativeContext = WIRE.runtimeNativeContext(context, request);
    safariVMWorkerDiagnostic.context(diagnosticRecord, nativeContext);
    switch (request.subject) {'''), (
'''browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    const context = WIRE.authorizeRuntimeMessage("worker", request, sender, browser.runtime);
    if (!context) { return false; }
    Promise.resolve(handleMessage(request, context)).then(sendResponse, () => sendResponse());
    return true;
});''',
'''browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (safariVMWorkerDiagnostic.isDump(request)) {
        sendResponse(safariVMWorkerDiagnostic.dump(sender, browser.runtime));
        return false;
    }
    const context = WIRE.authorizeRuntimeMessage("worker", request, sender, browser.runtime);
    const diagnosticRecord = safariVMWorkerDiagnostic.begin(request, sender, context, browser.runtime);
    if (!context) { return false; }
    Promise.resolve(handleMessage(request, context, diagnosticRecord)).then(response => {
        safariVMWorkerDiagnostic.response(diagnosticRecord, response);
        return sendResponse(response);
    }, () => {
        safariVMWorkerDiagnostic.thrown(diagnosticRecord);
        return sendResponse();
    });
    return true;
});''')]


def instrument(source):
    if "safariVMWorkerDiagnostic" in source:
        raise ValueError("Worker source already contains fixture diagnostics")
    for original, replacement in REPLACEMENTS:
        if source.count(original) != 1:
            raise ValueError("Worker diagnostic source anchor changed")
        source = source.replace(original, replacement, 1)
    return DIAGNOSTIC + source


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("fixture", "ordinary"):
        raise ValueError("Expected worker source, output, and fixture or ordinary mode")
    source, output = map(Path, sys.argv[1:3])
    if output.is_symlink() or not output.is_file() or source.resolve() == output.resolve():
        raise ValueError("Invalid bundled worker output")
    text = source.read_text()
    output.write_text(instrument(text) if sys.argv[3] == "fixture" else text)


if __name__ == "__main__":
    main()
