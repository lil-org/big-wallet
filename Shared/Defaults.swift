// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct Defaults {
 
    private static let userDefaults = UserDefaults.standard

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
    
    static var didReceiveShouldUpdateAppNotification: Bool {
        get {
            return userDefaults.bool(forKey: "didReceiveShouldUpdateAppNotification")
        }
        set {
            userDefaults.set(newValue, forKey: "didReceiveShouldUpdateAppNotification")
        }
    }
    
}
