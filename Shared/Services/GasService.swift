// ∅ 2026 lil org

import Foundation
import Synchronization

final class OneShotGate: Sendable {
    private let isAvailable = Mutex(true)

    func claim() -> Bool {
        isAvailable.withLock { available in
            guard available else { return false }
            available = false
            return true
        }
    }
}

actor GasService {

    struct Info: Equatable, Sendable {
        let recommendedPriorityFee: BigUInt
        let highPriorityFee: BigUInt

        init(
            recommendedPriorityFee: BigUInt,
            highPriorityFee: BigUInt
        ) {
            precondition(recommendedPriorityFee <= highPriorityFee)
            self.recommendedPriorityFee = recommendedPriorityFee
            self.highPriorityFee = highPriorityFee
        }

        var minimumSliderPriorityFee: BigUInt {
            max(
                PreparedTransactionFee.minimumPriorityFeePerGas,
                recommendedPriorityFee.quotientAndRemainder(
                    dividingBy: 2
                ).quotient
            )
        }

        var maximumSliderPriorityFee: BigUInt {
            min(
                highPriorityFee * BigUInt(2),
                Transaction.maximumUInt256
            )
        }

        static func relative(
            to referencePriorityFee: BigUInt
        ) -> Info? {
            guard Transaction.isValidUInt256(referencePriorityFee),
                  !referencePriorityFee.isZero else { return nil }
            return Info(
                recommendedPriorityFee: referencePriorityFee,
                highPriorityFee: referencePriorityFee
            )
        }
    }

    struct Estimate: Equatable, Sendable {
        let info: Info?
        let nextBaseFee: BigUInt?
        let currentBaseFee: BigUInt?
        let support: EthereumFeeMarketSupport
        let gasPrice: BigUInt?
        let endpointChainID: BigUInt?

        init(
            info: Info?,
            nextBaseFee: BigUInt?,
            currentBaseFee: BigUInt? = nil,
            support: EthereumFeeMarketSupport = .unknown,
            gasPrice: BigUInt? = nil,
            endpointChainID: BigUInt? = nil
        ) {
            self.info = info
            self.nextBaseFee = nextBaseFee
            self.currentBaseFee = currentBaseFee
            self.support = support
            self.gasPrice = gasPrice
            self.endpointChainID = endpointChainID
        }

        var carriesBaseFeeData: Bool {
            currentBaseFee != nil || nextBaseFee != nil
        }

        func applyBaseFeeContext(to transaction: inout Transaction) {
            switch support {
            case .eip1559:
                transaction.currentBaseFeePerGas =
                    currentBaseFee ?? nextBaseFee
                transaction.nextBaseFeePerGas = nextBaseFee
            case .unknown where carriesBaseFeeData:
                transaction.currentBaseFeePerGas =
                    currentBaseFee ?? nextBaseFee
                transaction.nextBaseFeePerGas = nextBaseFee
            case .legacy:
                transaction.currentBaseFeePerGas = nil
                transaction.nextBaseFeePerGas = nil
            case .unknown:
                break
            }
        }

        var recommendedEIP1559Fee: PreparedTransactionFee? {
            guard support == .eip1559,
                  let baseFee = nextBaseFee ?? currentBaseFee,
                  let priorityFee = info?.recommendedPriorityFee else {
                return nil
            }
            return PreparedTransactionFee.recommendedEIP1559(
                baseFeePerGas: baseFee,
                maxPriorityFeePerGas: priorityFee
            )
        }

        func suggestedFee(
            for intent: TransactionFeeIntent
        ) -> PreparedTransactionFee? {
            switch (support, intent) {
            case (.eip1559, .automatic),
                 (.eip1559, .eip1559):
                return recommendedEIP1559Fee
            case (.eip1559, .legacy):
                guard let baseFee = nextBaseFee ?? currentBaseFee,
                      let priorityFee = info?.recommendedPriorityFee,
                      let gasPrice = GasService.suggestedLegacyGasPrice(
                          baseFeePerGas: baseFee,
                          priorityFeePerGas: priorityFee
                      ) else {
                    return nil
                }
                return .legacy(gasPrice: gasPrice)
            case (.legacy, .automatic),
                 (.legacy, .legacy):
                guard let gasPrice else { return nil }
                let fee = PreparedTransactionFee.legacy(gasPrice: gasPrice)
                return fee.isStructurallyValid ? fee : nil
            case (.legacy, .eip1559), (.unknown, _):
                return nil
            }
        }
    }

    static let shared = GasService()
    private static let feeHistoryBlockCount: UInt = 10
    private static let rewardPercentiles: [Double] = [50, 95]
    private static let capabilityCache = FeeMarketCapabilityCache()

    static func suggestedLegacyGasPrice(
        baseFeePerGas: BigUInt,
        priorityFeePerGas: BigUInt
    ) -> BigUInt? {
        let headroom = baseFeePerGas.quotientAndRemainder(dividingBy: 8).quotient
        let gasPrice = baseFeePerGas + headroom + priorityFeePerGas
        return Transaction.isValidUInt256(gasPrice) ? gasPrice : nil
    }

    private static let adoptedPriorityFeeCapFloor =
        BigUInt(1_000_000_000_000)

    static func cappedAdoptedPriorityFee(
        _ suggested: BigUInt,
        currentBaseFee: BigUInt
    ) -> BigUInt {
        min(
            suggested,
            max(currentBaseFee * BigUInt(16), adoptedPriorityFeeCapFloor)
        )
    }

    private let rpc: any EthereumFeeRPCClient

    init(rpc: any EthereumFeeRPCClient = EthereumRPC()) {
        self.rpc = rpc
    }

    func fetchEstimate(
        endpoint: EthereumRPCEndpoint,
        chainID: Int? = nil
    ) async throws -> Estimate {
        try Task.checkCancellation()
        let cacheKey = FeeMarketCapabilityCache.Key(chainID: chainID, endpointURL: endpoint.url.absoluteString)
        let catalogObservation = endpoint.catalogFeeMarketObservation()
        var resolvedEndpointChainID: BigUInt?
        var knownSupport = catalogObservation

        if let chainID {
            guard chainID > 0 else { return Estimate(info: nil, nextBaseFee: nil) }
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
                    return Estimate(info: nil, nextBaseFee: nil, endpointChainID: actualChainID)
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

    func fetchEstimate(network: EthereumNetwork) async throws -> Estimate {
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

    private func legacy(_ query: Query) async throws -> Estimate {
        Estimate(
            info: nil, nextBaseFee: nil, support: .legacy, gasPrice: try await gasPrice(for: query),
            endpointChainID: query.endpointChainID)
    }

    private func unknown(_ query: Query, currentBaseFee: BigUInt? = nil, nextBaseFee: BigUInt? = nil) async throws
        -> Estimate
    {
        Estimate(
            info: nil, nextBaseFee: nextBaseFee, currentBaseFee: currentBaseFee, support: .unknown,
            gasPrice: try await gasPrice(for: query), endpointChainID: query.endpointChainID)
    }

    private func eip1559(
        _ query: Query,
        history: EthereumFeeHistory?,
        currentBaseFee: BigUInt,
        nextBaseFee: BigUInt
    ) async throws -> Estimate {
        if let history, let info = Self.priorityInfo(from: history) {
            return Estimate(
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
            let info = Info.relative(
                to: Self.cappedAdoptedPriorityFee(
                    max(priority, PreparedTransactionFee.minimumPriorityFeePerGas), currentBaseFee: currentBaseFee))
        {
            return Estimate(
                info: info, nextBaseFee: nextBaseFee, currentBaseFee: currentBaseFee, support: .eip1559,
                endpointChainID: query.endpointChainID)
        }
        let gasPrice = try await gasPrice(for: query)
        let referencePriority = gasPrice.map {
            Self.cappedAdoptedPriorityFee(
                $0 > currentBaseFee ? $0 - currentBaseFee : PreparedTransactionFee.minimumPriorityFeePerGas,
                currentBaseFee: currentBaseFee)
        }
        return Estimate(
            info: referencePriority.flatMap(Info.relative(to:)), nextBaseFee: nextBaseFee,
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

    private static func priorityInfo(from history: EthereumFeeHistory) -> Info? {
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

        return Info(
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

    func value(for key: Key) -> EthereumFeeMarketSupport? {
        values.withLock { $0[key] }
    }

    func set(_ support: EthereumFeeMarketSupport, for key: Key) {
        guard support != .unknown else { return }
        values.withLock { $0[key] = support }
    }

    func removeAll() {
        values.withLock { $0.removeAll() }
    }
}

struct GasSpeedConfiguration {
    static let sliderSegmentWidth = 100.0
    static let recommendedSliderPosition = sliderSegmentWidth
    static let maximumSliderPosition =
        recommendedSliderPosition + sliderSegmentWidth

    private enum CurveIdentity: Equatable {
        case live
        case relative(referencePriorityFee: BigUInt)
    }

    private struct RelativeCurve: Equatable {
        let referencePriorityFee: BigUInt
        let info: GasService.Info?

        init(referencePriorityFee: BigUInt) {
            self.referencePriorityFee = referencePriorityFee
            self.info = GasService.Info.relative(to: referencePriorityFee)
        }
    }

    private enum CurveState: Equatable {
        case unresolved
        case transactionFallback(RelativeCurve)
        case verifiedLive(GasService.Info)
        case verifiedUnavailable
        case verifiedUnavailableWithFallback(RelativeCurve)

        var identity: CurveIdentity? {
            switch self {
            case .unresolved, .verifiedUnavailable:
                return nil
            case .transactionFallback(let curve),
                 .verifiedUnavailableWithFallback(let curve):
                return .relative(
                    referencePriorityFee: curve.referencePriorityFee
                )
            case .verifiedLive:
                return .live
            }
        }

        var info: GasService.Info? {
            switch self {
            case .unresolved, .verifiedUnavailable:
                return nil
            case .transactionFallback(let curve),
                 .verifiedUnavailableWithFallback(let curve):
                return curve.info
            case .verifiedLive(let info):
                return info
            }
        }
    }

    private struct SliderSelection: Equatable {
        let position: Double
        let priorityFee: BigUInt
    }

    private enum FetchedCurve: Equatable {
        case available(GasService.Info)
        case unavailable
    }

    private enum InteractionState: Equatable {
        case idle
        case active
        case activeWithPending(FetchedCurve)

        var isActive: Bool {
            self != .idle
        }
    }

    private enum FeeChoice: Equatable {
        case suggested
        case userSet
    }

    private enum SliderPositionState: Equatable {
        case derived
        case selected(SliderSelection)
    }

    private struct CurvePresentation: Equatable {
        let identity: CurveIdentity?
        let info: GasService.Info?
        let sliderPosition: SliderPositionState
    }

    var info: GasService.Info? {
        curveState.info
    }

    var didUserSetFee: Bool {
        feeChoice == .userSet
    }

    func speedPriorityFeePerGas(
        for transaction: Transaction
    ) -> BigUInt? {
        guard let preparedFee = transaction.preparedFee else { return nil }
        switch preparedFee {
        case .eip1559(let priorityFee, _):
            return priorityFee
        case .legacy(let gasPrice):
            guard let baseFee = transaction.feeBasisBaseFeePerGas,
                  gasPrice >= baseFee else {
                return nil
            }
            return gasPrice - baseFee
        }
    }

    private var curveState = CurveState.unresolved
    private var interactionState = InteractionState.idle
    private var feeChoice = FeeChoice.suggested
    private var sliderPositionState = SliderPositionState.derived

    @discardableResult
    mutating func installTransactionFallback(feePerGas: BigUInt) -> Bool {
        guard !feePerGas.isZero,
              interactionState == .idle else { return false }

        switch curveState {
        case .unresolved, .transactionFallback:
            break
        case .verifiedLive,
             .verifiedUnavailable,
             .verifiedUnavailableWithFallback:
            return false
        }

        let oldInfo = info
        curveState = .transactionFallback(
            RelativeCurve(referencePriorityFee: feePerGas)
        )
        return info != oldInfo
    }

    @discardableResult
    mutating func applyFetchedEstimate(_ estimate: GasService.Estimate) -> Bool {
        let fetchedCurve = estimate.info.map(FetchedCurve.available)
            ?? .unavailable

        switch interactionState {
        case .idle:
            return applyFetchedCurve(fetchedCurve)
        case .active, .activeWithPending:
            interactionState = .activeWithPending(fetchedCurve)
            return false
        }
    }

    mutating func markGasSliderInteraction() {
        guard interactionState == .idle else { return }
        interactionState = .active
    }

    @discardableResult
    mutating func endGasSliderInteraction(didChangeFee: Bool) -> Bool {
        if didChangeFee {
            feeChoice = .userSet
        }

        return endInteractionAndApplyPendingCurve()
    }

    mutating func markGasSliderFeeChange() {
        markGasSliderInteraction()
        feeChoice = .userSet
    }

    mutating func recordSelectedSliderPosition(
        _ position: Double,
        for transaction: Transaction
    ) {
        guard let info,
              let priorityFee = Transaction.priorityFee(
                  atSpeed: position,
                  inRelationTo: info
              ),
              transaction.speedPriorityFeePerGas == priorityFee,
              transaction.speedPriorityFeeSource == .slider else {
            sliderPositionState = .derived
            return
        }
        sliderPositionState = .selected(
            SliderSelection(
                position: position,
                priorityFee: priorityFee
            )
        )
    }

    mutating func synchronizeSelectedSliderPosition(
        with transaction: Transaction
    ) {
        guard let selection = validSliderSelection(for: transaction) else {
            sliderPositionState = .derived
            return
        }
        sliderPositionState = .selected(selection)
    }

    func sliderPosition(for transaction: Transaction) -> Double {
        if let selection = validSliderSelection(for: transaction) {
            return selection.position
        }
        guard let info else { return 0 }
        return transaction.currentFeeInRelationTo(info: info)
    }

    mutating func commitManualFee(
        _ fee: PreparedTransactionFee?,
        baseFeePerGas: BigUInt? = nil
    ) {
        _ = endInteractionAndApplyPendingCurve()
        feeChoice = .userSet
        sliderPositionState = .derived

        if case .verifiedLive = curveState {
            return
        }

        let reference: BigUInt?
        switch fee {
        case .legacy(let gasPrice):
            if let baseFeePerGas {
                reference = gasPrice > baseFeePerGas
                    ? gasPrice - baseFeePerGas
                    : nil
            } else {
                reference = gasPrice
            }
        case .eip1559(let maxPriorityFeePerGas, _):
            reference = maxPriorityFeePerGas
        case .none:
            reference = nil
        }

        guard let reference, !reference.isZero else {
            switch curveState {
            case .verifiedUnavailable,
                 .verifiedUnavailableWithFallback:
                curveState = .verifiedUnavailable
            case .unresolved,
                 .transactionFallback,
                 .verifiedLive:
                curveState = .unresolved
            }
            return
        }

        let relativeCurve = RelativeCurve(
            referencePriorityFee: reference
        )
        switch curveState {
        case .verifiedUnavailable,
             .verifiedUnavailableWithFallback:
            curveState = .verifiedUnavailableWithFallback(relativeCurve)
        case .unresolved,
             .transactionFallback,
             .verifiedLive:
            curveState = .transactionFallback(relativeCurve)
        }
    }

    mutating func commitAppliedEdits(
        _ edits: Transaction.Edits,
        from previousTransaction: Transaction,
        to transaction: Transaction
    ) {
        if edits.restoresSuggestedFee {
            commitSuggestedFee()
            return
        }
        guard transaction.preparedFee != previousTransaction.preparedFee ||
                transaction.feeProvenance !=
                    previousTransaction.feeProvenance else {
            return
        }
        commitManualFee(
            transaction.preparedFee,
            baseFeePerGas: transaction.feeBasisBaseFeePerGas
        )
    }

    @discardableResult
    mutating func commitSuggestedFee() -> Bool {
        let wasOverridden = interactionState.isActive || didUserSetFee
        feeChoice = .suggested
        sliderPositionState = .derived

        let curveChanged = endInteractionAndApplyPendingCurve()
        return wasOverridden || curveChanged
    }

    @discardableResult
    private mutating func endInteractionAndApplyPendingCurve() -> Bool {
        let pendingCurve: FetchedCurve?
        switch interactionState {
        case .idle, .active:
            pendingCurve = nil
        case .activeWithPending(let fetchedCurve):
            pendingCurve = fetchedCurve
        }

        interactionState = .idle
        guard let pendingCurve else { return false }
        return applyFetchedCurve(pendingCurve)
    }

    @discardableResult
    private mutating func applyFetchedCurve(
        _ fetchedCurve: FetchedCurve
    ) -> Bool {
        let previousPresentation = curvePresentation

        switch fetchedCurve {
        case .available(let fetchedInfo):
            curveState = .verifiedLive(fetchedInfo)
        case .unavailable:
            sliderPositionState = .derived
            switch curveState {
            case .transactionFallback(let relativeCurve),
                 .verifiedUnavailableWithFallback(let relativeCurve):
                curveState = .verifiedUnavailableWithFallback(relativeCurve)
            case .unresolved,
                 .verifiedLive,
                 .verifiedUnavailable:
                curveState = .verifiedUnavailable
            }
        }

        return curvePresentation != previousPresentation
    }

    private func validSliderSelection(
        for transaction: Transaction
    ) -> SliderSelection? {
        guard case .selected(let sliderSelection) = sliderPositionState,
              transaction.speedPriorityFeeSource == .slider,
              transaction.speedPriorityFeePerGas
                == sliderSelection.priorityFee,
              let info,
              Transaction.priorityFee(
                  atSpeed: sliderSelection.position,
                  inRelationTo: info
              ) == sliderSelection.priorityFee else {
            return nil
        }
        return sliderSelection
    }

    private var curvePresentation: CurvePresentation {
        CurvePresentation(
            identity: curveState.identity,
            info: curveState.info,
            sliderPosition: sliderPositionState
        )
    }
}
