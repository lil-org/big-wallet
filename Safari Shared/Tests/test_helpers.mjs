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

export function nativeResult({id, name, provider, result, mutation = null, approvalCommitted = false}) {
    return {id, name, provider, kind: "result", result, mutation, approvalCommitted};
}

export function nativeError({id, name, provider, error, mutation = null, approvalCommitted = false, authorizationFailure = false}) {
    return {id, name, provider, kind: "error", error, mutation, approvalCommitted, authorizationFailure};
}
