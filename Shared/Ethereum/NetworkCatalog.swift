// ∅ 2026 lil org

import Foundation

struct NetworkCatalogNativeCurrency: Codable, Equatable {

    let name: String
    let symbol: String
    let decimals: Int

}

struct NetworkCatalogRecord: Codable, Equatable {

    let chainId: Int
    let name: String
    let nativeCurrency: NetworkCatalogNativeCurrency
    let explorerURL: String?
    let isTestnet: Bool
    let displayPrice: Bool
    let alchemyNetwork: String?
    let fallbackRPCURL: String?
    let accountDisabledAlchemyNetwork: String?

    var hasExactlyOneEndpoint: Bool {
        return (alchemyNetwork != nil) != (fallbackRPCURL != nil)
    }

    var rpcSource: RPCSource {
        return alchemyNetwork == nil ? .fallback : .alchemy
    }

    func rpcURL() -> URL? {
        if let alchemyNetwork {
            return AlchemyRPC.url(network: alchemyNetwork)
        }
        guard let fallbackRPCURL else { return nil }
        return URL(string: fallbackRPCURL)
    }

    func ethereumNetwork(rpcURL: URL) -> EthereumNetwork {
        return EthereumNetwork(chainId: chainId,
                               name: name,
                               symbol: nativeCurrency.symbol,
                               rpcEndpoint: .catalog(
                                   rpcURL,
                                   alchemyNetwork: alchemyNetwork
                               ),
                               isTestnet: isTestnet,
                               mightShowPrice: displayPrice,
                               explorer: explorerURL)
    }

}

enum NetworkCatalogError: Error, Equatable {

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

}

enum NetworkCatalogLoadError: Error, Equatable {

    case missingResource
    case unreadableResource
    case invalidCatalog(decodedChainIds: Set<Int>)

}

struct NetworkCatalog {

    static let resourceName = "NetworkCatalog"

    let records: [NetworkCatalogRecord]
    private let recordsByChainId: [Int: NetworkCatalogRecord]

    init(data: Data) throws {
        try self.init(records: JSONDecoder().decode([NetworkCatalogRecord].self, from: data))
    }

    init(records: [NetworkCatalogRecord]) throws {
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
            guard recordsByChainId.updateValue(record, forKey: record.chainId) == nil else {
                throw NetworkCatalogError.duplicateChainId(record.chainId)
            }
        }

        self.records = records
        self.recordsByChainId = recordsByChainId
    }

    func record(chainId: Int) -> NetworkCatalogRecord? {
        return recordsByChainId[chainId]
    }

    func contains(chainId: Int) -> Bool {
        return recordsByChainId[chainId] != nil
    }

    static func load(in bundle: Bundle = .main) throws -> NetworkCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw NetworkCatalogLoadError.missingResource
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NetworkCatalogLoadError.unreadableResource
        }

        do {
            return try NetworkCatalog(data: data)
        } catch {
            throw NetworkCatalogLoadError.invalidCatalog(
                decodedChainIds: decodedChainIds(from: data)
            )
        }
    }

    private static func decodedChainIds(from data: Data) -> Set<Int> {
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

enum BundledNetworkOwnership {

    static let chainIds: Set<Int> = [
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

enum RPCSource: Equatable {

    case alchemy
    case fallback
    case custom

}

struct ResolvedEthereumNetwork: Equatable {

    let network: EthereumNetwork
    let source: RPCSource

    var rpcEndpoint: EthereumRPCEndpoint {
        return network.rpcEndpoint
    }

    var rpcURL: URL {
        return rpcEndpoint.url
    }

    var allowsAlchemyAuthorization: Bool {
        return rpcEndpoint.allowsAlchemyAuthorization
    }

}

enum EthereumNetworkResolution: Equatable {

    case resolved(ResolvedEthereumNetwork)
    case catalogOwnedButUnavailable
    case unknown

    var resolvedNetwork: ResolvedEthereumNetwork? {
        guard case let .resolved(resolvedNetwork) = self else { return nil }
        return resolvedNetwork
    }

}

struct NetworkResolver {

    static let main: NetworkResolver = {
        let catalog: NetworkCatalog?
        let decodedChainIds: Set<Int>

        do {
            catalog = try NetworkCatalog.load(in: .main)
            decodedChainIds = []
        } catch {
            catalog = nil
            if let loadError = error as? NetworkCatalogLoadError,
               case let .invalidCatalog(ids) = loadError {
                decodedChainIds = ids
            } else {
                decodedChainIds = []
            }
        }

        return NetworkResolver(catalog: catalog,
                               catalogOwnedChainIds: BundledNetworkOwnership.chainIds,
                               decodedChainIds: decodedChainIds,
                               customSnapshot: { CustomNetworkCache.shared.snapshot() })
    }()

    let catalogIsAvailable: Bool

    private let catalogOwnedChainIds: Set<Int>
    private let resolvedCatalogByChainId: [Int: ResolvedEthereumNetwork]
    private let customSnapshot: () -> CustomNetworkSnapshot

    init(catalog: NetworkCatalog?,
         catalogOwnedChainIds: Set<Int>,
         decodedChainIds: Set<Int> = [],
         catalogURLBuilder: (NetworkCatalogRecord) -> URL? = {
             record in
             return record.rpcURL()
         },
         customSnapshot: @escaping () -> CustomNetworkSnapshot) {
        let catalogMatchesOwnership = catalog?.records.count == catalogOwnedChainIds.count
            && catalog?.records.allSatisfy {
                catalogOwnedChainIds.contains($0.chainId)
            } == true

        var runtimeOwnedChainIds = catalogOwnedChainIds.union(decodedChainIds)
        if let catalog {
            runtimeOwnedChainIds.formUnion(catalog.records.lazy.map(\.chainId))
        }
        self.catalogOwnedChainIds = runtimeOwnedChainIds
        self.customSnapshot = customSnapshot

        guard let catalog, catalogMatchesOwnership else {
            self.catalogIsAvailable = false
            self.resolvedCatalogByChainId = [:]
            return
        }

        var resolvedCatalogByChainId: [Int: ResolvedEthereumNetwork] = [:]
        for record in catalog.records {
            guard let rpcURL = catalogURLBuilder(record) else { continue }
            let network = record.ethereumNetwork(rpcURL: rpcURL)
            resolvedCatalogByChainId[record.chainId] = ResolvedEthereumNetwork(
                network: network,
                source: record.rpcSource
            )
        }

        self.catalogIsAvailable = true
        self.resolvedCatalogByChainId = resolvedCatalogByChainId
    }

    var bundledNetworks: [EthereumNetwork] {
        return resolvedCatalogByChainId.values
            .map(\.network)
            .sorted {
                if $0.name == $1.name {
                    return $0.chainId < $1.chainId
                }
                return $0.name < $1.name
            }
    }

    func resolve(chainId: Int) -> EthereumNetworkResolution {
        if let resolvedNetwork = resolvedCatalogByChainId[chainId] {
            return .resolved(resolvedNetwork)
        }

        if catalogOwnedChainIds.contains(chainId) {
            return .catalogOwnedButUnavailable
        }

        guard let resolvedNetwork = customSnapshot().entriesByChainId[chainId]?.resolvedNetwork else {
            return .unknown
        }
        return .resolved(resolvedNetwork)
    }

    func rpcURL(chainId: Int) -> URL? {
        return resolve(chainId: chainId).resolvedNetwork?.rpcURL
    }

    func network(chainId: Int) -> EthereumNetwork? {
        return resolve(chainId: chainId).resolvedNetwork?.network
    }

    var visibleCustomNetworks: [EthereumNetwork] {
        return customSnapshot().orderedEntries.compactMap { entry in
            guard !catalogOwnedChainIds.contains(entry.chainId) else { return nil }
            return entry.resolvedNetwork.network
        }
    }

}
