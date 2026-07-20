// ∅ 2026 lil org

import Foundation

struct EthereumRPCEndpoint: Equatable, Hashable {

    private enum Trust: Equatable, Hashable {
        case unauthenticated
        case alchemy
    }

    let url: URL
    private let trust: Trust

    private init(url: URL, trust: Trust) {
        self.url = url
        self.trust = trust
    }

    static func unauthenticated(_ url: URL) -> EthereumRPCEndpoint {
        return EthereumRPCEndpoint(url: url, trust: .unauthenticated)
    }

    static func catalog(
        _ url: URL,
        alchemyNetwork: String?
    ) -> EthereumRPCEndpoint {
        let canonicalURL = alchemyNetwork.flatMap(AlchemyRPC.url(network:))
        let isCanonical = canonicalURL?.absoluteString == url.absoluteString
        return EthereumRPCEndpoint(
            url: url,
            trust: isCanonical ? .alchemy : .unauthenticated
        )
    }

    var allowsAlchemyAuthorization: Bool {
        return trust == .alchemy
    }

}

struct EthereumNetwork: Codable, Equatable, Hashable {
    
    let chainId: Int
    let name: String
    let symbol: String
    let rpcEndpoint: EthereumRPCEndpoint
    let isTestnet: Bool
    let mightShowPrice: Bool
    let explorer: String?

    private enum CodingKeys: String, CodingKey {
        case chainId
        case name
        case symbol
        case nodeURLString
        case isTestnet
        case mightShowPrice
        case explorer
    }

    init(chainId: Int,
         name: String,
         symbol: String,
         rpcEndpoint: EthereumRPCEndpoint,
         isTestnet: Bool,
         mightShowPrice: Bool,
         explorer: String?) {
        self.chainId = chainId
        self.name = name
        self.symbol = symbol
        self.rpcEndpoint = rpcEndpoint
        self.isTestnet = isTestnet
        self.mightShowPrice = mightShowPrice
        self.explorer = explorer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainId = try container.decode(Int.self, forKey: .chainId)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decode(String.self, forKey: .symbol)
        let nodeURLString = try container.decode(String.self, forKey: .nodeURLString)
        guard let rpcURL = URL(string: nodeURLString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .nodeURLString,
                in: container,
                debugDescription: "Invalid Ethereum RPC URL"
            )
        }
        // Runtime trust is never persisted; decoded and custom networks stay untrusted.
        rpcEndpoint = .unauthenticated(rpcURL)
        isTestnet = try container.decode(Bool.self, forKey: .isTestnet)
        mightShowPrice = try container.decode(Bool.self, forKey: .mightShowPrice)
        explorer = try container.decodeIfPresent(String.self, forKey: .explorer)
    }

    var nodeURLString: String { return rpcEndpoint.url.absoluteString }
    var allowsAlchemyAuthorization: Bool {
        return rpcEndpoint.allowsAlchemyAuthorization
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chainId, forKey: .chainId)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(nodeURLString, forKey: .nodeURLString)
        try container.encode(isTestnet, forKey: .isTestnet)
        try container.encode(mightShowPrice, forKey: .mightShowPrice)
        try container.encodeIfPresent(explorer, forKey: .explorer)
    }
    
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
