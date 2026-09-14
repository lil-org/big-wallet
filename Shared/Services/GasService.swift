// ∅ 2026 lil org

import Foundation

final class OneShotGate: @unchecked Sendable {

    private let lock = NSLock()
    private var isAvailable = true

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isAvailable else { return false }
        isAvailable = false
        return true
    }

}

final class GasService {

    struct Info: Equatable {
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

    struct Estimate: Equatable {
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

    private let rpc: EthereumFeeRPCClient

    init(rpc: EthereumFeeRPCClient = EthereumRPC()) {
        self.rpc = rpc
    }

    func fetchEstimate(
        endpoint: EthereumRPCEndpoint,
        chainID: Int? = nil,
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Estimate) -> Void
    ) {
        let completionGate = OneShotGate()
        let cacheKey = FeeMarketCapabilityCache.Key(
            chainID: chainID,
            endpointURL: endpoint.url.absoluteString
        )
        var resolvedEndpointChainID: BigUInt?

        func complete(_ estimate: Estimate) {
            guard completionGate.claim() else { return }
            DispatchQueue.main.async {
                guard cancellation?.isCancelled != true else { return }
                completion(estimate)
            }
        }

        func fetchGasPrice(
            completion: @escaping (BigUInt?) -> Void
        ) {
            rpc.fetchGasPrice(
                endpoint: endpoint,
                cancellation: cancellation
            ) { result in
                guard cancellation?.isCancelled != true else { return }
                guard case .success(let value) = result,
                      let gasPrice = Self.validQuantity(value) else {
                    completion(nil)
                    return
                }
                completion(gasPrice)
            }
        }

        func completeLegacy() {
            fetchGasPrice { gasPrice in
                complete(Estimate(
                    info: nil,
                    nextBaseFee: nil,
                    support: .legacy,
                    gasPrice: gasPrice,
                    endpointChainID: resolvedEndpointChainID
                ))
            }
        }

        func completeUnknown(
            currentBaseFee: BigUInt? = nil,
            nextBaseFee: BigUInt? = nil
        ) {
            fetchGasPrice { gasPrice in
                complete(Estimate(
                    info: nil,
                    nextBaseFee: nextBaseFee,
                    currentBaseFee: currentBaseFee,
                    support: .unknown,
                    gasPrice: gasPrice,
                    endpointChainID: resolvedEndpointChainID
                ))
            }
        }

        func completeIdentityFailure(actualChainID: BigUInt? = nil) {
            complete(Estimate(
                info: nil,
                nextBaseFee: nil,
                support: .unknown,
                endpointChainID: actualChainID
            ))
        }

        func finishEIP1559(
            history: EthereumFeeHistory?,
            currentBaseFee: BigUInt,
            nextBaseFee: BigUInt
        ) {
            if let history,
               let info = Self.priorityInfo(from: history) {
                complete(Estimate(
                    info: info,
                    nextBaseFee: nextBaseFee,
                    currentBaseFee: currentBaseFee,
                    support: .eip1559,
                    endpointChainID: resolvedEndpointChainID
                ))
                return
            }

            rpc.fetchMaxPriorityFeePerGas(
                endpoint: endpoint,
                cancellation: cancellation
            ) { priorityResult in
                guard cancellation?.isCancelled != true else { return }
                if case .success(let value) = priorityResult,
                   let priority = Self.validQuantity(value),
                   let info = Info.relative(
                       to: Self.cappedAdoptedPriorityFee(
                           max(
                               priority,
                               PreparedTransactionFee.minimumPriorityFeePerGas
                           ),
                           currentBaseFee: currentBaseFee
                       )
                   ) {
                    complete(Estimate(
                        info: info,
                        nextBaseFee: nextBaseFee,
                        currentBaseFee: currentBaseFee,
                        support: .eip1559,
                        endpointChainID: resolvedEndpointChainID
                    ))
                    return
                }

                fetchGasPrice { gasPrice in
                    let referencePriority = gasPrice.map {
                        Self.cappedAdoptedPriorityFee(
                            $0 > currentBaseFee
                                ? $0 - currentBaseFee
                                : PreparedTransactionFee
                                    .minimumPriorityFeePerGas,
                            currentBaseFee: currentBaseFee
                        )
                    }
                    complete(Estimate(
                        info: referencePriority.flatMap {
                            Info.relative(to: $0)
                        },
                        nextBaseFee: nextBaseFee,
                        currentBaseFee: currentBaseFee,
                        support: .eip1559,
                        gasPrice: gasPrice,
                        endpointChainID: resolvedEndpointChainID
                    ))
                }
            }
        }

        func inspectFeeHistory(
            for block: EthereumLatestBlock,
            knownSupport: EthereumFeeMarketSupport?
        ) {
            guard let blockNumber = block.number,
                  let parsedBlockNumber = Self.validQuantity(blockNumber) else {
                completeUnknown()
                return
            }

            let blockBaseFee: BigUInt?
            switch block.baseFeeField {
            case .encoded(let baseFeeHex):
                guard let baseFee = Self.validQuantity(baseFeeHex) else {
                    completeUnknown()
                    return
                }
                blockBaseFee = baseFee
            case .null:
                completeUnknown()
                return
            case .missing:
                blockBaseFee = nil
            }

            rpc.fetchFeeHistory(
                endpoint: endpoint,
                blockCount: Self.feeHistoryBlockCount,
                newestBlock: parsedBlockNumber.toHexString(withPrefix: true),
                rewardPercentiles: Self.rewardPercentiles,
                cancellation: cancellation
            ) { result in
                guard cancellation?.isCancelled != true else { return }
                switch result {
                case .success(let history):
                    guard let parsedHistoryFees = Self.baseFees(from: history)
                    else {
                        completeUnknown(
                            currentBaseFee: blockBaseFee,
                            nextBaseFee: blockBaseFee
                        )
                        return
                    }
                    guard let blockBaseFee else {
                        completeUnknown()
                        return
                    }
                    guard blockBaseFee == parsedHistoryFees.current else {
                        completeUnknown(currentBaseFee: blockBaseFee)
                        return
                    }
                    if resolvedEndpointChainID != nil {
                        Self.capabilityCache.set(.eip1559, for: cacheKey)
                    }
                    finishEIP1559(
                        history: history,
                        currentBaseFee: parsedHistoryFees.current,
                        nextBaseFee: parsedHistoryFees.next
                    )
                case .failure(let error):
                    if (error as? EthereumRPCError)?.isMethodNotFound == true {
                        if let blockBaseFee {
                            if resolvedEndpointChainID != nil {
                                Self.capabilityCache.set(
                                    .eip1559,
                                    for: cacheKey
                                )
                            }
                            finishEIP1559(
                                history: nil,
                                currentBaseFee: blockBaseFee,
                                nextBaseFee: blockBaseFee
                            )
                        } else if knownSupport != .eip1559 {
                            if resolvedEndpointChainID != nil {
                                Self.capabilityCache.set(.legacy, for: cacheKey)
                            }
                            completeLegacy()
                        } else {
                            completeUnknown(
                                currentBaseFee: blockBaseFee,
                                nextBaseFee: blockBaseFee
                            )
                        }
                    } else if knownSupport == .eip1559,
                              let blockBaseFee {
                        finishEIP1559(
                            history: nil,
                            currentBaseFee: blockBaseFee,
                            nextBaseFee: blockBaseFee
                        )
                    } else if knownSupport == .legacy,
                              blockBaseFee == nil {
                        completeLegacy()
                    } else {
                        completeUnknown(
                            currentBaseFee: blockBaseFee,
                            nextBaseFee: blockBaseFee
                        )
                    }
                }
            }
        }

        func startDetection(knownSupport: EthereumFeeMarketSupport?) {
            rpc.fetchLatestBlock(
                endpoint: endpoint,
                cancellation: cancellation
            ) { result in
                guard cancellation?.isCancelled != true else { return }
                switch result {
                case .success(let block):
                    inspectFeeHistory(
                        for: block,
                        knownSupport: knownSupport
                    )
                case .failure:
                    if knownSupport == .eip1559 {
                        completeUnknown()
                    } else {
                        completeLegacy()
                    }
                }
            }
        }

        let catalogObservation = endpoint.catalogFeeMarketObservation()

        guard let chainID else {
            startDetection(knownSupport: catalogObservation)
            return
        }
        guard chainID > 0 else {
            completeIdentityFailure()
            return
        }

        let expectedChainID = BigUInt(UInt64(chainID))
        rpc.fetchChainID(
            endpoint: endpoint,
            cancellation: cancellation
        ) { result in
            guard cancellation?.isCancelled != true else { return }
            guard case .success(let encodedChainID) = result,
                  let actualChainID = EthereumQuantity.parseUInt256(
                      encodedChainID
                  ) else {
                startDetection(knownSupport: catalogObservation)
                return
            }
            guard actualChainID == expectedChainID else {
                completeIdentityFailure(actualChainID: actualChainID)
                return
            }

            resolvedEndpointChainID = actualChainID
            let cachedSupport = Self.capabilityCache.value(for: cacheKey)
            let knownSupport: EthereumFeeMarketSupport?
            if catalogObservation == .eip1559 ||
                cachedSupport == .eip1559 {
                knownSupport = .eip1559
            } else {
                knownSupport = catalogObservation ?? cachedSupport
            }
            startDetection(knownSupport: knownSupport)
        }
    }

    func fetchEstimate(
        network: EthereumNetwork,
        cancellation: EthereumRequestCancellation? = nil,
        completion: @escaping (Estimate) -> Void
    ) {
        fetchEstimate(
            endpoint: network.rpcEndpoint,
            chainID: network.chainId,
            cancellation: cancellation,
            completion: completion
        )
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

private final class FeeMarketCapabilityCache: @unchecked Sendable {

    struct Key: Hashable {
        let chainID: Int?
        let endpointURL: String
    }

    private let lock = NSLock()
    private var values = [Key: EthereumFeeMarketSupport]()

    func value(for key: Key) -> EthereumFeeMarketSupport? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ support: EthereumFeeMarketSupport, for key: Key) {
        guard support != .unknown else { return }
        lock.lock()
        values[key] = support
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        values.removeAll()
        lock.unlock()
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
