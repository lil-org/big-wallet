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
