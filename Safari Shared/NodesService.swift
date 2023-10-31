// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct NodesService {
    
    static func getNode(chainId: Int) -> String? {
        if let domain = Nodes.standard[chainId] {
            return "https://" + domain
        } else {
            return nil
        }
    }
    
}
