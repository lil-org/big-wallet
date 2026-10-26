// ∅ 2026 lil org

import Foundation
import WalletDomain
import Synchronization

public actor GasService {

    private static let feeHistoryBlockCount: UInt = 10
    private static let rewardPercentiles: [Double] = [50, 95]
    private static let capabilityCache = FeeMarketCapabilityCache()

    private static let adoptedPriorityFeeCapFloor =
        BigUInt(1_000_000_000_000)

    public static func cappedAdoptedPriorityFee(
        _ suggested: BigUInt,
        currentBaseFee: BigUInt
    ) -> BigUInt {
        min(
            suggested,
            max(currentBaseFee * BigUInt(16), adoptedPriorityFeeCapFloor)
        )
    }

    private let rpc: any EthereumFeeRPCClient

    public init(rpc: any EthereumFeeRPCClient) {
        self.rpc = rpc
    }

    public func fetchEstimate(
        endpoint: EthereumRPCEndpoint,
        chainID: Int? = nil
    ) async throws -> GasEstimate {
        try Task.checkCancellation()
        let cacheKey = FeeMarketCapabilityCache.Key(chainID: chainID, endpointURL: endpoint.url.absoluteString)
        let catalogObservation = endpoint.catalogFeeMarketObservation()
        var resolvedEndpointChainID: BigUInt?
        var knownSupport = catalogObservation

        if let chainID {
            guard chainID > 0 else { return GasEstimate(info: nil, nextBaseFee: nil) }
            let encodedChainID: String?
            do {
                encodedChainID = try await rpc.fetchChainID(endpoint: endpoint)
            } catch {
                try Task.checkCancellation()
                encodedChainID = nil
            }
            try Task.checkCancellation()
            if let encodedChainID, let actualChainID = EthereumQuantity.parseUInt256(encodedChainID) {
                guard actualChainID == BigUInt(UInt64(chainID)) else {
                    return GasEstimate(info: nil, nextBaseFee: nil, endpointChainID: actualChainID)
                }
                resolvedEndpointChainID = actualChainID
                let cachedSupport = Self.capabilityCache.value(for: cacheKey)
                knownSupport =
                    catalogObservation == .eip1559 || cachedSupport == .eip1559
                    ? .eip1559 : catalogObservation ?? cachedSupport
            }
        }
        let query = Query(endpoint: endpoint, endpointChainID: resolvedEndpointChainID, cacheKey: cacheKey)
        let block: EthereumLatestBlock
        do {
            block = try await rpc.fetchLatestBlock(endpoint: endpoint)
        } catch {
            try Task.checkCancellation()
            return knownSupport == .eip1559 ? try await unknown(query) : try await legacy(query)
        }
        try Task.checkCancellation()
        guard let blockNumber = block.number, let parsedBlockNumber = Self.validQuantity(blockNumber) else {
            return try await unknown(query)
        }
        let blockBaseFee: BigUInt?
        switch block.baseFeeField {
        case .encoded(let encoded):
            guard let parsed = Self.validQuantity(encoded) else { return try await unknown(query) }
            blockBaseFee = parsed
        case .null:
            return try await unknown(query)
        case .missing:
            blockBaseFee = nil
        }

        let history: EthereumFeeHistory
        do {
            history = try await rpc.fetchFeeHistory(
                endpoint: endpoint,
                blockCount: Self.feeHistoryBlockCount,
                newestBlock: parsedBlockNumber.toHexString(withPrefix: true),
                rewardPercentiles: Self.rewardPercentiles
            )
        } catch {
            try Task.checkCancellation()
            if (error as? EthereumRPCError)?.isMethodNotFound == true {
                if let blockBaseFee {
                    cache(.eip1559, for: query)
                    return try await eip1559(
                        query, history: nil, currentBaseFee: blockBaseFee, nextBaseFee: blockBaseFee)
                }
                if knownSupport != .eip1559 {
                    cache(.legacy, for: query)
                    return try await legacy(query)
                }
            } else if knownSupport == .eip1559, let blockBaseFee {
                return try await eip1559(query, history: nil, currentBaseFee: blockBaseFee, nextBaseFee: blockBaseFee)
            } else if knownSupport == .legacy, blockBaseFee == nil {
                return try await legacy(query)
            }
            return try await unknown(query, currentBaseFee: blockBaseFee, nextBaseFee: blockBaseFee)
        }
        try Task.checkCancellation()
        guard let parsedHistoryFees = Self.baseFees(from: history) else {
            return try await unknown(query, currentBaseFee: blockBaseFee, nextBaseFee: blockBaseFee)
        }
        guard let blockBaseFee else { return try await unknown(query) }
        guard blockBaseFee == parsedHistoryFees.current else {
            return try await unknown(query, currentBaseFee: blockBaseFee)
        }
        cache(.eip1559, for: query)
        return try await eip1559(
            query, history: history, currentBaseFee: parsedHistoryFees.current, nextBaseFee: parsedHistoryFees.next)
    }

    public func fetchEstimate(network: EthereumNetwork) async throws -> GasEstimate {
        try await fetchEstimate(endpoint: network.rpcEndpoint, chainID: network.chainId)
    }

    private struct Query: Sendable {
        let endpoint: EthereumRPCEndpoint
        let endpointChainID: BigUInt?
        let cacheKey: FeeMarketCapabilityCache.Key
    }

    private func cache(_ support: EthereumFeeMarketSupport, for query: Query) {
        guard query.endpointChainID != nil else { return }
        Self.capabilityCache.set(support, for: query.cacheKey)
    }

    private func gasPrice(for query: Query) async throws -> BigUInt? {
        do {
            let value = try await rpc.fetchGasPrice(endpoint: query.endpoint)
            try Task.checkCancellation()
            return Self.validQuantity(value)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    private func legacy(_ query: Query) async throws -> GasEstimate {
        GasEstimate(
            info: nil, nextBaseFee: nil, support: .legacy, gasPrice: try await gasPrice(for: query),
            endpointChainID: query.endpointChainID)
    }

    private func unknown(_ query: Query, currentBaseFee: BigUInt? = nil, nextBaseFee: BigUInt? = nil) async throws
        -> GasEstimate
    {
        GasEstimate(
            info: nil, nextBaseFee: nextBaseFee, currentBaseFee: currentBaseFee, support: .unknown,
            gasPrice: try await gasPrice(for: query), endpointChainID: query.endpointChainID)
    }

    private func eip1559(
        _ query: Query,
        history: EthereumFeeHistory?,
        currentBaseFee: BigUInt,
        nextBaseFee: BigUInt
    ) async throws -> GasEstimate {
        if let history, let info = Self.priorityInfo(from: history) {
            return GasEstimate(
                info: info, nextBaseFee: nextBaseFee, currentBaseFee: currentBaseFee, support: .eip1559,
                endpointChainID: query.endpointChainID)
        }
        let priority: BigUInt?
        do {
            let value = try await rpc.fetchMaxPriorityFeePerGas(endpoint: query.endpoint)
            try Task.checkCancellation()
            priority = Self.validQuantity(value)
        } catch {
            try Task.checkCancellation()
            priority = nil
        }
        if let priority,
            let info = GasPriceInfo.relative(
                to: Self.cappedAdoptedPriorityFee(
                    max(priority, PreparedTransactionFee.minimumPriorityFeePerGas), currentBaseFee: currentBaseFee))
        {
            return GasEstimate(
                info: info, nextBaseFee: nextBaseFee, currentBaseFee: currentBaseFee, support: .eip1559,
                endpointChainID: query.endpointChainID)
        }
        let gasPrice = try await gasPrice(for: query)
        let referencePriority = gasPrice.map {
            Self.cappedAdoptedPriorityFee(
                $0 > currentBaseFee ? $0 - currentBaseFee : PreparedTransactionFee.minimumPriorityFeePerGas,
                currentBaseFee: currentBaseFee)
        }
        return GasEstimate(
            info: referencePriority.flatMap(GasPriceInfo.relative(to:)), nextBaseFee: nextBaseFee,
            currentBaseFee: currentBaseFee, support: .eip1559, gasPrice: gasPrice,
            endpointChainID: query.endpointChainID)
    }

    static func resetCapabilityCacheForTests() {
        capabilityCache.removeAll()
    }

    private static func validQuantity(_ value: String) -> BigUInt? {
        EthereumQuantity.parseUInt256(value)
    }

    private static func baseFees(
        from history: EthereumFeeHistory
    ) -> (current: BigUInt, next: BigUInt)? {
        let feeCount = history.baseFeePerGas.count
        guard (2...(Int(feeHistoryBlockCount) + 1)).contains(feeCount) else {
            return nil
        }

        var fees = [BigUInt]()
        fees.reserveCapacity(feeCount)
        for encodedFee in history.baseFeePerGas {
            guard let fee = validQuantity(encodedFee) else { return nil }
            fees.append(fee)
        }

        return (
            current: fees[feeCount - 2],
            next: fees[feeCount - 1]
        )
    }

    private static func priorityInfo(from history: EthereumFeeHistory) -> GasPriceInfo? {
        let percentileCount = rewardPercentiles.count
        guard let reward = history.reward,
              !reward.isEmpty,
              history.baseFeePerGas.count == reward.count + 1 else { return nil }

        var rows = [[BigUInt]]()
        rows.reserveCapacity(reward.count)
        for row in reward {
            guard row.count == percentileCount else { return nil }
            let values = row.compactMap(validQuantity)
            guard values.count == percentileCount,
                  zip(values, values.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
            rows.append(values)
        }

        var percentileValues = [BigUInt]()
        percentileValues.reserveCapacity(percentileCount)
        for column in rewardPercentiles.indices {
            let values = rows.map { $0[column] }.sorted()
            let upperMedian = values[values.count / 2]
            percentileValues.append(max(
                upperMedian,
                PreparedTransactionFee.minimumPriorityFeePerGas
            ))
        }

        let recommended = percentileValues[0]
        let high = percentileValues[1]
        guard recommended <= high else { return nil }

        return GasPriceInfo(
            recommendedPriorityFee: recommended,
            highPriorityFee: high
        )
    }
}

private final class FeeMarketCapabilityCache: Sendable {
    struct Key: Hashable, Sendable {
        let chainID: Int?
        let endpointURL: String
    }

    private let values = Mutex([Key: EthereumFeeMarketSupport]())

    public func value(for key: Key) -> EthereumFeeMarketSupport? {
        values.withLock { $0[key] }
    }

    public func set(_ support: EthereumFeeMarketSupport, for key: Key) {
        guard support != .unknown else { return }
        values.withLock { $0[key] = support }
    }

    public func removeAll() {
        values.withLock { $0.removeAll() }
    }
}

