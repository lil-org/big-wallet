import Darwin
import WalletDomain
@testable import WalletAuthority
@testable import WalletNetworking
import Foundation
import Security
import Synchronization

final class HarnessClock: Sendable {
    private let file: URL
    private struct State {
        var milliseconds: Double
        var uptime: UInt64 = 1_000_000_000
        var sleepers = [UUID: (UInt64, CheckedContinuation<Void, Error>)]()
    }
    private let state: Mutex<State>
    private let waitObserver = Mutex<(@Sendable (UUID, Double, Bool) -> Void)?>(nil)

    init(root: URL) {
        file = root.appendingPathComponent("clock.json")
        let data = try? Data(contentsOf: file)
        let value = data.flatMap { try? JSONDecoder().decode(Double.self, from: $0) } ?? 0
        state = Mutex(State(milliseconds: value))
    }

    func now() -> Date {
        Date(timeIntervalSince1970: state.withLock { $0.milliseconds } / 1_000)
    }

    func uptime() -> UInt64 { state.withLock { $0.uptime } }
    var pendingSleeps: Int { state.withLock { $0.sleepers.count } }
    func observeWaits(_ observer: @escaping @Sendable (UUID, Double, Bool) -> Void) {
        waitObserver.withLock { $0 = observer }
    }

    func set(milliseconds: Double) throws {
        guard milliseconds.isFinite, milliseconds >= 0 else { throw HarnessError.invalid("Invalid harness clock") }
        try JSONEncoder().encode(milliseconds).write(to: file, options: .atomic)
        let due = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let elapsed = max(0, milliseconds - state.milliseconds) * 1_000_000
            let delta = elapsed < Double(UInt64.max) ? UInt64(elapsed) : UInt64.max
            let (uptime, overflow) = state.uptime.addingReportingOverflow(delta)
            state.uptime = overflow ? UInt64.max : uptime
            state.milliseconds = milliseconds
            let due = state.sleepers.filter { $0.value.0 <= state.uptime }
            due.keys.forEach { state.sleepers.removeValue(forKey: $0) }
            return due.values.map(\.1)
        }
        due.forEach { $0.resume() }
    }

    func sleep(for nanoseconds: UInt64) async throws {
        let (deadline, overflow) = uptime().addingReportingOverflow(nanoseconds)
        try await sleep(until: overflow ? UInt64.max : deadline)
    }

    func sleep(until deadline: UInt64) async throws {
        let id = UUID()
        let milliseconds = state.withLock { $0.milliseconds + Double(deadline > $0.uptime ? deadline - $0.uptime : 0) / 1_000_000 }
        defer { waitObserver.withLock { $0 }?(id, milliseconds, false) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate = state.withLock { state -> Result<Void, Error>? in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.uptime >= deadline { return .success(()) }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
                else { waitObserver.withLock { $0 }?(id, milliseconds, true) }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func sleep(until date: Date) async throws {
        let remaining = max(0, date.timeIntervalSince(now())) * 1_000_000_000
        try await sleep(for: remaining < Double(UInt64.max) ? UInt64(remaining) : UInt64.max)
    }
}

final class HarnessFixtureStorage: Sendable {
    let root: URL
    let helperURL: URL
    let clock: HarnessClock
    private let fixtureURL: URL
    private let originalURL: URL
    private let lock: AuthorityFileLock

    init(root: URL, role: String) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL, root.pathComponents.count > 2 else { throw HarnessError.invalid("Unsafe harness root") }
        let marker = root.appendingPathComponent(".approval-lifecycle-root")
        let manager = FileManager.default
        if !manager.fileExists(atPath: marker.path) {
            guard role == "bridge", try manager.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw HarnessError.invalid("Harness root must be empty or contain its marker")
            }
            try Data("approval-lifecycle-v1\n".utf8).write(to: marker, options: .withoutOverwriting)
        }
        guard try Data(contentsOf: marker) == Data("approval-lifecycle-v1\n".utf8) else {
            throw HarnessError.invalid("Unexpected harness root marker")
        }
        self.root = root
        helperURL = root.appendingPathComponent("Fixture Helper.app", isDirectory: true)
        fixtureURL = root.appendingPathComponent("wallets.plist")
        originalURL = root.appendingPathComponent("original-wallets.plist")
        lock = AuthorityFileLock(fileURL: root.appendingPathComponent("fixture-wallets.lock"))
        clock = HarnessClock(root: root)
        if role == "bridge", !manager.fileExists(atPath: fixtureURL.path) { try initialize() }
        guard manager.fileExists(atPath: fixtureURL.path) else { throw HarnessError.invalid("Missing fixture wallets") }
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] in copyMatching($0, $1) }, add: { [self] in add($0, $1) },
            update: { [self] in update($0, $1) }, delete: { [self] in delete($0) })
    }

    func restore(walletID: String) throws {
        try withLock {
            var records = try readRecords()
            let originals = try readRecords(at: originalURL)
            guard let data = originals["org.lil.wallet.wallet." + walletID] else { throw HarnessError.invalid("Unknown fixture wallet") }
            records["org.lil.wallet.wallet." + walletID] = data
            try saveRecords(records)
        }
    }

    func originals() throws -> [WalletSnapshot] {
        try withLock {
            try readRecords(at: originalURL).compactMap { key, data in
                guard key.hasPrefix("org.lil.wallet.wallet."), let stored = WalletStoredKey.importJSON(json: data) else { return nil }
                return WalletSnapshot(WalletContainer(id: String(key.dropFirst("org.lil.wallet.wallet.".count)), key: stored))
            }.sorted { $0.id < $1.id }
        }
    }

    private func initialize() throws {
        let password = "approval-fixture-password"
        let passwordData = Data(password.utf8)
        let passwordSecret = SecretBytes(utf8: password)
        defer { passwordSecret.invalidate() }
        var records = ["org.lil.wallet.password": passwordData]
        for (name, coin, seed) in [("fixture-ethereum", WalletCoin.ethereum, UInt8(1)), ("fixture-solana", .solana, UInt8(2))] {
            guard let privateKey = WalletPrivateKey(data: Data(repeating: seed, count: 32)) else { throw HarnessError.invalid("Cannot create fixture key") }
            defer { privateKey.invalidate() }
            guard let key = WalletStoredKey.importPrivateKey(privateKey: privateKey,
                name: name, password: passwordSecret, coin: coin) else { throw HarnessError.invalid("Cannot create fixture key") }
            let wallet = WalletContainer(id: name, key: key)
            _ = try wallet.getAccount(password: passwordSecret, coin: coin)
            guard let data = key.exportJSON() else { throw HarnessError.invalid("Cannot encode fixture wallet") }
            records["org.lil.wallet.wallet." + name] = data
        }
        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        guard let stored = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: "fixture-multicoin", password: passwordSecret, coin: .ethereum),
              let hd = WalletHDWallet(mnemonic: mnemonic, passphrase: ""),
              let ethereum = hd.ethereumPreviewAccounts(accountRange: 0..<2),
              let solana = hd.solanaPreviewAccounts(accountRange: 0..<2) else { throw HarnessError.invalid("Cannot create mnemonic fixture") }
        defer { hd.invalidate() }
        let wallet = WalletContainer(id: "fixture-multicoin", key: stored)
        for account in wallet.accounts { stored.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath) }
        for account in ethereum + solana {
            stored.addAccountDerivation(address: account.address, coin: account.coin, derivation: account.derivation,
                derivationPath: account.derivationPath, publicKey: account.publicKey, extendedPublicKey: account.extendedPublicKey)
        }
        guard let data = stored.exportJSON() else { throw HarnessError.invalid("Cannot encode mnemonic fixture") }
        records["org.lil.wallet.wallet.fixture-multicoin"] = data
        try saveRecords(records)
        try PropertyListEncoder().encode(records).write(to: originalURL, options: .atomic)
        try clock.set(milliseconds: 1_800_000_000_000)
        let contents = helperURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.lil.wallet.approval-fixture",
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1"], format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }

    private func readRecords(at url: URL? = nil) throws -> [String: Data] {
        try PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: url ?? fixtureURL))
    }

    private func saveRecords(_ records: [String: Data]) throws {
        try PropertyListEncoder().encode(records).write(to: fixtureURL, options: .atomic)
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.acquire(timeoutNanoseconds: 2_000_000_000, pollNanoseconds: 1_000_000)
        defer { lock.release() }
        return try operation()
    }

    private func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        do {
            return try withLock {
                let query = query as NSDictionary
                let records = try readRecords()
                if query[kSecReturnAttributes as String] as? Bool == true {
                    result?.pointee = records.keys.sorted().map {
                        [kSecAttrAccount as String: $0, kSecAttrCreationDate as String: Date(timeIntervalSince1970: 1)]
                    } as CFArray
                    return errSecSuccess
                }
                guard let name = query[kSecAttrAccount as String] as? String, let data = records[name] else { return errSecItemNotFound }
                result?.pointee = data as CFData
                return errSecSuccess
            }
        } catch { return errSecIO }
    }

    private func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        mutate(attributes, attributes: attributes, mode: "add")
    }

    private func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        mutate(query, attributes: attributes, mode: "update")
    }

    private func delete(_ query: CFDictionary) -> OSStatus { mutate(query, attributes: nil, mode: "delete") }

    private func mutate(_ query: CFDictionary, attributes: CFDictionary?, mode: String) -> OSStatus {
        do {
            return try withLock {
                guard let name = (query as NSDictionary)[kSecAttrAccount as String] as? String,
                      name == "org.lil.wallet.password" || name.hasPrefix("org.lil.wallet.wallet.") else { return errSecParam }
                var records = try readRecords()
                if mode == "add", records[name] != nil { return errSecDuplicateItem }
                if mode != "add", records[name] == nil { return errSecItemNotFound }
                if mode == "delete" { records[name] = nil }
                else {
                    guard let attributes, let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
                    records[name] = data
                }
                try saveRecords(records)
                return errSecSuccess
            }
        } catch { return errSecIO }
    }
}

final class HarnessPersistence: Sendable {
    private struct Descriptor: Sendable { var path: String; var syncs = 0 }
    private let descriptors = Mutex([Int32: Descriptor]())
    private let ipc: HarnessIPC

    init(ipc: HarnessIPC) { self.ipc = ipc }

    func fileIO(directoryBoundary: URL) -> ExtensionRequestStoreFiles.IO {
        var io = ExtensionRequestStoreFiles.IO(
            persistence: DurableProfilePersistence(
                directoryBoundary: directoryBoundary, operations: operations()
            ))
        let baseIO = io
        io.readData = { [ipc] url in
            let details = HarnessValue.object(["path": .string(url.path)])
            try ipc.checkpointSync("persistence.read.before", details: details)
            let data = try baseIO.readData(url)
            try ipc.checkpointSync("persistence.read.after", details: details)
            return data
        }
        io.readFileSize = { [ipc] url in
            let details = HarnessValue.object(["path": .string(url.path)])
            try ipc.checkpointSync("persistence.stat.before", details: details)
            let size = try baseIO.readFileSize(url)
            try ipc.checkpointSync("persistence.stat.after", details: details)
            return size
        }
        return io
    }

    private func operations() -> DurableProfilePersistence.Operations {
        let live = DurableProfilePersistence.Operations.live
        var operations = live
        operations.openDirectory = { [self] path in
            let descriptor = try live.openDirectory(path)
            descriptors.withLock { $0[descriptor] = Descriptor(path: path) }
            return descriptor
        }
        operations.openFile = { [self] directory, name, flags, mode in
            let descriptor = try live.openFile(directory, name, flags, mode)
            descriptors.withLock { state in
                state[descriptor] = Descriptor(path: (state[directory]?.path ?? "") + "/" + name)
            }
            return descriptor
        }
        operations.write = { [self] descriptor, bytes, count in
            let details = details(descriptor).merging(["requestedBytes": .number(Double(count))])
            try ipc.checkpointSync("persistence.write.before", details: details)
            let written = try live.write(descriptor, bytes, min(count, ipc.partialWriteBytes ?? count))
            try ipc.checkpointSync(
                "persistence.write.after", details: details.merging(["writtenBytes": .number(Double(written))]))
            return written
        }
        operations.fullSync = { [self] descriptor in
            let count = descriptors.withLock { state in
                state[descriptor]?.syncs += 1
                return state[descriptor]?.syncs ?? 1
            }
            let stage = count == 1 ? "fileSync" : "finalSync"
            try ipc.checkpointSync("persistence.\(stage).before", details: details(descriptor))
            try live.fullSync(descriptor)
            try ipc.checkpointSync("persistence.\(stage).after", details: details(descriptor))
        }
        operations.rename = { [self] directory, source, destination in
            let details = details(directory).merging(["source": .string(source), "destination": .string(destination)])
            try ipc.checkpointSync("persistence.rename.before", details: details)
            try live.rename(directory, source, destination)
            try ipc.checkpointSync("persistence.rename.after", details: details)
        }
        operations.syncDirectory = { [self] directory in
            try ipc.checkpointSync("persistence.directorySync.before", details: details(directory))
            try live.syncDirectory(directory)
            try ipc.checkpointSync("persistence.directorySync.after", details: details(directory))
        }
        operations.close = { [self] descriptor in
            descriptors.withLock { _ = $0.removeValue(forKey: descriptor) }
            live.close(descriptor)
        }
        return operations
    }

    private func details(_ descriptor: Int32) -> HarnessValue {
        .object(["path": .string(descriptors.withLock { $0[descriptor]?.path ?? "unknown" })])
    }
}
