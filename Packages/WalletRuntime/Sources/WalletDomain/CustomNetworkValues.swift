import Foundation

public enum CustomNetworkInsertionResult: Equatable, Hashable, Sendable {

    case inserted
    case matching
    case conflict
    case unavailable

    public var succeeded: Bool {
        switch self {
        case .inserted, .matching:
            return true
        case .conflict, .unavailable:
            return false
        }
    }

}


public enum CustomNetworkDefinition {

    public static func requestedRPCURLs(
        for record: EthereumNetworkFromDapp
    ) -> [URL] {
        var normalized = Set<String>()
        let candidates = [record.defaultRpcURL].compactMap { $0 } +
            record.rpcUrls.compactMap(CustomEthereumRPC.url(from:))
        return candidates.compactMap { candidate in
            return normalized.insert(normalizedRPCURL(candidate)).inserted
                ? candidate
                : nil
        }
    }

    public static func storedRPCURL(
        for record: EthereumNetworkFromDapp,
        legacyOverride: String?
    ) -> URL? {
        return legacyOverride.flatMap(CustomEthereumRPC.url(from:)) ??
            record.defaultRpcURL
    }

    public static func normalizedRPCURL(_ url: URL) -> String {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    public static func matches(
        requested: EthereumNetworkFromDapp,
        requestedRPCURL: URL,
        existing: EthereumNetworkFromDapp,
        existingRPCURL: URL
    ) -> Bool {
        return normalizedRPCURL(requestedRPCURL)
            == normalizedRPCURL(existingRPCURL)
            && requested.nativeCurrency.symbol == existing.nativeCurrency.symbol
            && requested.nativeCurrency.decimals == existing.nativeCurrency.decimals
    }

}


public enum CustomNetworkSnapshotLoadResult: Sendable {
    case loaded(CustomNetworkSnapshot)
    case unavailable
    case corrupt
}


public struct CustomNetworkSnapshot: Sendable {

    public struct Entry: Sendable {
        public let resolvedNetwork: ResolvedEthereumNetwork
        public let definition: EthereumNetworkFromDapp

        public var chainId: Int {
            return resolvedNetwork.network.chainId
        }

        public var rpcURL: URL {
            return resolvedNetwork.rpcURL
        }

        public init(resolvedNetwork: ResolvedEthereumNetwork, definition: EthereumNetworkFromDapp) {
            self.resolvedNetwork = resolvedNetwork
            self.definition = definition
        }
    }

    public static let empty = CustomNetworkSnapshot(orderedEntries: [], entriesByChainId: [:])

    public let orderedEntries: [Entry]
    public let entriesByChainId: [Int: Entry]

    public init(
        records: [EthereumNetworkFromDapp],
        nodeURLForChainId: (Int) -> String? = { _ in nil }
    ) {
        var lastRecordByChainId: [
            Int: (index: Int, record: EthereumNetworkFromDapp, rpcURL: URL)
        ] = [:]
        for (index, record) in records.enumerated() {
            guard let chainId = Int(hexString: record.chainId),
                  chainId > 0,
                  let rpcURL = CustomNetworkDefinition.storedRPCURL(
                      for: record,
                      legacyOverride: nodeURLForChainId(chainId)
                  ) else { continue }
            lastRecordByChainId[chainId] = (index, record, rpcURL)
        }

        let deduplicated = lastRecordByChainId.map { chainId, value in
            return (
                chainId: chainId,
                index: value.index,
                record: value.record,
                rpcURL: value.rpcURL
            )
        }.sorted { $0.index < $1.index }
        var orderedEntries: [Entry] = []
        var entriesByChainId: [Int: Entry] = [:]

        for value in deduplicated {
            let record = value.record
            let chainId = value.chainId
            let rpcURL = value.rpcURL

            let network = EthereumNetwork(chainId: chainId,
                                          name: record.chainName,
                                          symbol: record.nativeCurrency.symbol,
                                          rpcEndpoint: .unauthenticated(rpcURL),
                                          isTestnet: false,
                                          mightShowPrice: false,
                                          explorer: nil)
            let resolvedNetwork = ResolvedEthereumNetwork(network: network,
                                                          source: .custom)
            let entry = Entry(
                resolvedNetwork: resolvedNetwork,
                definition: record
            )
            orderedEntries.append(entry)
            entriesByChainId[chainId] = entry
        }

        self.init(orderedEntries: orderedEntries, entriesByChainId: entriesByChainId)
    }

    private init(orderedEntries: [Entry], entriesByChainId: [Int: Entry]) {
        self.orderedEntries = orderedEntries
        self.entriesByChainId = entriesByChainId
    }

}


