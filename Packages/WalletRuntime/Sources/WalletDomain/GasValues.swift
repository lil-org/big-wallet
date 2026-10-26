import Foundation

public struct GasPriceInfo: Equatable, Sendable {
    public let recommendedPriorityFee: BigUInt
    public let highPriorityFee: BigUInt

    public init(
        recommendedPriorityFee: BigUInt,
        highPriorityFee: BigUInt
    ) {
        precondition(recommendedPriorityFee <= highPriorityFee)
        self.recommendedPriorityFee = recommendedPriorityFee
        self.highPriorityFee = highPriorityFee
    }

    public var minimumSliderPriorityFee: BigUInt {
        max(
            PreparedTransactionFee.minimumPriorityFeePerGas,
            recommendedPriorityFee.quotientAndRemainder(
                dividingBy: 2
            ).quotient
        )
    }

    public var maximumSliderPriorityFee: BigUInt {
        min(
            highPriorityFee * BigUInt(2),
            Transaction.maximumUInt256
        )
    }

    public static func relative(
        to referencePriorityFee: BigUInt
    ) -> GasPriceInfo? {
        guard Transaction.isValidUInt256(referencePriorityFee),
              !referencePriorityFee.isZero else { return nil }
        return GasPriceInfo(
            recommendedPriorityFee: referencePriorityFee,
            highPriorityFee: referencePriorityFee
        )
    }
}
public struct GasEstimate: Equatable, Sendable {
    public let info: GasPriceInfo?
    public let nextBaseFee: BigUInt?
    public let currentBaseFee: BigUInt?
    public let support: EthereumFeeMarketSupport
    public let gasPrice: BigUInt?
    public let endpointChainID: BigUInt?

    public init(
        info: GasPriceInfo?,
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

    public var carriesBaseFeeData: Bool {
        currentBaseFee != nil || nextBaseFee != nil
    }

    public func applyBaseFeeContext(to transaction: inout Transaction) {
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

    public var recommendedEIP1559Fee: PreparedTransactionFee? {
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

    public func suggestedFee(
        for intent: TransactionFeeIntent
    ) -> PreparedTransactionFee? {
        switch (support, intent) {
        case (.eip1559, .automatic),
             (.eip1559, .eip1559):
            return recommendedEIP1559Fee
        case (.eip1559, .legacy):
            guard let baseFee = nextBaseFee ?? currentBaseFee,
                  let priorityFee = info?.recommendedPriorityFee,
                  let gasPrice = GasFeeMath.suggestedLegacyGasPrice(
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

public enum GasFeeMath {
    public static func suggestedLegacyGasPrice(
        baseFeePerGas: BigUInt,
        priorityFeePerGas: BigUInt
    ) -> BigUInt? {
        let headroom = baseFeePerGas.quotientAndRemainder(dividingBy: 8).quotient
        let gasPrice = baseFeePerGas + headroom + priorityFeePerGas
        return Transaction.isValidUInt256(gasPrice) ? gasPrice : nil
    }

}

public struct GasSpeedConfiguration {
    public init() {}
    public static let sliderSegmentWidth = 100.0
    public static let recommendedSliderPosition = sliderSegmentWidth
    public static let maximumSliderPosition =
        recommendedSliderPosition + sliderSegmentWidth

    private enum CurveIdentity: Equatable {
        case live
        case relative(referencePriorityFee: BigUInt)
    }

    private struct RelativeCurve: Equatable {
        let referencePriorityFee: BigUInt
        let info: GasPriceInfo?

        init(referencePriorityFee: BigUInt) {
            self.referencePriorityFee = referencePriorityFee
            self.info = GasPriceInfo.relative(to: referencePriorityFee)
        }
    }

    private enum CurveState: Equatable {
        case unresolved
        case transactionFallback(RelativeCurve)
        case verifiedLive(GasPriceInfo)
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

        var info: GasPriceInfo? {
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
        case available(GasPriceInfo)
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
        let info: GasPriceInfo?
        let sliderPosition: SliderPositionState
    }

    public var info: GasPriceInfo? {
        curveState.info
    }

    public var didUserSetFee: Bool {
        feeChoice == .userSet
    }

    public func speedPriorityFeePerGas(
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
    public mutating func installTransactionFallback(feePerGas: BigUInt) -> Bool {
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
    public mutating func applyFetchedEstimate(_ estimate: GasEstimate) -> Bool {
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

    public mutating func markGasSliderInteraction() {
        guard interactionState == .idle else { return }
        interactionState = .active
    }

    @discardableResult
    public mutating func endGasSliderInteraction(didChangeFee: Bool) -> Bool {
        if didChangeFee {
            feeChoice = .userSet
        }

        return endInteractionAndApplyPendingCurve()
    }

    public mutating func markGasSliderFeeChange() {
        markGasSliderInteraction()
        feeChoice = .userSet
    }

    public mutating func recordSelectedSliderPosition(
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

    public mutating func synchronizeSelectedSliderPosition(
        with transaction: Transaction
    ) {
        guard let selection = validSliderSelection(for: transaction) else {
            sliderPositionState = .derived
            return
        }
        sliderPositionState = .selected(selection)
    }

    public func sliderPosition(for transaction: Transaction) -> Double {
        if let selection = validSliderSelection(for: transaction) {
            return selection.position
        }
        guard let info else { return 0 }
        return transaction.currentFeeInRelationTo(info: info)
    }

    public mutating func commitManualFee(
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

    public mutating func commitAppliedEdits(
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
    public mutating func commitSuggestedFee() -> Bool {
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
