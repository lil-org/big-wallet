// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

public struct Constants {
    // MARK: - Public Properties

    public static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    public static var keychainGroup: String {
        #if DEBUG
        return Bundle.main.infoDictionary?["KEYCHAIN_ENTITLEMENT"] as? String ?? .empty
        #else
        return "" // ToDo(@petrrk) - Add entitlement parser
        #endif
    }

    public static var appGroupID: String {
        #if DEBUG
        return Bundle.main.infoDictionary?["APP_GROUP_ENTITLEMENT"] as? String ?? .empty
        #else
        return "" // ToDo(@petrrk) - Add entitlement parser
        #endif
    }
    
    public static var identifier: String {
        Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? .empty
    }
    
    public static var name: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? .empty
    }
    
    public static var shortVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? .empty
    }

    // MARK: - Schemes

    public static let tokenarySchemePrefix = "tokenary://"
    
    public static let contactsPhoneSchemeTemplate = "tel://%@"
    public static let tokenarySchemeTemplate = "tokenary://%@"

    // MARK: - Global Links
    
    public enum Links {
        public static let tokenarySiteURL = "https://tokenary.io"
        public static let rateAppstore = "https://itunes.apple.com/"
    }
}
