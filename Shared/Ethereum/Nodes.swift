// ∅ 2026 lil org

import Foundation

struct Nodes {

    static func resolution(chainId: Int) -> EthereumNetworkResolution {
        return NetworkResolver.main.resolve(chainId: chainId)
    }

    static func knowsNode(chainId: Int) -> Bool {
        return url(chainId: chainId) != nil
    }

    static func url(chainId: Int) -> URL? {
        return NetworkResolver.main.rpcURL(chainId: chainId)
    }

}
