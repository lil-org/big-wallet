// ∅ 2026 lil org

import assert from "node:assert/strict";
import test from "node:test";
import {createPopupHarness, flushPopup, popupMarkup, popupMarkupInventory} from "./popup_harness.mjs";
import {deferred} from "./test_helpers.mjs";

test("popup inventory preserves actual IDs, classes, and fallback localization", () => {
    const harness = createPopupHarness();
    assert.equal(harness.document.getElementById("misspelled-button"), null);
    assert.throws(() => harness.get("misspelled-button"), /Missing popup element/);
    assert.equal(harness.get("screen-loading").classList.contains("screen"), true);
    assert.equal(harness.get("screen-loading").classList.contains("hidden"), false);
    assert.equal(harness.get("screen-request").classList.contains("hidden"), true);
    assert.equal(harness.get("button-approve").classList.contains("hidden"), false);
    assert.equal(harness.get("button-approve").textContent, "OK");
    const labels = harness.document.querySelectorAll("[data-string]");
    assert.ok(labels.some(element => element.id === "" && element.dataset.string === "gasPrice" &&
        element.textContent === "Gas price (gwei)"));
    assert.throws(() => harness.document.querySelectorAll("button"), /Unsupported popup selector/);
});

test("popup runtime notifications carry realistic and overridable sender metadata", () => {
    const harness = createPopupHarness();
    const received = [];
    harness.browser.runtime.onMessage.addListener((message, sender) => {
        received.push({message, sender});
        return false;
    });
    assert.deepEqual(harness.notify(), {returns: [false], responses: []});
    const message = {subject: "pendingRequestAvailable", workflowVersion: 3};
    assert.deepEqual(received[0], {
        message,
        sender: {
            id: harness.browser.runtime.id,
            url: harness.browser.runtime.getURL("").replace(/\/$/, ""),
        },
    });
    harness.notify(message, null);
    assert.equal(received[1].sender, null);
    assert.equal(harness.browser.runtime.getURL("popup.html"), "safari-web-extension://wallet/popup.html");
});

test("unsupported inventory assumptions and duplicate IDs fail explicitly", () => {
    assert.throws(() => popupMarkupInventory(popupMarkup.replace(
        'id="screen-idle"', 'id="screen-loading"'
    )), /Duplicate or empty popup ID/);
    for (const title of ["a>b", "a<b"]) {
        assert.throws(() => popupMarkupInventory(popupMarkup.replace(
            'data-string="gasPrice"', `title="${title}" data-string="gasPrice"`
        )), /Unsupported/);
    }
    assert.throws(() => popupMarkupInventory(popupMarkup.replace(
        'for="edit-gas-price">Gas price (gwei)', 'for="edit-gas-price"><strong>Gas price</strong>'
    )), /fallback must be plain text/);
    assert.throws(() => popupMarkupInventory(popupMarkup.replace(
        'src="bridge_wire.js"', 'src="https://example.com/bridge_wire.js"'
    )), /local JavaScript files/);
});

test("production startup fails when a bound control is absent from the actual markup", async () => {
    const harness = createPopupHarness({markup: popupMarkup.replace('id="button-approve"', '')});
    await assert.rejects(harness.boot(), /Cannot read properties of null/);
});

test("markup script order boots and localizes both named and unnamed controls", async () => {
    const harness = createPopupHarness({
        native: () => ({
            requests: [], completedResponses: [],
            strings: {gasPrice: "Localized gas price", ok: "Localized OK"},
            layoutDirection: "rtl",
        }),
        worker: () => ({status: "ok"}),
    });
    await harness.boot();
    assert.equal(harness.get("screen-loading").classList.contains("hidden"), true);
    assert.equal(harness.get("screen-idle").classList.contains("hidden"), false);
    assert.equal(harness.get("button-approve").textContent, "Localized OK");
    const label = harness.document.querySelectorAll("[data-string]").find(element =>
        element.id === "" && element.dataset.string === "gasPrice"
    );
    assert.equal(label.textContent, "Localized gas price");
    assert.equal(harness.get("editor-apply").textContent, "Apply");
    assert.equal(harness.document.documentElement.dir, "rtl");
    assert.deepEqual(harness.nativeMessages.map(message => message.subject), ["getPendingRequests"]);
});

test("control clicks respect disabled state and retain all registered listeners", async () => {
    const harness = createPopupHarness();
    const button = harness.get("button-approve");
    const calls = [];
    const first = async () => { calls.push("first"); };
    button.addEventListener("click", first);
    button.addEventListener("click", first);
    button.addEventListener("click", () => { calls.push("second"); });
    button.disabled = true;
    await button.click();
    assert.deepEqual(calls, []);
    button.disabled = false;
    await button.click();
    assert.deepEqual(calls, ["first", "second"]);
    button.removeEventListener("click", first);
    button.disabled = true;
    await button.emit("click");
    assert.deepEqual(calls, ["first", "second", "second"]);
});

test("removing a dynamic subtree disconnects its descendants and preserves detached race events", async () => {
    const harness = createPopupHarness();
    const row = harness.document.createElement("div");
    const button = harness.document.createElement("button");
    row.appendChild(button);
    assert.equal(button.isConnected, false);
    harness.get("accounts-list").appendChild(row);
    assert.equal(button.isConnected, true);
    button.focus();
    assert.equal(harness.document.activeElement, button);
    assert.deepEqual(harness.focusCalls, [button.id]);
    harness.get("accounts-list").innerHTML = "";
    assert.equal(row.isConnected, false);
    assert.equal(button.isConnected, false);
    button.addEventListener("click", () => { button.textContent = "Late response"; });
    await button.emit("click");
    assert.deepEqual(harness.textWrites, [{id: button.id, text: "Late response"}]);
});

test("closing the popup suppresses late transport results and failures", async () => {
    for (const outcome of ["resolve", "reject"]) {
        const gate = deferred();
        let settled = false;
        const harness = createPopupHarness({native: () => gate.promise});
        const response = harness.browser.runtime.sendNativeMessage("org.lil.wallet", {subject: "getPendingRequests"});
        response.then(() => { settled = true; }, () => { settled = true; });
        harness.close();
        gate[outcome](outcome === "resolve" ? {requests: [], completedResponses: []} : new Error("Closed"));
        await flushPopup();
        assert.equal(settled, false);
    }
});
