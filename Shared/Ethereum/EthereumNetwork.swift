// ∅ 2024 lil org

import Foundation

struct EthereumNetwork: Codable, Equatable, Hashable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let nodeURLString: String
    let isTestnet: Bool
    let mightShowPrice: Bool
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    var chainIdHexString: String { String.hex(chainId, withPrefix: true) }
    var isEthMainnet: Bool { return chainId == EthereumNetwork.ethMainnetChainId }
    
    static let ethMainnetChainId = 1
    
}
