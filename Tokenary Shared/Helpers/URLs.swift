// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

// ToDo: Make this a collection & unify interface
extension URL {
    static let twitter = URL(string: "https://tokenary.io/twitter")!
    static let github = URL(string: "https://tokenary.io/github")!
    static let email = URL(string: "mailto:support@tokenary.io")!
    static let iosSafariGuide = URL(string: "https://tokenary.io/guide-ios")!
    static let appStore = URL(string: "https://tokenary.io/get")!
    
    static func etherscan(address: String) -> URL {
        return URL(string: "https://etherscan.io/address/\(address)")!
    }
    
    static func solanascan(address: String) -> URL {
        return URL(string: "https://explorer.solana.com/address/\(address)")!
    }

    static func tezosscan(address: String) -> URL {
        return URL(string: "https://tzkt.io/\(address)/operations")!
    }
    
    static func blankRedirect(id: Int) -> URL {
        return URL(string: "https://tokenary.io/blank/\(id)")!
    }
}
