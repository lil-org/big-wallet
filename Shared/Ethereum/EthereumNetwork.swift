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
    var supportsNativeBalance: Bool { return !Self.tempoChainIds.contains(chainId) }
    
    static let ethMainnetChainId = 1
    private static let tempoChainIds: Set<Int> = [
        4_217,
        31_318,
        42_429,
        42_431,
    ]
    
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
    
    var defaultRpcURL: URL? {
        return CustomEthereumRPC.preferredURL(in: rpcUrls)
    }

    var defaultRpcUrl: String {
        return defaultRpcURL?.absoluteString ?? ""
    }
    
}

enum CustomEthereumRPC {

    static func url(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    static func preferredURL(in values: [String]) -> URL? {
        var firstHTTPURL: URL?

        for value in values {
            guard let url = url(from: value) else { continue }
            if url.scheme?.lowercased() == "https" {
                return url
            }
            if firstHTTPURL == nil {
                firstHTTPURL = url
            }
        }

        return firstHTTPURL
    }

}
