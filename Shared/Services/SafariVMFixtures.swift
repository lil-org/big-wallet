#if BW_SAFARI_VM_TESTING
import Darwin
import Foundation
import Security
import Synchronization
#if os(iOS)
import LocalAuthentication
#endif

@_silgen_name("flock")
private func safariVMFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

final class SafariVMFixtures: Sendable {
    struct Descriptor: Codable, Equatable, Sendable {
        let version: Int
        let runID: String
        let root: String
        let platform: String
        let signingMode: String
        let configuration: String
    }

    struct Operation: Codable, Sendable {
        let requestID: Int?
        let scenarioID: String?
        let iteration: Int?
    }

    struct ActivationPreparation: Codable, Equatable, Sendable {
        let version: Int
        let runID: String
        let nonce: String
        let showPreferences: Bool
    }

    struct Mutation: Codable, Sendable {
        struct Scenario: Codable, Sendable {
            let id: String
            let iteration: Int
        }
        enum Kind: String, Codable, Sendable {
            case removeEthereumAccount, restoreEthereumAccount, replaceVaultGeneration, replaceCustomNetwork
        }
        let id: String
        let scenario: Scenario
        let operation: Kind
        let chainId: Int?
        let rpcURL: String?
    }

    private struct Control: Decodable {
        let url: String
        let token: String
    }

    enum Failure: Error { case invalidFixture, unavailable, rejected }

    static let shared: SafariVMFixtures = {
        do { return try SafariVMFixtures() }
        catch { fatalError("Safari VM fixture initialization failed: \(error)") }
    }()
    @TaskLocal static var operation: Operation?

    let descriptor: Descriptor
    let root: URL
    let activationPreparation: ActivationPreparation?
    let incarnation = UUID().uuidString.lowercased()
    private let storageLock: CrossProcessFileLock
    private let storageMutex = Mutex(())
    private let eventMutex = Mutex(())
    var isLocal: Bool { descriptor.signingMode == "local" }

    private init() throws {
#if os(macOS)
        let platform = "macos"
#elseif os(iOS) && targetEnvironment(simulator)
        let platform = "ios"
#else
        #error("Safari VM fixtures support macOS and iOS Simulator only")
#endif
#if DEBUG
        let configuration = "Debug"
#else
        let configuration = "Release"
#endif
        guard let resource = Bundle.main.url(forResource: "SafariVMRun", withExtension: "json") else {
            throw Failure.invalidFixture
        }
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: Self.read(resource, maximum: 16_384))
        guard descriptor.version == 1, descriptor.platform == platform,
              ["local", "apple"].contains(descriptor.signingMode),
              descriptor.configuration == configuration,
              !descriptor.runID.isEmpty, descriptor.runID.count <= 128,
              descriptor.runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
              descriptor.runID.first?.isLetter == true || descriptor.runID.first?.isNumber == true,
              !descriptor.runID.contains("..") else { throw Failure.invalidFixture }
        let expected = "/Volumes/BigWalletBuild/Exchange/\(descriptor.runID)/safari/\(platform)/\(descriptor.configuration)"
        guard descriptor.root == expected else { throw Failure.invalidFixture }
        let root = URL(fileURLWithPath: expected, isDirectory: true)
        guard root.standardizedFileURL.path == expected,
              root.resolvingSymlinksInPath().path == expected else { throw Failure.invalidFixture }
        var status = stat()
        guard lstat(expected, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              try JSONDecoder().decode(Descriptor.self, from: Self.read(root.appendingPathComponent(".run.json"), maximum: 16_384)) == descriptor
        else { throw Failure.invalidFixture }
        self.descriptor = descriptor
        self.root = root
        storageLock = CrossProcessFileLock(fileURL: root.appendingPathComponent("fixture-storage.lock"))
        let role = Bundle.main.bundleURL.pathExtension == "appex" ? "extension"
            : Bundle.main.bundleIdentifier == "org.lil.wallet.ambient" ? "helper" : "app"
        activationPreparation = platform == "macos" && role == "app"
            ? try Self.readActivationPreparation(root: root, runID: descriptor.runID, signingMode: descriptor.signingMode) : nil
        if activationPreparation == nil {
            if descriptor.signingMode == "local" {
                try initializeWallets()
            } else if role != "extension" {
                try initializeWallets()
                try initializeAppleWallets()
            }
        }
        event("processStarted", metadata: ["bundleID": Bundle.main.bundleIdentifier ?? "", "platform": platform,
            "role": role, "executablePath": Bundle.main.executableURL?.path ?? "",
            "storage": descriptor.signingMode == "local" ? "fixture" : "production"])
    }

    func matchesActivationPreparation(_ preparation: ActivationPreparation) -> Bool {
        (try? Self.readActivationPreparation(root: root, runID: descriptor.runID, signingMode: descriptor.signingMode)) == preparation
    }

    private static func readActivationPreparation(root: URL, runID: String, signingMode: String) throws -> ActivationPreparation? {
        let data: Data
        do { data = try read(root.appendingPathComponent("activation-preparation.json"), maximum: 4096, privateFile: true) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
        guard signingMode == "local",
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["version", "runID", "nonce", "showPreferences"]) else {
            throw Failure.invalidFixture
        }
        let preparation = try JSONDecoder().decode(ActivationPreparation.self, from: data)
        guard preparation.version == 1, preparation.runID == runID,
              UUID(uuidString: preparation.nonce)?.uuidString.lowercased() == preparation.nonce else {
            throw Failure.invalidFixture
        }
        return preparation
    }

    func capture(requestID: Int? = nil) -> Operation {
        let scenario = try? JSONSerialization.jsonObject(with: Self.read(root.appendingPathComponent("scenario.json"), maximum: 16_384)) as? [String: Any]
        return Operation(requestID: requestID, scenarioID: scenario?["id"] as? String, iteration: scenario?["iteration"] as? Int)
    }

    func capture(handle: ExtensionBridge.Handle) -> Operation {
        do {
            return try withStorage {
                if let data = try dataRecords("request-operations.plist")[operationKey(handle)] {
                    return try JSONDecoder().decode(Operation.self, from: data)
                }
                throw Failure.invalidFixture
            }
        } catch { fatalError("Safari VM request evidence is unavailable") }
    }

    func recordOperation(handle: ExtensionBridge.Handle) {
        do {
            try withStorage {
                var records = try dataRecords("request-operations.plist")
                let key = operationKey(handle)
                guard records[key] == nil else { return }
                guard records.count < 20_000 else { throw Failure.unavailable }
                let context = Self.operation ?? capture(requestID: handle.id)
                let operation = Operation(requestID: handle.id, scenarioID: context.scenarioID, iteration: context.iteration)
                records[key] = try JSONEncoder().encode(operation)
                try saveDataRecords(records, name: "request-operations.plist")
            }
        } catch { fatalError("Safari VM request evidence could not be saved") }
    }

    private func operationKey(_ handle: ExtensionBridge.Handle) -> String {
        "\(handle.profileIdentifier?.uuidString ?? "default"):\(handle.id):\(handle.requestToken)"
    }

    func event(_ kind: String, requestID: Int? = nil, metadata: [String: Any] = [:], operation: Operation? = nil) {
        let context = operation ?? Self.operation ?? capture(requestID: requestID)
        var record = metadata
        record["kind"] = kind
        record["runID"] = descriptor.runID
        record["processID"] = ProcessInfo.processInfo.processIdentifier
        record["incarnation"] = incarnation
        record["time"] = Date().timeIntervalSince1970
        record["requestID"] = (requestID ?? context.requestID).map { $0 as Any } ?? NSNull()
        record["scenario"] = context.scenarioID.map { $0 as Any } ?? NSNull()
        record["iteration"] = context.iteration.map { $0 as Any } ?? NSNull()
        do {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(10)
            try eventMutex.withLock { _ in
                let fd = Darwin.open(root.appendingPathComponent("native-events.ndjson").path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
                guard fd >= 0 else { throw Failure.unavailable }
                defer { Darwin.close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.invalidFixture }
                var locked: Int32
                repeat { locked = safariVMFlock(fd, LOCK_EX) } while locked != 0 && errno == EINTR
                guard locked == 0 else { throw Failure.unavailable }
                defer { _ = safariVMFlock(fd, LOCK_UN) }
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw Failure.unavailable }
                        offset += written
                    }
                }
                var synchronized: Int32
                repeat { synchronized = fsync(fd) } while synchronized != 0 && errno == EINTR
                guard synchronized == 0 else { throw Failure.unavailable }
            }
        } catch { fatalError("Safari VM event recording failed") }
    }

    func checkpoint(_ name: String, requestID: Int? = nil, operation: Operation? = nil) async throws {
        event("checkpointReached", requestID: requestID, metadata: ["checkpoint": name, "point": name], operation: operation)
        while true {
            try Task.checkCancellation()
            let url = root.appendingPathComponent("gates.json")
            let gates: [String: String]
            do { gates = try JSONDecoder().decode([String: String].self, from: Self.read(url, maximum: 16_384)) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return }
            switch gates[name] {
            case nil, "release": return
            case "hold": try await Task.sleep(for: .milliseconds(25))
            case "fail", "cancel": throw Failure.rejected
            default: throw Failure.invalidFixture
            }
        }
    }

    func ethereumEndpoint(chainID: Int, sourceURL: URL) -> EthereumRPCEndpoint {
        .fixture(url: rpcURL(path: "ethereum", query: URLQueryItem(name: "chainId", value: String(chainID))), sourceURL: sourceURL)
    }

    func rpcURL(path: String, query: URLQueryItem? = nil) -> URL {
        do {
            let control = try control()
            var components = URLComponents(string: control.url)!
            components.path = "/rpc/" + path
            components.queryItems = query.map { [$0] }
            guard let url = components.url else { throw Failure.invalidFixture }
            return url
        } catch { fatalError("Safari VM RPC configuration is unavailable") }
    }

    func authorize(_ request: inout URLRequest) throws {
        let control = try control()
        guard let url = request.url, let base = URL(string: control.url),
              url.scheme == "http", url.host == "127.0.0.1", url.port == base.port,
              ["/rpc/ethereum", "/rpc/solana"].contains(url.path),
              url.user == nil, url.password == nil else { throw Failure.invalidFixture }
        request.setValue(control.token, forHTTPHeaderField: "X-Big-Wallet-Test-Token")
        request.setValue(String(ProcessInfo.processInfo.processIdentifier), forHTTPHeaderField: "X-Big-Wallet-Test-Process")
    }

    private func control() throws -> Control {
        let value = try JSONDecoder().decode(Control.self, from: Self.read(root.appendingPathComponent("control.json"), maximum: 16_384))
        guard let url = URLComponents(string: value.url), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65_535).contains(port), url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              value.token.utf8.count == 64,
              value.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidFixture }
        return value
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, output in
            do {
                return try withStorage {
                    let query = query as NSDictionary
                    let records = try dataRecords("wallets.plist")
                    if query[kSecReturnAttributes as String] as? Bool == true {
                        output?.pointee = records.keys.sorted().map {
                            [kSecAttrAccount as String: $0, kSecAttrCreationDate as String: Date(timeIntervalSince1970: 1)]
                        } as CFArray
                        return errSecSuccess
                    }
                    guard let key = query[kSecAttrAccount as String] as? String, let data = records[key] else { return errSecItemNotFound }
                    output?.pointee = data as CFData
                    return errSecSuccess
                }
            } catch { return errSecIO }
        }, add: { [self] attributes, _ in mutateWallet(query: attributes, attributes: attributes, mode: "add") },
        update: { [self] query, attributes in mutateWallet(query: query, attributes: attributes, mode: "update") },
        delete: { [self] query in mutateWallet(query: query, attributes: nil, mode: "delete") })
    }

    func preference(_ key: String) -> Any? {
        do { return try withStorage { try preferences()[key] } }
        catch { fatalError("Safari VM preferences are unavailable") }
    }

    func setPreference(_ value: Any?, forKey key: String) {
        do {
            try withStorage {
                var records = try preferences()
                records[key] = value
                try PropertyListSerialization.data(fromPropertyList: records, format: .binary, options: 0)
                    .write(to: root.appendingPathComponent("preferences.plist"), options: .atomic)
            }
        } catch { fatalError("Safari VM preferences could not be saved") }
    }

    private func preferences() throws -> [String: Any] {
        let data: Data
        do { data = try Self.read(root.appendingPathComponent("preferences.plist"), maximum: 8 * 1_024 * 1_024) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [:] }
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Failure.invalidFixture }
        return values
    }

    private func mutateWallet(query: CFDictionary, attributes: CFDictionary?, mode: String) -> OSStatus {
        do {
            return try withStorage {
                guard let key = (query as NSDictionary)[kSecAttrAccount as String] as? String,
                      key == "org.lil.wallet.password" || key.hasPrefix("org.lil.wallet.wallet.") else { return errSecParam }
                var records = try dataRecords("wallets.plist")
                if mode == "add", records[key] != nil { return errSecDuplicateItem }
                if mode != "add", records[key] == nil { return errSecItemNotFound }
                if mode == "delete" { records[key] = nil }
                else {
                    guard let attributes, let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
                    records[key] = data
                }
                try saveDataRecords(records, name: "wallets.plist")
                return errSecSuccess
            }
        } catch { return errSecIO }
    }

    private func initializeWallets() throws {
        try withStorage {
            let file = root.appendingPathComponent("wallets.plist")
            let exists: Bool
            do { _ = try Self.read(file, maximum: 8 * 1_024 * 1_024); exists = true }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { exists = false }
            if exists {
                _ = try Self.read(root.appendingPathComponent("original-wallets.plist"), maximum: 8 * 1_024 * 1_024)
                return
            }
            let password = Data("approval-fixture-password".utf8)
            var records = ["org.lil.wallet.password": password]
            for (name, coin, seed) in [("fixture-ethereum", WalletCoin.ethereum, UInt8(1)), ("fixture-solana", .solana, UInt8(2))] {
                guard let key = WalletStoredKey.importPrivateKey(privateKey: Data(repeating: seed, count: 32), name: name, password: password, coin: coin) else { throw Failure.invalidFixture }
                let wallet = WalletContainer(id: name, key: key)
                _ = try wallet.getAccount(password: "approval-fixture-password", coin: coin)
                guard let data = key.exportJSON() else { throw Failure.invalidFixture }
                records["org.lil.wallet.wallet." + name] = data
            }
            let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            guard let stored = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: "fixture-multicoin", password: password, coin: .ethereum),
                  let hd = WalletHDWallet(mnemonic: mnemonic, passphrase: ""),
                  let ethereum = hd.ethereumPreviewAccounts(accountRange: 0..<2),
                  let solana = hd.solanaPreviewAccounts(accountRange: 0..<2) else { throw Failure.invalidFixture }
            let wallet = WalletContainer(id: "fixture-multicoin", key: stored)
            for account in wallet.accounts { stored.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath) }
            for account in ethereum + solana {
                stored.addAccountDerivation(address: account.address, coin: account.coin, derivation: account.derivation,
                    derivationPath: account.derivationPath, publicKey: account.publicKey, extendedPublicKey: account.extendedPublicKey)
            }
            guard let data = stored.exportJSON() else { throw Failure.invalidFixture }
            records["org.lil.wallet.wallet.fixture-multicoin"] = data
            try saveDataRecords(records, name: "original-wallets.plist")
            try saveDataRecords(records, name: "wallets.plist")
        }
    }

    private func initializeAppleWallets() throws {
        let walletCount = try withStorage {
            let keychain = Keychain()
            let password = "approval-fixture-password"
            let expectedIDs = Set(["fixture-ethereum", "fixture-solana", "fixture-multicoin"])
            let existingIDs = Set(try keychain.readAllWalletIDs())
            guard existingIDs.isSubset(of: expectedIDs) else { throw Failure.invalidFixture }
            if let existingPassword = try keychain.readPassword() {
                guard existingPassword == password else { throw Failure.invalidFixture }
            } else {
                guard existingIDs.isEmpty else { throw Failure.invalidFixture }
                _ = try keychain.createPasswordIfMissing(password, beforeInsert: {})
                guard try keychain.readPassword() == password else { throw Failure.invalidFixture }
            }
            let records = try dataRecords("wallets.plist")
            let initialized = try dataRecords("apple-wallet-bootstrap.plist")["complete"] != nil
            for id in expectedIDs.sorted() {
                guard let expected = records["org.lil.wallet.wallet." + id],
                      let expectedKey = WalletStoredKey.importJSON(json: expected) else { throw Failure.invalidFixture }
                if let existing = try keychain.readWalletData(id: id) {
                    guard let key = WalletStoredKey.importJSON(json: existing), key.isMnemonic == expectedKey.isMnemonic else { throw Failure.invalidFixture }
                    let current = WalletContainer(id: id, key: key)
                    let intended = WalletContainer(id: id, key: expectedKey)
                    let accounts = Set(current.accounts.map { WalletAccountDescriptor(walletID: id, account: $0) })
                    let expectedAccounts = Set(intended.accounts.map { WalletAccountDescriptor(walletID: id, account: $0) })
                    guard accounts == expectedAccounts else { throw Failure.invalidFixture }
                    let credential = Data(password.utf8)
                    if key.isMnemonic {
                        guard let mnemonic = key.decryptMnemonic(password: credential),
                              mnemonic == expectedKey.decryptMnemonic(password: credential) else { throw Failure.invalidFixture }
                    } else {
                        guard let privateKey = key.decryptPrivateKey(password: credential),
                              privateKey == expectedKey.decryptPrivateKey(password: credential) else { throw Failure.invalidFixture }
                    }
                } else if !initialized {
                    try keychain.saveWallet(id: id, data: expected)
                }
            }
            try saveDataRecords(["complete": Data([1])], name: "apple-wallet-bootstrap.plist")
            return try keychain.readAllWalletIDs().count
        }
        event("fixtureWalletsReady", metadata: ["storage": "production", "walletCount": walletCount])
    }

    func originalWalletData(id: String) throws -> Data {
        guard ["fixture-ethereum", "fixture-solana", "fixture-multicoin"].contains(id) else { throw Failure.invalidFixture }
        return try withStorage {
            guard let data = try dataRecords("original-wallets.plist")["org.lil.wallet.wallet." + id] else { throw Failure.invalidFixture }
            return data
        }
    }

    func claimMutation() throws -> Mutation? {
        guard Bundle.main.bundleIdentifier == "org.lil.wallet", Bundle.main.bundleURL.pathExtension == "app" else { throw Failure.invalidFixture }
        return try withStorage {
            let data: Data
            do { data = try Self.read(root.appendingPathComponent("mutation.json"), maximum: 16_384) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
            let mutation = try JSONDecoder().decode(Mutation.self, from: data)
            let current = capture()
            guard UUID(uuidString: mutation.id)?.uuidString.lowercased() == mutation.id,
                  mutation.scenario.id == current.scenarioID, mutation.scenario.iteration == current.iteration else { return nil }
            var receipts = try dataRecords("mutation-receipts.plist")
            guard receipts[mutation.id] == nil else { return nil }
            guard receipts.count < 1_024 else { throw Failure.unavailable }
            receipts[mutation.id] = Data("started".utf8)
            try saveDataRecords(receipts, name: "mutation-receipts.plist")
            return mutation
        }
    }

    func completeMutation(_ mutation: Mutation, result: Result<[String: String], any Error>) {
        let succeeded: Bool
        var metadata: [String: Any] = ["mutationID": mutation.id, "operation": mutation.operation.rawValue]
        switch result {
        case .success(let details):
            succeeded = true
            for (key, value) in details { metadata[key] = value }
        case .failure(let error): succeeded = false; metadata["error"] = String(describing: error)
        }
        metadata["succeeded"] = succeeded
        do {
            try withStorage {
                var receipts = try dataRecords("mutation-receipts.plist")
                receipts[mutation.id] = Data((succeeded ? "succeeded" : "failed").utf8)
                try saveDataRecords(receipts, name: "mutation-receipts.plist")
            }
        } catch { fatalError("Safari VM mutation receipt could not be saved") }
        event("mutationCompleted", metadata: metadata,
            operation: Operation(requestID: nil, scenarioID: mutation.scenario.id, iteration: mutation.scenario.iteration))
    }

    func validateMutationRPCURL(_ value: String) throws -> URL {
        guard [
            "https://safari-fixture.invalid/rpc/ethereum?chainId=64001&configuration=original",
            "https://safari-fixture.invalid/rpc/ethereum?chainId=64001&configuration=replaced"
        ].contains(value), let url = URL(string: value) else { throw Failure.invalidFixture }
        return url
    }

    func withStorage<Value>(_ operation: () throws -> Value) throws -> Value {
        try storageMutex.withLock { _ in
            try storageLock.acquire(timeoutNanoseconds: 30_000_000_000, pollNanoseconds: 1_000_000)
            defer { storageLock.release() }
            return try operation()
        }
    }

    func dataRecords(_ name: String) throws -> [String: Data] {
        do { return try PropertyListDecoder().decode([String: Data].self, from: Self.read(root.appendingPathComponent(name), maximum: 8 * 1_024 * 1_024)) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return [:] }
    }

    func saveDataRecords(_ values: [String: Data], name: String) throws {
        try PropertyListEncoder().encode(values).write(to: root.appendingPathComponent(name), options: .atomic)
    }

    fileprivate static func read(_ url: URL, maximum: Int, privateFile: Bool = false) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0, info.st_size <= Int64(maximum) else { throw Failure.invalidFixture }
        if privateFile {
            guard info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  info.st_size > 0 else { throw Failure.invalidFixture }
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        if privateFile {
            var after = stat()
            var pathInfo = stat()
            guard fstat(fd, &after) == 0, lstat(url.path, &pathInfo) == 0,
                  after.st_size == info.st_size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
                  pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino,
                  pathInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.invalidFixture }
        }
        return data
    }
}

actor SafariVMLockProbe {
    private struct Probe: Codable, Sendable {
        let version: Int
        let id: String
        let scenario: SafariVMFixtures.Mutation.Scenario

        var operation: SafariVMFixtures.Operation {
            .init(requestID: nil, scenarioID: scenario.id, iteration: scenario.iteration)
        }
    }

    private struct Acknowledgement: Codable, Equatable, Sendable {
        let probeID: String
        let holderProcessID: Int32
        let holderIncarnation: String
        let contenderProcessID: Int32?
        let contenderIncarnation: String?
    }

    private enum Failure: String, Error {
        case invalidProbe, invalidAcknowledgement, alreadyLocked, exclusionFailed, timedOut, peerFailed
    }

    static let shared = SafariVMLockProbe()
    private let lockName = "safari-lock-probe.lock"

    func holdIfRequested() async {
        guard Bundle.main.bundleIdentifier == "org.lil.wallet.Safari", Bundle.main.bundleURL.pathExtension == "appex" else { return }
        await run(role: "extension")
    }

    func contendIfRequested() async {
        guard Bundle.main.bundleIdentifier == "org.lil.wallet", Bundle.main.bundleURL.pathExtension == "app" else { return }
        await run(role: "app")
    }

    private func run(role: String) async {
        let fixtures = SafariVMFixtures.shared
        let probe: Probe
        do {
            guard let claimed = try claim(role: role, fixtures: fixtures) else { return }
            probe = claimed
        } catch {
            fixtures.event("fixtureLockFailed", metadata: ["probeID": "", "lockName": lockName,
                "role": role, "reason": "invalidProbe"])
            return
        }
        do {
            if role == "extension" { try await hold(probe, fixtures: fixtures) }
            else { try await contend(probe, fixtures: fixtures) }
        } catch {
            let reason = (error as? Failure)?.rawValue ?? (error is CancellationError ? "cancelled" : "ioFailure")
            var metadata: [String: Any] = ["probeID": probe.id, "lockName": lockName, "role": role, "reason": reason]
            if let acknowledgement = try? acknowledgement(probe, phase: "held", fixtures: fixtures) {
                metadata["holderProcessID"] = acknowledgement.holderProcessID
                metadata["holderIncarnation"] = acknowledgement.holderIncarnation
            }
            fixtures.event("fixtureLockFailed", metadata: metadata, operation: probe.operation)
            try? write(JSONSerialization.data(withJSONObject: ["probeID": probe.id, "reason": reason]),
                probe: probe, phase: "failed", fixtures: fixtures)
        }
    }

    private func claim(role: String, fixtures: SafariVMFixtures) throws -> Probe? {
        try fixtures.withStorage {
            let data: Data
            do { data = try SafariVMFixtures.read(fixtures.root.appendingPathComponent("lock-probe.json"), maximum: 16_384) }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
            let probe = try JSONDecoder().decode(Probe.self, from: data)
            let current = fixtures.capture()
            guard probe.version == 1, UUID(uuidString: probe.id)?.uuidString.lowercased() == probe.id,
                  ["install-native-roundtrip", "ethereum-signing"].contains(probe.scenario.id),
                  (1...10).contains(probe.scenario.iteration) else { throw Failure.invalidProbe }
            guard probe.scenario.id == current.scenarioID, probe.scenario.iteration == current.iteration else { return nil }
            var claims = try fixtures.dataRecords("lock-probe-claims.plist")
            let key = probe.id + "." + role
            guard claims[key] == nil else { return nil }
            guard claims.count < 1_024 else { throw Failure.invalidProbe }
            claims[key] = Data(fixtures.incarnation.utf8)
            try fixtures.saveDataRecords(claims, name: "lock-probe-claims.plist")
            return probe
        }
    }

    private func hold(_ probe: Probe, fixtures: SafariVMFixtures) async throws {
        let lock = CrossProcessFileLock(fileURL: fixtures.root.appendingPathComponent(lockName))
        guard try lock.tryAcquire() else { throw Failure.alreadyLocked }
        defer { lock.release() }
        let held = Acknowledgement(probeID: probe.id, holderProcessID: ProcessInfo.processInfo.processIdentifier,
            holderIncarnation: fixtures.incarnation, contenderProcessID: nil, contenderIncarnation: nil)
        emit("fixtureLockHeld", probe: probe, acknowledgement: held, role: "extension", fixtures: fixtures)
        try write(try JSONEncoder().encode(held), probe: probe, phase: "held", fixtures: fixtures)
        let deadline = ContinuousClock.now + .seconds(30)
        let excluded = try await wait(probe, phase: "excluded", deadline: deadline, fixtures: fixtures)
        guard excluded.holderProcessID == held.holderProcessID, excluded.holderIncarnation == held.holderIncarnation,
              let contender = excluded.contenderProcessID, contender != held.holderProcessID,
              excluded.contenderIncarnation != nil, excluded.contenderIncarnation != held.holderIncarnation else {
            throw Failure.invalidAcknowledgement
        }
        lock.release()
        emit("fixtureLockReleased", probe: probe, acknowledgement: excluded, role: "extension", fixtures: fixtures)
        try write(try JSONEncoder().encode(excluded), probe: probe, phase: "released", fixtures: fixtures)
    }

    private func contend(_ probe: Probe, fixtures: SafariVMFixtures) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        let held = try await wait(probe, phase: "held", deadline: deadline, fixtures: fixtures)
        let processID = ProcessInfo.processInfo.processIdentifier
        guard held.holderProcessID != processID, held.holderIncarnation != fixtures.incarnation,
              held.contenderProcessID == nil, held.contenderIncarnation == nil else { throw Failure.invalidAcknowledgement }
        let lock = CrossProcessFileLock(fileURL: fixtures.root.appendingPathComponent(lockName))
        if try lock.tryAcquire() {
            lock.release()
            throw Failure.exclusionFailed
        }
        let excluded = Acknowledgement(probeID: probe.id, holderProcessID: held.holderProcessID,
            holderIncarnation: held.holderIncarnation, contenderProcessID: processID, contenderIncarnation: fixtures.incarnation)
        emit("fixtureLockExcluded", probe: probe, acknowledgement: excluded, role: "app", fixtures: fixtures)
        try write(try JSONEncoder().encode(excluded), probe: probe, phase: "excluded", fixtures: fixtures)
        let released = try await wait(probe, phase: "released", deadline: deadline, fixtures: fixtures)
        guard released == excluded else { throw Failure.invalidAcknowledgement }
        while try !lock.tryAcquire() {
            try check(probe, deadline: deadline, fixtures: fixtures)
            try await Task.sleep(for: .milliseconds(25))
        }
        defer { lock.release() }
        emit("fixtureLockAcquired", probe: probe, acknowledgement: excluded, role: "app", fixtures: fixtures)
        try write(try JSONEncoder().encode(excluded), probe: probe, phase: "acquired", fixtures: fixtures)
    }

    private func wait(_ probe: Probe, phase: String, deadline: ContinuousClock.Instant, fixtures: SafariVMFixtures) async throws -> Acknowledgement {
        while true {
            try check(probe, deadline: deadline, fixtures: fixtures)
            if let value = try acknowledgement(probe, phase: phase, fixtures: fixtures) { return value }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func check(_ probe: Probe, deadline: ContinuousClock.Instant, fixtures: SafariVMFixtures) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw Failure.timedOut }
        if try read(probe, phase: "failed", fixtures: fixtures) != nil { throw Failure.peerFailed }
    }

    private func acknowledgement(_ probe: Probe, phase: String, fixtures: SafariVMFixtures) throws -> Acknowledgement? {
        guard let data = try read(probe, phase: phase, fixtures: fixtures) else { return nil }
        let value = try JSONDecoder().decode(Acknowledgement.self, from: data)
        guard value.probeID == probe.id, value.holderProcessID > 1,
              UUID(uuidString: value.holderIncarnation)?.uuidString.lowercased() == value.holderIncarnation,
              value.contenderProcessID == nil && value.contenderIncarnation == nil ||
                value.contenderProcessID.map({ $0 > 1 }) == true && value.contenderIncarnation.map({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }) == true else {
            throw Failure.invalidAcknowledgement
        }
        return value
    }

    private func read(_ probe: Probe, phase: String, fixtures: SafariVMFixtures) throws -> Data? {
        do { return try SafariVMFixtures.read(url(probe, phase: phase, fixtures: fixtures), maximum: 16_384) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
    }

    private func write(_ data: Data, probe: Probe, phase: String, fixtures: SafariVMFixtures) throws {
        let destination = url(probe, phase: phase, fixtures: fixtures)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func url(_ probe: Probe, phase: String, fixtures: SafariVMFixtures) -> URL {
        fixtures.root.appendingPathComponent("lock-probe.\(probe.id).\(phase).json")
    }

    private func emit(_ kind: String, probe: Probe, acknowledgement: Acknowledgement, role: String, fixtures: SafariVMFixtures) {
        var metadata: [String: Any] = ["probeID": probe.id, "lockName": lockName, "role": role,
            "holderProcessID": acknowledgement.holderProcessID, "holderIncarnation": acknowledgement.holderIncarnation]
        if let processID = acknowledgement.contenderProcessID, let incarnation = acknowledgement.contenderIncarnation {
            metadata["contenderProcessID"] = processID
            metadata["contenderIncarnation"] = incarnation
        }
        fixtures.event(kind, metadata: metadata, operation: probe.operation)
    }
}

@MainActor
final class SafariVMMutations {
    static let shared = SafariVMMutations()
    private var isProcessing = false

    func processPending() async {
        await SafariVMLockProbe.shared.contendIfRequested()
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let fixtures = SafariVMFixtures.shared
        do {
            guard let mutation = try fixtures.claimMutation() else { return }
            let context = SafariVMFixtures.Operation(requestID: nil, scenarioID: mutation.scenario.id, iteration: mutation.scenario.iteration)
            let result: Result<[String: String], any Error> = await SafariVMFixtures.$operation.withValue(context) {
                do { return .success(try await perform(mutation, fixtures: fixtures)) }
                catch { return .failure(error) }
            }
            fixtures.completeMutation(mutation, result: result)
        } catch {
            fixtures.event("mutationRejected", metadata: ["error": String(describing: error)])
        }
    }

    private func perform(_ mutation: SafariVMFixtures.Mutation, fixtures: SafariVMFixtures) async throws -> [String: String] {
        let wallets = WalletsManager.shared
        guard await wallets.start() else { throw SafariVMFixtures.Failure.unavailable }
        switch mutation.operation {
        case .removeEthereumAccount:
            guard let wallet = wallets.wallets.first(where: { $0.id == "fixture-ethereum" }),
                  wallet.accounts.count == 1, wallet.accounts[0].coin == .ethereum else { throw SafariVMFixtures.Failure.invalidFixture }
            try await wallets.delete(wallet: wallet)
        case .restoreEthereumAccount:
            try await wallets.restoreSafariVMFixtureWallet()
        case .replaceVaultGeneration:
#if os(iOS)
            let generations = try await SafariApprovalVaultHost.shared.replaceSafariVMGeneration()
            return ["previousGeneration": generations.previous, "generation": generations.current]
#else
            throw SafariVMFixtures.Failure.invalidFixture
#endif
        case .replaceCustomNetwork:
            guard let chainID = mutation.chainId, let rawURL = mutation.rpcURL else { throw SafariVMFixtures.Failure.invalidFixture }
            let rpcURL = try fixtures.validateMutationRPCURL(rawURL)
            try SharedDefaults.replaceSafariVMCustomNetwork(chainID: chainID, rpcURL: rpcURL)
        }
#if os(iOS)
        await SafariApprovalVaultHost.shared.waitForReconciliation()
#endif
        return [:]
    }
}

final class SafariVMPreferenceStorage: SharedPreferenceStorage, Sendable {
    static let shared = SafariVMPreferenceStorage()
    func object(forKey key: String) -> Any? { SafariVMFixtures.shared.preference(key) }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { SafariVMFixtures.shared.setPreference(value, forKey: key) }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func synchronize() -> Bool { true }
}

struct SafariVMRPCForbiddenAuthorization: AlchemyAuthorizationProviding {
    func authorization(for url: URL) async throws -> AlchemyAuthorization? { throw SafariVMFixtures.Failure.rejected }
    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? { throw SafariVMFixtures.Failure.rejected }
    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {}
}

#if os(iOS)
final class SafariVMApprovalKeyStore: SafariApprovalKeyStoring, SafariApprovalIntegrityKeyStoring {
    private let fixtures = SafariVMFixtures.shared

    func store(_ key: Data, identity: SafariApprovalKeyIdentity) throws {
        guard key.count == 32 else { throw SafariApprovalVault.Error.invalidKey }
        try fixtures.withStorage {
            var keys = try fixtures.dataRecords("vault-keys.plist")
            keys[try identity.keychainAccount()] = key
            try fixtures.saveDataRecords(keys, name: "vault-keys.plist")
        }
    }

    func load(identity: SafariApprovalKeyIdentity, context: LAContext) throws -> Data {
        let key = try fixtures.withStorage {
            guard let key = try fixtures.dataRecords("vault-keys.plist")[identity.keychainAccount()] else { throw SafariApprovalVault.Error.keychainFailure(errSecItemNotFound) }
            guard key.count == 32 else { throw SafariApprovalVault.Error.invalidKey }
            return key
        }
        return key
    }

    func availability(identities: [SafariApprovalKeyIdentity]) -> [SafariApprovalKeyIdentity: SafariApprovalKeyAvailability] {
        do {
            return try fixtures.withStorage {
                let keys = try fixtures.dataRecords("vault-keys.plist")
                return try Dictionary(uniqueKeysWithValues: identities.map { ($0, keys[try $0.keychainAccount()] == nil ? .missing : .authenticationRequired) })
            }
        } catch { return Dictionary(uniqueKeysWithValues: identities.map { ($0, .unavailable(errSecIO)) }) }
    }

    func removeAll() throws {
        try fixtures.withStorage { try fixtures.saveDataRecords([:], name: "vault-keys.plist") }
    }

    func loadOrCreate() throws -> Data {
        try fixtures.withStorage {
            var keys = try fixtures.dataRecords("vault-integrity.plist")
            if let key = keys["integrity"] {
                guard key.count == 32 else { throw SafariApprovalVault.Error.invalidKey }
                return key
            }
            var key = Data(count: 32)
            let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard status == errSecSuccess else { throw SafariVMFixtures.Failure.unavailable }
            keys["integrity"] = key
            try fixtures.saveDataRecords(keys, name: "vault-integrity.plist")
            return key
        }
    }
}
#endif
#endif
