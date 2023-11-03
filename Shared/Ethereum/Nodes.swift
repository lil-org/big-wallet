// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Nodes {
    
    private static var infuraKey = "" // TODO: get from CloudKit
    
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
