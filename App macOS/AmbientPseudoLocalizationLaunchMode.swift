import WalletDomain
import WalletAuthority
import WalletNetworking
import AppKit

#if DEBUG
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

    private var processDefaults: [String: Any] {
        switch self {
        case .long:
            return ["NSDoubleLocalizedStrings": true]
        case .rtl:
            return [
                "AppleTextDirection": true,
                "NSForceRightToLeftWritingDirection": true,
            ]
        }
    }

    static func recordFromEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment,
                                      ownerProcessId: pid_t = ProcessInfo.processInfo.processIdentifier,
                                      date: Date = Date(),
                                      defaults: UserDefaults? = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet")) {
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

    @discardableResult
    static func applyToAmbientProcess(
        date: Date = Date(),
        defaults: UserDefaults? = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet"),
        processDefaults: UserDefaults = .standard,
        argumentDomainName: String = UserDefaults.argumentDomain,
        isDockAppRunning: (pid_t) -> Bool = Self.isDockAppRunning(processId:)
    ) -> Self? {
        guard let defaults,
              let modeValue = defaults.string(forKey: modeKey),
              let mode = Self(rawValue: modeValue),
              let processIdValue = defaults.object(forKey: ownerProcessIdKey) as? Int,
              let updatedAt = defaults.object(forKey: updatedAtKey) as? Date,
              processIdValue > 0 else {
            clear(defaults: defaults)
            return nil
        }

        let processId = pid_t(processIdValue)
        let markerAge = date.timeIntervalSince(updatedAt)
        guard markerAge >= 0,
              markerAge <= markerMaxAge,
              isDockAppRunning(processId) else {
            clear(defaults: defaults)
            return nil
        }

        var argumentDomain = processDefaults.volatileDomain(
            forName: argumentDomainName
        )
        mode.processDefaults.forEach { argumentDomain[$0.key] = $0.value }
        processDefaults.setVolatileDomain(
            argumentDomain,
            forName: argumentDomainName
        )
        return mode
    }

    static func clear(defaults: UserDefaults? = UserDefaults(suiteName: "8DXC3N7E7P.group.org.lil.wallet")) {
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
