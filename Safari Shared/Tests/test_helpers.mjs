// ∅ 2026 lil org

export function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
        resolve = resolvePromise;
        reject = rejectPromise;
    });
    return { promise, reject, resolve };
}

export function normalized(value) {
    return JSON.parse(JSON.stringify(value));
}

export function popupElement(id) {
    const classes = new Set(id === "screen-loading" ? [] : ["hidden"]);
    const listeners = new Map;
    const element = {
        children: [],
        classList: {
            add: value => classes.add(value),
            contains: value => classes.has(value),
            remove: value => classes.delete(value),
        },
        dataset: {},
        disabled: false,
        focus() {},
        inert: false,
        isConnected: true,
        open: false,
        src: "",
        textContent: "",
        value: "",
        addEventListener(name, listener) { listeners.set(name, listener); },
        appendChild(child) { this.children.push(child); return child; },
        setAttribute(name, value) { this[name] = value; },
    };
    Object.defineProperty(element, "innerHTML", {
        get() { return ""; },
        set() { element.children = []; },
    });
    return element;
}
