// ∅ 2026 lil org

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

@_silgen_name("flock")
private func alchemySystemFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32

enum AlchemyRPC {

    static func url(network: String) -> URL? {
        guard isValidNetworkName(network) else { return nil }
        return URL(string: "https://\(network).g.alchemy.com/v2")
    }

    static func isValidNetworkName(_ network: String) -> Bool {
        let bytes = network.utf8
        guard (1...63).contains(bytes.count),
              let first = bytes.first,
              let last = bytes.last,
              isASCIIAlphanumeric(first),
              isASCIIAlphanumeric(last) else {
            return false
        }

        return bytes.allSatisfy {
            $0 == 45 || isASCIIAlphanumeric($0)
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        return (48...57).contains(byte) || (97...122).contains(byte)
    }

}

struct AlchemyAuthorization: Sendable, Equatable {

    let token: String

    func apply(to request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

}

protocol AlchemyAuthorizationProviding: Sendable {

    func authorization(for url: URL) async throws -> AlchemyAuthorization?

    func replacementAuthorization(
        afterUnauthorized rejected: AlchemyAuthorization,
        for url: URL
    ) async throws -> AlchemyAuthorization?

    func invalidateAuthorization(
        afterUnauthorized rejected: AlchemyAuthorization,
        for url: URL
    ) async

}

struct AlchemyJWTRecord: Codable, Equatable, Sendable {

    let token: String
    let issuedAt: Int64
    let expiresAt: Int64

    private static let maximumTokenLength = 8_192
    private static let maximumClockSkew: Int64 = 5 * 60
    private static let maximumLifetime: Int64 = 48 * 60 * 60
    private static let minimumLifetime: Int64 = 60
    private static let expirationSafetyMargin: Int64 = 30

    func isUsable(at now: Int64) -> Bool {
        return isStructurallyValid(at: now)
            && isTimeUsable(at: now)
    }

    func isTimeUsable(at now: Int64) -> Bool {
        let (latestIssuedAt, issuedAtOverflow) = now.addingReportingOverflow(
            Self.maximumClockSkew
        )
        let (minimumExpiration, expirationOverflow) = now.addingReportingOverflow(
            Self.expirationSafetyMargin
        )
        guard !issuedAtOverflow, !expirationOverflow else { return false }

        return issuedAt <= latestIssuedAt
            && expiresAt > minimumExpiration
    }

    func shouldRefresh(at now: Int64) -> Bool {
        guard let refreshAt = proactiveRefreshAt else { return false }
        return now >= refreshAt
    }

    var proactiveRefreshAt: Int64? {
        let (lifetime, lifetimeOverflow) = expiresAt
            .subtractingReportingOverflow(issuedAt)
        guard !lifetimeOverflow,
              lifetime > 0 else {
            return nil
        }
        let (refreshAt, refreshAtOverflow) = expiresAt
            .subtractingReportingOverflow(lifetime / 4)
        return refreshAtOverflow ? nil : refreshAt
    }

    func isStructurallyValid(at now: Int64) -> Bool {
        let (lifetime, lifetimeOverflow) = expiresAt
            .subtractingReportingOverflow(issuedAt)
        guard !token.isEmpty,
              token.utf8.count <= Self.maximumTokenLength,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              expiresAt > issuedAt,
              !lifetimeOverflow,
              lifetime >= Self.minimumLifetime,
              lifetime <= Self.maximumLifetime,
              expiresAt > now else {
            return false
        }

        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.base64URLData(segments[0]),
              let payloadData = Self.base64URLData(segments[1]),
              let signatureData = Self.base64URLData(segments[2]),
              signatureData.count == 256,
              let header = Self.jsonObject(from: headerData) as? [String: Any],
              let payload = Self.jsonObject(from: payloadData) as? [String: Any],
              Set(header.keys) == Set(["alg", "typ", "kid"]),
              header["alg"] as? String == "RS256",
              header["typ"] as? String == "JWT",
              let kid = header["kid"] as? String,
              !kid.isEmpty,
              Set(payload.keys) == Set(["iat", "exp"]),
              Self.integer(payload["iat"]) == issuedAt,
              Self.integer(payload["exp"]) == expiresAt else {
            return false
        }

        return true
    }

    private static func base64URLData(_ segment: Substring) -> Data? {
        let bytes = segment.utf8
        guard !bytes.isEmpty,
              bytes.count % 4 != 1,
              bytes.allSatisfy({
                  (48...57).contains($0)
                      || (65...90).contains($0)
                      || (97...122).contains($0)
                      || $0 == 45
                      || $0 == 95
              }) else {
            return nil
        }

        var base64 = String(segment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: paddingCount))

        guard let data = Data(base64Encoded: base64) else { return nil }
        let canonical = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard canonical == String(segment) else { return nil }
        return data
    }

    private static func jsonObject(from data: Data) -> Any? {
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int64.min),
              doubleValue <= Double(Int64.max) else {
            return nil
        }
        return number.int64Value
    }

}

struct AlchemyJWTRejectionTombstone: Codable, Equatable, Sendable {

    let tokenDigest: Data
    let rejectedAt: Int64
    let expiresAt: Int64

    func isLive(at now: Int64) -> Bool {
        return expiresAt > now
    }

}

struct AlchemyJWTPersistedState: Codable, Equatable, Sendable {

    static let currentVersion = 1

    let version: Int
    let revision: UInt64
    let record: AlchemyJWTRecord?
    let tombstones: [AlchemyJWTRejectionTombstone]

    init(
        revision: UInt64,
        record: AlchemyJWTRecord?,
        tombstones: [AlchemyJWTRejectionTombstone]
    ) {
        self.version = Self.currentVersion
        self.revision = revision
        self.record = record
        self.tombstones = tombstones
    }

    static func decodePersistenceData(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        if let object = try? JSONSerialization.jsonObject(
            with: data,
            options: []
        ),
           let dictionary = object as? [String: Any],
           dictionary.keys.contains("version") {
            guard let state = try? decoder.decode(Self.self, from: data),
                  state.version == currentVersion else {
                return nil
            }
            return state
        }
        if let legacyRecord = try? decoder.decode(
            AlchemyJWTRecord.self,
            from: data
        ) {
            return Self(
                revision: 0,
                record: legacyRecord,
                tombstones: []
            )
        }
        return nil
    }

}

protocol AlchemyJWTStoring: AnyObject, Sendable {

    func load() throws -> AlchemyJWTPersistedState?
    func save(_ state: AlchemyJWTPersistedState) throws

}

enum AlchemyJWTStorageError: Error, Equatable, Sendable {
    case invalidData
    case transient
}

protocol AlchemyInstallationIDProviding: AnyObject, Sendable {

    func installationID() throws -> UUID

}

protocol AlchemyJWTBrokerFetching: Sendable {

    func fetchToken(installationID: UUID) async throws -> AlchemyJWTRecord

}

enum AlchemyJWTBrokerError: Error, Equatable, Sendable {
    case invalidResponse
    case rateLimited(retryAfterSeconds: Int)
}

private func isAlchemyJWTBrokerRateLimit(_ error: Error) -> Bool {
    guard let brokerError = error as? AlchemyJWTBrokerError,
          case .rateLimited = brokerError else {
        return false
    }
    return true
}

protocol AlchemyJWTRefreshLocking: AnyObject, Sendable {

    func tryAcquire() throws -> Bool
    func release()

}

final class AlchemyJWTProvider: @unchecked Sendable, AlchemyAuthorizationProviding {

    static let shared = AlchemyJWTProvider.makeShared()

    private enum ProviderError: Error {
        case refreshBackoff
        case refreshLockContended
        case unchangedRejectedToken
        case invalidBrokerResponse
        case invalidPersistenceState
    }

    fileprivate enum RefreshFlightKey: Hashable, Sendable {
        case opportunistic
        case immediateUsePrewarm
        case demand
        case unauthorized(Data)
    }

    private enum RefreshIntent: Sendable {
        case opportunistic
        case immediateUsePrewarm
        case demand
        case unauthorized(
            rejectedToken: String,
            bypassesSharedLock: Bool
        )

        var allowsUncoordinatedFetch: Bool {
            switch self {
            case .opportunistic:
                return false
            case .immediateUsePrewarm, .demand, .unauthorized:
                return true
            }
        }

        var bypassesSharedLock: Bool {
            if case .unauthorized(_, let bypassesSharedLock) = self {
                return bypassesSharedLock
            }
            return false
        }

        var flightKey: RefreshFlightKey {
            switch self {
            case .opportunistic:
                return .opportunistic
            case .immediateUsePrewarm:
                return .immediateUsePrewarm
            case .demand:
                return .demand
            case .unauthorized(let rejectedToken, _):
                return .unauthorized(
                    AlchemyJWTProvider.tokenDigest(rejectedToken)
                )
            }
        }

        var brokerFlightKind: AlchemyJWTBrokerFlight.Kind {
            switch self {
            case .opportunistic, .immediateUsePrewarm:
                return .opportunistic
            case .demand:
                return .demand
            case .unauthorized:
                return .unauthorized
            }
        }
    }

    private enum RefreshLockAcquisition {
        case acquired
        case joinedOpportunisticBroker(AlchemyJWTRecord)
        case timedOut
    }

    private struct CachedRecord {
        let record: AlchemyJWTRecord
        let tokenDigest: Data
        let persistenceRevision: UInt64?
    }

    private struct State {
        var cachedRecord: CachedRecord?
        var tombstones: [Data: AlchemyJWTRejectionTombstone] = [:]
        var lastPersistedState: AlchemyJWTPersistedState?
        var opportunisticFailures = 0
        var nextOpportunisticRefreshAt: UInt64 = 0
        var demandFailures = 0
        var nextDemandRefreshAt: UInt64 = 0
        var nextBrokerRequestAt: UInt64 = 0
        var proactiveRefreshGeneration: UInt64 = 0
        var proactiveRefreshTokenDigest: Data?
        var proactiveRefreshAt: Int64?
        var proactiveRefreshDeadline: UInt64?
        var proactiveRefreshInFlightGeneration: UInt64?
        var proactiveRefreshTask: Task<Void, Never>?
    }

    private static let issuanceSecondWaitNanoseconds: UInt64 = 1_050_000_000
    private static let defaultRefreshLockTimeoutNanoseconds: UInt64 = 500_000_000
    private static let defaultRefreshLockPollNanoseconds: UInt64 = 25_000_000
    private static let defaultPersistenceRepairWindowNanoseconds: UInt64 =
        20_000_000_000
    private static let defaultPersistenceRepairInitialDelayNanoseconds: UInt64 =
        250_000_000
    private static let defaultPersistenceRepairMaximumDelayNanoseconds: UInt64 =
        2_000_000_000
    private static let defaultPersistenceRepairCooldownNanoseconds: UInt64 =
        30_000_000_000
    private static let maximumPersistenceRepairCooldownNanoseconds: UInt64 =
        300_000_000_000
    private static let maximumTombstones = 16
    private static let unknownTokenTombstoneLifetime: Int64 =
        (48 * 60 * 60) + (5 * 60)
    private static let proactiveScheduleClockToleranceNanoseconds: UInt64 =
        999_999_999

    private static let appGroupIdentifier: String = {
#if os(macOS)
        return "8DXC3N7E7P.group.org.lil.wallet"
#else
        return "group.org.lil.wallet"
#endif
    }()

    private static let notificationName = CFNotificationName(
        rawValue: "org.lil.wallet.alchemyJWTDidChange.v1" as CFString
    )

    private let stateLock = NSLock()
    private let persistenceMutationLock = NSLock()
    private var state: State
    private let tokenStore: AlchemyJWTStoring
    private let installationIDProvider: AlchemyInstallationIDProviding
    private let broker: AlchemyJWTBrokerFetching
    private let refreshLock: AlchemyJWTRefreshLocking
    private let refreshCoordinator = AlchemyJWTRefreshCoordinator()
    private let brokerFlight = AlchemyJWTBrokerFlight()
    private let persistenceRepairCoordinator:
        AlchemyJWTPersistenceRepairCoordinator
    private let now: @Sendable () -> Date
    private let uptimeNanoseconds: @Sendable () -> UInt64
    private let refreshLockTimeoutNanoseconds: UInt64
    private let refreshLockPollNanoseconds: UInt64
    private let persistenceRepairWindowNanoseconds: UInt64
    private let persistenceRepairInitialDelayNanoseconds: UInt64
    private let persistenceRepairMaximumDelayNanoseconds: UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let proactiveRefreshSleep:
        @Sendable (UInt64) async throws -> Void
    private let notificationCenter: NotificationCenter
    private var changeObserver: AlchemyJWTDarwinObserver?
    private var clockChangeObserver: NSObjectProtocol?

    init(
        tokenStore: AlchemyJWTStoring,
        installationIDProvider: AlchemyInstallationIDProviding,
        broker: AlchemyJWTBrokerFetching,
        refreshLock: AlchemyJWTRefreshLocking,
        now: @escaping @Sendable () -> Date = { Date() },
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        refreshLockTimeoutNanoseconds: UInt64 =
            AlchemyJWTProvider.defaultRefreshLockTimeoutNanoseconds,
        refreshLockPollNanoseconds: UInt64 =
            AlchemyJWTProvider.defaultRefreshLockPollNanoseconds,
        persistenceRepairWindowNanoseconds: UInt64 =
            AlchemyJWTProvider.defaultPersistenceRepairWindowNanoseconds,
        persistenceRepairInitialDelayNanoseconds: UInt64 =
            AlchemyJWTProvider.defaultPersistenceRepairInitialDelayNanoseconds,
        persistenceRepairMaximumDelayNanoseconds: UInt64 =
            AlchemyJWTProvider.defaultPersistenceRepairMaximumDelayNanoseconds,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        proactiveRefreshSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        persistenceRepairCooldownSleep:
            @escaping @Sendable (UInt64) async throws -> Void = {
                try await Task.sleep(nanoseconds: $0)
            },
        notificationCenter: NotificationCenter = .default,
        observesCrossProcessChanges: Bool = false
    ) {
        self.tokenStore = tokenStore
        self.installationIDProvider = installationIDProvider
        self.broker = broker
        self.refreshLock = refreshLock
        self.now = now
        self.uptimeNanoseconds = uptimeNanoseconds
        self.refreshLockTimeoutNanoseconds = refreshLockTimeoutNanoseconds
        self.refreshLockPollNanoseconds = refreshLockPollNanoseconds
        self.persistenceRepairWindowNanoseconds =
            persistenceRepairWindowNanoseconds
        self.persistenceRepairInitialDelayNanoseconds =
            persistenceRepairInitialDelayNanoseconds
        self.persistenceRepairMaximumDelayNanoseconds =
            persistenceRepairMaximumDelayNanoseconds
        self.sleep = sleep
        self.proactiveRefreshSleep = proactiveRefreshSleep
        self.persistenceRepairCoordinator =
            AlchemyJWTPersistenceRepairCoordinator(
                initialCooldownNanoseconds:
                    Self.defaultPersistenceRepairCooldownNanoseconds,
                maximumCooldownNanoseconds:
                    Self.maximumPersistenceRepairCooldownNanoseconds,
                sleep: persistenceRepairCooldownSleep
            )
        self.notificationCenter = notificationCenter
        self.changeObserver = nil
        self.clockChangeObserver = nil
        self.state = State()

        self.clockChangeObserver = notificationCenter.addObserver(
            forName: .NSSystemClockDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.synchronizeProactiveRefresh(at: self.nowSeconds())
        }

        if observesCrossProcessChanges {
            self.changeObserver = AlchemyJWTDarwinObserver(
                name: Self.notificationName
            ) { [weak self] in
                self?.reloadFromPersistence()
            }
        }
    }

    deinit {
        if let clockChangeObserver {
            notificationCenter.removeObserver(clockChangeObserver)
        }
        stateLock.lock()
        let task = state.proactiveRefreshTask
        state.proactiveRefreshGeneration &+= 1
        state.proactiveRefreshTokenDigest = nil
        state.proactiveRefreshAt = nil
        state.proactiveRefreshDeadline = nil
        state.proactiveRefreshInFlightGeneration = nil
        state.proactiveRefreshTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        guard Self.isAlchemyRPCURL(url) else { return nil }

        let currentTime = nowSeconds()
        if let record = usableMemoryRecord(at: currentTime) {
            schedulePersistenceRepairIfNeeded()
            synchronizeProactiveRefresh(at: currentTime)
            return AlchemyAuthorization(token: record.token)
        }

        if let record = loadUsablePersistedRecord(at: currentTime) {
            schedulePersistenceRepairIfNeeded()
            synchronizeProactiveRefresh(at: currentTime)
            return AlchemyAuthorization(token: record.token)
        }

        schedulePersistenceRepairIfNeeded()
        let record = try await refresh(intent: .demand)
        synchronizeProactiveRefresh(at: nowSeconds())
        return AlchemyAuthorization(token: record.token)
    }

    func replacementAuthorization(
        afterUnauthorized rejected: AlchemyAuthorization,
        for url: URL
    ) async throws -> AlchemyAuthorization? {
        guard Self.isAlchemyRPCURL(url) else { return nil }

        let rejectedRecord = markRejectedLocally(rejected.token)
        let memoryIntent = RefreshIntent.unauthorized(
            rejectedToken: rejected.token,
            bypassesSharedLock: false
        )
        if let current = eligibleMemoryRecord(
            for: memoryIntent,
            at: nowSeconds()
        ) {
            schedulePersistenceRepairIfNeeded()
            synchronizeProactiveRefresh(at: nowSeconds())
            return AlchemyAuthorization(token: current.token)
        }

        let rejectionWasShared = await persistRejection(
            rejected.token,
            knownRecord: rejectedRecord
        )
        if !rejectionWasShared {
            schedulePersistenceRepair()
        }

        let intent = RefreshIntent.unauthorized(
            rejectedToken: rejected.token,
            bypassesSharedLock: !rejectionWasShared
        )
        if let current = existingRecord(
            for: intent,
            at: nowSeconds()
        ) {
            synchronizeProactiveRefresh(at: nowSeconds())
            return AlchemyAuthorization(token: current.token)
        }
        guard isRefreshAttemptAllowed(for: intent) else {
            throw ProviderError.refreshBackoff
        }

        if let rejectedRecord,
           rejectedRecord.issuedAt >= nowSeconds() {
            try await sleep(Self.issuanceSecondWaitNanoseconds)
        }

        do {
            let record = try await refresh(intent: intent)
            if record.token != rejected.token {
                if !rejectionWasShared {
                    schedulePersistenceRepair()
                }
                synchronizeProactiveRefresh(at: nowSeconds())
                return AlchemyAuthorization(token: record.token)
            }
        } catch ProviderError.unchangedRejectedToken {
            // A same-second RS256 token has identical signing input.
        }

        try await sleep(Self.issuanceSecondWaitNanoseconds)

        do {
            let replacement = try await refresh(intent: intent)
            guard replacement.token != rejected.token else {
                throw ProviderError.invalidBrokerResponse
            }
            if !rejectionWasShared {
                schedulePersistenceRepair()
            }
            synchronizeProactiveRefresh(at: nowSeconds())
            return AlchemyAuthorization(token: replacement.token)
        } catch ProviderError.unchangedRejectedToken {
            throw ProviderError.invalidBrokerResponse
        }
    }

    func invalidateAuthorization(
        afterUnauthorized rejected: AlchemyAuthorization,
        for url: URL
    ) async {
        guard Self.isAlchemyRPCURL(url) else { return }

        let rejectedRecord = markRejectedLocally(rejected.token)
        let rejectionWasShared = await persistRejection(
            rejected.token,
            knownRecord: rejectedRecord
        )
        if !rejectionWasShared {
            schedulePersistenceRepair()
        }
    }

    @discardableResult
    func prewarm() -> Task<Void, Never> {
        return Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.prewarmIfNeeded()
        }
    }

    @discardableResult
    static func prewarmForApplicationLifecycle(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        provider: () -> AlchemyJWTProvider = {
            AlchemyJWTProvider.shared
        }
    ) -> Task<Void, Never>? {
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return nil
        }
        return provider().prewarm()
    }

    func prewarmForImmediateUse() async {
        let currentTime = nowSeconds()
        if usableMemoryRecord(at: currentTime) != nil
            || loadUsablePersistedRecord(at: currentTime) != nil {
            schedulePersistenceRepairIfNeeded()
            synchronizeProactiveRefresh(at: currentTime)
            return
        }

        schedulePersistenceRepairIfNeeded()
        guard (try? await refresh(intent: .immediateUsePrewarm)) != nil else {
            return
        }
        synchronizeProactiveRefresh(at: nowSeconds())
    }

    static func isAlchemyRPCURL(_ url: URL) -> Bool {
        guard let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              components.percentEncodedPath == "/v2",
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host,
              host == host.lowercased() else {
            return false
        }

        let suffix = ".g.alchemy.com"
        guard host.hasSuffix(suffix) else { return false }

        let network = String(host.dropLast(suffix.count))
        return AlchemyRPC.isValidNetworkName(network)
    }

    func reloadFromPersistence() {
        let currentTime = nowSeconds()

        do {
            let persisted = try tokenStore.load()
            _ = mergePersistedState(persisted, at: currentTime)
            synchronizeProactiveRefresh(at: currentTime)
        } catch {
            // Preserve the in-memory token when Keychain is temporarily unavailable.
        }
    }

    private static func makeShared() -> AlchemyJWTProvider {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        let tokenStore = AlchemyJWTKeychainStore()
        let installationIDProvider = AlchemyAppGroupInstallationIDProvider(
            containerURL: containerURL
        )
        let refreshLock = AlchemyJWTFileLock(
            fileURL: containerURL?.appendingPathComponent(
                ".alchemy-jwt-refresh.lock",
                isDirectory: false
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15

        return AlchemyJWTProvider(
            tokenStore: tokenStore,
            installationIDProvider: installationIDProvider,
            broker: AlchemyJWTBrokerClient(
                urlSession: URLSession(configuration: configuration)
            ),
            refreshLock: refreshLock,
            observesCrossProcessChanges: true
        )
    }

    private func prewarmIfNeeded() async {
        let currentTime = nowSeconds()
        if let record = usableMemoryRecord(at: currentTime)
            ?? loadUsablePersistedRecord(at: currentTime) {
            schedulePersistenceRepairIfNeeded()
            synchronizeProactiveRefresh(at: currentTime)
            guard record.shouldRefresh(at: currentTime) else { return }
        }

        schedulePersistenceRepairIfNeeded()
        do {
            _ = try await refresh(intent: .opportunistic)
            synchronizeProactiveRefresh(at: nowSeconds())
        } catch {
            // Prewarming is opportunistic; a still-valid token remains in memory.
            synchronizeProactiveRefresh(at: nowSeconds())
        }
    }

    private func synchronizeProactiveRefresh(at currentTime: Int64) {
        let currentUptime = uptimeNanoseconds()

        stateLock.lock()
        guard let cachedRecord = state.cachedRecord,
              cachedRecord.record.isTimeUsable(at: currentTime),
              state.tombstones[cachedRecord.tokenDigest] == nil,
              let refreshAt = cachedRecord.record.proactiveRefreshAt else {
            let previousTask = state.proactiveRefreshTask
            state.cachedRecord = nil
            state.proactiveRefreshGeneration &+= 1
            state.proactiveRefreshTokenDigest = nil
            state.proactiveRefreshAt = nil
            state.proactiveRefreshDeadline = nil
            state.proactiveRefreshInFlightGeneration = nil
            state.proactiveRefreshTask = nil
            stateLock.unlock()
            previousTask?.cancel()
            return
        }
        let tokenDigest = cachedRecord.tokenDigest

        if state.proactiveRefreshTask != nil,
           state.proactiveRefreshTokenDigest == tokenDigest,
           state.proactiveRefreshInFlightGeneration
                == state.proactiveRefreshGeneration {
            stateLock.unlock()
            return
        }

        let wallDelay = Self.nanosecondsUntil(
            refreshAt,
            from: currentTime
        )
        let wallDeadline = Self.monotonicDeadline(
            after: wallDelay,
            from: currentUptime
        )
        let deadline = max(
            wallDeadline,
            state.nextOpportunisticRefreshAt,
            state.nextBrokerRequestAt
        )
        if state.proactiveRefreshTask != nil,
           state.proactiveRefreshTokenDigest == tokenDigest,
           state.proactiveRefreshAt == refreshAt,
           let currentDeadline = state.proactiveRefreshDeadline,
           Self.absoluteDifference(currentDeadline, deadline)
               <= Self.proactiveScheduleClockToleranceNanoseconds {
            stateLock.unlock()
            return
        }

        let previousTask = state.proactiveRefreshTask
        state.proactiveRefreshGeneration &+= 1
        let generation = state.proactiveRefreshGeneration
        state.proactiveRefreshTokenDigest = tokenDigest
        state.proactiveRefreshAt = refreshAt
        state.proactiveRefreshDeadline = deadline
        state.proactiveRefreshInFlightGeneration = nil
        let delay = deadline > currentUptime
            ? deadline - currentUptime
            : 0
        let proactiveRefreshSleep = self.proactiveRefreshSleep
        let task = Task(priority: .utility) { [weak self] in
            do {
                try await proactiveRefreshSleep(delay)
            } catch {
                self?.clearProactiveRefreshSchedule(
                    generation: generation,
                    tokenDigest: tokenDigest
                )
                return
            }
            await self?.proactiveRefreshTimerFired(
                generation: generation,
                tokenDigest: tokenDigest
            )
        }
        state.proactiveRefreshTask = task
        stateLock.unlock()
        previousTask?.cancel()
    }

    private func clearProactiveRefreshSchedule(
        generation: UInt64,
        tokenDigest: Data
    ) {
        stateLock.lock()
        guard state.proactiveRefreshGeneration == generation,
              state.proactiveRefreshTokenDigest == tokenDigest else {
            stateLock.unlock()
            return
        }
        state.proactiveRefreshTokenDigest = nil
        state.proactiveRefreshAt = nil
        state.proactiveRefreshDeadline = nil
        state.proactiveRefreshInFlightGeneration = nil
        state.proactiveRefreshTask = nil
        stateLock.unlock()
    }

    private func proactiveRefreshTimerFired(
        generation: UInt64,
        tokenDigest: Data
    ) async {
        let currentTime = nowSeconds()
        guard let record = consumeProactiveRefreshSchedule(
            generation: generation,
            tokenDigest: tokenDigest,
            at: currentTime
        ) else {
            return
        }

        guard record.shouldRefresh(at: currentTime) else {
            clearProactiveRefreshSchedule(
                generation: generation,
                tokenDigest: tokenDigest
            )
            synchronizeProactiveRefresh(at: currentTime)
            return
        }
        guard isRefreshAttemptAllowed(for: .opportunistic) else {
            clearProactiveRefreshSchedule(
                generation: generation,
                tokenDigest: tokenDigest
            )
            synchronizeProactiveRefresh(at: currentTime)
            return
        }

        do {
            _ = try await refresh(intent: .opportunistic)
            let refreshedAt = nowSeconds()
            clearProactiveRefreshSchedule(
                generation: generation,
                tokenDigest: tokenDigest
            )
            synchronizeProactiveRefresh(at: refreshedAt)
        } catch {
            // The current JWT remains usable. Its monotonic cooldown controls
            // the next scheduled attempt.
            clearProactiveRefreshSchedule(
                generation: generation,
                tokenDigest: tokenDigest
            )
            synchronizeProactiveRefresh(at: nowSeconds())
        }
    }

    private func consumeProactiveRefreshSchedule(
        generation: UInt64,
        tokenDigest: Data,
        at currentTime: Int64
    ) -> AlchemyJWTRecord? {
        stateLock.lock()
        guard state.proactiveRefreshGeneration == generation,
              state.proactiveRefreshTokenDigest == tokenDigest else {
            stateLock.unlock()
            return nil
        }

        guard let cachedRecord = state.cachedRecord,
              cachedRecord.tokenDigest == tokenDigest,
              cachedRecord.record.isTimeUsable(at: currentTime),
              state.tombstones[tokenDigest] == nil else {
            if let cachedRecord = state.cachedRecord,
               !cachedRecord.record.isTimeUsable(at: currentTime)
                    || state.tombstones[cachedRecord.tokenDigest] != nil {
                state.cachedRecord = nil
            }
            state.proactiveRefreshTokenDigest = nil
            state.proactiveRefreshAt = nil
            state.proactiveRefreshDeadline = nil
            state.proactiveRefreshInFlightGeneration = nil
            state.proactiveRefreshTask = nil
            stateLock.unlock()
            return nil
        }
        state.proactiveRefreshInFlightGeneration = generation
        stateLock.unlock()
        return cachedRecord.record
    }

    private func refresh(intent: RefreshIntent) async throws -> AlchemyJWTRecord {
        return try await refreshCoordinator.run(
            key: intent.flightKey
        ) { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let record = try await self.performRefresh(intent: intent)
                guard let installedRecord =
                    self.recordRefreshSuccess(record, for: intent) else {
                    if case .unauthorized = intent {
                        throw ProviderError.unchangedRejectedToken
                    }
                    throw ProviderError.invalidBrokerResponse
                }
                self.schedulePersistenceRepairIfNeeded()
                return installedRecord
            } catch ProviderError.refreshBackoff {
                throw ProviderError.refreshBackoff
            } catch ProviderError.unchangedRejectedToken {
                throw ProviderError.unchangedRejectedToken
            } catch {
                self.recordRefreshFailure(for: intent, error: error)
                throw error
            }
        }
    }

    private func performRefresh(intent: RefreshIntent) async throws
        -> AlchemyJWTRecord {
        let currentTime = nowSeconds()
        if let record = existingRecord(
            for: intent,
            at: currentTime
        ) {
            return record
        }
        guard isRefreshAttemptAllowed(for: intent) else {
            throw ProviderError.refreshBackoff
        }
        if intent.bypassesSharedLock {
            return try await fetchRecord(for: intent, persists: false)
        }

        let lockAcquisition = try await acquireRefreshLock(
            joinsActiveOpportunisticBroker: {
                switch intent {
                case .immediateUsePrewarm, .demand:
                    return true
                case .opportunistic, .unauthorized:
                    return false
                }
            }()
        )
        let bypassesActiveOpportunisticBroker: Bool
        switch lockAcquisition {
        case .acquired:
            defer { refreshLock.release() }

            if let record = existingRecord(
                for: intent,
                at: nowSeconds()
            ) {
                return record
            }
            guard isRefreshAttemptAllowed(for: intent) else {
                throw ProviderError.refreshBackoff
            }
            return try await fetchRecord(for: intent, persists: true)
        case .joinedOpportunisticBroker(let record):
            return try validateFetchedRecord(record, for: intent)
        case .timedOut:
            bypassesActiveOpportunisticBroker = true
        }

        if let record = existingRecord(
            for: intent,
            at: nowSeconds()
        ) {
            return record
        }
        guard isRefreshAttemptAllowed(for: intent) else {
            throw ProviderError.refreshBackoff
        }

        guard intent.allowsUncoordinatedFetch else {
            throw ProviderError.refreshLockContended
        }
        return try await fetchRecord(
            for: intent,
            persists: false,
            bypassesActiveOpportunisticBroker:
                bypassesActiveOpportunisticBroker
        )
    }

    private func existingRecord(
        for intent: RefreshIntent,
        at currentTime: Int64
    ) -> AlchemyJWTRecord? {
        if let record = eligibleMemoryRecord(for: intent, at: currentTime) {
            return record
        }

        do {
            let persistedState = try tokenStore.load()
            _ = mergePersistedState(persistedState, at: currentTime)
        } catch {
            // A memory-only acquisition remains usable if Keychain is unavailable.
        }
        return eligibleMemoryRecord(for: intent, at: currentTime)
    }

    private func eligibleMemoryRecord(
        for intent: RefreshIntent,
        at currentTime: Int64
    ) -> AlchemyJWTRecord? {
        guard let record = memoryRecord(),
              record.isTimeUsable(at: currentTime) else {
            return nil
        }

        switch intent {
        case .immediateUsePrewarm, .demand:
            return record
        case .opportunistic:
            return record.shouldRefresh(at: currentTime) ? nil : record
        case .unauthorized(let rejectedToken, _):
            return record.token == rejectedToken ? nil : record
        }
    }

    private func fetchRecord(
        for intent: RefreshIntent,
        persists: Bool,
        bypassesActiveOpportunisticBroker: Bool = false
    ) async throws -> AlchemyJWTRecord {
        let fetchedRecord = try await fetchBrokerRecord(
            for: intent,
            bypassesActiveOpportunisticBroker:
                bypassesActiveOpportunisticBroker
        )
        let validatedRecord = try validateFetchedRecord(
            fetchedRecord,
            for: intent
        )

        if persists {
            return try persistFetchedRecord(validatedRecord)
        }
        return validatedRecord
    }

    private func fetchBrokerRecord(
        for intent: RefreshIntent,
        bypassesActiveOpportunisticBroker: Bool = false
    ) async throws -> AlchemyJWTRecord {
        return try await brokerFlight.run(
            kind: intent.brokerFlightKind,
            bypassesActiveOpportunisticRequest:
                bypassesActiveOpportunisticBroker
        ) {
            [weak self] in
            guard let self else { throw CancellationError() }
            let installationID = try self.installationIDProvider
                .installationID()
            let fetchedRecord = try await self.broker.fetchToken(
                installationID: installationID
            )
            guard fetchedRecord.isUsable(at: self.nowSeconds()) else {
                throw ProviderError.invalidBrokerResponse
            }
            return fetchedRecord
        }
    }

    private func validateFetchedRecord(
        _ fetchedRecord: AlchemyJWTRecord,
        for intent: RefreshIntent
    ) throws -> AlchemyJWTRecord {
        guard fetchedRecord.isUsable(at: nowSeconds()) else {
            throw ProviderError.invalidBrokerResponse
        }
        if case .unauthorized(let rejectedToken, _) = intent,
           fetchedRecord.token == rejectedToken {
            throw ProviderError.unchangedRejectedToken
        }
        guard !isTombstoned(fetchedRecord.token, at: nowSeconds()) else {
            if case .unauthorized = intent {
                throw ProviderError.unchangedRejectedToken
            }
            throw ProviderError.invalidBrokerResponse
        }
        return fetchedRecord
    }

    private func persistFetchedRecord(
        _ fetchedRecord: AlchemyJWTRecord
    ) throws -> AlchemyJWTRecord {
        let currentTime = nowSeconds()
        let persistedState: AlchemyJWTPersistedState?
        let replacesInvalidPersistence: Bool
        do {
            persistedState = try tokenStore.load()
            replacesInvalidPersistence = false
        } catch AlchemyJWTStorageError.invalidData {
            persistedState = nil
            replacesInvalidPersistence = true
        } catch {
            return fetchedRecord
        }
        if !replacesInvalidPersistence {
            _ = mergePersistedState(persistedState, at: currentTime)
        }

        let recordToPersist: AlchemyJWTRecord
        do {
            persistenceMutationLock.lock()
            defer { persistenceMutationLock.unlock() }

            let snapshot = persistenceSnapshot(at: currentTime)
            let tombstonedDigests = Set(
                snapshot.tombstones.map(\.tokenDigest)
            )
            let fetchedDigest = Self.tokenDigest(fetchedRecord.token)
            guard !tombstonedDigests.contains(fetchedDigest) else {
                throw ProviderError.invalidBrokerResponse
            }

            let currentPersistedRecord =
                snapshot.persistedState?.record.flatMap {
                    let digest = Self.tokenDigest($0.token)
                    return $0.isUsable(at: currentTime)
                        && !tombstonedDigests.contains(digest) ? $0 : nil
                }
            if let currentPersistedRecord,
               currentPersistedRecord.issuedAt >= fetchedRecord.issuedAt {
                recordToPersist = currentPersistedRecord
            } else {
                recordToPersist = fetchedRecord
            }

            let envelope = AlchemyJWTPersistedState(
                revision: try nextPersistenceRevision(snapshot.revision),
                record: recordToPersist,
                tombstones: snapshot.tombstones
            )

            do {
                try tokenStore.save(envelope)
            } catch {
                return fetchedRecord
            }
            _ = mergePersistedState(envelope, at: currentTime)
        }
        Self.postChangeNotification()
        return recordToPersist
    }

    @discardableResult
    private func persistRejection(
        _ rejectedToken: String,
        knownRecord: AlchemyJWTRecord?
    ) async -> Bool {
        guard let lockAcquisition = try? await acquireRefreshLock(),
              case .acquired = lockAcquisition else {
            return false
        }
        defer { refreshLock.release() }

        let currentTime = nowSeconds()
        let persistedState: AlchemyJWTPersistedState?
        let replacesInvalidPersistence: Bool
        do {
            persistedState = try tokenStore.load()
            replacesInvalidPersistence = false
        } catch AlchemyJWTStorageError.invalidData {
            persistedState = nil
            replacesInvalidPersistence = true
        } catch {
            return false
        }
        if !replacesInvalidPersistence {
            _ = mergePersistedState(persistedState, at: currentTime)
        }

        let rejectedDigest = Self.tokenDigest(rejectedToken)
        let persistedMatchingRecord = persistenceSnapshot(
            at: currentTime
        ).persistedState?.record.flatMap {
            Self.tokenDigest($0.token) == rejectedDigest ? $0 : nil
        }
        _ = markRejectedLocally(
            rejectedToken,
            knownRecord: knownRecord ?? persistedMatchingRecord
        )

        let saved = saveRejectionEnvelope(at: currentTime)
        if saved {
            Self.postChangeNotification()
        }
        return saved
    }

    private func saveRejectionEnvelope(at currentTime: Int64) -> Bool {
        persistenceMutationLock.lock()
        defer { persistenceMutationLock.unlock() }

        let snapshot = persistenceSnapshot(at: currentTime)
        let tombstonedDigests = Set(
            snapshot.tombstones.map(\.tokenDigest)
        )
        let revision: UInt64
        do {
            revision = try nextPersistenceRevision(snapshot.revision)
        } catch {
            return false
        }
        let retainedRecord = bestPersistableRecord(
            at: currentTime,
            persistedState: snapshot.persistedState,
            tombstonedDigests: tombstonedDigests
        )
        let envelope = AlchemyJWTPersistedState(
            revision: revision,
            record: retainedRecord,
            tombstones: snapshot.tombstones
        )

        do {
            try tokenStore.save(envelope)
        } catch {
            return false
        }
        _ = mergePersistedState(envelope, at: currentTime)
        return true
    }

    private func acquireRefreshLock(
        joinsActiveOpportunisticBroker: Bool = false,
        timeoutNanoseconds: UInt64? = nil
    ) async throws -> RefreshLockAcquisition {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, deadlineOverflow) = startedAt.addingReportingOverflow(
            timeoutNanoseconds ?? refreshLockTimeoutNanoseconds
        )
        let effectiveDeadline = deadlineOverflow ? UInt64.max : deadline

        while true {
            try Task.checkCancellation()
            if try refreshLock.tryAcquire() {
                return .acquired
            }

            if joinsActiveOpportunisticBroker {
                let currentTime = DispatchTime.now().uptimeNanoseconds
                let remaining = currentTime < effectiveDeadline
                    ? effectiveDeadline - currentTime
                    : 0
                if let outcome = await brokerFlight.joinActiveOpportunistic(
                    timeoutNanoseconds: remaining
                ) {
                    try Task.checkCancellation()
                    switch outcome {
                    case .succeeded(let record):
                        return .joinedOpportunisticBroker(record)
                    case .failed(let error):
                        if isAlchemyJWTBrokerRateLimit(error) {
                            throw error
                        }
                        // Demand retains its independent retry/backoff behavior.
                    case .timedOut:
                        return .timedOut
                    }
                }
            }

            let currentTime = DispatchTime.now().uptimeNanoseconds
            guard currentTime < effectiveDeadline else {
                return .timedOut
            }
            let remaining = effectiveDeadline - currentTime
            let pollInterval = max(refreshLockPollNanoseconds, 1)
            try await sleep(min(pollInterval, remaining))
        }
    }

    private func usableMemoryRecord(at currentTime: Int64) -> AlchemyJWTRecord? {
        stateLock.lock()
        guard let record = state.cachedRecord?.record else {
            stateLock.unlock()
            synchronizeProactiveRefresh(at: currentTime)
            return nil
        }
        guard record.isTimeUsable(at: currentTime) else {
            state.cachedRecord = nil
            stateLock.unlock()
            synchronizeProactiveRefresh(at: currentTime)
            return nil
        }
        stateLock.unlock()
        return record
    }

    private func loadUsablePersistedRecord(
        at currentTime: Int64
    ) -> AlchemyJWTRecord? {
        let persistedState: AlchemyJWTPersistedState?
        do {
            persistedState = try tokenStore.load()
        } catch {
            return nil
        }
        return mergePersistedState(persistedState, at: currentTime)
    }

    private func isRefreshAttemptAllowed(for intent: RefreshIntent) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        let currentUptime = uptimeNanoseconds()
        guard currentUptime >= state.nextBrokerRequestAt else {
            return false
        }

        switch intent {
        case .opportunistic, .immediateUsePrewarm:
            return currentUptime >= state.nextOpportunisticRefreshAt
        case .demand:
            return currentUptime >= state.nextDemandRefreshAt
        case .unauthorized:
            return true
        }
    }

    private func memoryRecord() -> AlchemyJWTRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.cachedRecord?.record
    }

    private func requiresPersistenceRepair() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let cachedRecord = state.cachedRecord,
           cachedRecord.persistenceRevision == nil {
            return true
        }

        let persistedTombstones = state.lastPersistedState?.tombstones ?? []
        if state.tombstones.isEmpty, persistedTombstones.isEmpty {
            return false
        }

        let localTombstones = Self.tombstonesByDigest(
            state.tombstones.values
        )
        guard localTombstones == Self.tombstonesByDigest(
            persistedTombstones
        ) else {
            return true
        }

        guard let persistedRecord = state.lastPersistedState?.record else {
            return false
        }
        return localTombstones[Self.tokenDigest(persistedRecord.token)] != nil
    }

    private func schedulePersistenceRepairIfNeeded() {
        guard requiresPersistenceRepair() else { return }
        schedulePersistenceRepair()
    }

    private func schedulePersistenceRepair() {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.persistenceRepairCoordinator.markDirty {
                [weak self] in
                guard let self else { return true }
                return await self.runPersistenceRepairWindow()
            }
        }
    }

    private func runPersistenceRepairWindow() async -> Bool {
        guard requiresPersistenceRepair() else { return true }

        let startedAt = uptimeNanoseconds()
        let deadline = Self.monotonicDeadline(
            after: persistenceRepairWindowNanoseconds,
            from: startedAt
        )
        var retryDelay = max(
            persistenceRepairInitialDelayNanoseconds,
            1
        )
        let maximumRetryDelay = max(
            persistenceRepairMaximumDelayNanoseconds,
            1
        )

        while true {
            guard !Task.isCancelled else { return false }

            do {
                if try refreshLock.tryAcquire() {
                    let didPersist = persistBestAvailableState()
                    refreshLock.release()
                    if didPersist && !requiresPersistenceRepair() {
                        return true
                    }
                }
            } catch {
                // Retry within this bounded best-effort repair window.
            }

            let currentUptime = uptimeNanoseconds()
            guard currentUptime < deadline else {
                return !requiresPersistenceRepair()
            }
            let remaining = deadline - currentUptime
            do {
                try await sleep(min(retryDelay, remaining))
            } catch {
                return false
            }
            retryDelay = min(
                Self.multipliedWithoutOverflow(retryDelay, by: 2),
                maximumRetryDelay
            )
        }
    }

    private func persistBestAvailableState() -> Bool {
        let currentTime = nowSeconds()
        let persistedState: AlchemyJWTPersistedState?
        let replacesInvalidPersistence: Bool
        do {
            persistedState = try tokenStore.load()
            replacesInvalidPersistence = false
        } catch AlchemyJWTStorageError.invalidData {
            persistedState = nil
            replacesInvalidPersistence = true
        } catch {
            return false
        }
        if !replacesInvalidPersistence {
            _ = mergePersistedState(persistedState, at: currentTime)
        }

        do {
            persistenceMutationLock.lock()
            defer { persistenceMutationLock.unlock() }

            let snapshot = persistenceSnapshot(at: currentTime)
            let tombstonedDigests = Set(
                snapshot.tombstones.map(\.tokenDigest)
            )
            let recordToPersist = bestPersistableRecord(
                at: currentTime,
                persistedState: snapshot.persistedState,
                tombstonedDigests: tombstonedDigests
            )
            if !replacesInvalidPersistence,
               let currentPersistedState = snapshot.persistedState,
               currentPersistedState.record == recordToPersist,
               Self.tombstonesByDigest(currentPersistedState.tombstones)
                    == Self.tombstonesByDigest(snapshot.tombstones) {
                return true
            }
            let revision: UInt64
            do {
                revision = try nextPersistenceRevision(snapshot.revision)
            } catch {
                return false
            }
            let envelope = AlchemyJWTPersistedState(
                revision: revision,
                record: recordToPersist,
                tombstones: snapshot.tombstones
            )
            do {
                try tokenStore.save(envelope)
            } catch {
                return false
            }
            _ = mergePersistedState(envelope, at: currentTime)
        }
        Self.postChangeNotification()
        return true
    }

    private func bestPersistableRecord(
        at currentTime: Int64,
        persistedState: AlchemyJWTPersistedState?,
        tombstonedDigests: Set<Data>
    ) -> AlchemyJWTRecord? {
        let candidates = [
            persistedState?.record,
            memoryRecord(),
        ].compactMap { $0 }.filter {
            $0.isUsable(at: currentTime)
                && !tombstonedDigests.contains(Self.tokenDigest($0.token))
        }
        return candidates.max {
            if $0.issuedAt != $1.issuedAt {
                return $0.issuedAt < $1.issuedAt
            }
            if $0.expiresAt != $1.expiresAt {
                return $0.expiresAt < $1.expiresAt
            }
            return $0.token < $1.token
        }
    }

    @discardableResult
    private func markRejectedLocally(
        _ token: String,
        knownRecord: AlchemyJWTRecord? = nil
    ) -> AlchemyJWTRecord? {
        let currentTime = nowSeconds()
        let digest = Self.tokenDigest(token)

        // Local rejection must not wait for a synchronous Keychain mutation.
        // Any persistence snapshot that raced this tombstone is repaired by the
        // existing dirty-state persistence coordinator.
        stateLock.lock()
        let cachedMatchingRecord = state.cachedRecord.flatMap {
            $0.record.token == token ? $0.record : nil
        }
        let rejectedRecord = knownRecord ?? cachedMatchingRecord
        let fallbackExpiration = Self.addingWithoutOverflow(
            currentTime,
            Self.unknownTokenTombstoneLifetime
        )
        let tombstone = AlchemyJWTRejectionTombstone(
            tokenDigest: digest,
            rejectedAt: currentTime,
            expiresAt: max(rejectedRecord?.expiresAt ?? fallbackExpiration, currentTime + 1)
        )
        if rejectedRecord != nil {
            let previousRejection = state.tombstones[digest]?.rejectedAt
                ?? Int64.min
            state.tombstones[digest] = AlchemyJWTRejectionTombstone(
                tokenDigest: digest,
                rejectedAt: max(previousRejection, currentTime),
                expiresAt: tombstone.expiresAt
            )
        } else {
            Self.merge(
                tombstone,
                into: &state.tombstones
            )
        }
        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime,
            preserving: digest
        )
        if cachedMatchingRecord != nil {
            state.cachedRecord = nil
        }
        stateLock.unlock()
        synchronizeProactiveRefresh(at: currentTime)
        return rejectedRecord
    }

    private func recordRefreshSuccess(
        _ record: AlchemyJWTRecord,
        for intent: RefreshIntent
    ) -> AlchemyJWTRecord? {
        let currentTime = nowSeconds()
        let currentUptime = uptimeNanoseconds()
        let digest = Self.tokenDigest(record.token)

        stateLock.lock()
        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime
        )
        if let cached = state.cachedRecord {
            if state.tombstones[cached.tokenDigest] != nil
                || !cached.record.isTimeUsable(at: currentTime) {
                state.cachedRecord = nil
            }
        }
        guard state.tombstones[digest] == nil else {
            stateLock.unlock()
            return nil
        }

        if let existing = state.cachedRecord,
           existing.record.token != record.token,
           existing.record.issuedAt >= record.issuedAt {
            // A concurrent refresh already installed an equally new or newer JWT.
        } else {
            let existingRevision: UInt64?
            if state.cachedRecord?.record.token == record.token {
                existingRevision = state.cachedRecord?.persistenceRevision
            } else {
                existingRevision = nil
            }
            state.cachedRecord = CachedRecord(
                record: record,
                tokenDigest: digest,
                persistenceRevision: existingRevision
            )
        }
        let installedRecord = state.cachedRecord?.record
        if case .opportunistic = intent,
           let installedRecord,
           installedRecord.shouldRefresh(at: currentTime) {
            advanceOpportunisticBackoffLocked(at: currentUptime)
        } else {
            state.opportunisticFailures = 0
            state.nextOpportunisticRefreshAt = 0
        }
        state.demandFailures = 0
        state.nextDemandRefreshAt = 0
        stateLock.unlock()
        return installedRecord
    }

    private func recordRefreshFailure(
        for intent: RefreshIntent,
        error: Error
    ) {
        stateLock.lock()
        let currentUptime = uptimeNanoseconds()
        if let brokerError = error as? AlchemyJWTBrokerError,
           case .rateLimited(let retryAfterSeconds) = brokerError {
            let deadline = Self.monotonicDeadline(
                after: Self.nanoseconds(
                    seconds: TimeInterval(max(retryAfterSeconds, 0))
                ),
                from: currentUptime
            )
            state.nextBrokerRequestAt = max(
                state.nextBrokerRequestAt,
                deadline
            )
            stateLock.unlock()
            return
        }

        switch intent {
        case .opportunistic, .immediateUsePrewarm:
            advanceOpportunisticBackoffLocked(at: currentUptime)
        case .demand:
            state.demandFailures = min(state.demandFailures + 1, 5)
            let delay = min(
                0.25 * pow(2, Double(state.demandFailures - 1)),
                4
            )
            state.nextDemandRefreshAt = Self.monotonicDeadline(
                after: Self.nanoseconds(seconds: delay),
                from: currentUptime
            )
        case .unauthorized:
            break
        }
        stateLock.unlock()
    }

    // Call only while stateLock is held.
    private func advanceOpportunisticBackoffLocked(
        at currentUptime: UInt64
    ) {
        state.opportunisticFailures = min(
            state.opportunisticFailures + 1,
            10
        )
        let delay = min(
            pow(2, Double(state.opportunisticFailures - 1)),
            300
        )
        state.nextOpportunisticRefreshAt = Self.monotonicDeadline(
            after: Self.nanoseconds(seconds: delay),
            from: currentUptime
        )
    }

    private func mergePersistedState(
        _ persistedState: AlchemyJWTPersistedState?,
        at currentTime: Int64
    ) -> AlchemyJWTRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }

        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime
        )

        if let cached = state.cachedRecord {
            if state.tombstones[cached.tokenDigest] != nil
                || !cached.record.isTimeUsable(at: currentTime) {
                state.cachedRecord = nil
            }
        }

        guard let persistedState,
              persistedState.version ==
                  AlchemyJWTPersistedState.currentVersion else {
            return state.cachedRecord?.record
        }
        if let lastPersistedState = state.lastPersistedState {
            guard persistedState.revision > lastPersistedState.revision else {
                return state.cachedRecord?.record
            }
        }

        let candidate = persistedState.record
        let usableCandidateDigest = candidate.flatMap { record -> Data? in
            guard record.isUsable(at: currentTime) else { return nil }
            return Self.tokenDigest(record.token)
        }
        for tombstone in persistedState.tombstones
            where tombstone.isLive(at: currentTime) {
            Self.merge(tombstone, into: &state.tombstones)
        }
        let rejectedPersistedRecordDigest = usableCandidateDigest.flatMap {
            state.tombstones[$0] == nil ? nil : $0
        }
        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime,
            preserving: rejectedPersistedRecordDigest
        )
        state.lastPersistedState = persistedState

        if let cached = state.cachedRecord {
            if state.tombstones[cached.tokenDigest] != nil
                || !cached.record.isTimeUsable(at: currentTime) {
                state.cachedRecord = nil
            }
        }

        guard let candidate,
              let usableCandidateDigest,
              state.tombstones[usableCandidateDigest] == nil else {
            return state.cachedRecord?.record
        }

        let shouldInstall: Bool
        if let current = state.cachedRecord {
            if candidate.token == current.record.token {
                shouldInstall = true
            } else if candidate.issuedAt > current.record.issuedAt {
                shouldInstall = true
            } else if candidate.issuedAt == current.record.issuedAt,
                      let currentRevision = current.persistenceRevision,
                      persistedState.revision > currentRevision {
                shouldInstall = true
            } else {
                shouldInstall = false
            }
        } else {
            shouldInstall = true
        }

        if shouldInstall {
            let installsDifferentFreshToken =
                state.cachedRecord?.record.token != candidate.token
                && !candidate.shouldRefresh(at: currentTime)
            state.cachedRecord = CachedRecord(
                record: candidate,
                tokenDigest: usableCandidateDigest,
                persistenceRevision: persistedState.revision
            )
            if installsDifferentFreshToken {
                state.opportunisticFailures = 0
                state.nextOpportunisticRefreshAt = 0
                state.demandFailures = 0
                state.nextDemandRefreshAt = 0
            }
        }
        return state.cachedRecord?.record
    }

    private func persistenceSnapshot(
        at currentTime: Int64
    ) -> (
        revision: UInt64,
        persistedState: AlchemyJWTPersistedState?,
        tombstones: [AlchemyJWTRejectionTombstone]
    ) {
        stateLock.lock()
        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime
        )
        let persistedState = state.lastPersistedState
        let revision = persistedState?.revision ?? 0
        let tombstones = state.tombstones.values.sorted {
            if $0.rejectedAt == $1.rejectedAt {
                return $0.tokenDigest.lexicographicallyPrecedes(
                    $1.tokenDigest
                )
            }
            return $0.rejectedAt > $1.rejectedAt
        }
        stateLock.unlock()
        return (revision, persistedState, tombstones)
    }

    private func isTombstoned(_ token: String, at currentTime: Int64) -> Bool {
        let digest = Self.tokenDigest(token)
        stateLock.lock()
        state.tombstones = Self.trimmedTombstones(
            state.tombstones.values,
            at: currentTime
        )
        let isTombstoned = state.tombstones[digest] != nil
        stateLock.unlock()
        return isTombstoned
    }

    private func nextPersistenceRevision(
        _ currentRevision: UInt64
    ) throws -> UInt64 {
        guard currentRevision < UInt64.max else {
            throw ProviderError.invalidPersistenceState
        }
        return currentRevision + 1
    }

    private static func tokenDigest(_ token: String) -> Data {
        return Data(SHA256.hash(data: Data(token.utf8)))
    }

    private static func merge(
        _ tombstone: AlchemyJWTRejectionTombstone,
        into tombstones: inout [Data: AlchemyJWTRejectionTombstone]
    ) {
        if let current = tombstones[tombstone.tokenDigest] {
            tombstones[tombstone.tokenDigest] =
                AlchemyJWTRejectionTombstone(
                    tokenDigest: tombstone.tokenDigest,
                    rejectedAt: max(
                        current.rejectedAt,
                        tombstone.rejectedAt
                    ),
                    expiresAt: max(current.expiresAt, tombstone.expiresAt)
                )
        } else {
            tombstones[tombstone.tokenDigest] = tombstone
        }
    }

    private static func tombstonesByDigest<S: Sequence>(
        _ tombstones: S
    ) -> [Data: AlchemyJWTRejectionTombstone]
    where S.Element == AlchemyJWTRejectionTombstone {
        var result: [Data: AlchemyJWTRejectionTombstone] = [:]
        for tombstone in tombstones {
            merge(tombstone, into: &result)
        }
        return result
    }

    private static func trimmedTombstones<S: Sequence>(
        _ tombstones: S,
        at currentTime: Int64,
        preserving preservedDigest: Data? = nil
    ) -> [Data: AlchemyJWTRejectionTombstone]
    where S.Element == AlchemyJWTRejectionTombstone {
        var merged: [Data: AlchemyJWTRejectionTombstone] = [:]
        for tombstone in tombstones where tombstone.isLive(at: currentTime) {
            merge(tombstone, into: &merged)
        }
        var retained: [AlchemyJWTRejectionTombstone] = []
        if let preservedDigest,
           let preserved = merged.removeValue(forKey: preservedDigest) {
            retained.append(preserved)
        }
        retained.append(contentsOf: merged.values.sorted {
            if $0.rejectedAt == $1.rejectedAt {
                return $0.tokenDigest.lexicographicallyPrecedes(
                    $1.tokenDigest
                )
            }
            return $0.rejectedAt > $1.rejectedAt
        }.prefix(maximumTombstones - retained.count))
        return Dictionary(
            uniqueKeysWithValues: retained.map {
                ($0.tokenDigest, $0)
            }
        )
    }

    private static func addingWithoutOverflow(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : result
    }

    private static func monotonicDeadline(
        after delay: UInt64,
        from currentTime: UInt64
    ) -> UInt64 {
        let (deadline, overflow) = currentTime.addingReportingOverflow(delay)
        return overflow ? UInt64.max : deadline
    }

    private static func nanoseconds(seconds: TimeInterval) -> UInt64 {
        guard seconds > 0 else { return 0 }
        let value = seconds * 1_000_000_000
        guard value.isFinite, value < Double(UInt64.max) else {
            return UInt64.max
        }
        return UInt64(value.rounded(.up))
    }

    private static func nanosecondsUntil(
        _ deadline: Int64,
        from currentTime: Int64
    ) -> UInt64 {
        let (seconds, overflow) = deadline.subtractingReportingOverflow(
            currentTime
        )
        guard !overflow, seconds > 0 else {
            return overflow && deadline > currentTime ? UInt64.max : 0
        }
        let (nanoseconds, nanosecondsOverflow) = UInt64(seconds)
            .multipliedReportingOverflow(by: 1_000_000_000)
        return nanosecondsOverflow ? UInt64.max : nanoseconds
    }

    private static func absoluteDifference(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        return lhs >= rhs ? lhs - rhs : rhs - lhs
    }

    private static func multipliedWithoutOverflow(
        _ value: UInt64,
        by multiplier: UInt64
    ) -> UInt64 {
        let (result, overflow) = value.multipliedReportingOverflow(
            by: multiplier
        )
        return overflow ? UInt64.max : result
    }

    private func nowSeconds() -> Int64 {
        return Int64(now().timeIntervalSince1970.rounded(.down))
    }

    private static func postChangeNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil,
            nil,
            true
        )
    }

}

private actor AlchemyJWTRefreshCoordinator {

    private struct InFlightRefresh {
        let identifier: UInt64
        let task: Task<AlchemyJWTRecord, Error>
    }

    private var inFlightRefreshes: [
        AlchemyJWTProvider.RefreshFlightKey: InFlightRefresh
    ] = [:]
    private var nextIdentifier: UInt64 = 0

    func run(
        key: AlchemyJWTProvider.RefreshFlightKey,
        operation: @escaping @Sendable () async throws -> AlchemyJWTRecord
    ) async throws -> AlchemyJWTRecord {
        if let inFlightRefresh = inFlightRefreshes[key] {
            return try await value(of: inFlightRefresh, key: key)
        }

        let task = Task {
            try await operation()
        }
        nextIdentifier &+= 1
        let refresh = InFlightRefresh(
            identifier: nextIdentifier,
            task: task
        )
        inFlightRefreshes[key] = refresh
        return try await value(of: refresh, key: key)
    }

    private func value(
        of refresh: InFlightRefresh,
        key: AlchemyJWTProvider.RefreshFlightKey
    ) async throws -> AlchemyJWTRecord {
        defer { clear(refresh, key: key) }
        return try await refresh.task.value
    }

    private func clear(
        _ refresh: InFlightRefresh,
        key: AlchemyJWTProvider.RefreshFlightKey
    ) {
        guard inFlightRefreshes[key]?.identifier == refresh.identifier else {
            return
        }
        inFlightRefreshes[key] = nil
    }

}

private actor AlchemyJWTBrokerFlight {

    enum Kind: Equatable, Sendable {
        case opportunistic
        case demand
        case unauthorized
    }

    private struct InFlightBrokerRequest {
        let identifier: UInt64
        let kind: Kind
        let task: Task<AlchemyJWTRecord, Error>
    }

    enum OpportunisticJoinOutcome {
        case succeeded(AlchemyJWTRecord)
        case failed(Error)
        case timedOut
    }

    private struct OpportunisticWaiter {
        let requestIdentifier: UInt64
        let continuation: CheckedContinuation<
            OpportunisticJoinOutcome,
            Never
        >
    }

    private var inFlightRequest: InFlightBrokerRequest?
    private var nextIdentifier: UInt64 = 0
    private var nextWaiterIdentifier: UInt64 = 0
    private var opportunisticWaiters: [UInt64: OpportunisticWaiter] = [:]

    func run(
        kind: Kind,
        bypassesActiveOpportunisticRequest: Bool = false,
        operation: @escaping @Sendable () async throws -> AlchemyJWTRecord
    ) async throws -> AlchemyJWTRecord {
        while let inFlightRequest {
            if bypassesActiveOpportunisticRequest,
               inFlightRequest.kind == .opportunistic {
                break
            }
            do {
                return try await value(of: inFlightRequest)
            } catch {
                guard Self.shouldRetryIndependently(
                    requesting: kind,
                    after: inFlightRequest,
                    error: error
                ) else {
                    throw error
                }
            }
        }

        let task = Task {
            try await operation()
        }
        nextIdentifier &+= 1
        let request = InFlightBrokerRequest(
            identifier: nextIdentifier,
            kind: kind,
            task: task
        )
        inFlightRequest = request
        return try await value(of: request)
    }

    func joinActiveOpportunistic(
        timeoutNanoseconds: UInt64
    ) async -> OpportunisticJoinOutcome? {
        guard let request = inFlightRequest,
              request.kind == .opportunistic else {
            return nil
        }
        guard timeoutNanoseconds > 0 else {
            return .timedOut
        }

        nextWaiterIdentifier &+= 1
        let waiterIdentifier = nextWaiterIdentifier
        return await withCheckedContinuation { continuation in
            opportunisticWaiters[waiterIdentifier] = OpportunisticWaiter(
                requestIdentifier: request.identifier,
                continuation: continuation
            )
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.timeOutWaiter(
                    identifier: waiterIdentifier,
                    requestIdentifier: request.identifier
                )
            }
        }
    }

    private static func shouldRetryIndependently(
        requesting kind: Kind,
        after request: InFlightBrokerRequest,
        error: Error
    ) -> Bool {
        guard request.kind == .opportunistic,
              !isAlchemyJWTBrokerRateLimit(error) else {
            return false
        }

        switch kind {
        case .demand, .unauthorized:
            return true
        case .opportunistic:
            return false
        }
    }

    private func value(
        of request: InFlightBrokerRequest
    ) async throws -> AlchemyJWTRecord {
        do {
            let record = try await request.task.value
            finish(request, outcome: .succeeded(record))
            return record
        } catch {
            finish(request, outcome: .failed(error))
            throw error
        }
    }

    private func finish(
        _ request: InFlightBrokerRequest,
        outcome: OpportunisticJoinOutcome
    ) {
        if inFlightRequest?.identifier == request.identifier {
            inFlightRequest = nil
        }

        let matchingWaiters = opportunisticWaiters.filter {
            $0.value.requestIdentifier == request.identifier
        }
        for (identifier, waiter) in matchingWaiters {
            opportunisticWaiters[identifier] = nil
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func timeOutWaiter(
        identifier: UInt64,
        requestIdentifier: UInt64
    ) {
        guard let waiter = opportunisticWaiters[identifier],
              waiter.requestIdentifier == requestIdentifier else {
            return
        }
        opportunisticWaiters[identifier] = nil
        waiter.continuation.resume(returning: .timedOut)
    }

}

private actor AlchemyJWTPersistenceRepairCoordinator {

    typealias Operation = @Sendable () async -> Bool
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var latestOperation: Operation?
    private var activeIdentifier: UInt64?
    private var consecutiveFailedWindows: UInt64 = 0
    private let initialCooldownNanoseconds: UInt64
    private let maximumCooldownNanoseconds: UInt64
    private let sleep: Sleeper

    init(
        initialCooldownNanoseconds: UInt64,
        maximumCooldownNanoseconds: UInt64,
        sleep: @escaping Sleeper
    ) {
        self.initialCooldownNanoseconds = max(
            initialCooldownNanoseconds,
            1
        )
        self.maximumCooldownNanoseconds = max(
            maximumCooldownNanoseconds,
            1
        )
        self.sleep = sleep
    }

    func markDirty(operation: @escaping Operation) {
        generation &+= 1
        latestOperation = operation
        guard activeIdentifier == nil else { return }
        startRepair()
    }

    private func startRepair() {
        guard let operation = latestOperation else { return }

        nextIdentifier &+= 1
        let identifier = nextIdentifier
        let observedGeneration = generation
        activeIdentifier = identifier
        Task { [weak self] in
            let isClean = await operation()
            await self?.repairCompleted(
                identifier: identifier,
                observedGeneration: observedGeneration,
                isClean: isClean
            )
        }
    }

    private func repairCompleted(
        identifier: UInt64,
        observedGeneration: UInt64,
        isClean: Bool
    ) {
        guard activeIdentifier == identifier else { return }

        if isClean {
            activeIdentifier = nil
            consecutiveFailedWindows = 0
            if generation != observedGeneration {
                startRepair()
            }
            return
        }

        consecutiveFailedWindows = min(
            consecutiveFailedWindows + 1,
            5
        )
        let cooldown = cooldownNanoseconds(
            after: consecutiveFailedWindows
        )
        nextIdentifier &+= 1
        let cooldownIdentifier = nextIdentifier
        activeIdentifier = cooldownIdentifier
        let cooldownSleep = sleep
        Task { [weak self, cooldownSleep] in
            do {
                try await cooldownSleep(cooldown)
            } catch {
                await self?.cooldownCancelled(
                    identifier: cooldownIdentifier
                )
                return
            }
            await self?.cooldownCompleted(identifier: cooldownIdentifier)
        }
    }

    private func cooldownCompleted(identifier: UInt64) {
        guard activeIdentifier == identifier else { return }
        activeIdentifier = nil
        if latestOperation != nil {
            startRepair()
        }
    }

    private func cooldownCancelled(identifier: UInt64) {
        guard activeIdentifier == identifier else { return }
        activeIdentifier = nil
    }

    private func cooldownNanoseconds(after failures: UInt64) -> UInt64 {
        var cooldown = initialCooldownNanoseconds
        var remainingDoublings = failures > 0 ? failures - 1 : 0
        while remainingDoublings > 0,
              cooldown < maximumCooldownNanoseconds {
            let (doubled, overflow) = cooldown.multipliedReportingOverflow(
                by: 2
            )
            cooldown = overflow
                ? maximumCooldownNanoseconds
                : min(doubled, maximumCooldownNanoseconds)
            remainingDoublings -= 1
        }
        return min(cooldown, maximumCooldownNanoseconds)
    }

}

private final class AlchemyJWTKeychainStore:
    @unchecked Sendable,
    AlchemyJWTStoring {

    private let accessGroup = "8DXC3N7E7P.org.lil.wallet.rpc-auth"
    private let service = "org.lil.wallet.alchemy-jwt"
    private let account = "shared-token-v1"

    func load() throws -> AlchemyJWTPersistedState? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AlchemyJWTStorageError.transient
        }
        guard let data = item as? Data,
              let state = AlchemyJWTPersistedState
                  .decodePersistenceData(data) else {
            throw AlchemyJWTStorageError.invalidData
        }
        return state
    }

    func save(_ state: AlchemyJWTPersistedState) throws {
        let data = try JSONEncoder().encode(state)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            updateAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw AlchemyJWTStorageError.transient
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw AlchemyJWTStorageError.transient
            }
            return
        }
        guard addStatus == errSecSuccess else {
            throw AlchemyJWTStorageError.transient
        }
    }

    private var baseQuery: [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

}

final class AlchemyAppGroupInstallationIDProvider:
    @unchecked Sendable,
    AlchemyInstallationIDProviding {

    private enum InstallationIDError: Error {
        case missingAppGroupContainer
    }

    private static let lockTimeoutNanoseconds: UInt64 = 500_000_000
    private static let lockPollNanoseconds: UInt64 = 10_000_000

    private let containerURL: URL?
    private let memoryLock = NSLock()
    private var cachedInstallationID: UUID?

    init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    func installationID() throws -> UUID {
        memoryLock.lock()
        defer { memoryLock.unlock() }

        if let cachedInstallationID {
            return cachedInstallationID
        }

        guard let containerURL else {
            throw InstallationIDError.missingAppGroupContainer
        }

        let fileURL = containerURL.appendingPathComponent(
            "alchemy-jwt-installation-id",
            isDirectory: false
        )
        if let existingID = Self.readInstallationID(at: fileURL) {
            cachedInstallationID = existingID
            return existingID
        }

        let fileLock = AlchemyJWTFileLock(
            fileURL: containerURL.appendingPathComponent(
                ".alchemy-jwt-installation.lock",
                isDirectory: false
            )
        )
        try fileLock.acquire(
            timeoutNanoseconds: Self.lockTimeoutNanoseconds,
            pollNanoseconds: Self.lockPollNanoseconds
        )
        defer { fileLock.release() }

        let installationID: UUID
        if let existingID = Self.readInstallationID(at: fileURL) {
            installationID = existingID
        } else {
            let newID = UUID()
            let data = Data(newID.uuidString.lowercased().utf8)
            try data.write(to: fileURL, options: .atomic)
            installationID = newID
        }

        cachedInstallationID = installationID
        return installationID
    }

    private static func readInstallationID(at fileURL: URL) -> UUID? {
        guard let data = try? Data(contentsOf: fileURL),
              let value = String(data: data, encoding: .utf8),
              value == value.lowercased(),
              let existingID = UUID(uuidString: value),
              existingID.uuidString.lowercased() == value else {
            return nil
        }
        return existingID
    }

}

final class AlchemyJWTFileLock:
    @unchecked Sendable,
    AlchemyJWTRefreshLocking {

    private enum FileLockError: Error {
        case missingFileURL
        case openFailed
        case lockFailed
        case lockTimedOut
    }

    private let fileURL: URL?
    private let descriptorLock = NSLock()
    private var descriptor: Int32 = -1
    private var acquisitionInProgress = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func acquire(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64
    ) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, deadlineOverflow) = startedAt.addingReportingOverflow(
            timeoutNanoseconds
        )
        let effectiveDeadline = deadlineOverflow ? UInt64.max : deadline

        while true {
            if try tryAcquire() {
                return
            }

            let currentTime = DispatchTime.now().uptimeNanoseconds
            guard currentTime < effectiveDeadline else {
                throw FileLockError.lockTimedOut
            }
            let remaining = effectiveDeadline - currentTime
            let interval = min(max(pollNanoseconds, 1), remaining)
            Thread.sleep(
                forTimeInterval: TimeInterval(interval) / 1_000_000_000
            )
        }
    }

    func tryAcquire() throws -> Bool {
        guard let fileURL else { throw FileLockError.missingFileURL }

        descriptorLock.lock()
        guard descriptor < 0, !acquisitionInProgress else {
            descriptorLock.unlock()
            return false
        }
        acquisitionInProgress = true
        descriptorLock.unlock()

        let openedDescriptor = Darwin.open(
            fileURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            finishFailedAcquisition()
            throw FileLockError.openFailed
        }

        while alchemySystemFlock(openedDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR {
                continue
            }
            Darwin.close(openedDescriptor)
            finishFailedAcquisition()
            if lockError == EACCES
                || lockError == EAGAIN
                || lockError == EWOULDBLOCK {
                return false
            }
            throw FileLockError.lockFailed
        }

        descriptorLock.lock()
        descriptor = openedDescriptor
        acquisitionInProgress = false
        descriptorLock.unlock()
        return true
    }

    func release() {
        descriptorLock.lock()
        let openedDescriptor = descriptor
        descriptor = -1
        descriptorLock.unlock()

        guard openedDescriptor >= 0 else { return }
        _ = alchemySystemFlock(openedDescriptor, LOCK_UN)
        Darwin.close(openedDescriptor)
    }

    private func finishFailedAcquisition() {
        descriptorLock.lock()
        acquisitionInProgress = false
        descriptorLock.unlock()
    }

    deinit {
        release()
    }

}

final class AlchemyJWTBrokerClient:
    @unchecked Sendable,
    AlchemyJWTBrokerFetching {

    private struct RequestBody: Encodable {
        let installationId: String
    }

    private let endpoint = URL(string: "https://api.lil.org/v1/alchemy/jwt")!
    private let urlSession: URLSession

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func fetchToken(installationID: UUID) async throws -> AlchemyJWTRecord {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                installationId: installationID.uuidString.lowercased()
            )
        )

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw AlchemyJWTBrokerError.invalidResponse
        }
        if response.statusCode == 429 {
            bytes.task.cancel()
            throw AlchemyJWTBrokerError.rateLimited(
                retryAfterSeconds: Self.retryAfterSeconds(
                    response.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            bytes.task.cancel()
            throw AlchemyJWTBrokerError.invalidResponse
        }

        let maximumResponseBytes = 16_384
        let declaredLength = response.expectedContentLength
        guard declaredLength < 0
                || declaredLength <= Int64(maximumResponseBytes) else {
            bytes.task.cancel()
            throw AlchemyJWTBrokerError.invalidResponse
        }

        var data = Data()
        if declaredLength > 0 {
            data.reserveCapacity(Int(declaredLength))
        }
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    bytes.task.cancel()
                    throw AlchemyJWTBrokerError.invalidResponse
                }
                data.append(byte)
            }
        } catch {
            bytes.task.cancel()
            throw error
        }

        guard let record = try? JSONDecoder().decode(
                  AlchemyJWTRecord.self,
                  from: data
              ) else {
            bytes.task.cancel()
            throw AlchemyJWTBrokerError.invalidResponse
        }
        return record
    }

    static func retryAfterSeconds(_ value: String?) -> Int {
        guard let value else { return 60 }
        let bytes = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .utf8
        guard !bytes.isEmpty,
              bytes.allSatisfy({ (48...57).contains($0) }) else {
            return 60
        }

        var seconds = 0
        for byte in bytes {
            seconds = seconds * 10 + Int(byte - 48)
            if seconds >= 300 {
                return 300
            }
        }
        return max(seconds, 1)
    }

}

private final class AlchemyJWTDarwinObserver {

    private let name: CFNotificationName
    private let callback: () -> Void

    init(name: CFNotificationName, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let notificationObserver = Unmanaged<AlchemyJWTDarwinObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                notificationObserver.callback()
            },
            name.rawValue,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            name,
            nil
        )
    }

}
