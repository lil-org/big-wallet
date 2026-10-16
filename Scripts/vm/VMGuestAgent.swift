import Darwin
import Foundation

private let exchangePath = "/Volumes/BigWalletBuild/Exchange"
private let runnerPath = "/usr/local/libexec/big-wallet-vm/guest_runner"

private func isRegularFile(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
}

private func readJobFile(_ path: String) throws -> Data {
    let maximum = 1024 * 1024
    var fd: Int32
    repeat { fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    while fd < 0 && errno == EINTR
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd) }
    var info = stat()
    var result: Int32
    repeat { result = fstat(fd, &info) } while result != 0 && errno == EINTR
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard info.st_mode & S_IFMT == S_IFREG else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)) }
    guard info.st_size >= 0 && info.st_size <= maximum else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG)) }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &bytes, min(bytes.count, maximum - data.count + 1))
        if count == 0 { return data }
        if count < 0 {
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard count <= maximum - data.count else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFBIG)) }
        data.append(contentsOf: bytes.prefix(count))
    }
}

private func writeReceiptData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(count == 0 ? EIO : errno)) }
            offset += count
        }
    }
    var result: Int32
    repeat { result = fsync(fd) } while result != 0 && errno == EINTR
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private func writeReceiptAtomically(_ data: Data, to path: String) throws {
    let temporary = path + "." + UUID().uuidString + ".tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd); unlink(temporary) }
    try writeReceiptData(data, to: fd)
    guard rename(temporary, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private func consoleIdentity() -> (uid: uid_t, name: String)? {
    var info = stat()
    guard stat("/dev/console", &info) == 0, info.st_uid > 0,
          let entry = getpwuid(info.st_uid), let name = entry.pointee.pw_name else { return nil }
    return (info.st_uid, String(cString: name))
}

private enum SocketConnectionOutcome: Sendable {
    case connected(Int32)
    case failed(String, Int32)

    static func establish() -> SocketConnectionOutcome {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket", errno) }
        func failed(_ operation: String, _ code: Int32) -> SocketConnectionOutcome {
            close(fd)
            return .failed(operation, code)
        }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return failed("socket-SO_NOSIGPIPE", errno)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            return failed("socket-flags", errno)
        }
        // Darwin virtio sockets require blocking connect; the kernel timeout bounds this background attempt.
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return failed("connect-timeout", errno)
        }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_cid = UInt32(VMADDR_CID_HOST)
        address.svm_port = 50777
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard result == 0 else { return failed("connect", errno) }
        timeout = timeval()
        guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return failed("connected-socket-flags", errno)
        }
        return .connected(fd)
    }
}

@MainActor
private final class GuestAgent {
    private var socketFD: Int32 = -1
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var input = Data()
    private var output = Data()
    private var acknowledged = false
    private var lastHostMessage: Date?
    private var process: Process?
    private var activeRunID: String?
    private var seenRunIDs = Set<String>()
    private var lastError: String?
    private var terminalEvent: [String: Any]?
    private var runnerLog: FileHandle?
    private let connectQueue = DispatchQueue(label: "org.lil.big-wallet.vm.connect", qos: .utility)
    private var connectAttempt: UUID?
    private var diagnosticTimes: [String: Date] = [:]

    func start() {
        for value in [SIGINT, SIGTERM, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.process?.terminate()
                    self?.disconnect()
                    exit(0)
                }
            }
            source.resume()
            signals.append(source)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let console = consoleIdentity(), console.uid == getuid(), getuid() != 0 else {
            diagnose("console-session", phase: "waiting-console", code: 0)
            disconnect()
            return
        }
        if let last = lastHostMessage, Date().timeIntervalSince(last) > 15 {
            diagnose("host-heartbeat", phase: "error", code: ETIMEDOUT)
            disconnect()
        }
        if socketFD < 0 && connectAttempt == nil { connect(console: console) }
        if socketFD >= 0 {
            var heartbeat: [String: Any] = ["type": "heartbeat", "protocolVersion": 1]
            if let activeRunID { heartbeat["runId"] = activeRunID }
            send(heartbeat)
        }
        if acknowledged { inspectJob() }
    }

    private func connect(console: (uid: uid_t, name: String)) {
        let attempt = UUID()
        connectAttempt = attempt
        diagnose("connect-start", phase: "connecting", code: 0)
        connectQueue.async { [self] in
            let outcome = SocketConnectionOutcome.establish()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.completeConnect(outcome, attempt: attempt, console: console)
                }
            }
        }
    }

    private func completeConnect(_ outcome: SocketConnectionOutcome, attempt: UUID, console: (uid: uid_t, name: String)) {
        guard connectAttempt == attempt else {
            if case .connected(let fd) = outcome { close(fd) }
            return
        }
        connectAttempt = nil
        let fd: Int32
        switch outcome {
        case .failed(let operation, let code):
            diagnose(operation, phase: "error", code: code)
            return
        case .connected(let descriptor):
            fd = descriptor
        }
        guard socketFD < 0, let current = consoleIdentity(), current.uid == console.uid,
              current.name == console.name, current.uid == getuid() else {
            close(fd)
            diagnose("console-changed", phase: "waiting-console", code: 0)
            return
        }
        socketFD = fd
        lastHostMessage = Date()
        diagnose("connected", phase: "awaiting-hello-ack", code: 0)
        startReading(fd)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        send(["type": "hello", "protocolVersion": 1, "uid": getuid(), "user": NSUserName(),
              "consoleUser": console.name, "consoleUID": console.uid, "osVersion": os])
    }

    private func startReading(_ fd: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.socketFD == fd else { return }
                self.readMessages()
            }
        }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        self.reader = reader
    }

    private func readMessages() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(socketFD, &bytes, bytes.count)
            if count > 0 {
                input.append(contentsOf: bytes.prefix(count))
                guard input.count <= 65536 else {
                    diagnose("receive-limit", phase: "error", code: EMSGSIZE)
                    disconnect()
                    return
                }
                while let newline = input.firstIndex(of: 10) {
                    let line = Data(input[..<newline])
                    input.removeSubrange(...newline)
                    guard line.count <= 16384,
                          let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          message["protocolVersion"] as? Int == 1,
                          let type = message["type"] as? String,
                          ["hello", "helloAck", "heartbeat"].contains(type) else {
                        diagnose("host-message", phase: "error", code: EPROTO)
                        disconnect()
                        return
                    }
                    if type == "helloAck" {
                        guard message["accepted"] as? Bool == true else {
                            diagnose("hello-ack-rejected", phase: "error", code: EPROTO)
                            disconnect()
                            return
                        }
                        acknowledged = true
                        diagnose("hello-ack", phase: "ready", code: 0)
                        if let terminalEvent { send(terminalEvent) }
                    }
                    lastHostMessage = Date()
                }
            } else if count == 0 {
                diagnose("host-closed", phase: "disconnected", code: 0)
                disconnect()
                return
            }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else {
                let failure = errno
                diagnose("read", phase: "error", code: failure)
                disconnect()
                return
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard socketFD >= 0, let encoded = try? JSONSerialization.data(withJSONObject: message) else { return }
        output.append(encoded)
        output.append(10)
        guard output.count <= 65536 else {
            diagnose("send-limit", phase: "error", code: EMSGSIZE)
            disconnect()
            return
        }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(socketFD, $0.baseAddress, $0.count) }
            if count > 0 { output.removeFirst(count) }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else {
                let failure = count == 0 ? EPIPE : errno
                diagnose("write", phase: "error", code: failure)
                disconnect()
                return
            }
        }
    }

    private func diagnose(_ operation: String, phase: String, code: Int32) {
        let description = code == 0 ? "" : String(cString: strerror(code))
        logDiagnostic(key: "\(operation):\(code)",
                      message: "transport \(operation), phase=\(phase), errno=\(code)\(description.isEmpty ? "" : " (\(description))")")
    }

    private func logDiagnostic(key: String, message: String) {
        let now = Date()
        if let previous = diagnosticTimes[key], now.timeIntervalSince(previous) < 60 { return }
        if diagnosticTimes.count >= 64, let oldest = diagnosticTimes.min(by: { $0.value < $1.value })?.key {
            diagnosticTimes.removeValue(forKey: oldest)
        }
        diagnosticTimes[key] = now
        let timestamp = ISO8601DateFormatter().string(from: now)
        FileHandle.standardError.write(Data(("\(timestamp) VMGuestAgent: \(message)\n").utf8))
    }

    private func disconnect() {
        connectAttempt = nil
        let previousReader = reader
        let previousFD = socketFD
        reader = nil
        socketFD = -1
        if let previousReader { previousReader.cancel() }
        else if previousFD >= 0 { close(previousFD) }
        input.removeAll()
        output.removeAll()
        acknowledged = false
        lastHostMessage = nil
    }

    private func inspectJob() {
        guard process == nil else { return }
        let jobURL = URL(fileURLWithPath: exchangePath).appendingPathComponent("job.json")
        guard let data = try? readJobFile(jobURL.path),
              let job = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runID = job["runId"] as? String,
              runID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              !seenRunIDs.contains(runID) else { return }
        guard isRegularFile(runnerPath), access(runnerPath, X_OK) == 0 else {
            reportError("Guest runner is not installed or executable", runID: runID)
            return
        }
        do {
            guard try claim(runID) else {
                seenRunIDs.insert(runID)
                reportError("This runId was already claimed; refusing to repeat it", runID: runID)
                return
            }
            seenRunIDs.insert(runID)
            let logURL = URL(fileURLWithPath: exchangePath).appendingPathComponent("guest-runner.log")
            let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard logFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let log = FileHandle(fileDescriptor: logFD, closeOnDealloc: true)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: runnerPath)
            child.arguments = [jobURL.path]
            child.currentDirectoryURL = URL(fileURLWithPath: exchangePath)
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = log
            child.standardError = log
            child.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(),
                                 "USER": NSUserName(), "LOGNAME": NSUserName(), "TMPDIR": NSTemporaryDirectory(),
                                 "BW_VM_EXCHANGE": exchangePath]
            child.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.completed(runID: runID, code: child.terminationStatus)
                    }
                }
            }
            try child.run()
            runnerLog = log
            process = child
            activeRunID = runID
            send(["type": "jobStarted", "protocolVersion": 1, "runId": runID])
        } catch {
            reportError("Guest runner could not start (\((error as NSError).domain):\((error as NSError).code))", runID: runID)
        }
    }

    private func claim(_ runID: String) throws -> Bool {
        let directory = URL(fileURLWithPath: exchangePath).appendingPathComponent(".agent-runs", isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        let receipt = directory.appendingPathComponent(runID + ".json")
        let fd = open(receipt.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 && errno == EEXIST { return false }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        let data = try JSONSerialization.data(withJSONObject: ["runId": runID, "state": "claimed", "agentPID": getpid()])
        try writeReceiptData(data, to: fd)
        return true
    }

    private func completed(runID: String, code: Int32) {
        process = nil
        activeRunID = nil
        runnerLog = nil
        let receipt = URL(fileURLWithPath: exchangePath).appendingPathComponent(".agent-runs/" + runID + ".json")
        if let data = try? JSONSerialization.data(withJSONObject: ["runId": runID, "state": "completed", "exitCode": code]) {
            try? writeReceiptAtomically(data, to: receipt.path)
        }
        sendTerminalEvent(["type": "jobFinished", "protocolVersion": 1, "runId": runID, "exitCode": code])
    }

    private func reportError(_ message: String, runID: String) {
        guard lastError != message || terminalEvent?["runId"] as? String != runID else { return }
        lastError = message
        FileHandle.standardError.write(Data((message + "\n").utf8))
        sendTerminalEvent(["type": "agentError", "protocolVersion": 1, "runId": runID, "error": message])
    }

    private func sendTerminalEvent(_ message: [String: Any]) {
        terminalEvent = message
        if acknowledged { send(message) }
    }
}

@main
@MainActor
private struct VMGuestAgentProgram {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty && arguments != ["--runner", runnerPath, "--port", "50777"] {
            FileHandle.standardError.write(Data("Only the fixed guest runner and vsock port are supported\n".utf8))
            exit(2)
        }
        let agent = GuestAgent()
        agent.start()
        withExtendedLifetime(agent) { RunLoop.main.run() }
    }
}
