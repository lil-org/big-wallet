// ∅ 2025 lil org

import Foundation

struct Defaults {
 
    private static let userDefaults = UserDefaults.standard

    static var walletsAndAccountsNames: [String: String]? {
        get {
            return userDefaults.value(forKey: "walletsAndAccountsNames") as? [String: String]
        }
        set {
            userDefaults.set(newValue, forKey: "walletsAndAccountsNames")
        }
    }
    
    static var latestReviewRequestDate: Date? {
        get {
            return userDefaults.value(forKey: "latestReviewRequestDate") as? Date
        }
        set {
            userDefaults.set(newValue, forKey: "latestReviewRequestDate")
        }
    }
    
    static var reviewRequestsGoodMomentsCount: Int {
        get {
            return userDefaults.integer(forKey: "reviewRequestsGoodMomentsCount")
        }
        set {
            userDefaults.set(newValue, forKey: "reviewRequestsGoodMomentsCount")
        }
    }
    
    static var isHiddenFromMenuBar: Bool {
        get {
            return userDefaults.bool(forKey: "isHiddenFromMenuBar")
        }
        set {
            userDefaults.set(newValue, forKey: "isHiddenFromMenuBar")
        }
    }
    
}
