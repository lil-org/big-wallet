import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Foundation

@MainActor
struct Nodes {

    static func resolution(chainId: Int) -> EthereumNetworkResolution {
        return ApplicationServices.shared.networks.resolve(chainId: chainId)
    }

    static func knowsNode(chainId: Int) -> Bool {
        return url(chainId: chainId) != nil
    }

    static func url(chainId: Int) -> URL? {
        return ApplicationServices.shared.networks.rpcURL(chainId: chainId)
    }

}
