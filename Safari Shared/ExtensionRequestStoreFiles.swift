// ∅ 2026 lil org

import Foundation

final class ExtensionRequestStoreFiles {
    private typealias AtomicWrite = ExtensionRequestFileStore.AtomicWrite
    private typealias SynchronizePublishedFile = ExtensionRequestFileStore.SynchronizePublishedFile
    private typealias ReadData = ExtensionRequestFileStore.ReadData
    private typealias ReadFileSize = ExtensionRequestFileStore.ReadFileSize
    private typealias RemoveItem = ExtensionRequestFileStore.RemoveItem
    private typealias WalletAuthorityRemovalError = ExtensionRequestFileStore.WalletAuthorityRemovalError

    enum ProfileDataRead {
        case missing
        case data(Data)
        case corrupt
        case unavailable
    }

    enum WriteFailureRecovery {
        case none
        case readBack
    }

    enum OperationLockStatus {
        case held, unlocked, unsafe, unavailable
    }

    enum RegularFileStatus {
        case missing, regular, unsafe, unavailable
    }

    enum DirectoryStatus {
        case missing, directory, unsafe, unavailable
    }

    struct ProfileFileIdentity {
        let identifier: UUID?
    }

    struct ProfileFileCandidate {
        let url: URL
        let identity: ProfileFileIdentity
    }

    private static let profileDirectoryName = "profiles-v9"
    private static let operationLockDirectoryName = "operation-locks-v9"

    private let rootURL: URL?
    private let storeLock: CrossProcessFileLock?
    private let lockTimeout: UInt64
    private let lockPoll: UInt64
    private let atomicWrite: AtomicWrite
    private let synchronizePublishedFile: SynchronizePublishedFile
    private let readData: ReadData
    private let readFileSize: ReadFileSize
    private let removeItem: RemoveItem
    private let fileManager = FileManager.default

    init(
        rootURL: URL?,
        directoryBoundary: URL?,
        dependencies: ExtensionRequestFileStore.Dependencies
    ) {
        self.rootURL = rootURL
        lockTimeout = dependencies.crossProcessLockTimeoutNanoseconds
        lockPoll = dependencies.crossProcessLockPollNanoseconds
        let persistence = directoryBoundary.map {
            DurableProfilePersistence(
                directoryBoundary: $0,
                operations: dependencies.persistenceOperations
            )
        }
        atomicWrite = dependencies.atomicWrite ?? { data, url in
            guard let persistence else { throw CocoaError(.fileWriteUnknown) }
            try persistence.replace(data, at: url)
        }
        synchronizePublishedFile = dependencies.synchronizePublishedFile ?? { url in
            guard let persistence else { throw CocoaError(.fileWriteUnknown) }
            try persistence.synchronizePublishedFile(at: url)
        }
        readData = dependencies.readData
        readFileSize = dependencies.readFileSize
        removeItem = dependencies.removeItem
        storeLock = dependencies.crossProcessLock ?? rootURL.map {
            CrossProcessFileLock(fileURL: $0.appendingPathComponent("bridge-v9.lock"))
        }
    }

    func discoverProfileCandidatesForRemovalLocked() throws -> [ProfileFileCandidate] {
        switch directoryStatus(at: profileDirectoryURL) {
        case .missing: return []
        case .directory: break
        case .unsafe, .unavailable: throw WalletAuthorityRemovalError.unavailable
        }
        do {
            return try fileManager.contentsOfDirectory(
                at: profileDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                guard let identity = profileFileIdentity(for: url) else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }
        } catch {
            throw WalletAuthorityRemovalError.unavailable
        }
    }

    func discoverProfileCandidates() -> [ProfileFileCandidate] {
        guard rootURL != nil else { return [] }
        do {
            let attributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: profileDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard let identity = profileFileIdentity(for: url) else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }
        } catch {
            return []
        }
    }

    func acquireOperationLeaseLocked(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.OperationLease? {
        guard prepareDirectoriesLocked() else { return nil }
        let url = operationLockURL(handle)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return nil
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            try lock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
            return .init(fileURL: url, lock: lock)
        } catch {
            return nil
        }
    }

    func operationLockStatusLocked(
        handle: ExtensionBridge.Handle
    ) -> OperationLockStatus {
        operationLockStatusLocked(at: operationLockURL(handle))
    }

    func operationLockStatusLocked(at url: URL) -> OperationLockStatus {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .unlocked
        case .regular:
            break
        case .unsafe:
            return .unsafe
        case .unavailable:
            return .unavailable
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            guard try lock.tryAcquireExisting() else { return .held }
            lock.release()
            return .unlocked
        } catch {
            return .unavailable
        }
    }

    func removeOperationLockLocked(handle: ExtensionBridge.Handle) {
        removeOperationLockLocked(at: operationLockURL(handle))
    }

    func removeOperationLockLocked(at url: URL) {
        guard case .unlocked = operationLockStatusLocked(at: url),
              case .regular = regularFileStatusLocked(at: url) else { return }
        try? removeItem(url)
    }

    func readProfileDataLocked(at url: URL) -> ProfileDataRead {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .missing
        case .regular:
            break
        case .unsafe:
            return .corrupt
        case .unavailable:
            return .unavailable
        }
        do {
            guard let size = try readFileSize(url) else {
                return .unavailable
            }
            guard size > 0, size <= ExtensionRequestProfile.maximumProfileBytes else {
                return .corrupt
            }
            let data = try readData(url)
            guard !data.isEmpty, data.count <= ExtensionRequestProfile.maximumProfileBytes else {
                return .corrupt
            }
            return .data(data)
        } catch {
            return .unavailable
        }
    }

    func synchronizeProfileLocked(_ profileIdentifier: UUID?) -> Bool {
        let url = profileURL(profileIdentifier)
        guard case .regular = regularFileStatusLocked(at: url) else { return false }
        do {
            try synchronizePublishedFile(url)
            return true
        } catch {
            return false
        }
    }

    func regularFileStatusLocked(at url: URL) -> RegularFileStatus {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                return .unavailable
            }
            return type == .typeRegular ? .regular : .unsafe
        } catch {
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return .unsafe
            }
            return fileManager.fileExists(atPath: url.path) ? .unavailable : .missing
        }
    }

    func directoryStatus(at url: URL) -> DirectoryStatus {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                return .unavailable
            }
            return type == .typeDirectory ? .directory : .unsafe
        } catch let error as CocoaError where error.code == .fileNoSuchFile ||
            error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unavailable
        }
    }

    func prepareDirectoriesLocked() -> Bool {
        guard let rootURL else { return false }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.profileDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.operationLockDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            let profileAttributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            let lockAttributes = try fileManager.attributesOfItem(
                atPath: operationLockDirectoryURL.path
            )
            return profileAttributes[.type] as? FileAttributeType == .typeDirectory &&
                lockAttributes[.type] as? FileAttributeType == .typeDirectory
        } catch {
            return false
        }
    }

    func withLock<T>(or fallback: T, _ body: () -> T) -> T {
        do { return try withRequiredLock(body) }
        catch { return fallback }
    }

    func withRequiredLock<T>(_ body: () throws -> T) throws -> T {
        guard let rootURL, let storeLock else { throw WalletAuthorityRemovalError.unavailable }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableRootURL = rootURL
            try mutableRootURL.setResourceValues(resourceValues)
            try storeLock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
        } catch {
            throw WalletAuthorityRemovalError.unavailable
        }
        defer { storeLock.release() }
        return try body()
    }

    func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return profileDirectoryURL
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return operationLockDirectoryURL
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    func profileFileIdentity(for url: URL) -> ProfileFileIdentity? {
        let name = url.lastPathComponent
        if name == "default.state" {
            return .init(identifier: nil)
        }
        guard name.hasSuffix(".state") else { return nil }
        let namespace = String(name.dropLast(".state".count))
        guard let identifier = UUID(uuidString: namespace),
              namespace == identifier.uuidString.lowercased(),
              name == "\(namespace).state" else { return nil }
        return .init(identifier: identifier)
    }

    var profileDirectoryURL: URL {
        rootURL!.appendingPathComponent(Self.profileDirectoryName, isDirectory: true)
    }

    var operationLockDirectoryURL: URL {
        rootURL!.appendingPathComponent(
            Self.operationLockDirectoryName,
            isDirectory: true
        )
    }
    func withExistingStoreLock<Value>(
        unavailable: Value,
        missing: @autoclosure () -> Value,
        _ operation: () -> Value
    ) -> Value {
        guard let rootURL, let storeLock else { return unavailable }
        switch directoryStatus(at: rootURL) {
        case .missing: return missing()
        case .directory: break
        case .unsafe, .unavailable: return unavailable
        }
        switch regularFileStatusLocked(at: rootURL.appendingPathComponent("bridge-v9.lock")) {
        case .missing:
            return directoryStatus(at: profileDirectoryURL) == .missing ? missing() : unavailable
        case .regular: break
        case .unsafe, .unavailable: return unavailable
        }
        guard (try? storeLock.tryAcquireExisting()) == true else { return unavailable }
        defer { storeLock.release() }
        switch directoryStatus(at: profileDirectoryURL) {
        case .missing: return missing()
        case .directory: return operation()
        case .unsafe, .unavailable: return unavailable
        }
    }

    func publishProfileDataLocked(
        _ data: Data,
        profileIdentifier: UUID?,
        failureRecovery: WriteFailureRecovery
    ) -> Bool {
        guard prepareDirectoriesLocked() else { return false }
        let url = profileURL(profileIdentifier)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular: break
        case .unsafe, .unavailable: return false
        }
        do {
            try atomicWrite(data, url)
            return true
        } catch {
            guard failureRecovery == .readBack,
                  case .data(let persistedData) = readProfileDataLocked(at: url) else {
                return false
            }
            return persistedData == data && synchronizeProfileLocked(profileIdentifier)
        }
    }
}
