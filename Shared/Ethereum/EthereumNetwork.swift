// ∅ 2026 lil org

import Foundation

struct EthereumNetwork: Codable, Equatable, Hashable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let nodeURLString: String
    let isTestnet: Bool
    let mightShowPrice: Bool
    let explorer: String?
    
    var symbolIsETH: Bool { return symbol == "ETH" }
    var chainIdHexString: String { String.hex(chainId, withPrefix: true) }
    var isEthMainnet: Bool { return chainId == EthereumNetwork.ethMainnetChainId }
    
    static let ethMainnetChainId = 1
    
}

struct EthereumNetworkFromDapp: Codable {
    var chainId: String
    var rpcUrls: [String]
    var blockExplorerUrls: [String]
    var nativeCurrency: Currency
    var chainName: String
    
    struct Currency: Codable {
        var decimals: Int
        var name: String
        var symbol: String
    }
    
    static func from(_ dict: [String: Any]?) -> EthereumNetworkFromDapp? {
        if let dict = dict,
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let network = try? JSONDecoder().decode(EthereumNetworkFromDapp.self, from: data) {
            return network
        } else {
            return nil
        }
    }
    
    var defaultRpcUrl: String {
        return rpcUrls.first(where: { $0.starts(with: "https") }) ?? rpcUrls.first ?? ""
    }
    
}
