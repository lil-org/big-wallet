// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Nodes {
    
    private static let infuraKey: String = {
        if let path = Bundle.main.path(forResource: "shared", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject],
           let infuraKey = dict["InfuraKey"] as? String {
            return infuraKey
        } else {
            // TODO: get from CloudKit
            // TODO: hande infura key not being bundled
            return ""
        }
    }()
    
    static func getNode(chainId: Int) -> String? {
        if let domain = BundledNodes.dict[chainId] {
            let https = "https://" + domain
            if domain.hasSuffix(".infura.io/v3/") {
                return https + infuraKey
            } else {
                return https
            }
        } else {
            return nil
        }
    }
    
}
