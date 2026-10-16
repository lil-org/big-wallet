import Darwin
import AppKit
import Foundation
import Virtualization

private struct RunnerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Options {
    let vm: URL
    let exchange: URL
    let status: URL
    let stopFile: URL
    let ownerPID: pid_t
    let provisionUser: String?
    let provisionPasswordFile: URL?
    let setupWindow: Bool

    init(arguments: [String]) throws {
        let allowed: Set<String> = ["--vm", "--exchange", "--status", "--stop-file", "--owner-pid", "--provision-user", "--provision-password-file"]
        var values: [String: String] = [:]
        var setupWindow = false
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--setup-window" {
                guard !setupWindow else { throw RunnerFailure("Duplicate setup-window option") }
                setupWindow = true
                index += 1
                continue
            }
            guard allowed.contains(key), values[key] == nil, index + 1 < arguments.count else {
                throw RunnerFailure("Invalid or duplicate command-line option")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        func path(_ key: String) throws -> URL {
            guard let value = values[key], value.hasPrefix("/"), !value.contains("\0") else {
                throw RunnerFailure("Missing or nonabsolute path for \(key)")
            }
            guard !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw RunnerFailure("Path must not contain relative components for \(key)")
            }
            return URL(fileURLWithPath: value)
        }
        vm = try path("--vm")
        exchange = try path("--exchange")
        status = try path("--status")
        stopFile = try path("--stop-file")
        guard let rawPID = values["--owner-pid"], let pid = Int32(rawPID), pid > 1, pid != getpid() else {
            throw RunnerFailure("Invalid owner PID")
        }
        ownerPID = pid
        provisionUser = values["--provision-user"]
        provisionPasswordFile = try values["--provision-password-file"].map { _ in try path("--provision-password-file") }
        self.setupWindow = setupWindow
        guard (provisionUser == nil) == (provisionPasswordFile == nil) else {
            throw RunnerFailure("Provisioning requires both a username and a password file")
        }
        if let user = provisionUser {
            guard user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil else {
                throw RunnerFailure("Invalid provisioning username")
            }
        }
    }
}

private func checkedPath(_ url: URL, directory: Bool, mayBeMissing: Bool = false) throws {
    let components = url.pathComponents
    var current = ""
    for (index, component) in components.enumerated() {
        current = index == 0 ? "/" : (current as NSString).appendingPathComponent(component)
        var info = stat()
        if lstat(current, &info) != 0 {
            if index == components.count - 1 && mayBeMissing && errno == ENOENT { return }
            throw RunnerFailure("Required path is unavailable: \(url.lastPathComponent)")
        }
        let expected = index < components.count - 1 || directory ? S_IFDIR : S_IFREG
        guard info.st_mode & S_IFMT == expected else {
            throw RunnerFailure("Path contains a symlink or unexpected file type: \(url.lastPathComponent)")
        }
    }
}

private func boundedData(_ url: URL, maximum: Int) throws -> Data {
    try checkedPath(url, directory: false)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= maximum else {
        throw RunnerFailure("Input file is too large: \(url.lastPathComponent)")
    }
    return try Data(contentsOf: url)
}

private func within(_ child: URL, _ parent: URL) -> Bool {
    child.path == parent.path || child.path.hasPrefix(parent.path + "/")
}

private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

@MainActor
private final class Host: NSObject, VZVirtualMachineDelegate, @MainActor VZVirtioSocketListenerDelegate, NSWindowDelegate {
    private let options: Options
    private var machine: VZVirtualMachine?
    private var setupWindow: NSWindow?
    private var setupView: VZVirtualMachineView?
    private var listener: VZVirtioSocketListener?
    private var connection: VZVirtioSocketConnection?
    private var connectionAttempts = 0
    private var connectionReader: DispatchSourceRead?
    private var input = Data()
    private var pendingOutput = Data()
    private var lockFD: Int32 = -1
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var state = "starting"
    private var guest: [String: Any]?
    private var lastGuestEvent: [String: Any]?
    private var lastHeartbeat: Date?
    private var connectedAt: Date?
    private var shutdownStarted: Date?
    private var stopReason: String?
    private var failure: String?
    private var forceStopRequested = false
    private let startedAt = timestamp()
    private let sessionID = UUID().uuidString

    init(options: Options) { self.options = options }

    func start() throws {
        try validatePaths()
        try acquireLock()
        try writeStatus()
        if stopRequested() { finish(code: 0); return }
        let configuration = try makeConfiguration()
        try configuration.validate()
        let machine = VZVirtualMachine(configuration: configuration, queue: .main)
        self.machine = machine
        machine.delegate = self
        guard let socket = machine.socketDevices.first as? VZVirtioSocketDevice else {
            throw RunnerFailure("Virtio socket device is unavailable")
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        socket.setSocketListener(listener, forPort: 50777)
        self.listener = listener
        installWatchdog()
        let startOptions = try makeStartOptions()
        machine.start(options: startOptions) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    self.fail("VM start failed (\((error as NSError).domain):\((error as NSError).code))")
                } else {
                    if self.shutdownStarted != nil {
                        self.requestShutdown()
                    } else {
                        self.state = "running"
                        self.publishStatus()
                        self.showSetupWindowIfRequested()
                    }
                }
            }
        }
    }

    private func validatePaths() throws {
        guard options.vm.pathExtension == "vbvm" else { throw RunnerFailure("VM must be a .vbvm bundle") }
        try checkedPath(options.vm, directory: true)
        try checkedPath(options.exchange, directory: true)
        try checkedPath(options.status, directory: false, mayBeMissing: true)
        try checkedPath(options.stopFile, directory: false, mayBeMissing: true)
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard options.exchange.pathComponents.count >= 4, options.exchange != home,
              !within(options.vm, options.exchange), !within(options.exchange, options.vm),
              options.status != options.stopFile,
              !within(options.status, options.vm), !within(options.stopFile, options.vm) else {
            throw RunnerFailure("Exchange and control paths must be scoped outside the VM bundle")
        }
        for filename in ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier", ".vbdata/Config.plist"] {
            try checkedPath(options.vm.appendingPathComponent(filename), directory: false)
        }
        try checkedPath(options.vm.appendingPathComponent("BuildData.img"), directory: false, mayBeMissing: true)
    }

    private func showSetupWindowIfRequested() {
        guard options.setupWindow, setupWindow == nil, let machine else { return }
        let frame = NSRect(x: 0, y: 0, width: 1120, height: 700)
        let view = VZVirtualMachineView(frame: frame)
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = false
        view.virtualMachine = machine
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Big Wallet Test VM — Setup"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.contentView = view
        window.delegate = self
        setupWindow = window
        setupView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApplication.shared.activate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === setupWindow else { return true }
        beginShutdown(reason: "setup-window-closed")
        return true
    }

    private func acquireLock() throws {
        let url = options.vm.appendingPathComponent(".big-wallet-vm-run.lock")
        try checkedPath(url, directory: false, mayBeMissing: true)
        lockFD = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw RunnerFailure("VM is already owned by another runner or cannot be locked")
        }
    }

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let data = try boundedData(options.vm.appendingPathComponent(".vbdata/Config.plist"), maximum: 1024 * 1024)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["systemType"] as? String == "mac", let hardware = plist["hardware"] as? [String: Any],
              let cpu = hardware["cpuCount"] as? NSNumber, let memory = hardware["memorySize"] as? NSNumber,
              cpu.intValue >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
              cpu.intValue <= VZVirtualMachineConfiguration.maximumAllowedCPUCount,
              memory.uint64Value >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
              memory.uint64Value <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else {
            throw RunnerFailure("Unsupported VM configuration or host resource limits")
        }
        let platform = VZMacPlatformConfiguration()
        guard let model = VZMacHardwareModel(dataRepresentation: try boundedData(options.vm.appendingPathComponent("HardwareModel"), maximum: 65536)), model.isSupported,
              let identifier = VZMacMachineIdentifier(dataRepresentation: try boundedData(options.vm.appendingPathComponent("MachineIdentifier"), maximum: 65536)) else {
            throw RunnerFailure("VM hardware model or machine identity is unsupported")
        }
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: options.vm.appendingPathComponent("AuxiliaryStorage"))
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = cpu.intValue
        configuration.memorySize = memory.uint64Value
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 110)]
        configuration.graphicsDevices = [graphics]
        let silentOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
        silentOutput.sink = nil
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [silentOutput]
        configuration.audioDevices = [sound]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        let network = VZVirtioNetworkDeviceConfiguration()
        if let networks = hardware["networkDevices"] as? [[String: Any]], let raw = networks.first?["macAddress"] as? String {
            guard let address = VZMACAddress(string: raw) else { throw RunnerFailure("VM MAC address is invalid") }
            network.macAddress = address
        }
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let attachment = try VZDiskImageStorageDeviceAttachment(url: options.vm.appendingPathComponent("Disk.img"), readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        let buildData = options.vm.appendingPathComponent("BuildData.img")
        if FileManager.default.fileExists(atPath: buildData.path) {
            let buildAttachment = try VZDiskImageStorageDeviceAttachment(url: buildData, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
            configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: buildAttachment))
        }
        configuration.directorySharingDevices = []
        return configuration
    }

    private func makeStartOptions() throws -> VZMacOSVirtualMachineStartOptions {
        let start = VZMacOSVirtualMachineStartOptions()
        guard let user = options.provisionUser, let passwordFile = options.provisionPasswordFile else { return start }
        guard #available(macOS 27.0, *) else { throw RunnerFailure("Guest provisioning requires macOS 27") }
        try checkedPath(passwordFile, directory: false)
        var info = stat()
        guard lstat(passwordFile.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              var password = String(data: try boundedData(passwordFile, maximum: 4096), encoding: .utf8) else {
            throw RunnerFailure("Provisioning password file must be private, owned by this user, and UTF-8")
        }
        if password.hasSuffix("\n") { password.removeLast(); if password.hasSuffix("\r") { password.removeLast() } }
        guard !password.isEmpty, !password.contains("\0"), !password.contains("\n") else {
            throw RunnerFailure("Provisioning password file is invalid")
        }
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.username = user
        provisioning.fullName = "Big Wallet Tests"
        provisioning.password = password
        provisioning.logsInAutomatically = true
        provisioning.enablesRemoteLogin = true
        do { try start.setGuestProvisioning(provisioning) }
        catch { throw RunnerFailure("Guest provisioning options failed validation") }
        return start
    }

    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer.resume()
        self.timer = timer
        for value in [SIGINT, SIGTERM, SIGHUP] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.beginShutdown(reason: "signal") }
            }
            source.resume()
            signals.append(source)
        }
    }

    private func stopRequested() -> Bool {
        if FileManager.default.fileExists(atPath: options.stopFile.path) {
            stopReason = "stop-file"
            return true
        }
        if kill(options.ownerPID, 0) != 0 && errno == ESRCH {
            stopReason = "owner-exited"
            return true
        }
        return false
    }

    private func tick() {
        if shutdownStarted == nil && stopRequested() { beginShutdown(reason: stopReason ?? "requested") }
        if let since = shutdownStarted {
            if Date().timeIntervalSince(since) >= 15 && !forceStopRequested { forceStop() }
            if Date().timeIntervalSince(since) >= 25 { finish(code: failure == nil ? 0 : 1) }
        }
        if let last = lastHeartbeat ?? connectedAt, Date().timeIntervalSince(last) > 15 { closeConnection() }
        if connection != nil { send(["type": "heartbeat", "protocolVersion": 1, "sessionId": sessionID]) }
        publishStatus()
    }

    private func beginShutdown(reason: String) {
        guard shutdownStarted == nil else { return }
        shutdownStarted = Date()
        stopReason = reason
        state = "stopping"
        publishStatus()
        requestShutdown()
    }

    private func requestShutdown() {
        guard let machine else { finish(code: failure == nil ? 0 : 1); return }
        if machine.state == .stopped || machine.state == .error { finish(code: failure == nil ? 0 : 1); return }
        guard machine.state == .running else { return }
        do { try machine.requestStop() } catch { forceStop() }
    }

    private func forceStop() {
        guard !forceStopRequested, let machine else { return }
        forceStopRequested = true
        machine.stop { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { self.failure = "VM force stop failed (\((error as NSError).code))" }
                self.finish(code: self.failure == nil ? 0 : 1)
            }
        }
    }

    private func fail(_ message: String) {
        failure = message
        if machine?.state == .running { beginShutdown(reason: "error") }
        else { finish(code: 1) }
    }

    func startupFailed(_ error: Error) {
        failure = (error as? RunnerFailure)?.description ?? "VM configuration failed (\((error as NSError).domain):\((error as NSError).code))"
        finish(code: 1)
    }

    private func finish(code: Int32) {
        closeConnection()
        state = code == 0 ? "stopped" : "failed"
        try? writeStatus()
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
        if let failure { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
        exit(code)
    }

    private func writeStatus() throws {
        var status: [String: Any] = [
            "schemaVersion": 1, "state": state, "running": machine?.state == .running,
            "guestConnected": connection != nil && guest != nil, "hostPID": getpid(), "ownerPID": options.ownerPID,
            "connectionPending": connection != nil && guest == nil, "connectionAttempts": connectionAttempts,
            "vmPath": options.vm.path, "sessionId": sessionID, "startedAt": startedAt, "updatedAt": timestamp(),
        ]
        if let guest { status["guest"] = guest }
        if let lastGuestEvent { status["lastGuestEvent"] = lastGuestEvent }
        if let lastHeartbeat { status["lastHeartbeatAt"] = ISO8601DateFormatter().string(from: lastHeartbeat) }
        if let stopReason { status["stopReason"] = stopReason }
        if let failure { status["error"] = failure }
        try checkedPath(options.status, directory: false, mayBeMissing: true)
        try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: options.status, options: .atomic)
    }

    private func publishStatus() {
        do { try writeStatus() }
        catch {
            if failure == nil { failure = "Cannot publish VM status" }
            if shutdownStarted == nil { beginShutdown(reason: "status-write-failed") }
        }
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        connectionAttempts += 1
        guard shutdownStarted == nil, self.connection == nil else { return false }
        self.connection = connection
        connectedAt = Date()
        let fd = connection.fileDescriptor
        guard fd >= 0 else { self.connection = nil; return false }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        startReading(connection)
        send(["type": "hello", "role": "host", "protocolVersion": 1, "sessionId": sessionID])
        return true
    }

    private func startReading(_ connection: VZVirtioSocketConnection) {
        let fd = connection.fileDescriptor
        let read: @MainActor () -> Void = { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            self.readConnection()
        }
        let close: @MainActor () -> Void = { connection.close() }
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        reader.setEventHandler { MainActor.assumeIsolated { read() } }
        reader.setCancelHandler { MainActor.assumeIsolated { close() } }
        reader.resume()
        connectionReader = reader
    }

    private func readConnection() {
        guard let connection else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(connection.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                input.append(contentsOf: bytes.prefix(count))
                guard input.count <= 65536 else { closeConnection(); return }
                while let newline = input.firstIndex(of: 10) {
                    let line = Data(input[..<newline])
                    input.removeSubrange(...newline)
                    guard line.count <= 16384, accept(line) else { closeConnection(); return }
                }
            } else if count == 0 { closeConnection(); return }
            else if errno == EINTR { continue }
            else if errno != EAGAIN && errno != EWOULDBLOCK { closeConnection(); return }
            else { return }
        }
    }

    private func accept(_ line: Data) -> Bool {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              message["protocolVersion"] as? Int == 1, let type = message["type"] as? String else { return false }
        if type == "hello" {
            guard guest == nil, let uid = message["uid"] as? Int, uid > 0,
                  let user = message["user"] as? String, user.count <= 256,
                  let consoleUser = message["consoleUser"] as? String, consoleUser == user,
                  let consoleUID = message["consoleUID"] as? Int, consoleUID == uid,
                  let os = message["osVersion"] as? String, os.count <= 256 else { return false }
            guest = ["protocolVersion": 1, "uid": uid, "user": user, "consoleUser": consoleUser, "consoleUID": consoleUID, "osVersion": os]
            send(["type": "helloAck", "protocolVersion": 1, "accepted": true, "sessionId": sessionID])
        } else {
            guard guest != nil, ["heartbeat", "jobStarted", "jobFinished", "agentError"].contains(type) else { return false }
            if type != "heartbeat" {
                var event: [String: Any] = ["type": type, "receivedAt": timestamp()]
                if let runID = message["runId"] as? String, runID.count <= 128 { event["runId"] = runID }
                if let code = message["exitCode"] as? Int { event["exitCode"] = code }
                if let error = message["error"] as? String { event["error"] = String(error.prefix(512)) }
                lastGuestEvent = event
            }
        }
        lastHeartbeat = Date()
        publishStatus()
        return true
    }

    private func send(_ message: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        pendingOutput.append(data)
        pendingOutput.append(10)
        guard pendingOutput.count <= 65536 else { closeConnection(); return }
        while !pendingOutput.isEmpty {
            let written = pendingOutput.withUnsafeBytes { Darwin.write(connection.fileDescriptor, $0.baseAddress, $0.count) }
            if written > 0 { pendingOutput.removeFirst(written) }
            else if written < 0 && errno == EINTR { continue }
            else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else { closeConnection(); return }
        }
    }

    private func closeConnection() {
        let previousReader = connectionReader
        let previousConnection = connection
        connectionReader = nil
        connection = nil
        if let previousReader { previousReader.cancel() }
        else { previousConnection?.close() }
        guest = nil
        connectedAt = nil
        lastHeartbeat = nil
        input.removeAll()
        pendingOutput.removeAll()
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { finish(code: failure == nil ? 0 : 1) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            failure = "VM stopped with an error (\((error as NSError).domain):\((error as NSError).code))"
            finish(code: 1)
        }
    }
}

@main
@MainActor
private struct VMHostProgram {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let application = NSApplication.shared
            let policy: NSApplication.ActivationPolicy = options.setupWindow ? .regular : .prohibited
            if application.activationPolicy() != policy {
                _ = application.setActivationPolicy(policy)
            }
            guard application.activationPolicy() == policy else {
                throw RunnerFailure("VM host could not apply the requested application activation policy")
            }
            let host = Host(options: options)
            do { try host.start() } catch { host.startupFailed(error) }
            withExtendedLifetime(host) { application.run() }
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            exit(2)
        }
    }
}
