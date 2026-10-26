// ∅ 2026 lil org

import Foundation
import Synchronization

public enum EthereumFeeMarketSupport: String, Codable, Equatable, Hashable, Sendable {

    case eip1559
    case legacy
    case unknown

}

public struct EthereumFeeMarketHint: Codable, Equatable, Hashable, Sendable {

    private static let checkedAtFormatter = Mutex({
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    public let support: EthereumFeeMarketSupport
    public let checkedAt: String
    public let observedEndpoint: String

    public var checkedAtDate: Date? {
        Self.checkedAtFormatter.withLock { $0.date(from: checkedAt) }
    }

    public func matches(endpointURL: URL) -> Bool {
        return observedEndpoint == endpointURL.absoluteString
    }

    public func applicableSupport(
        for endpointURL: URL
    ) -> EthereumFeeMarketSupport? {
        guard support != .unknown,
              matches(endpointURL: endpointURL) else {
            return nil
        }
        return support
    }


    public init(support: EthereumFeeMarketSupport, checkedAt: String, observedEndpoint: String) {
        self.support = support
        self.checkedAt = checkedAt
        self.observedEndpoint = observedEndpoint
    }
}

public struct EthereumRPCEndpoint: Equatable, Hashable, Sendable {

    private enum Trust: Equatable, Hashable, Sendable {
        case unauthenticated
        case alchemy
    }

    public let url: URL
    private let trust: Trust
    public let feeMarketHint: EthereumFeeMarketHint?

    private init(
        url: URL,
        trust: Trust,
        feeMarketHint: EthereumFeeMarketHint?
    ) {
        self.url = url
        self.trust = trust
        self.feeMarketHint = feeMarketHint
    }


    public static func unauthenticated(_ url: URL) -> EthereumRPCEndpoint {
        return EthereumRPCEndpoint(
            url: url,
            trust: .unauthenticated,
            feeMarketHint: nil
        )
    }

    public static func catalog(
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

    public var allowsAlchemyAuthorization: Bool {
        return trust == .alchemy
    }

    public func catalogFeeMarketObservation() -> EthereumFeeMarketSupport? {
        return feeMarketHint?.applicableSupport(for: url)
    }

    public func catalogFeeMarketSupport() -> EthereumFeeMarketSupport? {
        let observation = catalogFeeMarketObservation()
        return observation == .eip1559 ? .eip1559 : nil
    }

    public func requiresFeeMarketDetection() -> Bool {
        return catalogFeeMarketSupport() == nil
    }

    public static func == (
        lhs: EthereumRPCEndpoint,
        rhs: EthereumRPCEndpoint
    ) -> Bool {
        return lhs.url == rhs.url && lhs.trust == rhs.trust
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(trust)
    }

}

public struct EthereumNetwork: Codable, Equatable, Hashable, Sendable {
    
    public let chainId: Int
    public let name: String
    public let symbol: String
    public let rpcEndpoint: EthereumRPCEndpoint
    public let isTestnet: Bool
    public let mightShowPrice: Bool
    public let explorer: String?

    private enum CodingKeys: String, CodingKey {
        case chainId
        case name
        case symbol
        case nodeURLString
        case isTestnet
        case mightShowPrice
        case explorer
    }

    public init(chainId: Int,
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

    public init(from decoder: Decoder) throws {
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

    public var nodeURLString: String {
        return rpcEndpoint.url.absoluteString
    }
    public var allowsAlchemyAuthorization: Bool {
        return rpcEndpoint.allowsAlchemyAuthorization
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chainId, forKey: .chainId)
        try container.encode(name, forKey: .name)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(nodeURLString, forKey: .nodeURLString)
        try container.encode(isTestnet, forKey: .isTestnet)
        try container.encode(mightShowPrice, forKey: .mightShowPrice)
        try container.encodeIfPresent(explorer, forKey: .explorer)
    }
    
    public var symbolIsETH: Bool { return symbol == "ETH" }
    public var chainIdHexString: String { String.hex(chainId, withPrefix: true) }
    public var isEthMainnet: Bool { return chainId == EthereumNetwork.ethMainnetChainId }
    public var supportsNativeBalance: Bool { return !Self.tempoChainIds.contains(chainId) }
    
    public static let ethMainnetChainId = 1
    private static let tempoChainIds: Set<Int> = [
        4_217,
        31_318,
        42_429,
        42_431,
    ]
    
}

public struct EthereumNetworkFromDapp: Codable, Sendable {
    public var chainId: String
    public var rpcUrls: [String]
    public var blockExplorerUrls: [String]
    public var nativeCurrency: Currency
    public var chainName: String
    
    public struct Currency: Codable, Sendable {
        public var decimals: Int
        public var name: String
        public var symbol: String

        public init(decimals: Int, name: String, symbol: String) {
            self.decimals = decimals
            self.name = name
            self.symbol = symbol
        }
    }
    
    public static func from(_ dict: [String: Any]?) -> EthereumNetworkFromDapp? {
        if let dict = dict,
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let network = try? JSONDecoder().decode(EthereumNetworkFromDapp.self, from: data) {
            return network
        } else {
            return nil
        }
    }
    
    public var defaultRpcURL: URL? {
        return CustomEthereumRPC.preferredURL(in: rpcUrls)
    }

    public var defaultRpcUrl: String {
        return defaultRpcURL?.absoluteString ?? ""
    }
    

    public init(chainId: String, rpcUrls: [String], blockExplorerUrls: [String], nativeCurrency: Currency, chainName: String) {
        self.chainId = chainId
        self.rpcUrls = rpcUrls
        self.blockExplorerUrls = blockExplorerUrls
        self.nativeCurrency = nativeCurrency
        self.chainName = chainName
    }
}

public enum CustomEthereumRPC {

    public static func url(from value: String) -> URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    public static func preferredURL(in values: [String]) -> URL? {
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
