// ∅ 2026 lil org

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
    
    private static let customEthereumNetworksKey = "customEthereumNetworks"
    private static let customEthereumNetworkNodeKeyPrefix = "customEthereumNetworkNode_"

    static func synchronize() {
        defaults?.synchronize()
    }
    
    static func addNetwork(_ network: EthereumNetworkFromDapp) {
        synchronize()
        guard let chainId = Int(hexString: network.chainId) else { return }
        let updated = getCustomNetworks() + [network]
        defaults?.setCodable(updated, forKey: customEthereumNetworksKey)
        let nodeKey = customEthereumNetworkNodeKeyPrefix + String(chainId)
        defaults?.set(network.defaultRpcUrl, forKey: nodeKey)
        synchronize()
    }
    
    static func getCustomNetworks() -> [EthereumNetworkFromDapp] {
        synchronize()
        return defaults?.codableValue(type: [EthereumNetworkFromDapp].self, forKey: customEthereumNetworksKey) ?? []
    }
    
    static func getCustomNetworkNode(chainId: Int) -> String? {
        synchronize()
        let key = customEthereumNetworkNodeKeyPrefix + String(chainId)
        return defaults?.string(forKey: key)
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
