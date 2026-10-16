private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

private final class FixtureConnectionStats {
    var closes = 0
}

private final class FixtureConnection {
    private(set) var fileDescriptor: Int32
    let stats = FixtureConnectionStats()

    init(_ fd: Int32) { fileDescriptor = fd }

    func close() {
        stats.closes += 1
        if fileDescriptor >= 0 { Darwin.close(fileDescriptor); fileDescriptor = -1 }
    }

    deinit {
        if fileDescriptor >= 0 { Darwin.close(fileDescriptor) }
    }
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
private extension Host {
    static func fixtureHost() throws -> Host {
        let root = CommandLine.arguments[1]
        return try Host(options: Options(arguments: [
            "--vm", root + "/fixture.vbvm", "--exchange", root, "--status", root + "/status.json",
            "--stop-file", root + "/stop", "--owner-pid", String(getpid() + 1),
        ]))
    }

    func fixtureConnection(reading: Bool = true) -> Int32 {
        var pair = [Int32](repeating: -1, count: 2)
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0, "Create fixture socket pair")
        for fd in pair {
            var enabled: Int32 = 1
            expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
                   "Disable fixture SIGPIPE")
            expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0, "Set fixture socket nonblocking")
        }
        let connection = FixtureConnection(pair[0])
        self.connection = connection
        if reading { startReading(connection) }
        return pair[1]
    }

    func checkDeferredClose() async throws {
        let peer = fixtureConnection()
        let originalFD = connection!.fileDescriptor
        let originalStats = connection!.stats
        weak var originalConnection = connection
        let originalReader = connectionReader!
        let malformed = Data("invalid old message\n".utf8)
        expect(malformed.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == malformed.count,
               "Queue an old read event before disconnect")
        closeConnection()
        closeConnection()
        expect(connection == nil && connectionReader == nil, "Close immediately detaches active connection state")
        expect(originalConnection != nil && originalStats.closes == 0, "Cancellation retains the original connection")
        expect(fcntl(originalFD, F_GETFD) >= 0, "Pending cancellation leaves the original descriptor open")

        let replacementPeer = fixtureConnection()
        let replacement = connection!
        let replacementFD = replacement.fileDescriptor
        expect(replacementFD != originalFD, "Pending cancellation prevents original descriptor reuse")
        var hello = try JSONSerialization.data(withJSONObject: [
            "type": "hello", "protocolVersion": 1, "uid": 501, "user": "fixture", "consoleUser": "fixture",
            "consoleUID": 501, "osVersion": "fixture",
        ])
        hello.append(10)
        expect(hello.withUnsafeBytes { Darwin.write(replacementPeer, $0.baseAddress, $0.count) } == hello.count,
               "Queue replacement greeting")
        try await eventually("Cancellation closes the original connection") { originalStats.closes == 1 }
        try await eventually("Replacement read source processes its own greeting") { guest != nil }
        expect(fcntl(originalFD, F_GETFD) == -1, "Original close releases its own descriptor")
        expect(connection === replacement && replacement.stats.closes == 0 && fcntl(replacementFD, F_GETFD) >= 0,
               "Old cancellation and queued read cannot close the replacement")

        expect(dup2(replacementFD, originalFD) == originalFD, "Reuse the released descriptor number")
        originalReader.cancel()
        try await Task.sleep(for: .milliseconds(20))
        expect(originalStats.closes == 1 && fcntl(originalFD, F_GETFD) >= 0,
               "Repeated old cancellation cannot close a reused descriptor")
        Darwin.close(originalFD)
        closeConnection()
        closeConnection()
        expect(replacement.stats.closes == 0, "Repeated close still defers replacement closure")
        try await eventually("Replacement cancellation closes exactly once") { replacement.stats.closes == 1 }
        expect(fcntl(replacementFD, F_GETFD) == -1, "Replacement closes its own descriptor")
        Darwin.close(peer)
        Darwin.close(replacementPeer)
    }

    func checkCloseWithoutReader() {
        let peer = fixtureConnection(reading: false)
        let original = connection!
        let descriptor = original.fileDescriptor
        closeConnection()
        closeConnection()
        expect(original.stats.closes == 1 && fcntl(descriptor, F_GETFD) == -1,
               "An unregistered connection closes immediately and only once")
        Darwin.close(peer)
    }

    static func checkReleasedHost() async throws {
        var host: Host? = try fixtureHost()
        weak var weakHost = host
        let peer = host!.fixtureConnection()
        let descriptor = host!.connection!.fileDescriptor
        let stats = host!.connection!.stats
        weak var original = host!.connection
        host!.closeConnection()
        host = nil
        expect(weakHost == nil, "Cancellation does not retain the host")
        expect(original != nil && fcntl(descriptor, F_GETFD) >= 0,
               "Detached source retains its connection until cancellation")
        try await eventually("Cancellation closes after host deallocation") { stats.closes == 1 }
        try await eventually("Cancelled source releases its connection") { original == nil }
        expect(fcntl(descriptor, F_GETFD) == -1, "Released connection leaves no descriptor open")
        Darwin.close(peer)
    }
}

@main
@MainActor
private struct HostSocketLifetimeFixture {
    static func main() async throws {
        try Host.fixtureHost().checkCloseWithoutReader()
        try await Host.fixtureHost().checkDeferredClose()
        try await Host.checkReleasedHost()
        print("Host socket lifetime fixtures passed")
    }
}
