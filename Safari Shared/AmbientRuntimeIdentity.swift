// ∅ 2026 lil org

import Darwin
import Foundation
import OSLog

struct AmbientRuntimeIdentity: Codable, Equatable, Sendable {

    private static let logger = Logger(subsystem: "org.lil.wallet", category: "AmbientRuntimeIdentity")

    typealias AtomicWrite = (Data, URL) throws -> Void
    typealias RemoveItem = (URL) throws -> Void

    private enum FileStatus {
        case missing, regular, directory, unavailable
    }

    enum RunningProcessStatus: Equatable {
        case current
        case replaced
        case unknown
    }

    struct Version: Codable, Equatable, Sendable {
        let marketing: String
        let build: String
    }

    static let currentRuntimeProtocolVersion = 4

    let instanceIdentifier: UUID
    let processIdentifier: Int32
    let bundlePath: String
    let version: Version
    let runtimeProtocolVersion: Int
    let supportedWorkflowVersions: [Int]
    let launchedAt: Date

    static func current(
        bundle: Bundle = .main,
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        launchedAt: Date? = nil
    ) -> AmbientRuntimeIdentity? {
        guard let version = bundleVersion(for: bundle),
              processIdentifier > 0,
              let launchedAt = launchedAt ?? processStartDate(
                  processIdentifier: processIdentifier
              ) else { return nil }
        return AmbientRuntimeIdentity(
            instanceIdentifier: UUID(),
            processIdentifier: processIdentifier,
            bundlePath: bundle.bundleURL.standardizedFileURL.path,
            version: version,
            runtimeProtocolVersion: currentRuntimeProtocolVersion,
            supportedWorkflowVersions: [ExtensionBridge.workflowVersion],
            launchedAt: launchedAt
        )
    }

    static func bundleVersion(at bundleURL: URL) -> Version? {
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        return bundleVersion(for: bundle)
    }

    var bundleURL: URL {
        URL(fileURLWithPath: bundlePath).standardizedFileURL
    }

    var nativeDeliveryOwner: ExtensionBridge.NativeDeliveryOwner? {
        ExtensionBridge.NativeDeliveryOwner(
            bundleURL: bundleURL,
            marketingVersion: version.marketing,
            buildVersion: version.build
        )
    }

    func matches(_ owner: ExtensionBridge.NativeDeliveryOwner) -> Bool {
        bundleURL == owner.bundleURL &&
            version.marketing == owner.marketingVersion &&
            version.build == owner.buildVersion
    }

    func isCompatible(withWorkflowVersion workflowVersion: Int) -> Bool {
        runtimeProtocolVersion == Self.currentRuntimeProtocolVersion &&
            supportedWorkflowVersions.contains(workflowVersion)
    }

    func isCompatible(
        withWorkflowVersion workflowVersion: Int,
        expectedVersion: Version
    ) -> Bool {
        version == expectedVersion &&
            isCompatible(withWorkflowVersion: workflowVersion)
    }

    func matches(
        processIdentifier: Int32,
        bundleURL: URL,
        processStartDate: Date? = nil,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        }
    ) -> Bool {
        guard self.processIdentifier == processIdentifier,
              self.bundleURL == bundleURL.standardizedFileURL else { return false }
        if let processStartDate {
            return Self.matchesProcessStart(launchedAt, processStartDate)
        }
        if let processStartDate = runningProcessStartDate(processIdentifier) {
            return Self.matchesProcessStart(launchedAt, processStartDate)
        }
        return false
    }

    @discardableResult
    func persist(
        directoryURL: URL? = AmbientRuntimeIdentity.defaultDirectoryURL,
        atomicWrite: AtomicWrite = { try $0.write(to: $1, options: .atomic) }
    ) -> Bool {
        guard isValid,
              let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumEncodedBytes else { return false }
        return Self.withMutationLock(directoryURL: directoryURL) { directory in
            let url = Self.fileURL(
                processIdentifier: processIdentifier,
                directoryURL: directory
            )
            switch Self.fileStatus(at: url) {
            case .missing, .regular:
                break
            case .directory, .unavailable:
                return false
            }
            do {
                try atomicWrite(data, url)
            } catch {
                return false
            }
            return Self.readData(at: url) == data && Self.load(
                processIdentifier: processIdentifier,
                directoryURL: directory
            ) == self
        }
    }

    static func load(
        processIdentifier: Int32,
        directoryURL: URL? = AmbientRuntimeIdentity.defaultDirectoryURL
    ) -> AmbientRuntimeIdentity? {
        guard processIdentifier > 0,
              let directoryURL, directoryURL.isFileURL else { return nil }
        let url = fileURL(
            processIdentifier: processIdentifier,
            directoryURL: directoryURL
        )
        let data: Data
        switch fileStatus(at: url) {
        case .regular:
            guard let stored = readData(at: url) else { return nil }
            data = stored
        case .missing:
            return nil
        case .directory, .unavailable:
            return nil
        }
        guard let identity = try? JSONDecoder().decode(Self.self, from: data),
              identity.isValid,
              identity.processIdentifier == processIdentifier else {
            return nil
        }
        return identity
    }

    @discardableResult
    func clear(
        directoryURL: URL? = AmbientRuntimeIdentity.defaultDirectoryURL,
        removeItem: RemoveItem = { try FileManager.default.removeItem(at: $0) }
    ) -> Bool {
        guard processIdentifier > 0 else { return false }
        return Self.withMutationLock(directoryURL: directoryURL) { directory in
            let url = Self.fileURL(
                processIdentifier: processIdentifier,
                directoryURL: directory
            )
            switch Self.fileStatus(at: url) {
            case .missing:
                return true
            case .regular:
                break
            case .directory, .unavailable:
                return false
            }
            guard let stored = Self.load(
                      processIdentifier: processIdentifier,
                      directoryURL: directory
                  ), stored.instanceIdentifier == instanceIdentifier else {
                return false
            }
            do {
                try removeItem(url)
            } catch {
                return false
            }
            return Self.fileStatus(at: url) == .missing
        }
    }

    private static let maximumEncodedBytes = 4 * 1024

    private static var defaultDirectoryURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDefaults.suiteName
        )?.appendingPathComponent(
            "native-runtime-identities-v1",
            isDirectory: true
        )
    }

    private static func fileURL(
        processIdentifier: Int32,
        directoryURL: URL
    ) -> URL {
        directoryURL.appendingPathComponent("\(processIdentifier).json")
    }

    private static func withMutationLock(
        directoryURL: URL?,
        operation: (URL) -> Bool
    ) -> Bool {
        guard let directoryURL, directoryURL.isFileURL else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        guard fileStatus(at: directoryURL) == .directory else { return false }
        let lockURL = directoryURL.appendingPathComponent("identities.lock")
        switch fileStatus(at: lockURL) {
        case .missing, .regular:
            break
        case .directory, .unavailable:
            return false
        }
        let lock = CrossProcessFileLock(fileURL: lockURL)
        do {
            try lock.acquire(
                timeoutNanoseconds: 1_000_000_000,
                pollNanoseconds: 10_000_000
            )
        } catch {
            return false
        }
        defer { lock.release() }
        return operation(directoryURL)
    }

    private static func fileStatus(at url: URL) -> FileStatus {
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular:
                return .regular
            case .typeDirectory:
                return .directory
            default:
                return .unavailable
            }
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError ||
                 error.code == NSFileReadNoSuchFileError)
                ? .missing
                : .unavailable
        }
    }

    private static func readData(at url: URL) -> Data? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size > 0,
              metadata.st_size <= maximumEncodedBytes,
              let data = try? handle.read(upToCount: maximumEncodedBytes + 1),
              data.count == metadata.st_size else { return nil }
        return data
    }

    private var isValid: Bool {
        processIdentifier > 0 &&
            !bundlePath.isEmpty && bundlePath.count <= 4_096 &&
            bundleURL.pathExtension == "app" &&
            !version.marketing.isEmpty && version.marketing.count <= 128 &&
            !version.build.isEmpty && version.build.count <= 128 &&
            runtimeProtocolVersion > 0 &&
            !supportedWorkflowVersions.isEmpty &&
            supportedWorkflowVersions.allSatisfy { $0 > 0 }
    }

    private static func bundleVersion(for bundle: Bundle) -> Version? {
        guard let marketing = bundle.object(
                  forInfoDictionaryKey: "CFBundleShortVersionString"
              ).map({ String(describing: $0) }),
              let build = bundle.object(
                  forInfoDictionaryKey: "CFBundleVersion"
              ).map({ String(describing: $0) }),
              !marketing.isEmpty,
              !build.isEmpty else { return nil }
        return Version(marketing: marketing, build: build)
    }

    static func processStartDate(processIdentifier: Int32) -> Date? {
#if os(macOS)
        guard processIdentifier > 0 else { return nil }
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let readSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            Int32(expectedSize)
        )
        guard readSize == expectedSize,
              information.pbi_pid == UInt32(processIdentifier),
              information.pbi_start_tvsec > 0,
              information.pbi_start_tvusec < 1_000_000 else {
            logger.error("Cannot read process start: bytes=\(readSize) expected=\(expectedSize) errno=\(errno) pid=\(information.pbi_pid)")
            return nil
        }
        return Date(
            timeIntervalSince1970:
                TimeInterval(information.pbi_start_tvsec) +
                TimeInterval(information.pbi_start_tvusec) / 1_000_000
        )
#else
        return nil
#endif
    }

    static func processStatus(
        processIdentifier: Int32,
        capturedStartDate: Date?,
        runningProcessStartDate: (Int32) -> Date? = {
            AmbientRuntimeIdentity.processStartDate(processIdentifier: $0)
        }
    ) -> RunningProcessStatus {
        guard processIdentifier > 0,
              let capturedStartDate,
              let currentStartDate = runningProcessStartDate(
                processIdentifier
              ) else { return .unknown }
        return matchesProcessStart(capturedStartDate, currentStartDate)
            ? .current
            : .replaced
    }

    private static func matchesProcessStart(
        _ lhs: Date,
        _ rhs: Date
    ) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= 0.001
    }
}
