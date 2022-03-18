// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

// ToDo: Make this a collection & unify interface
struct Defaults {
    struct Key<ReturnType> {
        var name: String
    }
 
    private static let userDefaults = UserDefaults.standard

    static var latestReviewRequestDate: Date? {
        get {
            return userDefaults.value(forKey: "latestReviewRequestDate") as? Date
        }
        set {
            userDefaults.set(newValue, forKey: "latestReviewRequestDate")
        }
    }
    
    static var shouldPromptSafariForLegacyUsers: Bool {
        get {
            return userDefaults.bool(forKey: "shouldPromptSafariForLegacyUsers")
        }
        set {
            userDefaults.set(newValue, forKey: "shouldPromptSafariForLegacyUsers")
        }
    }
    
    static var didMigrateKeychainFromTokenaryV1: Bool {
        get {
            return userDefaults.bool(forKey: "didMigrateKeychainFromTokenaryV1")
        }
        set {
            userDefaults.set(newValue, forKey: "didMigrateKeychainFromTokenaryV1")
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
    
    static subscript(integerKey: Key<Int>) -> Int {
        get {
            return userDefaults.integer(forKey: integerKey.name)
        }
        set {
            userDefaults.set(newValue, forKey: integerKey.name)
        }
    }
}

extension Defaults.Key {
    static var numberOfCreatedWallets: (SupportedChainType) -> Defaults.Key<Int> {
        return { (chainType: SupportedChainType) in
            return .init(name: "numberOfCreatedWallets_" + chainType.ticker )
        }
    }
}
