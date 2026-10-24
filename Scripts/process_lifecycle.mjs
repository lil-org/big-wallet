export function observeProcess(child, {
    policy,
    terminationGraceMilliseconds,
    signalGroup,
    onStop,
    onFailure,
    onExit,
}) {
    const safari = policy === "safari-command";
    const finalizer = policy === "vm-finalizer";
    let exited = false;
    let stopping = false;
    let closed = false;
    let disposed = false;
    let escalation = Promise.resolve();
    let escalationTimer;
    let resolveEscalation;
    let drainTimer;
    let resolveExit;
    let resolveClose;

    const exit = new Promise(resolve => { resolveExit = resolve; });
    const outputClosed = new Promise(resolve => { resolveClose = resolve; });

    const removeObservers = () => {
        child.removeListener("exit", childExited);
        child.removeListener("error", childFailed);
        child.removeListener("close", childClosed);
    };
    const finish = (code, signal) => {
        if (exited) { return; }
        exited = true;
        onExit();
        if (finalizer) {
            clearTimeout(escalationTimer);
            resolveEscalation?.();
        }
        resolveExit({code, signal});
    };
    const childExited = (code, signal) => finish(code, signal);
    const childFailed = error => {
        onFailure("spawn", error);
        finish(null, null);
    };
    const childClosed = () => {
        closed = true;
        resolveClose();
        if (disposed) { removeObservers(); }
    };
    child.once("exit", childExited);
    if (safari) { child.once("error", childFailed); }
    else { child.on("error", childFailed); }
    child.once("close", childClosed);

    const signal = value => {
        if (!child.pid) { return; }
        try { signalGroup(child.pid, value); }
        catch (error) {
            if (error.code !== "ESRCH") { onFailure("signal", error); }
        }
    };
    const stop = reason => {
        if (stopping || exited && !safari) { return false; }
        stopping = true;
        onStop(reason);
        signal("SIGTERM");
        if (safari || child.pid) {
            escalation = new Promise(resolve => {
                resolveEscalation = resolve;
                escalationTimer = setTimeout(() => {
                    if (!finalizer || !exited) { signal("SIGKILL"); }
                    if (safari) { finish(null, "SIGKILL"); }
                    resolve();
                }, terminationGraceMilliseconds);
            });
        }
        return true;
    };
    const drainOutput = async milliseconds => {
        let timedOut = false;
        await Promise.race([
            outputClosed,
            new Promise(resolve => {
                drainTimer = setTimeout(() => {
                    timedOut = true;
                    child.stdout?.destroy();
                    child.stderr?.destroy();
                    resolve();
                }, milliseconds);
            }),
        ]);
        clearTimeout(drainTimer);
        drainTimer = undefined;
        return timedOut;
    };
    const dispose = () => {
        disposed = true;
        clearTimeout(drainTimer);
        if (closed) { removeObservers(); }
    };

    return {exit, stop, waitForEscalation: () => escalation, drainOutput, dispose};
}
