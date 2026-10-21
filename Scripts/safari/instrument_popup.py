from pathlib import Path
import sys


DIAGNOSTIC = r'''
const safariVMPopupDiagnostic = (() => {
    const records = [];
    let element;
    let sequence = 0;
    const type = value => value === null ? "null" : typeof value;
    const boolean = value => typeof value === "boolean" ? value : type(value);
    const integer = value => Number.isSafeInteger(value) ? value : null;
    function record(value, failed = false) {
        try {
            records.push({sequence: ++sequence, ...value});
            if (records.length > 8) { records.shift(); }
            if (failed && !element) {
                element = document.createElement("div");
                element.id = "safari-vm-popup-diagnostics";
                element.className = "hint";
                element.setAttribute("role", "status");
                document.body.appendChild(element);
            }
            if (element) { element.textContent = "Safari VM popup: " + JSON.stringify(records); }
        } catch {}
    }
    return {
        query(outcome, tabs) {
            const tab = Array.isArray(tabs) ? tabs[0] : null;
            record({kind: "tabs", outcome, resultType: Array.isArray(tabs) ? "array" : type(tabs),
                count: Array.isArray(tabs) ? Math.min(tabs.length, 1000) : null,
                tabID: integer(tab?.id), windowID: integer(tab?.windowId),
                incognito: boolean(tab?.incognito), urlType: type(tab?.url),
                urlValid: !!BigWalletBridgeWire.configurationIdentityForURL(tab?.url)});
        },
        context(value, privateContext) {
            record({kind: "context", valid: !!value,
                extensionPrivacy: boolean(privateContext), privacy: value?.privateBrowsing ?? null}, !value);
        },
    };
})();
'''

REPLACEMENTS = [(
'''async function captureNativeContext() {
    const tab = await readActiveTab();
    return BigWalletBridgeWire.popupNativeContext(tab, extensionPrivateBrowsing());
}''',
'''async function captureNativeContext() {
    const tab = await readActiveTab();
    const privateContext = extensionPrivateBrowsing();
    const context = BigWalletBridgeWire.popupNativeContext(tab, privateContext);
    safariVMPopupDiagnostic.context(context, privateContext);
    return context;
}'''), (
'''async function readActiveTab() {
    let tabs;
    let pendingTabs;
    try {
        pendingTabs = browser.tabs.query({ active: true, currentWindow: true });
    } catch {}
    if (pendingTabs) {
        const outcome = await settleExtensionMessage(pendingTabs);
        tabs = outcome.status === "response" ? outcome.response : null;
    }
    return Array.isArray(tabs) ? tabs[0] : null;
}''',
'''async function readActiveTab() {
    let tabs;
    let pendingTabs;
    let diagnosticOutcome = "no-promise";
    try {
        pendingTabs = browser.tabs.query({ active: true, currentWindow: true });
    } catch { diagnosticOutcome = "sync-throw"; }
    if (pendingTabs) {
        const outcome = await settleExtensionMessage(pendingTabs);
        diagnosticOutcome = outcome.status;
        tabs = outcome.status === "response" ? outcome.response : null;
    }
    safariVMPopupDiagnostic.query(diagnosticOutcome, tabs);
    return Array.isArray(tabs) ? tabs[0] : null;
}''')]


def instrument(source):
    if "safariVMPopupDiagnostic" in source:
        raise ValueError("Popup source already contains fixture diagnostics")
    for original, replacement in REPLACEMENTS:
        if source.count(original) != 1:
            raise ValueError("Popup diagnostic source anchor changed")
        source = source.replace(original, replacement, 1)
    return DIAGNOSTIC + source


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("fixture", "ordinary"):
        raise ValueError("Expected popup source, output, and fixture or ordinary mode")
    source, output = map(Path, sys.argv[1:3])
    if output.is_symlink() or not output.is_file() or source.resolve() == output.resolve():
        raise ValueError("Invalid bundled popup output")
    text = source.read_text()
    output.write_text(instrument(text) if sys.argv[3] == "fixture" else text)


if __name__ == "__main__":
    main()
