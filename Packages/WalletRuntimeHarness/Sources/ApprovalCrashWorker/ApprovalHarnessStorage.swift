import Darwin
import CryptoKit
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
    private let acknowledgedGrantProofs = Mutex(Set<String>())
    private let ipc: HarnessIPC

    init(ipc: HarnessIPC) { self.ipc = ipc }

    func fileIO(directoryBoundary: URL) -> ExtensionRequestStoreFiles.IO {
        var io = ExtensionRequestStoreFiles.IO(
            persistence: DurableProfilePersistence(
                directoryBoundary: directoryBoundary, operations: operations(directoryBoundary: directoryBoundary)
            ))
        let baseIO = io
        io.replace = { [self] data, url in
            if url.standardizedFileURL == directoryBoundary.appendingPathComponent("bridge/wallet-authority-revocations.state").standardizedFileURL {
                try confirmPublishedGrants(directoryBoundary: directoryBoundary)
            }
            try prepareGrantCandidate(data: data, url: url, directoryBoundary: directoryBoundary)
            try baseIO.replace(data, url)
            try confirmPublishedGrant(at: url, directoryBoundary: directoryBoundary)
        }
        io.synchronizePublishedFile = { [self] url in
            try baseIO.synchronizePublishedFile(url)
            try confirmPublishedGrant(at: url, directoryBoundary: directoryBoundary)
        }
        io.readData = { [self] url in
            let details = HarnessValue.object(["path": .string(url.path)])
            try ipc.checkpointSync("persistence.read.before", details: details)
            let data = try baseIO.readData(url)
            try confirmPublishedGrant(data: data, url: url, directoryBoundary: directoryBoundary)
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

    private func operations(directoryBoundary: URL) -> DurableProfilePersistence.Operations {
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
            if stage == "finalSync", let path = descriptors.withLock({ $0[descriptor]?.path }) {
                try confirmPublishedGrant(at: URL(fileURLWithPath: path), directoryBoundary: directoryBoundary)
            }
            try ipc.checkpointSync("persistence.\(stage).after", details: details(descriptor))
        }
        operations.rename = { [self] directory, source, destination in
            let details = details(directory).merging(["source": .string(source), "destination": .string(destination)])
            try ipc.checkpointSync("persistence.rename.before", details: details)
            try live.rename(directory, source, destination)
            if let parent = descriptors.withLock({ $0[directory]?.path }) {
                let sourcePath = (parent as NSString).appendingPathComponent(source)
                let destinationPath = (parent as NSString).appendingPathComponent(destination)
                descriptors.withLock { state in
                    for descriptor in state.keys where state[descriptor]?.path == sourcePath {
                        state[descriptor]?.path = destinationPath
                    }
                }
                try confirmPublishedGrant(at: URL(fileURLWithPath: destinationPath), directoryBoundary: directoryBoundary)
            }
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

    private func isProfile(_ url: URL, directoryBoundary: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directoryBoundary
            .appendingPathComponent("bridge/profiles-v\(ExtensionRequestProfile.profileSchemaVersion)", isDirectory: true).standardizedFileURL &&
            url.pathExtension == "state"
    }

    private func prepareGrantCandidate(data: Data, url: URL, directoryBoundary: URL) throws {
        guard isProfile(url, directoryBoundary: directoryBoundary), HarnessOperation.name == "completion",
              let handle = try? harnessDecodeHandle(HarnessOperation.identity),
              let executionID = HarnessOperation.identity["executionID"].string,
              UUID(uuidString: executionID) != nil else { return }
        let beforeData = try readBounded(url, maximum: 16 * 1024 * 1024)
        let before = try PropertyListDecoder().decode(ExtensionRequestProfile.State.self, from: beforeData)
        let after = try PropertyListDecoder().decode(ExtensionRequestProfile.State.self, from: data)
        guard before.profileIdentifier == handle.profileIdentifier, after.profileIdentifier == handle.profileIdentifier,
              let oldRecord = before.records.first(where: { $0.handle == handle }),
              case .claimed(_, let request, _) = oldRecord.state,
              let record = after.records.first(where: { $0.handle == handle }),
              record.configurationKey == oldRecord.configurationKey, record.requestFingerprint == oldRecord.requestFingerprint,
              case .completed(_, let responseData, _) = record.state,
              let response = ExtensionRequestProfileCodec.decodeResponseData(responseData, id: handle.id),
              response.approvalCommitted, case .result = response.payload,
              ["requestAccounts", "connect", "switchAccount"].contains(request.name), response.name == request.name,
              response.provider == (request.provider == .unknown && request.name == "switchAccount" ? .multiple : request.provider) else { return }
        let digest = Self.profileDigest(data)
        let proof = HarnessValue.object([
            "handle": harnessHandle(handle), "executionID": .string(executionID),
            "configurationKey": .string(record.configurationKey),
            "state": try HarnessValue.convert(ExtensionRequestProfile.authoritySnapshot(after, configurationKey: record.configurationKey).json),
            "response": try HarnessValue.convert(response.json), "profileSHA256": .string(digest),
            "creatorEpoch": .string(ipc.epoch), "creatorRole": .string(ipc.role),
        ])
        let candidate = candidateURL(digest, directoryBoundary: directoryBoundary)
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: candidate.path) {
            let existing = try readCandidate(candidate, digest: digest)
            guard try harnessDecodeHandle(existing["handle"]) == handle,
                  existing["configurationKey"].string == record.configurationKey else {
                throw HarnessError.invalid("Grant candidate identity changed")
            }
            if existing["executionID"].string == executionID { return }
            let published = try readBounded(url, maximum: 16 * 1024 * 1024)
            guard published == beforeData, Self.profileDigest(published) != digest else {
                throw HarnessError.invalid("Cannot replace a published grant candidate")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(proof)
        guard encoded.count <= 1_048_576 else { throw HarnessError.invalid("Grant candidate exceeds its bound") }
        try DurableProfilePersistence(directoryBoundary: directoryBoundary).replace(encoded, at: candidate)
    }

    private func confirmPublishedGrants(directoryBoundary: URL) throws {
        guard HarnessOperation.taskID != nil else { return }
        let directory = directoryBoundary.appendingPathComponent("bridge/profiles-v\(ExtensionRequestProfile.profileSchemaVersion)", isDirectory: true)
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw HarnessError.invalid("Invalid grant profile directory")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 20_000 else { throw HarnessError.invalid("Grant profile inventory exceeds its bound") }
        for name in names.sorted() where name.hasSuffix(".state") {
            let profile = String(name.dropLast(".state".count))
            guard profile == "default" || UUID(uuidString: profile)?.uuidString.lowercased() == profile else {
                throw HarnessError.invalid("Invalid grant profile identity")
            }
            try confirmPublishedGrant(at: directory.appendingPathComponent(name), directoryBoundary: directoryBoundary)
        }
    }

    private func confirmPublishedGrant(at url: URL, directoryBoundary: URL) throws {
        guard isProfile(url, directoryBoundary: directoryBoundary), HarnessOperation.taskID != nil else { return }
        try confirmPublishedGrant(data: readBounded(url, maximum: 16 * 1024 * 1024), url: url, directoryBoundary: directoryBoundary)
    }

    private func confirmPublishedGrant(data: Data, url: URL, directoryBoundary: URL) throws {
        guard isProfile(url, directoryBoundary: directoryBoundary), HarnessOperation.taskID != nil else { return }
        let digest = Self.profileDigest(data)
        guard !acknowledgedGrantProofs.withLock({ $0.contains(digest) }) else { return }
        let candidate = candidateURL(digest, directoryBoundary: directoryBoundary)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return }
        let proof = try readCandidate(candidate, digest: digest)
        let handle = try harnessDecodeHandle(proof["handle"])
        let profile = try PropertyListDecoder().decode(ExtensionRequestProfile.State.self, from: data)
        guard profile.profileIdentifier == handle.profileIdentifier,
              url.lastPathComponent == "\(handle.profileIdentifier?.uuidString.lowercased() ?? "default").state",
              let record = profile.records.first(where: { $0.handle == handle }),
              record.configurationKey == proof["configurationKey"].string,
              case .completed(_, let responseData, _) = record.state,
              let response = ExtensionRequestProfileCodec.decodeResponseData(responseData, id: handle.id),
              response.approvalCommitted, case .result = response.payload else {
            throw HarnessError.invalid("Published grant does not match its candidate")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(proof["state"]) == encoder.encode(HarnessValue.convert(
            ExtensionRequestProfile.authoritySnapshot(profile, configurationKey: record.configurationKey).json)),
              try encoder.encode(proof["response"]) == encoder.encode(HarnessValue.convert(response.json)) else {
            throw HarnessError.invalid("Published grant snapshot changed")
        }
        try ipc.publishGrantSync(proof)
        acknowledgedGrantProofs.withLock { _ = $0.insert(digest) }
    }

    private func candidateURL(_ digest: String, directoryBoundary: URL) -> URL {
        directoryBoundary.appendingPathComponent("grant-proofs", isDirectory: true).appendingPathComponent(digest + ".json")
    }

    private func readCandidate(_ url: URL, digest: String) throws -> HarnessValue {
        let value = try JSONDecoder().decode(HarnessValue.self, from: readBounded(url, maximum: 1_048_576))
        guard value["profileSHA256"].string == digest, let executionID = value["executionID"].string,
              UUID(uuidString: executionID) != nil, let creatorEpoch = value["creatorEpoch"].string, !creatorEpoch.isEmpty,
              ["bridge", "approval"].contains(value["creatorRole"].string ?? "") else {
            throw HarnessError.invalid("Invalid grant candidate")
        }
        return value
    }

    private func readBounded(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_size >= 0, metadata.st_size <= Int64(maximum) else { throw HarnessError.invalid("Invalid grant evidence file") }
        var data = Data(count: Int(metadata.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw HarnessError.invalid("Truncated grant evidence file") }
                offset += count
            }
        }
        return data
    }

    private static func profileDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
