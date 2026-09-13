// ∅ 2026 lil org

import Foundation

enum EthereumFeeMarketSupport: String, Codable, Equatable, Hashable, Sendable {

    case eip1559
    case legacy
    case unknown

}

struct EthereumFeeMarketHint: Codable, Equatable, Hashable, Sendable {

    private static let checkedAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    let support: EthereumFeeMarketSupport
    let checkedAt: String
    let observedEndpoint: String

    var checkedAtDate: Date? {
        Self.checkedAtFormatter.date(from: checkedAt)
    }

    func matches(endpointURL: URL) -> Bool {
        return observedEndpoint == endpointURL.absoluteString
    }

    func applicableSupport(
        for endpointURL: URL
    ) -> EthereumFeeMarketSupport? {
        guard support != .unknown,
              matches(endpointURL: endpointURL) else {
            return nil
        }
        return support
    }

}

struct EthereumRPCEndpoint: Equatable, Hashable, Sendable {

    private enum Trust: Equatable, Hashable, Sendable {
        case unauthenticated
        case alchemy
    }

    let url: URL
    private let trust: Trust
    let feeMarketHint: EthereumFeeMarketHint?

    private init(
        url: URL,
        trust: Trust,
        feeMarketHint: EthereumFeeMarketHint?
    ) {
        self.url = url
        self.trust = trust
        self.feeMarketHint = feeMarketHint
    }

    static func unauthenticated(_ url: URL) -> EthereumRPCEndpoint {
        return EthereumRPCEndpoint(
            url: url,
            trust: .unauthenticated,
            feeMarketHint: nil
        )
    }

    static func catalog(
        _ url: URL,
        alchemyNetwork: String?,
        feeMarketHint: EthereumFeeMarketHint? = nil
    ) -> EthereumRPCEndpoint {
        let canonicalURL = alchemyNetwork.flatMap(AlchemyRPC.url(network:))
        let isCanonical = canonicalURL?.absoluteString == url.absoluteString
        let applicableHint = feeMarketHint?.matches(endpointURL: url) == true
            ? feeMarketHint
            : nil
        return EthereumRPCEndpoint(
            url: url,
            trust: isCanonical ? .alchemy : .unauthenticated,
            feeMarketHint: applicableHint
        )
    }

    var allowsAlchemyAuthorization: Bool {
        return trust == .alchemy
    }

    func catalogFeeMarketObservation() -> EthereumFeeMarketSupport? {
        return feeMarketHint?.applicableSupport(for: url)
    }

    func catalogFeeMarketSupport() -> EthereumFeeMarketSupport? {
        let observation = catalogFeeMarketObservation()
        return observation == .eip1559 ? .eip1559 : nil
    }

    func requiresFeeMarketDetection() -> Bool {
        return catalogFeeMarketSupport() == nil
    }

    static func == (
        lhs: EthereumRPCEndpoint,
        rhs: EthereumRPCEndpoint
    ) -> Bool {
        return lhs.url == rhs.url && lhs.trust == rhs.trust
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(trust)
    }

}

struct EthereumNetwork: Codable, Equatable, Hashable, Sendable {
    
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

struct EthereumNetworkFromDapp: Codable, Sendable {
    var chainId: String
    var rpcUrls: [String]
    var blockExplorerUrls: [String]
    var nativeCurrency: Currency
    var chainName: String
    
    struct Currency: Codable, Sendable {
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
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func preferredURL(in values: [String]) -> URL? {
        var firstHTTPURL: URL?
        for value in values {
            guard let url = url(from: value) else { continue }
            if url.scheme?.lowercased() == "https" { return url }
            if firstHTTPURL == nil { firstHTTPURL = url }
        }
        return firstHTTPURL
    }

}
