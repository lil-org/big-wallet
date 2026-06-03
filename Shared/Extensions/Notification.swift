// ∅ 2026 lil org

import Foundation

extension Notification.Name {
    static let walletsChanged = Notification.Name("walletsChanged")
    static let walletStoreChanged = Notification.Name("walletStoreChanged")
    static let receievedWalletRequest = Notification.Name("receievedWalletRequest")
    static let ambientAgentMustTerminate = Notification.Name("org.lil.wallet.ambient.terminateOtherInstances")
}

enum AmbientAgentTerminationRequest {

    static let safariRequestUserInfoKey = "ambientAgent"

    private static let versionKey = "version"
    private static let buildKey = "build"
    private static let bundlePathKey = "bundlePath"
    private static let bundleIdentifierKey = "CFBundleIdentifier"
    private static let bundleShortVersionKey = "CFBundleShortVersionString"
    private static let bundleVersionKey = "CFBundleVersion"
    private static let userInfoKeys = [versionKey, buildKey, bundlePathKey]
    private static let unknownVersionValue = "0"

    static func notificationUserInfo(from userInfo: [String: String]) -> [AnyHashable: Any] {
        var notificationUserInfo = [AnyHashable: Any]()
        for (key, value) in userInfo {
            notificationUserInfo[AnyHashable(key)] = value
        }
        return notificationUserInfo
    }

    static func userInfo(for bundle: Bundle) -> [String: String] {
        let version = stringValue(for: bundleShortVersionKey, in: bundle) ?? unknownVersionValue
        let build = stringValue(for: bundleVersionKey, in: bundle) ?? unknownVersionValue
        return userInfo(version: version, build: build, bundleURL: bundle.bundleURL)
    }

    static func userInfo(forBundleAt bundleURL: URL) -> [String: String]? {
        return bundleInfo(forBundleAt: bundleURL)?.versionInfo
    }

    static func bundleInfo(forBundleAt bundleURL: URL) -> (identifier: String, versionInfo: [String: String])? {
        guard let infoDictionary = infoDictionary(forBundleAt: bundleURL),
              let identifier = stringValue(for: bundleIdentifierKey, in: infoDictionary) else {
            return nil
        }

        let version = stringValue(for: bundleShortVersionKey, in: infoDictionary) ?? unknownVersionValue
        let build = stringValue(for: bundleVersionKey, in: infoDictionary) ?? unknownVersionValue
        return (identifier, userInfo(version: version, build: build, bundleURL: bundleURL))
    }

    static func userInfo(in json: [String: Any]) -> [String: String]? {
        guard let payload = json[safariRequestUserInfoKey] as? [String: Any] else { return nil }
        return userInfo(valueForKey: { payload[$0] })
    }

    static func userInfo(in notificationUserInfo: [AnyHashable: Any]?) -> [String: String]? {
        guard let notificationUserInfo else { return nil }
        return userInfo(valueForKey: { notificationUserInfo[AnyHashable($0)] })
    }

    static func matches(_ userInfo: [String: String], versionInfo: [String: String]?) -> Bool {
        guard let versionInfo else { return false }
        return userInfoKeys.allSatisfy { userInfo[$0] == versionInfo[$0] }
    }

    static func isNewer(_ userInfo: [String: String], than versionInfo: [String: String]?) -> Bool {
        guard let comparison = buildComparison(userInfo, versionInfo) else { return false }

        return comparison == .orderedDescending
    }

    static func isSameBuild(_ userInfo: [String: String], as versionInfo: [String: String]?) -> Bool {
        guard let comparison = buildComparison(userInfo, versionInfo) else { return false }

        return comparison == .orderedSame
    }

    static func bundleURL(from userInfo: [String: String]) -> URL? {
        guard let bundlePath = userInfo[bundlePathKey], !bundlePath.isEmpty else { return nil }
        return URL(fileURLWithPath: bundlePath)
    }

    private static func stringValue(for key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) else { return nil }
        return String(describing: value)
    }

    private static func stringValue(for key: String, in infoDictionary: [String: Any]) -> String? {
        guard let value = infoDictionary[key] else { return nil }
        return String(describing: value)
    }

    private static func userInfo(valueForKey: (String) -> Any?) -> [String: String]? {
        var values = [String: String]()
        for key in userInfoKeys {
            guard let value = valueForKey(key) as? String else { return nil }
            values[key] = value
        }
        return values
    }

    private static func userInfo(version: String, build: String, bundleURL: URL) -> [String: String] {
        return [
            versionKey: version,
            buildKey: build,
            bundlePathKey: bundleURL.standardizedFileURL.path
        ]
    }

    private static func buildComparison(_ userInfo: [String: String], _ versionInfo: [String: String]?) -> ComparisonResult? {
        guard let versionInfo,
              let build = userInfo[buildKey],
              let otherBuild = versionInfo[buildKey] else {
            return nil
        }

        return build.compare(otherBuild, options: [.caseInsensitive, .numeric])
    }

    private static func infoDictionary(forBundleAt bundleURL: URL) -> [String: Any]? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let infoDictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return infoDictionary
    }

}
