// ∅ 2026 lil org

import CoreFoundation
import Foundation

enum CustomNetworkInsertionResult: Equatable, Hashable, Sendable {

    case inserted
    case matching
    case conflict
    case unavailable

    var succeeded: Bool {
        switch self {
        case .inserted, .matching:
            return true
        case .conflict, .unavailable:
            return false
        }
    }

}

enum CustomNetworkDefinition {

    static func requestedRPCURLs(
        for record: EthereumNetworkFromDapp
    ) -> [URL] {
        var normalized = Set<String>()
        let candidates = [record.defaultRpcURL].compactMap { $0 } +
            record.rpcUrls.compactMap(CustomEthereumRPC.storedURL(from:))
        return candidates.compactMap { candidate in
            return normalized.insert(normalizedRPCURL(candidate)).inserted
                ? candidate
                : nil
        }
    }

    static func storedRPCURL(
        for record: EthereumNetworkFromDapp,
        legacyOverride: String?
    ) -> URL? {
        return legacyOverride.flatMap(CustomEthereumRPC.storedURL(from:)) ??
            record.defaultRpcURL ??
            record.storedRpcURL
    }

    static func normalizedRPCURL(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    static func matches(
        requested: EthereumNetworkFromDapp,
        requestedRPCURL: URL,
        existing: EthereumNetworkFromDapp,
        existingRPCURL: URL
    ) -> Bool {
        return normalizedRPCURL(requestedRPCURL)
            == normalizedRPCURL(existingRPCURL)
            && requested.chainName == existing.chainName
            && requested.nativeCurrency.name == existing.nativeCurrency.name
            && requested.nativeCurrency.symbol == existing.nativeCurrency.symbol
            && requested.nativeCurrency.decimals == existing.nativeCurrency.decimals
    }

}

struct SharedDefaults {
    
#if os(macOS)
    static let suiteName = "8DXC3N7E7P.group.org.lil.wallet"
#else
    static let suiteName = "group.org.lil.wallet"
#endif
    static let defaults = UserDefaults(suiteName: suiteName)
    
    static let customEthereumNetworksKey = "customEthereumNetworks"
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"
    private static let customNetworksStorageLock = NSLock()
    private static let customNetworksStorageFileLock = CrossProcessFileLock(
        fileURL: FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        )?.appendingPathComponent(
            ".custom-ethereum-networks.lock",
            isDirectory: false
        )
    )
    private static let customNetworksStorageLockTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let customNetworksStorageLockPollNanoseconds: UInt64 = 10_000_000

    static func synchronize() {
        defaults?.synchronize()
    }
    
    @discardableResult
    static func addNetwork(_ network: EthereumNetworkFromDapp) -> Bool {
        return insertNetwork(network).succeeded
    }

    static func insertNetwork(
        _ network: EthereumNetworkFromDapp
    ) -> CustomNetworkInsertionResult {
        guard let defaults else { return .unavailable }
        let result = insertNetwork(
            network,
            to: defaults,
            crossProcessLock: customNetworksStorageFileLock
        )
        if result.succeeded {
            CustomNetworkCache.shared.invalidate()
            CustomNetworkChangeNotification.post()
        }
        return result
    }

    @discardableResult
    static func addNetwork(_ network: EthereumNetworkFromDapp,
                           to defaults: UserDefaults) -> Bool {
        return insertNetwork(network, to: defaults).succeeded
    }

    @discardableResult
    static func addNetwork(
        _ network: EthereumNetworkFromDapp,
        to defaults: UserDefaults,
        crossProcessLock: CrossProcessFileLock?
    ) -> Bool {
        return insertNetwork(
            network,
            to: defaults,
            crossProcessLock: crossProcessLock
        ).succeeded
    }

    static func insertNetwork(
        _ network: EthereumNetworkFromDapp,
        to defaults: UserDefaults
    ) -> CustomNetworkInsertionResult {
        return insertNetwork(network, to: defaults, crossProcessLock: nil)
    }

    static func insertNetwork(
        _ network: EthereumNetworkFromDapp,
        to defaults: UserDefaults,
        crossProcessLock: CrossProcessFileLock?,
        synchronizeDefaults: (UserDefaults) -> Bool = { $0.synchronize() }
    ) -> CustomNetworkInsertionResult {
        guard let chainId = Int(hexString: network.chainId),
              chainId > 0 else {
            return .unavailable
        }

        if let crossProcessLock {
            do {
                try crossProcessLock.acquire(
                    timeoutNanoseconds: customNetworksStorageLockTimeoutNanoseconds,
                    pollNanoseconds: customNetworksStorageLockPollNanoseconds
                )
            } catch {
                return .unavailable
            }
        }
        defer { crossProcessLock?.release() }

        return withCustomNetworksStorageLock {
            guard synchronizeDefaults(defaults) else { return .unavailable }

            let storedNetworks: [EthereumNetworkFromDapp]
            switch customNetworksArchive(in: defaults) {
            case .missing:
                storedNetworks = []
            case .decoded(let networks):
                storedNetworks = networks
            case .corrupt:
                return .unavailable
            }

            if let existing = storedNetworks.last(where: {
                Int(hexString: $0.chainId) == chainId
            }) {
                let requestedRPCURLs = CustomNetworkDefinition.requestedRPCURLs(
                    for: network
                )
                guard !requestedRPCURLs.isEmpty,
                      let existingRPCURL = CustomNetworkDefinition.storedRPCURL(
                    for: existing,
                    legacyOverride: defaults.string(
                        forKey: customEthereumNetworkNodeKey(chainId: chainId)
                    )
                ) else {
                    return .unavailable
                }
                guard requestedRPCURLs.contains(where: { requestedRPCURL in
                    CustomNetworkDefinition.matches(
                        requested: network,
                        requestedRPCURL: requestedRPCURL,
                        existing: existing,
                        existingRPCURL: existingRPCURL
                    )
                }) else {
                    return .conflict
                }
                return .matching
            }

            guard network.defaultRpcURL != nil else { return .unavailable }

            var networkToStore = network
            networkToStore.rpcUrls = network.rpcUrls.compactMap {
                CustomEthereumRPC.url(from: $0)?.absoluteString
            }
            guard let encoded = try? JSONEncoder().encode(
                storedNetworks + [networkToStore]
            ) else {
                return .unavailable
            }

            let overrideKey = customEthereumNetworkNodeKey(chainId: chainId)
            let previousArchive = defaults.object(forKey: customEthereumNetworksKey)
            let previousOverride = defaults.object(forKey: overrideKey)
            defaults.set(encoded, forKey: customEthereumNetworksKey)
            defaults.removeObject(forKey: overrideKey)
            guard synchronizeDefaults(defaults) else {
                restore(previousArchive, forKey: customEthereumNetworksKey, in: defaults)
                restore(previousOverride, forKey: overrideKey, in: defaults)
                _ = synchronizeDefaults(defaults)
                return .unavailable
            }
            return .inserted
        }
    }

    static func loadCustomNetworkSnapshot() -> CustomNetworkSnapshotLoadResult {
        guard let defaults else { return .unavailable }
        do {
            try customNetworksStorageFileLock.acquire(
                timeoutNanoseconds: customNetworksStorageLockTimeoutNanoseconds,
                pollNanoseconds: customNetworksStorageLockPollNanoseconds
            )
        } catch {
            return .unavailable
        }
        defer { customNetworksStorageFileLock.release() }
        return loadCustomNetworkSnapshotResult(from: defaults)
    }

    static func loadCustomNetworkSnapshot(from defaults: UserDefaults) -> CustomNetworkSnapshot {
        guard case .loaded(let snapshot) = loadCustomNetworkSnapshotResult(
            from: defaults
        ) else { return .empty }
        return snapshot
    }

    static func loadCustomNetworkSnapshotResult(
        from defaults: UserDefaults,
        synchronizeDefaults: (UserDefaults) -> Bool = { $0.synchronize() }
    ) -> CustomNetworkSnapshotLoadResult {
        return withCustomNetworksStorageLock {
            guard synchronizeDefaults(defaults) else { return .unavailable }
            let records: [EthereumNetworkFromDapp]
            switch customNetworksArchive(in: defaults) {
            case .missing:
                return .loaded(.empty)
            case .decoded(let decodedRecords):
                records = decodedRecords
            case .corrupt:
                return .corrupt
            }
            return .loaded(CustomNetworkSnapshot(records: records) { chainId in
                defaults.string(forKey: customEthereumNetworkNodeKey(chainId: chainId))
            })
        }
    }

    static func customEthereumNetworkNodeKey(chainId: Int) -> String {
        return customEthereumNetworkNodeKeyPrefix + String(chainId)
    }

    private enum CustomNetworksArchive {
        case missing
        case decoded([EthereumNetworkFromDapp])
        case corrupt
    }

    private static func customNetworksArchive(in defaults: UserDefaults) -> CustomNetworksArchive {
        guard let storedValue = defaults.object(forKey: customEthereumNetworksKey) else {
            return .missing
        }
        guard let data = storedValue as? Data else {
            return .corrupt
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [Any] else {
            return .corrupt
        }
        let decoder = JSONDecoder()
        let records = values.compactMap { value -> EthereumNetworkFromDapp? in
            guard JSONSerialization.isValidJSONObject(value),
                  let recordData = try? JSONSerialization.data(withJSONObject: value),
                  let record = try? decoder.decode(
                      EthereumNetworkFromDapp.self,
                      from: recordData
                  ),
                  let chainId = Int(hexString: record.chainId),
                  chainId > 0,
                  CustomNetworkDefinition.storedRPCURL(
                      for: record,
                      legacyOverride: defaults.string(
                          forKey: customEthereumNetworkNodeKey(chainId: chainId)
                      )
                  ) != nil else {
                return nil
            }
            return record
        }
        return .decoded(records)
    }

    private static func restore(
        _ value: Any?,
        forKey key: String,
        in defaults: UserDefaults
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func withCustomNetworksStorageLock<T>(_ body: () -> T) -> T {
        customNetworksStorageLock.lock()
        defer { customNetworksStorageLock.unlock() }
        return body()
    }
    
}

enum CustomNetworkSnapshotLoadResult {
    case loaded(CustomNetworkSnapshot)
    case unavailable
    case corrupt
}

struct CustomNetworkSnapshot {

    struct Entry {
        let resolvedNetwork: ResolvedEthereumNetwork
        let definition: EthereumNetworkFromDapp

        var chainId: Int {
            return resolvedNetwork.network.chainId
        }

        var rpcURL: URL {
            return resolvedNetwork.rpcURL
        }
    }

    static let empty = CustomNetworkSnapshot(orderedEntries: [], entriesByChainId: [:])

    let orderedEntries: [Entry]
    let entriesByChainId: [Int: Entry]

    init(
        records: [EthereumNetworkFromDapp],
        nodeURLForChainId: (Int) -> String? = { _ in nil }
    ) {
        var lastRecordByChainId: [
            Int: (index: Int, record: EthereumNetworkFromDapp, rpcURL: URL)
        ] = [:]
        for (index, record) in records.enumerated() {
            guard let chainId = Int(hexString: record.chainId),
                  chainId > 0,
                  let rpcURL = CustomNetworkDefinition.storedRPCURL(
                      for: record,
                      legacyOverride: nodeURLForChainId(chainId)
                  ) else { continue }
            lastRecordByChainId[chainId] = (index, record, rpcURL)
        }

        let deduplicated = lastRecordByChainId.map { chainId, value in
            return (
                chainId: chainId,
                index: value.index,
                record: value.record,
                rpcURL: value.rpcURL
            )
        }.sorted { $0.index < $1.index }
        var orderedEntries: [Entry] = []
        var entriesByChainId: [Int: Entry] = [:]

        for value in deduplicated {
            let record = value.record
            let chainId = value.chainId
            let rpcURL = value.rpcURL

            let network = EthereumNetwork(chainId: chainId,
                                          name: record.chainName,
                                          symbol: record.nativeCurrency.symbol,
                                          rpcEndpoint: .unauthenticated(rpcURL),
                                          isTestnet: false,
                                          mightShowPrice: false,
                                          explorer: nil)
            let resolvedNetwork = ResolvedEthereumNetwork(network: network,
                                                          source: .custom)
            let entry = Entry(
                resolvedNetwork: resolvedNetwork,
                definition: record
            )
            orderedEntries.append(entry)
            entriesByChainId[chainId] = entry
        }

        self.init(orderedEntries: orderedEntries, entriesByChainId: entriesByChainId)
    }

    private init(orderedEntries: [Entry], entriesByChainId: [Int: Entry]) {
        self.orderedEntries = orderedEntries
        self.entriesByChainId = entriesByChainId
    }

}

final class CustomNetworkCache {

    static let shared = CustomNetworkCache(
        loader: { SharedDefaults.loadCustomNetworkSnapshot() },
        observesDarwinChanges: true
    )

    private let lock = NSLock()
    private let loader: () -> CustomNetworkSnapshotLoadResult
    private var cachedSnapshot: CustomNetworkSnapshot?
    private var needsReload = true
    private var changeObserver: DarwinNotificationObserver?

    init(loader: @escaping () -> CustomNetworkSnapshotLoadResult,
         observesDarwinChanges: Bool = false) {
        self.loader = loader
        self.changeObserver = nil

        if observesDarwinChanges {
            self.changeObserver = DarwinNotificationObserver(
                name: CustomNetworkChangeNotification.name
            ) { [weak self] in
                self?.invalidate()
            }
        }
    }

    func snapshot() -> CustomNetworkSnapshot {
        lock.lock()
        defer { lock.unlock() }

        if !needsReload, let cachedSnapshot {
            return cachedSnapshot
        }

        switch loader() {
        case .loaded(let loadedSnapshot):
            cachedSnapshot = loadedSnapshot
            needsReload = false
        case .unavailable:
            break
        case .corrupt:
            cachedSnapshot = .empty
            needsReload = false
        }
        return cachedSnapshot ?? .empty
    }

    func invalidate() {
        lock.lock()
        needsReload = true
        lock.unlock()
    }

}

enum CustomNetworkChangeNotification {

    static let identifier = "org.lil.wallet.customEthereumNetworksDidChange.v1"
    static let name = CFNotificationName(rawValue: identifier as CFString)

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

}

private final class DarwinNotificationObserver {

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
                let notificationObserver = Unmanaged<DarwinNotificationObserver>
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

#if os(macOS) && DEBUG
enum AmbientPseudoLocalizationLaunchMode: String {

    case long
    case rtl

    static let environmentKey = "BIG_WALLET_AMBIENT_PSEUDO_LOCALIZATION"

    private static let dockAppBundleIdentifier = "org.lil.wallet"
    private static let markerMaxAge: TimeInterval = 24 * 60 * 60
    private static let modeKey = "ambientPseudoLocalizationLaunchMode.mode"
    private static let ownerProcessIdKey = "ambientPseudoLocalizationLaunchMode.ownerProcessId"
    private static let updatedAtKey = "ambientPseudoLocalizationLaunchMode.updatedAt"

    init?(environmentValue: String?) {
        guard let value = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let mode = Self(rawValue: value) else {
            return nil
        }
        self = mode
    }

    var launchArguments: [String] {
        switch self {
        case .long:
            return ["-NSDoubleLocalizedStrings", "YES"]
        case .rtl:
            return ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"]
        }
    }

    static func recordFromEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      ownerProcessId: pid_t = ProcessInfo.processInfo.processIdentifier,
                                      date: Date = Date(),
                                      defaults: UserDefaults? = SharedDefaults.defaults) {
        guard let defaults else { return }
        guard let mode = Self(environmentValue: environment[environmentKey]) else {
            clear(defaults: defaults)
            return
        }

        defaults.set(mode.rawValue, forKey: modeKey)
        defaults.set(Int(ownerProcessId), forKey: ownerProcessIdKey)
        defaults.set(date, forKey: updatedAtKey)
        defaults.synchronize()
    }

    static func ambientLaunchArguments(date: Date = Date(),
                                       defaults: UserDefaults? = SharedDefaults.defaults,
                                       isDockAppRunning: (pid_t) -> Bool = Self.isDockAppRunning(processId:)) -> [String] {
        guard let defaults,
              let modeValue = defaults.string(forKey: modeKey),
              let mode = Self(rawValue: modeValue),
              let processIdValue = defaults.object(forKey: ownerProcessIdKey) as? Int,
              let updatedAt = defaults.object(forKey: updatedAtKey) as? Date,
              processIdValue > 0 else {
            clear(defaults: defaults)
            return []
        }

        let processId = pid_t(processIdValue)
        guard date.timeIntervalSince(updatedAt) <= markerMaxAge,
              isDockAppRunning(processId) else {
            clear(defaults: defaults)
            return []
        }

        return mode.launchArguments
    }

    static func clear(defaults: UserDefaults? = SharedDefaults.defaults) {
        guard let defaults else { return }
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: ownerProcessIdKey)
        defaults.removeObject(forKey: updatedAtKey)
        defaults.synchronize()
    }

    private static func isDockAppRunning(processId: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processId) else { return false }
        return !app.isTerminated && app.bundleIdentifier == dockAppBundleIdentifier
    }

}
#endif
