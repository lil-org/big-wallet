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

private func writeReceiptAtomically(_ data: Data, to path: String, exclusive: Bool = false) throws {
    let temporary = path + "." + UUID().uuidString + ".tmp"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { close(fd); unlink(temporary) }
    try writeReceiptData(data, to: fd)
    let result = exclusive ? link(temporary, path) : rename(temporary, path)
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private func consoleIdentity() -> (uid: uid_t, name: String)? {
    var info = stat()
    guard stat("/dev/console", &info) == 0, info.st_uid > 0,
          let entry = getpwuid(info.st_uid), let name = entry.pointee.pw_name else { return nil }
    return (info.st_uid, String(cString: name))
}

private func processStart(_ pid: pid_t) throws -> [UInt64]? {
    var information = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    errno = 0
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, Int32(size))
    guard count == size else {
        if errno == ESRCH { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
    }
    guard information.pbi_pid == UInt32(pid), information.pbi_start_tvsec > 0,
          information.pbi_start_tvusec < 1_000_000 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
    }
    return [information.pbi_start_tvsec, information.pbi_start_tvusec]
}

@MainActor
private final class GuestAgent {
    private var process: Process?
    private var signals: [DispatchSourceSignal] = []
    private var runnerLog: FileHandle?
    private var receipt: [String: Any]?
    private var launchFailure: String?
    private var terminationTimer: DispatchSourceTimer?
    private let console: () -> (uid: uid_t, name: String)?
    private let finish: (Int32) -> Void
    private let writeReceipt: (Data, String, Bool) throws -> Void

    init(console: @escaping () -> (uid: uid_t, name: String)? = consoleIdentity,
         writeReceipt: @escaping (Data, String, Bool) throws -> Void = {
             try writeReceiptAtomically($0, to: $1, exclusive: $2)
         },
         finish: @escaping (Int32) -> Void = { exit($0) }) {
        self.console = console
        self.writeReceipt = writeReceipt
        self.finish = finish
    }

    func start() {
        do {
            guard let console = console(), console.uid == getuid(), getuid() != 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
            }
            let jobURL = URL(fileURLWithPath: exchangePath).appendingPathComponent("job.json")
            let data = try readJobFile(jobURL.path)
            guard let job = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runID = job["runId"] as? String,
                  runID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil,
                  let vmID = job["vmId"] as? String, !vmID.isEmpty, vmID.utf8.count <= 128 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
            }
            try claim(runID: runID, vmID: vmID)
            guard isRegularFile(runnerPath), access(runnerPath, X_OK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            }
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
                    MainActor.assumeIsolated { self?.completed(code: child.terminationStatus) }
                }
            }
            installSignalHandlers()
            try child.run()
            runnerLog = log
            process = child
            if let start = try processStart(child.processIdentifier) {
                try publish(state: "running", fields: ["runnerPID": child.processIdentifier, "runnerStart": start])
            }
        } catch {
            let message = "Guest runner could not start (\((error as NSError).domain):\((error as NSError).code))"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            if process != nil {
                launchFailure = message
                terminateChild()
            } else {
                try? publish(state: "failed", fields: ["reason": "guest_launch_failed", "error": message])
                finish(2)
            }
        }
    }

    private func terminateChild() {
        guard let process, terminationTimer == nil else { return }
        if process.isRunning { process.terminate() }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if let child = self?.process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        terminationTimer = timer
        timer.resume()
    }

    private func installSignalHandlers() {
        for value in [SIGINT, SIGTERM, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.terminateChild() }
            }
            source.resume()
            signals.append(source)
        }
    }

    private func claim(runID: String, vmID: String) throws {
        let directory = URL(fileURLWithPath: exchangePath).appendingPathComponent(".agent-runs", isDirectory: true)
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard let start = try processStart(getpid()) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESRCH)) }
        let value: [String: Any] = ["version": 1, "vmId": vmID, "runId": runID,
                                  "agentPID": getpid(), "agentStart": start, "state": "claimed"]
        try writeReceipt(JSONSerialization.data(withJSONObject: value),
                         directory.appendingPathComponent(runID + ".json").path, true)
        receipt = value
    }

    private func publish(state: String, fields: [String: Any]) throws {
        guard var value = receipt, let runID = value["runId"] as? String else { return }
        value["state"] = state
        value.merge(fields) { _, new in new }
        let path = URL(fileURLWithPath: exchangePath).appendingPathComponent(".agent-runs/" + runID + ".json").path
        try writeReceipt(JSONSerialization.data(withJSONObject: value), path, false)
    }

    private func completed(code: Int32) {
        terminationTimer?.cancel()
        terminationTimer = nil
        process = nil
        runnerLog = nil
        do {
            if let launchFailure {
                try publish(state: "failed", fields: ["reason": "guest_launch_failed", "error": launchFailure])
                finish(2)
            } else {
                try publish(state: "completed", fields: ["exitCode": code])
                finish(code)
            }
        } catch {
            FileHandle.standardError.write(Data("Guest completion receipt could not be published\n".utf8))
            finish(2)
        }
    }
}

@main
@MainActor
private struct VMGuestAgentProgram {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--process-identity",
           let pid = Int32(CommandLine.arguments[2]), pid > 1 {
            do {
                let value: Any = try processStart(pid).map { $0 as Any } ?? NSNull()
                let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                FileHandle.standardOutput.write(data)
                return
            } catch { exit(2) }
        }
        guard CommandLine.arguments.count == 1 else {
            FileHandle.standardError.write(Data("The guest supervisor accepts no arguments\n".utf8))
            exit(2)
        }
        let agent = GuestAgent()
        agent.start()
        withExtendedLifetime(agent) { RunLoop.main.run() }
    }
}
