// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct NodesService {
    
    static func getNode(chainId: Int) -> String? {
        if let domain = Nodes.standard[chainId] {
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
