// Copyright © 2021 Encrypted Ink. All rights reserved.

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
    
    static var storedSessions: [String: SessionStorage.Item] {
        get {
            return userDefaults.codableValue(type: [String: SessionStorage.Item].self, forKey: "storedSessions") ?? [:]
        }
        set {
            userDefaults.setCodable(newValue, forKey: "storedSessions")
        }
    }
    
    static var latestInteractionDates: [String: Date] {
        get {
            return userDefaults.codableValue(type: [String: Date].self, forKey: "latestInteractionDates") ?? [:]
        }
        set {
            userDefaults.setCodable(newValue, forKey: "latestInteractionDates")
        }
    }
    
}
