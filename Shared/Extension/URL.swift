// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension URL {
    
    static let twitter = URL(string: "https://twitter.com/Balance_io")!
    static let github = URL(string: "https://github.com/balance-io")!
    static let email = URL(string: "mailto:support@tokenary.io")!
    static let iosSafariGuide = URL(string: "https://support.apple.com/en-gb/guide/iphone/iphab0432bf6/ios#iphb7bf168dc")!
    static let appStore = URL(string: "https://tokenary.io/get")!
    
    static func etherscan(address: String) -> URL {
        return URL(string: "https://etherscan.io/address/\(address)")!
    }
    
    static func blankRedirect(id: Int) -> URL {
        return URL(string: "https://www.balance.io/blank/?\(id)")!
    }
    
}
