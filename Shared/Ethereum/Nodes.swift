// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

struct Nodes {
    
    private static let infuraKey: String = {
        if let latest = ExtensionBridge.defaultInfuraKeys?.first, !latest.isEmpty {
            return latest
        } else if let path = Bundle.main.path(forResource: "shared", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject],
           let infuraKey = dict["InfuraKey"] as? String, !infuraKey.isEmpty {
            return infuraKey
        } else {
            return "" // TODO: return nil instead
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
