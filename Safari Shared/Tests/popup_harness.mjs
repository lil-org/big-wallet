// ∅ 2026 lil org

import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import vm from "node:vm";
import {normalized} from "./test_helpers.mjs";

export const popupMarkup = await readFile(new URL("../Resources/popup.html", import.meta.url), "utf8");

// This inventory mock does not model layout, event propagation, or browser default actions.
export function popupMarkupInventory(markup) {
    const elements = [];
    const ids = new Set;
    const scripts = [];
    assert.doesNotMatch(markup, /<!--|<!\[|<template\b|<style\b/i, "Unsupported popup markup");
    for (const match of markup.matchAll(/<([a-z][\w-]*)(\s[^<>]*?)?>/gi)) {
        const tag = match[1].toLowerCase();
        const attributes = {};
        let remaining = (match[2] || "").trim();
        while (remaining) {
            const attribute = /^([\w-]+)(?:="([^"<>]*)")?(?:\s+|$)/.exec(remaining);
            assert.ok(attribute, `Unsupported attributes on ${tag}: ${remaining}`);
            assert.ok(!Object.hasOwn(attributes, attribute[1]), `Duplicate attribute ${attribute[1]}`);
            attributes[attribute[1]] = attribute[2] ?? "";
            remaining = remaining.slice(attribute[0].length);
        }
        if (Object.hasOwn(attributes, "id")) {
            assert.ok(attributes.id && !ids.has(attributes.id), `Duplicate or empty popup ID: ${attributes.id}`);
            ids.add(attributes.id);
        }
        if (tag === "script") {
            assert.deepEqual(Object.keys(attributes), ["src"], "Popup scripts must have only a local src");
            assert.match(attributes.src, /^[\w-]+\.js$/, "Popup scripts must be local JavaScript files");
            assert.ok(markup.slice(match.index + match[0].length).startsWith("</script>"), "Inline popup scripts are unsupported");
            scripts.push(attributes.src);
        }
        if (!attributes.id && !Object.hasOwn(attributes, "data-string")) { continue; }
        let text = "";
        if (Object.hasOwn(attributes, "data-string")) {
            const content = markup.slice(match.index + match[0].length);
            const end = content.indexOf(`</${tag}>`);
            assert.ok(end >= 0, `Missing closing tag for localized ${tag}`);
            text = content.slice(0, end).trim();
            assert.doesNotMatch(text, /[<&]/, "Localized popup fallback must be plain text");
        }
        elements.push({tag, attributes, text});
    }
    for (const name of ["id", "data-string"]) {
        const declared = [...markup.matchAll(new RegExp(`\\s${name}\\s*=`, "g"))].length;
        const recognized = elements.filter(item => Object.hasOwn(item.attributes, name)).length;
        assert.equal(recognized, declared, `Unsupported popup markup containing ${name}`);
    }
    assert.equal(scripts.length, [...markup.matchAll(/<script\b/gi)].length, "Unsupported popup script markup");
    assert.ok(scripts.length, "Popup must load local scripts");
    return {elements, scripts};
}

const inventory = popupMarkupInventory(popupMarkup);
const scripts = new Map(await Promise.all(inventory.scripts.map(async name => [
    name,
    new vm.Script(await readFile(new URL(`../Resources/${name}`, import.meta.url), "utf8"), {filename: name}),
])));

export async function flushPopup() {
    for (let index = 0; index < 3; index += 1) {
        await new Promise(resolve => setImmediate(resolve));
    }
}

export function createPopupHarness(options = {}) {
    const markupInventory = options.markup === undefined ? inventory : popupMarkupInventory(options.markup);
    const nativeMessages = [];
    const workerMessages = [];
    const tabMessages = [];
    const focusCalls = [];
    const textWrites = [];
    const elements = new Map;
    const localizedElements = [];
    const runtimeListeners = new Set;
    const timers = new Map;
    const timerHistory = [];
    const model = options.model || {};
    model.closed = 0;
    let nextTimer = 0;
    let nextElement = 0;
    let randomValue = 0;
    let open = true;
    let document;
    function eventTarget() {
        const listeners = new Map;
        return {
            addEventListener(name, listener) {
                if (!listeners.has(name)) { listeners.set(name, new Set); }
                listeners.get(name).add(listener);
            },
            removeEventListener(name, listener) { listeners.get(name)?.delete(listener); },
            emit(name, event = {}) {
                const suppliedEvent = {target: this, preventDefault() {}, ...event};
                const results = [...(listeners.get(name) || [])].map(listener => listener(suppliedEvent));
                return results.length === 1 ? results[0] : Promise.all(results);
            },
        };
    }
    function element(id, {tag = "div", attributes = {}, text = "", connected = false} = {}) {
        const classes = new Set((attributes.class || "").split(/\s+/).filter(Boolean));
        let textContent = text;
        let parent = null;
        const value = {
            ...eventTarget(),
            id,
            tagName: tag.toUpperCase(),
            children: [],
            classList: {
                add: (...names) => names.forEach(name => classes.add(name)),
                contains: name => classes.has(name),
                remove: (...names) => names.forEach(name => classes.delete(name)),
            },
            dataset: {},
            disabled: Object.hasOwn(attributes, "disabled"),
            inert: Object.hasOwn(attributes, "inert"),
            get isConnected() { return parent ? parent.isConnected : connected; },
            open: Object.hasOwn(attributes, "open"),
            src: attributes.src || "",
            value: attributes.value || "",
            appendChild(child) {
                child.detach();
                child.attach(this);
                this.children.push(child);
                return child;
            },
            attach(parentElement) { parent = parentElement; },
            detach() {
                if (parent) { parent.children.splice(parent.children.indexOf(this), 1); }
                parent = null;
                connected = false;
            },
            click(event) { if (!this.disabled) { return this.emit("click", event); } },
            focus() { document.activeElement = this; focusCalls.push(id); },
            setAttribute(name, attribute) { this[name] = String(attribute); },
        };
        for (const [name, attribute] of Object.entries(attributes)) {
            if (name.startsWith("data-")) {
                value.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = attribute;
            }
        }
        const clearChildren = () => {
            for (const child of [...value.children]) { child.detach(); }
        };
        Object.defineProperty(value, "textContent", {
            get() { return textContent; },
            set(text) {
                clearChildren();
                textContent = String(text);
                textWrites.push({id, text: textContent});
            },
        });
        Object.defineProperty(value, "innerHTML", {
            get() { return ""; },
            set(html) {
                assert.equal(html, "", "Popup harness only supports clearing innerHTML");
                clearChildren();
                textContent = "";
            },
        });
        return value;
    }
    for (const item of markupInventory.elements) {
        const value = element(item.attributes.id || "", {...item, connected: true});
        if (value.id) { elements.set(value.id, value); }
        if (Object.hasOwn(item.attributes, "data-string")) { localizedElements.push(value); }
    }
    document = {
        ...eventTarget(),
        activeElement: null,
        documentElement: element("document-element", {tag: "html", connected: true}),
        createElement: tag => element(`${tag}-${++nextElement}`, {tag}),
        getElementById: id => elements.get(id) || null,
        querySelectorAll(selector) {
            assert.equal(selector, "[data-string]", `Unsupported popup selector: ${selector}`);
            return localizedElements;
        },
    };
    const unavailable = () => new Promise(() => {});
    function dispatch(handler, message) {
        if (!open) { return unavailable(); }
        assert.equal(typeof handler, "function", `Unexpected popup message: ${message.subject}`);
        return Promise.resolve(handler(message)).then(
            value => open ? value : unavailable(),
            error => { if (!open) { return unavailable(); } throw error; }
        );
    }
    const browser = {
        extension: {inIncognitoContext: false},
        permissions: {contains: async () => true},
        runtime: {
            onMessage: {addListener(listener) { runtimeListeners.add(listener); }},
            sendMessage(message) {
                workerMessages.push(normalized(message));
                return dispatch(options.worker, message);
            },
            sendNativeMessage(application, message) {
                assert.equal(application, "org.lil.wallet");
                nativeMessages.push(normalized(message));
                return dispatch(options.native, message);
            },
        },
        storage: {local: {get: options.storageGet || (async () => ({}))}},
        tabs: {
            query: async () => options.tab ? [options.tab] : [],
            sendMessage(id, message) {
                tabMessages.push({id, message: normalized(message)});
                return dispatch(options.tabMessage, message);
            },
        },
    };
    const close = () => { open = false; };
    const context = vm.createContext({
        URL,
        browser,
        clearTimeout: id => timers.delete(id),
        crypto: {getRandomValues(values) {
            for (let index = 0; index < values.length; index += 1) { values[index] = ++randomValue; }
            return values;
        }},
        document,
        navigator: {maxTouchPoints: 5},
        setTimeout(callback, delay) {
            const timer = {callback, delay, id: ++nextTimer};
            timers.set(timer.id, timer);
            timerHistory.push(timer);
            return timer.id;
        },
        window: {close() { model.closed += 1; close(); }},
    });
    for (const name of markupInventory.scripts) {
        assert.ok(scripts.has(name), `Unknown popup script: ${name}`);
        scripts.get(name).runInContext(context);
    }
    return {
        browser, context, document, focusCalls, model, nativeMessages, tabMessages,
        textWrites, timerHistory, timers, workerMessages, close,
        get(id) {
            const value = document.getElementById(id);
            assert.ok(value, `Missing popup element: ${id}`);
            return value;
        },
        async boot() { await document.emit("DOMContentLoaded"); await flushPopup(); },
        async fire(id) {
            const timer = timers.get(id);
            assert.ok(timer, `Expected live timer ${id}`);
            timers.delete(id);
            timer.callback();
            await flushPopup();
        },
        notify(message = {subject: "pendingRequestAvailable", workflowVersion: 3}) {
            for (const listener of runtimeListeners) { listener(message); }
        },
        clearMessages() {
            nativeMessages.length = 0;
            workerMessages.length = 0;
            tabMessages.length = 0;
        },
        visibleSnapshot() {
            return [...elements].map(([id, item]) => ({
                id,
                text: item.textContent,
                value: item.value,
                disabled: item.disabled,
                hidden: item.classList.contains("hidden"),
                inert: item.inert,
                open: item.open,
                children: item.children.map(child => [child.id, child.textContent]),
            }));
        },
    };
}
