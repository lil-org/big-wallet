function errorData(error, depth = 0) {
    if (!error || depth > 4) { return null; }
    return {name: String(error.name ?? ""), code: String(error.code ?? ""),
        message: String(error.message ?? "").slice(0, 16384),
        failureType: String(error.failureType ?? ""), cause: errorData(error.cause, depth + 1)};
}

export default async function* mutationReporter(events) {
    let count = 0;
    for await (const event of events) {
        if (event.type !== "test:pass" && event.type !== "test:fail") { continue; }
        const data = event.data;
        count += 1;
        yield JSON.stringify({kind: "case", name: data.name, file: data.file ?? null,
            result: data.skip ? "skipped" : event.type === "test:pass" ? "passed" : "failed",
            skip: data.skip ?? null, error: errorData(data.details?.error)}) + "\n";
    }
    yield JSON.stringify({kind: "complete", count}) + "\n";
}
