// ∅ 2026 lil org

import Foundation

public struct NetworkCatalogNativeCurrency: Codable, Equatable, Sendable {

    public let name: String
    public let symbol: String
    public let decimals: Int


    public init(name: String, symbol: String, decimals: Int) {
        self.name = name
        self.symbol = symbol
        self.decimals = decimals
    }
}

public struct NetworkCatalogRecord: Codable, Equatable, Sendable {

    public let chainId: Int
    public let name: String
    public let nativeCurrency: NetworkCatalogNativeCurrency
    public let explorerURL: String?
    public let isTestnet: Bool
    public let displayPrice: Bool
    public let alchemyNetwork: String?
    public let fallbackRPCURL: String?
    public let accountDisabledAlchemyNetwork: String?
    public let feeMarketHint: EthereumFeeMarketHint

    public var hasExactlyOneEndpoint: Bool {
        return (alchemyNetwork != nil) != (fallbackRPCURL != nil)
    }

    public var rpcSource: RPCSource {
        return alchemyNetwork == nil ? .fallback : .alchemy
    }

    public func rpcURL() -> URL? {
        if let alchemyNetwork {
            return AlchemyRPC.url(network: alchemyNetwork)
        }
        guard let fallbackRPCURL else { return nil }
        return URL(string: fallbackRPCURL)
    }

    public func ethereumNetwork(rpcURL: URL) -> EthereumNetwork {
        return EthereumNetwork(chainId: chainId,
                               name: name,
                               symbol: nativeCurrency.symbol,
                               rpcEndpoint: .catalog(
                                   rpcURL,
                                   alchemyNetwork: alchemyNetwork,
                                   feeMarketHint: feeMarketHint
                               ),
                               isTestnet: isTestnet,
                               mightShowPrice: displayPrice,
                               explorer: explorerURL)
    }


    public init(chainId: Int, name: String, nativeCurrency: NetworkCatalogNativeCurrency, explorerURL: String?, isTestnet: Bool, displayPrice: Bool, alchemyNetwork: String?, fallbackRPCURL: String?, accountDisabledAlchemyNetwork: String?, feeMarketHint: EthereumFeeMarketHint) {
        self.chainId = chainId
        self.name = name
        self.nativeCurrency = nativeCurrency
        self.explorerURL = explorerURL
        self.isTestnet = isTestnet
        self.displayPrice = displayPrice
        self.alchemyNetwork = alchemyNetwork
        self.fallbackRPCURL = fallbackRPCURL
        self.accountDisabledAlchemyNetwork = accountDisabledAlchemyNetwork
        self.feeMarketHint = feeMarketHint
    }
}

public enum NetworkCatalogError: Error, Equatable {

    case duplicateChainId(Int)
    case duplicateAlchemyNetwork(String)
    case invalidChainId(Int)
    case invalidName(Int)
    case invalidNativeCurrency(Int)
    case invalidExplorerURL(Int)
    case invalidEndpointDescriptor(Int)
    case invalidAlchemyNetwork(Int)
    case invalidFallbackRPCURL(Int)
    case invalidAccountDisabledAlchemyNetwork(Int)
    case invalidFeeMarketHint(Int)

}

public enum NetworkCatalogLoadError: Error, Equatable {

    case missingResource
    case unreadableResource
    case invalidCatalog(decodedChainIds: Set<Int>)

}

public struct NetworkCatalog: Sendable {

    public static let resourceName = "NetworkCatalog"

    public let records: [NetworkCatalogRecord]
    private let recordsByChainId: [Int: NetworkCatalogRecord]

    public init(data: Data) throws {
        try self.init(records: JSONDecoder().decode([NetworkCatalogRecord].self, from: data))
    }

    public init(records: [NetworkCatalogRecord]) throws {
        var recordsByChainId: [Int: NetworkCatalogRecord] = [:]
        var alchemyNetworks = Set<String>()

        for record in records {
            guard record.chainId > 0 else {
                throw NetworkCatalogError.invalidChainId(record.chainId)
            }
            let trimmedName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, record.name == trimmedName else {
                throw NetworkCatalogError.invalidName(record.chainId)
            }
            let trimmedCurrencyName = record.nativeCurrency.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCurrencySymbol = record.nativeCurrency.symbol
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCurrencyName.isEmpty,
                  record.nativeCurrency.name == trimmedCurrencyName,
                  !trimmedCurrencySymbol.isEmpty,
                  record.nativeCurrency.symbol == trimmedCurrencySymbol,
                  (0...255).contains(record.nativeCurrency.decimals) else {
                throw NetworkCatalogError.invalidNativeCurrency(record.chainId)
            }
            if let explorerURL = record.explorerURL {
                guard Self.isValidWebURL(explorerURL) else {
                    throw NetworkCatalogError.invalidExplorerURL(record.chainId)
                }
            }
            guard record.hasExactlyOneEndpoint else {
                throw NetworkCatalogError.invalidEndpointDescriptor(record.chainId)
            }
            if let alchemyNetwork = record.alchemyNetwork {
                guard AlchemyRPC.isValidNetworkName(alchemyNetwork) else {
                    throw NetworkCatalogError.invalidAlchemyNetwork(record.chainId)
                }
                guard alchemyNetworks.insert(alchemyNetwork).inserted else {
                    throw NetworkCatalogError.duplicateAlchemyNetwork(alchemyNetwork)
                }
            }
            if let fallbackRPCURL = record.fallbackRPCURL {
                guard Self.isValidHTTPSURL(fallbackRPCURL) else {
                    throw NetworkCatalogError.invalidFallbackRPCURL(record.chainId)
                }
            }
            if let accountDisabledAlchemyNetwork = record.accountDisabledAlchemyNetwork {
                guard record.alchemyNetwork == nil,
                      record.fallbackRPCURL != nil,
                      AlchemyRPC.isValidNetworkName(accountDisabledAlchemyNetwork) else {
                    throw NetworkCatalogError.invalidAccountDisabledAlchemyNetwork(record.chainId)
                }
                guard alchemyNetworks.insert(accountDisabledAlchemyNetwork).inserted else {
                    throw NetworkCatalogError.duplicateAlchemyNetwork(accountDisabledAlchemyNetwork)
                }
            }
            guard record.feeMarketHint.checkedAtDate != nil else {
                throw NetworkCatalogError.invalidFeeMarketHint(record.chainId)
            }
            guard recordsByChainId.updateValue(record, forKey: record.chainId) == nil else {
                throw NetworkCatalogError.duplicateChainId(record.chainId)
            }
        }

        self.records = records
        self.recordsByChainId = recordsByChainId
    }

    public func record(chainId: Int) -> NetworkCatalogRecord? {
        return recordsByChainId[chainId]
    }

    public func contains(chainId: Int) -> Bool {
        return recordsByChainId[chainId] != nil
    }

    public static func decodedChainIds(from data: Data) -> Set<Int> {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let values = json as? [Any] else {
            return []
        }

        return Set(values.compactMap { value in
            guard let object = value as? [String: Any] else { return nil }
            if let chainId = object["chainId"] as? Int {
                return chainId
            }
            if let chainId = object["chainId"] as? String {
                return Int(chainId)
            }
            return nil
        })
    }

    private static func isValidWebURL(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

    private static func isValidHTTPSURL(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }

}

public enum BundledNetworkOwnership {

    public static let chainIds: Set<Int> = [
        1, 10, 25, 30, 31, 40, 56, 66, 69, 77, 97, 99, 100, 122, 128, 130,
        137, 143, 146, 169, 185, 196, 200, 204, 232, 250, 252, 255, 280, 288,
        300, 314, 324, 338, 360, 420, 424, 480, 545, 592, 690, 747, 869, 919,
        988, 998, 999, 1001, 1088, 1101, 1284, 1285, 1301, 1315, 1328, 1329,
        1439, 1442, 1514, 1672, 1776, 1868, 1946, 1952, 2020, 2201, 2221,
        2222, 2741, 2818, 3343, 4002, 4114, 4153, 4157, 4158, 4217, 4326,
        4337, 4663, 4801, 5000, 5001, 5003, 5115, 5330, 5371, 5373, 5545,
        5611, 6342, 6343, 6900, 7000, 7001, 7700, 8217, 8333, 8453, 9001,
        9745, 9746, 10143, 10200, 11011, 11124, 11235, 13371, 14601, 28882,
        33111, 33139, 33431, 34443, 36900, 37111, 42018, 42161, 42170, 42220,
        42431, 42766, 43113, 43114, 43288, 44787, 46630, 53302, 56288, 57073,
        58008, 59140, 59141, 59144, 60808, 69000, 80001, 80002, 80069, 80094,
        81457, 84531, 84532, 99999, 167000, 202601, 323432, 421613, 421614,
        534351, 534352, 560048, 613419, 685685, 685689, 688689, 737373,
        747474, 763373, 808813, 810180, 843843, 2019775, 5042002, 5734951,
        6985385, 7080969, 7777777, 11142220, 11155111, 11155420, 11155931,
        68840142, 168587773, 245022926, 245022934, 351243127, 666666666,
        999999999, 1313161554, 1313161555, 1666600000, 11297108099,
        11297108109,
    ]

}

public enum RPCSource: Equatable, Sendable {

    case alchemy
    case fallback
    case custom

}

public struct ResolvedEthereumNetwork: Equatable, Sendable {

    public let network: EthereumNetwork
    public let source: RPCSource

    public var rpcEndpoint: EthereumRPCEndpoint {
        return network.rpcEndpoint
    }

    public var rpcURL: URL {
        return rpcEndpoint.url
    }

    public var allowsAlchemyAuthorization: Bool {
        return rpcEndpoint.allowsAlchemyAuthorization
    }


    public init(network: EthereumNetwork, source: RPCSource) {
        self.network = network
        self.source = source
    }
}

public enum EthereumNetworkResolution: Equatable, Sendable {

    case resolved(ResolvedEthereumNetwork)
    case catalogOwnedButUnavailable
    case unknown

    public var resolvedNetwork: ResolvedEthereumNetwork? {
        guard case let .resolved(resolvedNetwork) = self else { return nil }
        return resolvedNetwork
    }

}

public enum ApprovalNetworkResolution: Equatable, Sendable {
    case resolved(ResolvedEthereumNetwork)
    case missing
    case unavailable
}

