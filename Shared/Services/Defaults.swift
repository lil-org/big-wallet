// ∅ 2026 lil org

import Foundation

struct Defaults {
 
    private static let userDefaults = UserDefaults.standard

    private enum Keys {
        static let walletsAndAccountsNames = "walletsAndAccountsNames"
        static let latestReviewRequestDate = "latestReviewRequestDate"
        static let reviewRequestsGoodMomentsCount = "reviewRequestsGoodMomentsCount"
        static let isHiddenFromMenuBar = "isHiddenFromMenuBar"
    }

    static var walletsAndAccountsNames: [String: String]? {
        get {
            userDefaults.object(forKey: Keys.walletsAndAccountsNames) as? [String: String]
        }
        set {
            userDefaults.set(newValue, forKey: Keys.walletsAndAccountsNames)
        }
    }
    
    static var latestReviewRequestDate: Date? {
        get {
            userDefaults.object(forKey: Keys.latestReviewRequestDate) as? Date
        }
        set {
            userDefaults.set(newValue, forKey: Keys.latestReviewRequestDate)
        }
    }
    
    static var reviewRequestsGoodMomentsCount: Int {
        get {
            userDefaults.integer(forKey: Keys.reviewRequestsGoodMomentsCount)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.reviewRequestsGoodMomentsCount)
        }
    }
    
    static var isHiddenFromMenuBar: Bool {
        get {
            userDefaults.bool(forKey: Keys.isHiddenFromMenuBar)
        }
        set {
            userDefaults.set(newValue, forKey: Keys.isHiddenFromMenuBar)
        }
    }
    
}
