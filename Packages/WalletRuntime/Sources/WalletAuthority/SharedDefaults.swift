import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import CoreFoundation
import Foundation
import Synchronization

protocol SharedPreferenceStorage: AnyObject, Sendable {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    @discardableResult func synchronize() -> Bool
}

// UserDefaults documents concurrent access; arbitrary storage conformers must provide their own Sendable implementation.
final class UserDefaultsPreferenceStorage: SharedPreferenceStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    private init(_ defaults: UserDefaults) { self.defaults = defaults }

    init?(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
    }

    static let standard = UserDefaultsPreferenceStorage(.standard)

    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
    @discardableResult func synchronize() -> Bool { defaults.synchronize() }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func removePersistentDomain(forName name: String) { defaults.removePersistentDomain(forName: name) }
    func setPersistentDomain(_ domain: [String: Any], forName name: String) { defaults.setPersistentDomain(domain, forName: name) }
    func persistentDomain(forName name: String) -> [String: Any]? { defaults.persistentDomain(forName: name) }
    func dictionaryRepresentation() -> [String: Any] { defaults.dictionaryRepresentation() }
}

struct SharedDefaults {
    
#if os(macOS)
    static let suiteName = "8DXC3N7E7P.group.org.lil.wallet"
#else
    static let suiteName = "group.org.lil.wallet"
#endif
    static var defaults: (any SharedPreferenceStorage)? {
        return UserDefaultsPreferenceStorage(suiteName: suiteName)
    }

    static var containerURL: URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }
    
    static let customEthereumNetworksKey = "customEthereumNetworks"
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"
    private static let customNetworksStorageLock = Mutex(())
    private static let customNetworksStorageFileLock = CrossProcessFileLock(
        fileURL: containerURL?.appendingPathComponent(
            ".custom-ethereum-networks.lock",
            isDirectory: false
        ),
        directoryBoundary: containerURL
    )
    private static let customNetworksStorageLockTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let customNetworksStorageLockPollNanoseconds: UInt64 = 10_000_000

    static func synchronize() {
        defaults?.synchronize()
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

    static func insertNetwork(
        _ network: EthereumNetworkFromDapp,
        to defaults: any SharedPreferenceStorage
    ) -> CustomNetworkInsertionResult {
        return insertNetwork(network, to: defaults, crossProcessLock: nil)
    }

    static func insertNetwork(
        _ network: EthereumNetworkFromDapp,
        to defaults: any SharedPreferenceStorage,
        crossProcessLock: CrossProcessFileLock?,
        synchronizeDefaults: (any SharedPreferenceStorage) -> Bool = { $0.synchronize() }
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

    static func loadCustomNetworkSnapshotResult(
        from defaults: any SharedPreferenceStorage,
        synchronizeDefaults: (any SharedPreferenceStorage) -> Bool = { $0.synchronize() }
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

    private static func customNetworksArchive(in defaults: any SharedPreferenceStorage) -> CustomNetworksArchive {
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
        in defaults: any SharedPreferenceStorage
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func withCustomNetworksStorageLock<T>(_ body: () -> T) -> T {
        customNetworksStorageLock.withLock { _ in body() }
    }
    
}

final class CustomNetworkCache: Sendable {
    static let shared = CustomNetworkCache(
        loader: { SharedDefaults.loadCustomNetworkSnapshot() },
        observesDarwinChanges: true
    )

    private struct State {
        var cachedSnapshot: CustomNetworkSnapshot?
        var needsReload = true
        var changeObserver: DarwinNotificationObserver?
    }

    private let state = Mutex(State())
    private let loader: @Sendable () -> CustomNetworkSnapshotLoadResult

    init(loader: @escaping @Sendable () -> CustomNetworkSnapshotLoadResult,
         observesDarwinChanges: Bool = false) {
        self.loader = loader
        if observesDarwinChanges {
            let observer = DarwinNotificationObserver(
                name: CustomNetworkChangeNotification.name
            ) { [weak self] in
                self?.invalidate()
            }
            state.withLock { $0.changeObserver = observer }
        }
    }

    func snapshot() -> CustomNetworkSnapshot {
        state.withLock { state in
            if !state.needsReload, let cachedSnapshot = state.cachedSnapshot {
                return cachedSnapshot
            }
            switch loader() {
            case .loaded(let loadedSnapshot):
                state.cachedSnapshot = loadedSnapshot
                state.needsReload = false
            case .unavailable:
                break
            case .corrupt:
                state.cachedSnapshot = .empty
                state.needsReload = false
            }
            return state.cachedSnapshot ?? .empty
        }
    }

    func refreshSnapshot() -> CustomNetworkSnapshotLoadResult {
        state.withLock { state in
            let result = loader()
            switch result {
            case .loaded(let snapshot):
                state.cachedSnapshot = snapshot
                state.needsReload = false
            case .unavailable:
                state.needsReload = true
            case .corrupt:
                state.cachedSnapshot = .empty
                state.needsReload = false
            }
            return result
        }
    }

    func invalidate() {
        state.withLock { $0.needsReload = true }
    }
}

enum CustomNetworkChangeNotification {

    static let identifier = "org.lil.wallet.customEthereumNetworksDidChange.v1"
    static var name: CFNotificationName { CFNotificationName(rawValue: identifier as CFString) }

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

private final class DarwinNotificationObserver: Sendable {

    private let identifier: String
    private var name: CFNotificationName { CFNotificationName(rawValue: identifier as CFString) }
    private let callback: @Sendable () -> Void

    init(name: CFNotificationName, callback: @escaping @Sendable () -> Void) {
        identifier = name.rawValue as String
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

