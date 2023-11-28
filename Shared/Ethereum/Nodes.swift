// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Nodes {
    
    private static let infuraKey: String? = {
        if let latest = ExtensionBridge.defaultInfuraKeys?.first, !latest.isEmpty {
            return latest
        } else if let infuraKey = Secrets.infuraKey {
            return infuraKey
        } else {
            return nil
        }
    }()
    
    static func getNode(chainId: Int) -> String? {
        let https = "https://"
        if let infura = BundledNodes.infura[chainId], let infuraKey = infuraKey {
            return https + infura + ".infura.io/v3/" + infuraKey
        } else if let domain = BundledNodes.dict[chainId] {
            return https + domain
        } else {
            return nil
        }
    }
    
}
