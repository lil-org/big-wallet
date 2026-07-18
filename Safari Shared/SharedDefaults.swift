// ∅ 2026 lil org

import CoreFoundation
import Foundation
#if os(macOS) && DEBUG
import AppKit
#endif

struct SharedDefaults {
    
#if os(macOS)
    static let suiteName = "8DXC3N7E7P.group.org.lil.wallet"
#else
    static let suiteName = "group.org.lil.wallet"
#endif
    static let defaults = UserDefaults(suiteName: suiteName)
    
    static let customEthereumNetworksKey = "customEthereumNetworks"
    static let corruptCustomEthereumNetworksKeyPrefix = "customEthereumNetworks.quarantine.v1."
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"
    private static let customNetworksStorageLock = NSLock()

    static func synchronize() {
        defaults?.synchronize()
    }
    
    @discardableResult
    static func addNetwork(_ network: EthereumNetworkFromDapp) -> Bool {
        guard let defaults else { return false }
        let didCommit = addNetwork(network, to: defaults)
        guard didCommit else { return false }

        CustomNetworkCache.shared.invalidate()
        CustomNetworkChangeNotification.post()
        return true
    }

    @discardableResult
    static func addNetwork(_ network: EthereumNetworkFromDapp,
                           to defaults: UserDefaults) -> Bool {
        guard let chainId = Int(hexString: network.chainId),
              chainId > 0,
              let rpcURL = network.defaultRpcURL else {
            return false
        }

        return withCustomNetworksStorageLock {
            defaults.synchronize()

            let storedNetworks: [EthereumNetworkFromDapp]
            let corruptArchiveToQuarantine: Any?
            switch customNetworksArchive(in: defaults) {
            case .missing:
                storedNetworks = []
                corruptArchiveToQuarantine = nil
            case .decoded(let networks):
                storedNetworks = networks
                corruptArchiveToQuarantine = nil
            case .corrupt(let recoveredNetworks, let originalValue):
                storedNetworks = recoveredNetworks
                corruptArchiveToQuarantine = originalValue
            }

            guard let encoded = try? JSONEncoder().encode(storedNetworks + [network]) else {
                return false
            }

            if let corruptArchiveToQuarantine,
               !quarantineCorruptCustomNetworksArchive(
                   corruptArchiveToQuarantine,
                   in: defaults
               ) {
                return false
            }
            defaults.set(rpcURL.absoluteString, forKey: customEthereumNetworkNodeKey(chainId: chainId))
            defaults.set(encoded, forKey: customEthereumNetworksKey)
            defaults.synchronize()
            return true
        }
    }

    static func loadCustomNetworkSnapshot() -> CustomNetworkSnapshot {
        guard let defaults else { return .empty }
        return loadCustomNetworkSnapshot(from: defaults)
    }

    static func loadCustomNetworkSnapshot(from defaults: UserDefaults) -> CustomNetworkSnapshot {
        return withCustomNetworksStorageLock {
            defaults.synchronize()
            let records: [EthereumNetworkFromDapp]
            switch customNetworksArchive(in: defaults) {
            case .missing:
                return .empty
            case .decoded(let decodedRecords):
                records = decodedRecords
            case .corrupt(let recoveredRecords, _):
                records = recoveredRecords
            }
            return CustomNetworkSnapshot(records: records) { chainId in
                return defaults.string(forKey: customEthereumNetworkNodeKey(chainId: chainId))
            }
        }
    }

    static func customEthereumNetworkNodeKey(chainId: Int) -> String {
        return customEthereumNetworkNodeKeyPrefix + String(chainId)
    }

    private enum CustomNetworksArchive {
        case missing
        case decoded([EthereumNetworkFromDapp])
        case corrupt(recoveredNetworks: [EthereumNetworkFromDapp], originalValue: Any)
    }

    private static func customNetworksArchive(in defaults: UserDefaults) -> CustomNetworksArchive {
        guard let storedValue = defaults.object(forKey: customEthereumNetworksKey) else {
            return .missing
        }
        guard let data = storedValue as? Data else {
            return .corrupt(recoveredNetworks: [], originalValue: storedValue)
        }
        if let networks = try? JSONDecoder().decode([EthereumNetworkFromDapp].self, from: data) {
            return .decoded(networks)
        }
        return .corrupt(
            recoveredNetworks: recoverCustomNetworks(from: data),
            originalValue: data
        )
    }

    private static func recoverCustomNetworks(from data: Data) -> [EthereumNetworkFromDapp] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [Any] else {
            return []
        }

        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let recordData = try? JSONSerialization.data(withJSONObject: value),
                  let network = try? decoder.decode(EthereumNetworkFromDapp.self, from: recordData) else {
                return nil
            }
            return network
        }
    }

    private static func quarantineCorruptCustomNetworksArchive(_ value: Any,
                                                               in defaults: UserDefaults) -> Bool {
        let key = corruptCustomEthereumNetworksKeyPrefix + UUID().uuidString
        defaults.set(value, forKey: key)
        defaults.synchronize()
        return defaults.object(forKey: key) != nil
    }

    private static func withCustomNetworksStorageLock<T>(_ body: () -> T) -> T {
        customNetworksStorageLock.lock()
        defer { customNetworksStorageLock.unlock() }
        return body()
    }
    
}

struct CustomNetworkSnapshot {

    struct Entry {
        let resolvedNetwork: ResolvedEthereumNetwork

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

    init(records: [EthereumNetworkFromDapp],
         nodeURLForChainId: (Int) -> String?) {
        var lastRecordByChainId: [Int: (index: Int, record: EthereumNetworkFromDapp)] = [:]
        for (index, record) in records.enumerated() {
            guard let chainId = Int(hexString: record.chainId), chainId > 0 else { continue }
            lastRecordByChainId[chainId] = (index, record)
        }

        let deduplicated = lastRecordByChainId.map { chainId, value in
            return (chainId: chainId, index: value.index, record: value.record)
        }.sorted { $0.index < $1.index }
        var orderedEntries: [Entry] = []
        var entriesByChainId: [Int: Entry] = [:]

        for value in deduplicated {
            let record = value.record
            let chainId = value.chainId

            let rpcURL: URL?
            if let storedNodeURL = nodeURLForChainId(chainId) {
                rpcURL = CustomEthereumRPC.url(from: storedNodeURL)
            } else {
                rpcURL = record.defaultRpcURL
            }
            guard let rpcURL else { continue }

            let network = EthereumNetwork(chainId: chainId,
                                          name: record.chainName,
                                          symbol: record.nativeCurrency.symbol,
                                          nodeURLString: rpcURL.absoluteString,
                                          isTestnet: false,
                                          mightShowPrice: false,
                                          explorer: nil)
            let resolvedNetwork = ResolvedEthereumNetwork(network: network,
                                                          rpcURL: rpcURL,
                                                          source: .custom)
            let entry = Entry(resolvedNetwork: resolvedNetwork)
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
    private let loader: () -> CustomNetworkSnapshot
    private var cachedSnapshot: CustomNetworkSnapshot?
    private var changeObserver: DarwinNotificationObserver?

    init(loader: @escaping () -> CustomNetworkSnapshot,
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

        if let cachedSnapshot {
            return cachedSnapshot
        }

        let loadedSnapshot = loader()
        cachedSnapshot = loadedSnapshot
        return loadedSnapshot
    }

    func invalidate() {
        lock.lock()
        cachedSnapshot = nil
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
