// ∅ 2026 lil org

struct Nodes {
    
    static func knowsNode(chainId: Int) -> Bool {
        return getNode(chainId: chainId) != nil
    }
    
    static func getNode(chainId: Int) -> String? {
        let https = "https://"
        if let domain = BundledNodes.dict[chainId] {
            return https + domain
        } else if let custom = SharedDefaults.getCustomNetworkNode(chainId: chainId) {
            return custom
        } else {
            return nil
        }
    }
    
}
