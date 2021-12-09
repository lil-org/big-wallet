// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension URL {
    
    static let twitter = URL(string: "https://tokenary.io/twitter")!
    static let github = URL(string: "https://tokenary.io/github")!
    static let email = URL(string: "mailto:support@tokenary.io")!
    static func etherscan(address: String) -> URL {
        return URL(string: "https://etherscan.io/address/\(address)")!
    }
    
}
