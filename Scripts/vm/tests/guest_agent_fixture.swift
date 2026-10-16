private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

private func expectReadFailure(_ path: String, code: Int32) {
    do {
        _ = try readJobFile(path)
        expect(false, "Reject invalid job file: \(path)")
    } catch {
        let failure = error as NSError
        expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(code), "Return the job file's POSIX error")
    }
}

private func checkJobFileReader() throws {
    let directory = URL(fileURLWithPath: exchangePath).appendingPathComponent("file-fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let valid = directory.appendingPathComponent("valid.json")
    let payload = Data("{\"runId\":\"reader-fixture\"}".utf8)
    try payload.write(to: valid)
    let received = try readJobFile(valid.path)
    expect(received == payload, "Read the opened regular job file exactly")

    let maximum = directory.appendingPathComponent("maximum.json")
    var maximumPayload = payload
    maximumPayload.append(Data(repeating: 32, count: 1024 * 1024 - payload.count))
    try maximumPayload.write(to: maximum)
    let maximumData = try readJobFile(maximum.path)
    expect(maximumData == maximumPayload, "Accept a job exactly at the one MiB limit")

    let oversized = directory.appendingPathComponent("oversized.json")
    maximumPayload.append(32)
    try maximumPayload.write(to: oversized)
    let linked = directory.appendingPathComponent("linked.json")
    expect(symlink(valid.path, linked.path) == 0, "Create fixture symlink")
    let fifo = directory.appendingPathComponent("fifo.json")
    expect(mkfifo(fifo.path, 0o600) == 0, "Create fixture FIFO without a writer")
    let empty = directory.appendingPathComponent("empty.json")
    try Data().write(to: empty)
    let emptyData = try readJobFile(empty.path)
    expect(emptyData.isEmpty, "Read an empty file without blocking")

    let firstDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
    expect(firstDescriptor >= 0, "Open descriptor cleanup probe")
    close(firstDescriptor)
    for _ in 0..<16 {
        _ = try readJobFile(valid.path)
        expectReadFailure(oversized.path, code: EFBIG)
        expectReadFailure(linked.path, code: ELOOP)
        expectReadFailure(directory.path, code: EINVAL)
        expectReadFailure(fifo.path, code: EINVAL)
        expectReadFailure(directory.appendingPathComponent("missing.json").path, code: ENOENT)
    }
    let finalDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
    expect(finalDescriptor == firstDescriptor, "Successful and failed job reads close every descriptor")
    close(finalDescriptor)
}

private func checkAtomicReceipt() throws {
    let directory = URL(fileURLWithPath: exchangePath).appendingPathComponent("receipt-fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let preserved = directory.appendingPathComponent("preserved.json")
    let original = Data("preserve this file".utf8)
    try original.write(to: preserved)
    let receipt = directory.appendingPathComponent("receipt.json")
    expect(symlink(preserved.path, receipt.path) == 0, "Create receipt destination symlink")
    let completed = Data("{\"state\":\"completed\"}".utf8)
    try writeReceiptAtomically(completed, to: receipt.path)
    let saved = try Data(contentsOf: receipt)
    let unchanged = try Data(contentsOf: preserved)
    expect(isRegularFile(receipt.path) && saved == completed, "Atomically replace the receipt without following its symlink")
    expect(unchanged == original, "Receipt replacement preserves the symlink target")
    let blocked = directory.appendingPathComponent("blocked.json", isDirectory: true)
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    do {
        try writeReceiptAtomically(completed, to: blocked.path)
        expect(false, "An invalid receipt destination must fail")
    } catch {}
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    expect(!files.contains { $0.hasSuffix(".tmp") }, "Receipt writes remove temporary files after success and failure")
}

@MainActor
private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    expect(condition(), message)
}

@MainActor
private extension GuestAgent {
    func checkJobDiscovery() async throws {
        let jobURL = URL(fileURLWithPath: exchangePath).appendingPathComponent("job.json")
        for text in ["{\"runId\":", "[]", "{\"runId\":\"../escape\"}"] {
            try Data(text.utf8).write(to: jobURL)
            inspectJob()
            expect(process == nil && seenRunIDs.isEmpty && terminalEvent == nil, "Malformed jobs cannot launch or claim a run")
        }
        let runID = "discovered-job"
        try JSONSerialization.data(withJSONObject: ["runId": runID]).write(to: jobURL)
        let peer = fixtureConnection()
        fixtureHandshake(peer)
        inspectJob()
        expect(activeRunID == runID && process != nil, "Discover and launch the bounded job file")
        inspectJob()
        try await eventually("The fixture runner finishes") { process == nil }
        inspectJob()
        let messages = fixtureMessages(peer)
        expect(messages.count == 2 && messages.map { $0["type"] as? String } == ["jobStarted", "jobFinished"],
               "One discovered job produces one start and one completion")
        expect(messages.allSatisfy { $0["runId"] as? String == runID }, "Job events retain the discovered run identity")
        expect(messages.last?["exitCode"] as? Int == 0, "The fixture runner succeeds")
        let invocation = try String(contentsOfFile: exchangePath + "/fixture-job-path", encoding: .utf8)
        expect(invocation == jobURL.path + "\n", "The runner receives the fixed job path exactly once")
        let log = try String(contentsOfFile: exchangePath + "/guest-runner.log", encoding: .utf8)
        expect(log == "fixture runner output\n", "The runner writes its output to the exchange log")
        disconnect()
        close(peer)
    }

    func fixtureConnection(reading: Bool = false) -> Int32 {
        var pair = [Int32](repeating: -1, count: 2)
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "Create fixture socket pair")
        for fd in pair {
            var enabled: Int32 = 1
            expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                   "Disable fixture SIGPIPE")
            expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "Set fixture socket nonblocking")
        }
        socketFD = pair[0]
        if reading { startReading(socketFD) }
        return pair[1]
    }

    func fixtureHandshake(_ peer: Int32, accepted: Bool = true) {
        var data = try! JSONSerialization.data(withJSONObject: ["type": "helloAck", "protocolVersion": 1, "accepted": accepted])
        data.append(10)
        expect(data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == data.count, "Send fixture acknowledgement")
        readMessages()
    }

    func fixtureMessages(_ peer: Int32) -> [[String: Any]] {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(peer, &bytes, bytes.count)
            if count > 0 { result.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        return result.split(separator: 10).map { try! JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    }

    func expectTerminal(_ peer: Int32, runID: String, type: String, exitCode: Int? = nil) {
        let messages = fixtureMessages(peer)
        expect(messages.count == 1, "Exactly one retained terminal event must be delivered")
        expect(messages[0]["runId"] as? String == runID, "Terminal event retains its run identity")
        expect(messages[0]["type"] as? String == type, "Terminal event retains its outcome type")
        expect(messages[0]["protocolVersion"] as? Int == 1, "Terminal event retains protocol version")
        if let exitCode { expect(messages[0]["exitCode"] as? Int == exitCode, "Terminal event retains exit code") }
    }

    func checkCompletionAcrossReconnect() throws {
        let runID = "disconnected-completion"
        seenRunIDs.insert(runID)
        activeRunID = runID
        completed(runID: runID, code: 23)
        let receipt = URL(fileURLWithPath: exchangePath).appendingPathComponent(".agent-runs/\(runID).json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as! [String: Any]
        expect(saved["state"] as? String == "completed", "Disconnected completion remains durable")
        expect(saved["exitCode"] as? Int == 23, "Receipt retains the exit code")
        expect(activeRunID == nil, "Completion clears the active run")

        for _ in 0..<2 {
            let peer = fixtureConnection()
            expect(fixtureMessages(peer).isEmpty, "Do not replay before acknowledgement")
            fixtureHandshake(peer)
            expectTerminal(peer, runID: runID, type: "jobFinished", exitCode: 23)
            expect(seenRunIDs == [runID], "Reconnection preserves run claiming")
            expect(process == nil, "Reconnection cannot relaunch a completed runner")
            disconnect()
            close(peer)
        }
    }

    func checkLaunchErrorAcrossReconnect() {
        let peer = fixtureConnection()
        reportError("fixture launch failed", runID: "first-failure")
        expect(fixtureMessages(peer).isEmpty, "Do not report terminal errors before acknowledgement")
        fixtureHandshake(peer)
        expectTerminal(peer, runID: "first-failure", type: "agentError")
        reportError("fixture launch failed", runID: "first-failure")
        expect(fixtureMessages(peer).isEmpty, "Repeated errors for one run stay deduplicated")
        disconnect()
        close(peer)

        let nextPeer = fixtureConnection()
        fixtureHandshake(nextPeer)
        expectTerminal(nextPeer, runID: "first-failure", type: "agentError")
        reportError("fixture launch failed", runID: "second-failure")
        expectTerminal(nextPeer, runID: "second-failure", type: "agentError")
        disconnect()
        close(nextPeer)
    }

    func checkFailedWriteAcrossReconnect() {
        let peer = fixtureConnection()
        fixtureHandshake(peer)
        close(peer)
        completed(runID: "write-failure", code: 9)
        expect(socketFD == -1, "Failed terminal write disconnects transport")
        let replacement = fixtureConnection()
        fixtureHandshake(replacement)
        expectTerminal(replacement, runID: "write-failure", type: "jobFinished", exitCode: 9)
        disconnect()
        close(replacement)
    }

    func checkRejectedHandshake() {
        completed(runID: "unacknowledged", code: 4)
        let peer = fixtureConnection()
        fixtureHandshake(peer, accepted: false)
        expect(fixtureMessages(peer).isEmpty, "Rejected handshake cannot receive a terminal event")
        expect(!acknowledged && socketFD == -1, "Rejected handshake disconnects")
        close(peer)
    }

    func checkDeferredDisconnect() async throws {
        let peer = fixtureConnection(reading: true)
        let originalFD = socketFD
        let originalReader = reader!
        let malformed = Data("invalid old message\n".utf8)
        expect(malformed.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == malformed.count,
               "Queue an old read event before disconnect")
        disconnect()
        disconnect()
        expect(socketFD == -1 && reader == nil, "Disconnect immediately detaches active reader state")
        expect(fcntl(originalFD, F_GETFD) >= 0, "Original descriptor remains open while cancellation is pending")

        let replacementPeer = fixtureConnection(reading: true)
        let replacementFD = socketFD
        expect(replacementFD != originalFD, "Pending cancellation prevents original descriptor reuse")
        var acknowledgement = try JSONSerialization.data(withJSONObject: ["type": "helloAck", "protocolVersion": 1, "accepted": true])
        acknowledgement.append(10)
        expect(acknowledgement.withUnsafeBytes { Darwin.write(replacementPeer, $0.baseAddress, $0.count) } == acknowledgement.count,
               "Queue replacement acknowledgement")
        try await eventually("Cancellation closes the original descriptor") { fcntl(originalFD, F_GETFD) == -1 }
        try await eventually("Replacement read source processes its own acknowledgement") { acknowledged }
        expect(socketFD == replacementFD && fcntl(replacementFD, F_GETFD) >= 0,
               "Old cancellation and queued read cannot disconnect the replacement")

        expect(dup2(replacementFD, originalFD) == originalFD, "Reuse the released descriptor number")
        originalReader.cancel()
        try await Task.sleep(for: .milliseconds(20))
        expect(fcntl(originalFD, F_GETFD) >= 0, "Repeated old cancellation cannot close a reused descriptor")
        close(originalFD)
        disconnect()
        disconnect()
        expect(fcntl(replacementFD, F_GETFD) >= 0, "Repeated disconnect still defers replacement close")
        try await eventually("Replacement cancellation eventually closes its descriptor") { fcntl(replacementFD, F_GETFD) == -1 }
        close(peer)
        close(replacementPeer)
    }

    func checkDisconnectWithoutReader() {
        let peer = fixtureConnection()
        let descriptor = socketFD
        disconnect()
        disconnect()
        expect(fcntl(descriptor, F_GETFD) == -1, "An unregistered descriptor closes immediately")
        close(peer)
    }

    static func checkReleasedAgent() async throws {
        var agent: GuestAgent? = GuestAgent()
        weak var weakAgent = agent
        let peer = agent!.fixtureConnection(reading: true)
        let descriptor = agent!.socketFD
        agent!.disconnect()
        agent = nil
        expect(weakAgent == nil, "Cancellation does not retain the guest agent")
        expect(fcntl(descriptor, F_GETFD) >= 0, "Detached source retains its descriptor until cancellation")
        try await eventually("Cancellation closes after guest agent deallocation") { fcntl(descriptor, F_GETFD) == -1 }
        close(peer)
    }
}

@main
@MainActor
private struct GuestAgentFixture {
    static func main() async throws {
        try FileManager.default.createDirectory(atPath: exchangePath + "/.agent-runs", withIntermediateDirectories: true)
        try checkJobFileReader()
        try checkAtomicReceipt()
        try await GuestAgent().checkJobDiscovery()
        try GuestAgent().checkCompletionAcrossReconnect()
        GuestAgent().checkLaunchErrorAcrossReconnect()
        GuestAgent().checkFailedWriteAcrossReconnect()
        GuestAgent().checkRejectedHandshake()
        GuestAgent().checkDisconnectWithoutReader()
        try await GuestAgent().checkDeferredDisconnect()
        try await GuestAgent.checkReleasedAgent()
        print("Guest agent terminal replay fixtures passed")
        print("Guest agent socket lifetime fixtures passed")
        print("Guest agent bounded job file fixtures passed")
        print("Guest agent atomic receipt fixtures passed")
    }
}
