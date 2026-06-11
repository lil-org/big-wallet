// ∅ 2026 lil org

import Foundation

struct Defaults {

#if os(macOS)
    private static let dockAppDefaultsDomain = "org.lil.wallet"
#endif

    private enum Keys {
        static let walletsAndAccountsNames = "walletsAndAccountsNames"
        static let latestReviewRequestDate = "latestReviewRequestDate"
        static let reviewRequestsGoodMomentsCount = "reviewRequestsGoodMomentsCount"
        static let didMigrateLegacyDefaults = "didMigrateLegacyDefaults"
    }

    private static let userDefaults: UserDefaults = {
        guard let sharedDefaults = SharedDefaults.defaults else {
            return .standard
        }
        migrateLegacyDefaultsIfNeeded(to: sharedDefaults)
        return sharedDefaults
    }()

    static func synchronize() {
        userDefaults.synchronize()
    }

    private static func migrateLegacyDefaultsIfNeeded(to sharedDefaults: UserDefaults) {
        sharedDefaults.synchronize()
        guard !sharedDefaults.bool(forKey: Keys.didMigrateLegacyDefaults) else { return }

        let didReadNames = migrateWalletNames(to: sharedDefaults)
        let didReadReviewDate = migrateReviewRequestDate(to: sharedDefaults)
        let didReadReviewCount = migrateReviewRequestsCount(to: sharedDefaults)
        if didReadNames || didReadReviewDate || didReadReviewCount {
            sharedDefaults.set(true, forKey: Keys.didMigrateLegacyDefaults)
        }
        sharedDefaults.synchronize()
    }

    private static func migrateWalletNames(to sharedDefaults: UserDefaults) -> Bool {
        guard let legacyNames = legacyStringDictionary(forKey: Keys.walletsAndAccountsNames) else { return false }
        guard !legacyNames.isEmpty else { return true }

        let sharedNames = sharedDefaults.object(forKey: Keys.walletsAndAccountsNames) as? [String: String] ?? [:]
        let mergedNames = legacyNames.merging(sharedNames) { _, sharedName in sharedName }
        if mergedNames != sharedNames {
            sharedDefaults.set(mergedNames, forKey: Keys.walletsAndAccountsNames)
        }
        return true
    }

    private static func migrateReviewRequestDate(to sharedDefaults: UserDefaults) -> Bool {
        guard let legacyDate = legacyDate(forKey: Keys.latestReviewRequestDate) else { return false }
        if let sharedDate = sharedDefaults.object(forKey: Keys.latestReviewRequestDate) as? Date,
           sharedDate >= legacyDate {
            return true
        }
        sharedDefaults.set(legacyDate, forKey: Keys.latestReviewRequestDate)
        return true
    }

    private static func migrateReviewRequestsCount(to sharedDefaults: UserDefaults) -> Bool {
        guard let legacyCount = legacyInteger(forKey: Keys.reviewRequestsGoodMomentsCount) else { return false }
        let sharedObject = sharedDefaults.object(forKey: Keys.reviewRequestsGoodMomentsCount)
        if sharedObject != nil, sharedDefaults.integer(forKey: Keys.reviewRequestsGoodMomentsCount) >= legacyCount {
            return true
        }
        sharedDefaults.set(legacyCount, forKey: Keys.reviewRequestsGoodMomentsCount)
        return true
    }

    private static func legacyStringDictionary(forKey key: String) -> [String: String]? {
        let object = legacyObject(forKey: key)
        if let dictionary = object as? [String: String] {
            return dictionary
        }
        if let dictionary = object as? NSDictionary {
            var strings = [String: String]()
            for (key, value) in dictionary {
                guard let key = key as? String, let value = value as? String else { continue }
                strings[key] = value
            }
            return strings
        }
        return nil
    }

    private static func legacyDate(forKey key: String) -> Date? {
        let object = legacyObject(forKey: key)
        if let date = object as? Date {
            return date
        }
        if let date = object as? NSDate {
            return date as Date
        }
        return nil
    }

    private static func legacyInteger(forKey key: String) -> Int? {
        let object = legacyObject(forKey: key)
        if let count = object as? Int {
            return count
        }
        if let count = object as? NSNumber {
            return count.intValue
        }
        return nil
    }

    private static func legacyObject(forKey key: String) -> Any? {
#if os(macOS)
        let standardDefaults = UserDefaults.standard
        standardDefaults.synchronize()
        if let value = standardDefaults.persistentDomain(forName: dockAppDefaultsDomain)?[key] {
            return value
        }
        if Bundle.main.bundleIdentifier == dockAppDefaultsDomain,
           let value = standardDefaults.object(forKey: key) {
            return value
        }
        if let dockAppDefaults = UserDefaults(suiteName: dockAppDefaultsDomain) {
            dockAppDefaults.synchronize()
            return dockAppDefaults.object(forKey: key)
        }
        return nil
#else
        return UserDefaults.standard.object(forKey: key)
#endif
    }

    static var walletsAndAccountsNames: [String: String]? {
        get {
            userDefaults.object(forKey: Keys.walletsAndAccountsNames) as? [String: String]
        }
        set {
            userDefaults.set(newValue, forKey: Keys.walletsAndAccountsNames)
            synchronize()
        }
    }
    
    static var latestReviewRequestDate: Date? {
        get {
            userDefaults.object(forKey: Keys.latestReviewRequestDate) as? Date
        }
        set {
            userDefaults.set(newValue, forKey: Keys.latestReviewRequestDate)
            synchronize()
        }
    }
    
}
