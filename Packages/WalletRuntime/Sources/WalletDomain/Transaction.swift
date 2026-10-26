// ∅ 2026 lil org

import Foundation

public enum TransactionFeeIntent: Equatable, Sendable {
    case automatic
    case legacy(gasPrice: BigUInt?)
    case eip1559(maxPriorityFeePerGas: BigUInt?, maxFeePerGas: BigUInt?)

    public var preparedFee: PreparedTransactionFee? {
        switch self {
        case .automatic:
            return nil
        case .legacy(let gasPrice):
            return gasPrice.map(PreparedTransactionFee.legacy)
        case .eip1559(
            let maxPriorityFeePerGas?,
            let maxFeePerGas?
        ):
            return .eip1559(
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                maxFeePerGas: maxFeePerGas
            )
        case .eip1559:
            return nil
        }
    }

    public var isEIP1559: Bool {
        if case .eip1559 = self {
            return true
        }
        return false
    }

    public var isStructurallyValid: Bool {
        switch self {
        case .automatic:
            return true
        case .legacy(let gasPrice):
            return gasPrice.map {
                Transaction.isValidUInt256($0)
            } ?? true
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            if let maxPriorityFeePerGas {
                guard Transaction.isValidUInt256(maxPriorityFeePerGas) else {
                    return false
                }
            }
            if let maxFeePerGas {
                guard Transaction.isValidUInt256(maxFeePerGas) else { return false }
            }
            if let maxPriorityFeePerGas, let maxFeePerGas {
                return maxFeePerGas >= maxPriorityFeePerGas
            }
            return true
        }
    }
}

public enum PreparedTransactionFee: Equatable, Sendable {
    case legacy(gasPrice: BigUInt)
    case eip1559(maxPriorityFeePerGas: BigUInt, maxFeePerGas: BigUInt)

    public static let minimumPriorityFeePerGas = BigUInt(1)

    public var intent: TransactionFeeIntent {
        switch self {
        case .legacy(let gasPrice):
            return .legacy(gasPrice: gasPrice)
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            return .eip1559(
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                maxFeePerGas: maxFeePerGas
            )
        }
    }

    public var isEIP1559: Bool {
        if case .eip1559 = self {
            return true
        }
        return false
    }

    public var gasPrice: BigUInt? {
        guard case .legacy(let gasPrice) = self else { return nil }
        return gasPrice
    }

    public var maxPriorityFeePerGas: BigUInt? {
        guard case .eip1559(let maxPriorityFeePerGas, _) = self else { return nil }
        return maxPriorityFeePerGas
    }

    public var maxFeePerGas: BigUInt? {
        guard case .eip1559(_, let maxFeePerGas) = self else { return nil }
        return maxFeePerGas
    }

    public var feeCapPerGas: BigUInt {
        switch self {
        case .legacy(let gasPrice):
            return gasPrice
        case .eip1559(_, let maxFeePerGas):
            return maxFeePerGas
        }
    }

    public var isStructurallyValid: Bool {
        switch self {
        case .legacy(let gasPrice):
            return Transaction.isValidUInt256(gasPrice)
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            return Transaction.isValidUInt256(maxPriorityFeePerGas) &&
                Transaction.isValidUInt256(maxFeePerGas) &&
                maxFeePerGas >= maxPriorityFeePerGas
        }
    }

    public static func recommendedEIP1559(
        baseFeePerGas: BigUInt,
        maxPriorityFeePerGas: BigUInt
    ) -> PreparedTransactionFee? {
        guard Transaction.isValidUInt256(baseFeePerGas),
              Transaction.isValidUInt256(maxPriorityFeePerGas),
              maxPriorityFeePerGas >= minimumPriorityFeePerGas else { return nil }

        let maxFeePerGas = (baseFeePerGas * BigUInt(2)) + maxPriorityFeePerGas
        guard Transaction.isValidUInt256(maxFeePerGas) else { return nil }
        return .eip1559(
            maxPriorityFeePerGas: maxPriorityFeePerGas,
            maxFeePerGas: maxFeePerGas
        )
    }

    public func effectivePriorityFeePerGas(baseFeePerGas: BigUInt) -> BigUInt? {
        guard isStructurallyValid,
              Transaction.isValidUInt256(baseFeePerGas) else { return nil }

        switch self {
        case .legacy(let gasPrice):
            guard gasPrice >= baseFeePerGas else { return nil }
            return gasPrice - baseFeePerGas
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            guard maxFeePerGas >= baseFeePerGas else { return nil }
            return min(maxPriorityFeePerGas, maxFeePerGas - baseFeePerGas)
        }
    }

    public func effectiveGasPrice(baseFeePerGas: BigUInt?) -> BigUInt? {
        guard isStructurallyValid else { return nil }

        switch self {
        case .legacy(let gasPrice):
            return gasPrice
        case .eip1559:
            guard let baseFeePerGas,
                  let effectivePriorityFee = effectivePriorityFeePerGas(
                      baseFeePerGas: baseFeePerGas
                  ) else { return nil }
            return baseFeePerGas + effectivePriorityFee
        }
    }

    public func hasSufficientEffectivePriorityFee(
        baseFeePerGas: BigUInt,
        minimum: BigUInt = BigUInt()
    ) -> Bool {
        guard Transaction.isValidUInt256(minimum),
              let effectivePriorityFee = effectivePriorityFeePerGas(
                  baseFeePerGas: baseFeePerGas
              ) else { return false }
        return effectivePriorityFee >= minimum
    }

    public func estimatedNetworkFee(
        gasLimit: BigUInt,
        baseFeePerGas: BigUInt?
    ) -> BigUInt? {
        guard Transaction.isValidUInt256(gasLimit),
              let effectiveGasPrice = effectiveGasPrice(baseFeePerGas: baseFeePerGas)
        else { return nil }
        return Self.checkedUInt256Product(gasLimit, effectiveGasPrice)
    }

    public func maximumNetworkFee(gasLimit: BigUInt) -> BigUInt? {
        guard Transaction.isValidUInt256(gasLimit), isStructurallyValid else { return nil }
        return Self.checkedUInt256Product(gasLimit, feeCapPerGas)
    }

    public func maximumNetworkFeeFitsUInt256(gasLimit: BigUInt?) -> Bool {
        guard let gasLimit = gasLimit else { return true }
        return maximumNetworkFee(gasLimit: gasLimit) != nil
    }

    private static func checkedUInt256Product(_ lhs: BigUInt, _ rhs: BigUInt) -> BigUInt? {
        let product = lhs * rhs
        return Transaction.isValidUInt256(product) ? product : nil
    }
}

public enum TransactionFeeSource: String, Codable, Equatable, Sendable {
    case automatic
    case dapp
    case slider
    case manual

    public var isWalletManaged: Bool {
        self == .automatic || self == .slider
    }

    public var isUserControlled: Bool {
        !isWalletManaged
    }
}

public struct TransactionFeeProvenance: Codable, Equatable, Sendable {
    public var gasPrice: TransactionFeeSource?
    public var maxPriorityFeePerGas: TransactionFeeSource?
    public var maxFeePerGas: TransactionFeeSource?

    public init(
        gasPrice: TransactionFeeSource? = nil,
        maxPriorityFeePerGas: TransactionFeeSource? = nil,
        maxFeePerGas: TransactionFeeSource? = nil
    ) {
        self.gasPrice = gasPrice
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.maxFeePerGas = maxFeePerGas
    }

    public init(source: TransactionFeeSource, for fee: PreparedTransactionFee) {
        switch fee {
        case .legacy:
            self.init(gasPrice: source)
        case .eip1559:
            self.init(
                maxPriorityFeePerGas: source,
                maxFeePerGas: source
            )
        }
    }

    public func containsUserControlledValue(
        for fee: PreparedTransactionFee
    ) -> Bool {
        let fallbackSource = dominantSource(for: fee)
        switch fee {
        case .legacy:
            return (gasPrice ?? fallbackSource).isUserControlled
        case .eip1559:
            return (maxPriorityFeePerGas ?? fallbackSource)
                .isUserControlled ||
                (maxFeePerGas ?? fallbackSource).isUserControlled
        }
    }

    public var containsUserControlledValue: Bool {
        [gasPrice, maxPriorityFeePerGas, maxFeePerGas]
            .compactMap { $0 }
            .contains(where: \.isUserControlled)
    }

    public mutating func fillMissingSources(
        for fee: PreparedTransactionFee,
        with source: TransactionFeeSource
    ) {
        switch fee {
        case .legacy:
            gasPrice = gasPrice ?? source
            maxPriorityFeePerGas = nil
            maxFeePerGas = nil
        case .eip1559:
            gasPrice = nil
            maxPriorityFeePerGas = maxPriorityFeePerGas ?? source
            maxFeePerGas = maxFeePerGas ?? source
        }
    }

    public func dominantSource(for fee: PreparedTransactionFee?) -> TransactionFeeSource {
        let sources: [TransactionFeeSource]
        switch fee {
        case .some(.legacy):
            sources = [gasPrice].compactMap { $0 }
        case .some(.eip1559):
            sources = [maxPriorityFeePerGas, maxFeePerGas].compactMap { $0 }
        case .none:
            sources = [gasPrice, maxPriorityFeePerGas, maxFeePerGas].compactMap { $0 }
        }

        if sources.contains(.manual) { return .manual }
        if sources.contains(.dapp) { return .dapp }
        if sources.contains(.slider) { return .slider }
        return .automatic
    }
}

public struct Transaction: Sendable {

    private struct FeeState: Equatable, Sendable {

        private enum Backing: Equatable, Sendable {
            case unprepared(rawLegacyGasPrice: String?)
            case legacy(value: BigUInt, encoded: String)
            case eip1559(priority: BigUInt, cap: BigUInt)
        }

        private var backing: Backing
        var provenance: TransactionFeeProvenance

        init(
            rawLegacyGasPrice: String?,
            preparedFee: PreparedTransactionFee?,
            provenance: TransactionFeeProvenance
        ) {
            backing = Self.initialBacking(
                rawLegacyGasPrice: rawLegacyGasPrice,
                preparedFee: preparedFee
            )
            self.provenance = provenance
        }

        var preparedFee: PreparedTransactionFee? {
            switch backing {
            case .unprepared:
                return nil
            case .legacy(let value, _):
                return .legacy(gasPrice: value)
            case .eip1559(let priority, let cap):
                return .eip1559(
                    maxPriorityFeePerGas: priority,
                    maxFeePerGas: cap
                )
            }
        }

        var legacyGasPrice: String? {
            switch backing {
            case .unprepared(let rawLegacyGasPrice):
                return rawLegacyGasPrice
            case .legacy(_, let encoded):
                return encoded
            case .eip1559:
                return nil
            }
        }

        mutating func setPreparedFee(_ fee: PreparedTransactionFee?) {
            let previousFee = preparedFee
            backing = Self.canonicalBacking(for: fee)
            transitionProvenance(from: previousFee, to: fee)
        }

        mutating func setLegacyGasPrice(_ rawLegacyGasPrice: String?) {
            let previousFee = preparedFee
            guard let rawLegacyGasPrice,
                  let value = EthereumQuantity.parseUInt256(
                      rawLegacyGasPrice,
                      allowPrefixless: true
                  ) else {
                backing = .unprepared(
                    rawLegacyGasPrice: rawLegacyGasPrice
                )
                transitionProvenance(from: previousFee, to: nil)
                return
            }
            backing = .legacy(
                value: value,
                encoded: rawLegacyGasPrice
            )
            transitionProvenance(
                from: previousFee,
                to: .legacy(gasPrice: value)
            )
        }

        mutating func replace(
            preparedFee: PreparedTransactionFee,
            provenance: TransactionFeeProvenance
        ) {
            backing = Self.canonicalBacking(for: preparedFee)
            self.provenance = provenance
        }

        private mutating func transitionProvenance(
            from previousFee: PreparedTransactionFee?,
            to fee: PreparedTransactionFee?
        ) {
            guard let fee else {
                provenance = TransactionFeeProvenance()
                return
            }
            let fallbackSource = previousFee.map {
                provenance.dominantSource(for: $0)
            } ?? .automatic
            var nextProvenance: TransactionFeeProvenance
            switch previousFee {
            case .some(.legacy):
                nextProvenance = TransactionFeeProvenance(
                    gasPrice: provenance.gasPrice
                )
            case .some(.eip1559):
                nextProvenance = TransactionFeeProvenance(
                    maxPriorityFeePerGas:
                        provenance.maxPriorityFeePerGas,
                    maxFeePerGas: provenance.maxFeePerGas
                )
            case .none:
                nextProvenance = provenance
            }
            nextProvenance.fillMissingSources(
                for: fee,
                with: fallbackSource
            )
            provenance = nextProvenance
        }

        private static func initialBacking(
            rawLegacyGasPrice: String?,
            preparedFee: PreparedTransactionFee?
        ) -> Backing {
            guard let preparedFee else {
                return .unprepared(
                    rawLegacyGasPrice: rawLegacyGasPrice
                )
            }
            switch preparedFee {
            case .legacy(let value):
                let parsedGasPrice = rawLegacyGasPrice.flatMap {
                    EthereumQuantity.parseUInt256(
                        $0,
                        allowPrefixless: true
                    )
                }
                let encoded: String
                if let rawLegacyGasPrice,
                   parsedGasPrice == value {
                    encoded = rawLegacyGasPrice
                } else {
                    encoded = value.toHexString(withPrefix: true)
                }
                return .legacy(
                    value: value,
                    encoded: encoded
                )
            case .eip1559(let priority, let cap):
                return .eip1559(priority: priority, cap: cap)
            }
        }

        private static func canonicalBacking(
            for fee: PreparedTransactionFee?
        ) -> Backing {
            switch fee {
            case .some(.legacy(let value)):
                return .legacy(
                    value: value,
                    encoded: value.toHexString(withPrefix: true)
                )
            case .some(.eip1559(let priority, let cap)):
                return .eip1559(priority: priority, cap: cap)
            case .none:
                return .unprepared(rawLegacyGasPrice: nil)
            }
        }
    }

    public struct Edits: Equatable {
        public let preparedFee: PreparedTransactionFee?
        public let feeSource: TransactionFeeSource?
        public let replacementFeeProvenance: TransactionFeeProvenance?
        public let restoresSuggestedFee: Bool
        public let nonce: UInt?

        public init(gasPrice: BigUInt? = nil, nonce: UInt? = nil) {
            self.preparedFee = gasPrice.map(PreparedTransactionFee.legacy)
            self.feeSource = gasPrice == nil ? nil : .manual
            self.replacementFeeProvenance = nil
            self.restoresSuggestedFee = false
            self.nonce = nonce
        }

        public init(
            preparedFee: PreparedTransactionFee,
            source: TransactionFeeSource = .manual,
            replacementFeeProvenance: TransactionFeeProvenance? = nil,
            restoresSuggestedFee: Bool = false,
            nonce: UInt? = nil
        ) {
            self.preparedFee = preparedFee
            self.feeSource = source
            self.replacementFeeProvenance = replacementFeeProvenance
            self.restoresSuggestedFee = restoresSuggestedFee
            self.nonce = nonce
        }
    }

    public var id: UUID
    public let from: String
    public let to: String
    public var nonce: String?
    private var feeState: FeeState
    public var gas: String?
    public let value: String?
    public let data: String
    public var interpretation: String?
    public var externalInterpretation: String?
    public let feeIntent: TransactionFeeIntent
    public var accessList: [EthereumAccessListEntry]
    public var currentBaseFeePerGas: BigUInt?
    public var nextBaseFeePerGas: BigUInt?

    public var feeBasisBaseFeePerGas: BigUInt? {
        nextBaseFeePerGas ?? currentBaseFeePerGas
    }

    public var usesEIP1559Fees: Bool {
        preparedFee?.isEIP1559 == true || feeIntent.isEIP1559
    }

    public init(
        id: UUID = UUID(),
        from: String,
        to: String,
        nonce: String? = nil,
        gasPrice: String? = nil,
        gas: String? = nil,
        value: String?,
        data: String,
        interpretation: String? = nil,
        externalInterpretation: String? = nil,
        feeIntent: TransactionFeeIntent? = nil,
        preparedFee: PreparedTransactionFee? = nil,
        feeSource: TransactionFeeSource? = nil,
        feeProvenance: TransactionFeeProvenance? = nil,
        accessList: [EthereumAccessListEntry] = [],
        currentBaseFeePerGas: BigUInt? = nil,
        nextBaseFeePerGas: BigUInt? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.nonce = nonce
        self.gas = gas
        self.value = value
        self.data = data
        self.interpretation = interpretation
        self.externalInterpretation = externalInterpretation
        self.accessList = accessList
        self.currentBaseFeePerGas = currentBaseFeePerGas
        self.nextBaseFeePerGas = nextBaseFeePerGas

        let parsedGasPrice = gasPrice.flatMap(
            { EthereumQuantity.parseUInt256($0, allowPrefixless: true) }
        )
        let resolvedPreparedFee = preparedFee ?? parsedGasPrice.map(PreparedTransactionFee.legacy)

        let resolvedIntent: TransactionFeeIntent
        if let feeIntent {
            resolvedIntent = feeIntent
        } else if let preparedFee {
            resolvedIntent = preparedFee.intent
        } else if gasPrice != nil {
            resolvedIntent = .legacy(gasPrice: parsedGasPrice)
        } else {
            resolvedIntent = .automatic
        }
        self.feeIntent = resolvedIntent

        let resolvedProvenance: TransactionFeeProvenance
        if let feeProvenance {
            resolvedProvenance = feeProvenance
        } else {
            let requestedSource = feeSource ?? (gasPrice == nil ? .automatic : .dapp)
            var provenance = TransactionFeeProvenance()
            switch resolvedIntent {
            case .automatic:
                break
            case .legacy(let requestedGasPrice):
                if requestedGasPrice != nil {
                    provenance.gasPrice = requestedSource
                }
            case .eip1559(let requestedPriority, let requestedMaxFee):
                if requestedPriority != nil {
                    provenance.maxPriorityFeePerGas = requestedSource
                }
                if requestedMaxFee != nil {
                    provenance.maxFeePerGas = requestedSource
                }
            }
            if let resolvedPreparedFee {
                let sourceForCompletedFee: TransactionFeeSource
                if case .automatic = resolvedIntent {
                    sourceForCompletedFee = requestedSource
                } else {
                    sourceForCompletedFee = .automatic
                }
                provenance.fillMissingSources(
                    for: resolvedPreparedFee,
                    with: sourceForCompletedFee
                )
            }
            resolvedProvenance = provenance
        }
        self.feeState = FeeState(
            rawLegacyGasPrice: gasPrice,
            preparedFee: resolvedPreparedFee,
            provenance: resolvedProvenance
        )
    }

    public var preparedFee: PreparedTransactionFee? {
        get {
            feeState.preparedFee
        }
        set {
            feeState.setPreparedFee(newValue)
        }
    }

    public var gasPrice: String? {
        get {
            feeState.legacyGasPrice
        }
        set {
            feeState.setLegacyGasPrice(newValue)
        }
    }

    public var feeProvenance: TransactionFeeProvenance {
        get {
            feeState.provenance
        }
        set {
            feeState.provenance = newValue
        }
    }

    public var feeSource: TransactionFeeSource {
        get {
            feeProvenance.dominantSource(for: preparedFee)
        }
        set {
            guard let preparedFee else {
                feeProvenance = TransactionFeeProvenance()
                return
            }
            feeProvenance = TransactionFeeProvenance(source: newValue, for: preparedFee)
        }
    }

    public mutating func setPreparedFee(
        _ fee: PreparedTransactionFee,
        source: TransactionFeeSource,
        preservingExistingSources: Bool = true
    ) {
        var provenance = feeProvenance
        if preservingExistingSources {
            provenance.fillMissingSources(for: fee, with: source)
        } else {
            provenance = TransactionFeeProvenance(source: source, for: fee)
        }
        replacePreparedFee(fee, provenance: provenance)
    }

    public mutating func replacePreparedFee(
        _ fee: PreparedTransactionFee,
        provenance: TransactionFeeProvenance
    ) {
        feeState.replace(
            preparedFee: fee,
            provenance: provenance
        )
    }

    public mutating func replaceFeeProvenance(
        _ provenance: TransactionFeeProvenance
    ) {
        feeState.provenance = provenance
    }

    public mutating func copyFeeState(from transaction: Transaction) {
        feeState = transaction.feeState
    }

    public var decimalNonceString: String? {
        guard let nonce,
              EthereumQuantity.parseUInt256(
                  nonce,
                  allowPrefixless: true
              ) != nil,
              let number = UInt(hexString: nonce) else { return nil }
        return String(number)
    }
    
    public var gasPriceGwei: String? {
        gasPriceValue?.gwei
    }

    public var editableGasPriceGwei: String? {
        Self.editableGwei(fromWei: gasPriceValue)
    }

    public struct EditableFields: Equatable {
        public let nonce: String
        public let gasPriceGwei: String
        public let maxPriorityFeePerGasGwei: String
        public let maxFeePerGasGwei: String

        public init(nonce: String, gasPriceGwei: String, maxPriorityFeePerGasGwei: String, maxFeePerGasGwei: String) {
            self.nonce = nonce
            self.gasPriceGwei = gasPriceGwei
            self.maxPriorityFeePerGasGwei = maxPriorityFeePerGasGwei
            self.maxFeePerGasGwei = maxFeePerGasGwei
        }
    }

    public var editableFields: EditableFields {
        return EditableFields(
            nonce: nonce.flatMap {
                EthereumQuantity.parseUInt256($0, allowPrefixless: true)
            }?.description ?? "",
            gasPriceGwei: editableGasPriceGwei ?? "",
            maxPriorityFeePerGasGwei: Self.editableGwei(
                fromWei: maxPriorityFeePerGasValue
            ) ?? "",
            maxFeePerGasGwei: Self.editableGwei(
                fromWei: maxFeePerGasValue
            ) ?? ""
        )
    }

    public func edits(
        from fields: EditableFields,
        on chain: EthereumNetwork,
        resettingFeeTo suggestedFee: PreparedTransactionFee? = nil
    ) -> Edits? {
        var nonceEdit: UInt?
        if fields.nonce != editableFields.nonce {
            guard let nonce = UInt(fields.nonce) else { return nil }
            nonceEdit = nonce
        }

        var baseline = self
        if let suggestedFee {
            baseline.replacePreparedFee(
                suggestedFee,
                provenance: TransactionFeeProvenance(
                    source: .automatic,
                    for: suggestedFee
                )
            )
        }
        let baselineFields = baseline.editableFields
        var provenance = baseline.feeProvenance
        let candidateFee: PreparedTransactionFee

        if suggestedFee?.isEIP1559 ?? usesEIP1559Fees {
            let priorityChanged = fields.maxPriorityFeePerGasGwei !=
                baselineFields.maxPriorityFeePerGasGwei
            let capChanged = fields.maxFeePerGasGwei !=
                baselineFields.maxFeePerGasGwei
            guard priorityChanged || capChanged || suggestedFee != nil else {
                return Edits(nonce: nonceEdit)
            }
            guard let priority = Self.exactFeeWei(
                fromGwei: fields.maxPriorityFeePerGasGwei
            ), let cap = Self.exactFeeWei(
                fromGwei: fields.maxFeePerGasGwei
            ) else { return nil }

            candidateFee = .eip1559(
                maxPriorityFeePerGas: priority,
                maxFeePerGas: cap
            )
            let editsSliderFee = (priorityChanged || capChanged) &&
                (provenance.maxPriorityFeePerGas == .slider ||
                    provenance.maxFeePerGas == .slider)
            if priorityChanged || editsSliderFee {
                provenance.maxPriorityFeePerGas = .manual
            }
            if capChanged || editsSliderFee {
                provenance.maxFeePerGas = .manual
            }
        } else {
            let gasPriceChanged = fields.gasPriceGwei != baselineFields.gasPriceGwei
            guard gasPriceChanged || suggestedFee != nil else {
                return Edits(nonce: nonceEdit)
            }
            guard let gasPrice = Self.exactFeeWei(fromGwei: fields.gasPriceGwei),
                  Self.isValidGasPrice(gasPrice, on: chain) else { return nil }
            candidateFee = .legacy(gasPrice: gasPrice)
            if gasPriceChanged {
                provenance = TransactionFeeProvenance(gasPrice: .manual)
            }
        }

        guard candidateFee.isStructurallyValid,
              feeBasisBaseFeePerGas.map({ candidateFee.feeCapPerGas >= $0 }) != false,
              candidateFee.maximumNetworkFeeFitsUInt256(gasLimit: gasLimitValue)
        else { return nil }
        guard candidateFee != preparedFee || provenance != feeProvenance else {
            return Edits(nonce: nonceEdit)
        }

        return Edits(
            preparedFee: candidateFee,
            source: provenance.dominantSource(for: candidateFee),
            replacementFeeProvenance: provenance,
            restoresSuggestedFee: suggestedFee == candidateFee &&
                provenance == TransactionFeeProvenance(
                    source: .automatic,
                    for: candidateFee
                ),
            nonce: nonceEdit
        )
    }

    public var maxPriorityFeePerGasValue: BigUInt? {
        preparedFee?.maxPriorityFeePerGas ?? {
            guard case .eip1559(let value, _) = feeIntent else { return nil }
            return value
        }()
    }

    public var maxFeePerGasValue: BigUInt? {
        preparedFee?.maxFeePerGas ?? {
            guard case .eip1559(_, let value) = feeIntent else { return nil }
            return value
        }()
    }

    public static func editableGwei(fromWei value: BigUInt?) -> String? {
        guard let value else { return nil }
        let division = value.quotientAndRemainder(dividingBy: 1_000_000_000)
        guard division.remainder > 0 else { return division.quotient.description }

        let paddedFraction = String(repeating: "0", count: 9 - String(division.remainder).count) + String(division.remainder)
        let fraction = paddedFraction.reversed().drop(while: { $0 == "0" }).reversed()
        return division.quotient.description + "." + String(fraction)
    }

    public var gasPriceValue: BigUInt? {
        preparedFee?.gasPrice
    }

    public var gasLimitValue: BigUInt? {
        gas.flatMap {
            EthereumQuantity.parseUInt256(
                $0,
                allowPrefixless: true
            )
        }
    }

    public var estimatedFeeValue: BigUInt? {
        guard let gasLimit = gasLimitValue,
              !gasLimit.isZero,
              let preparedFee else { return nil }

        return preparedFee.estimatedNetworkFee(
            gasLimit: gasLimit,
            baseFeePerGas: feeBasisBaseFeePerGas
        )
    }

    public var maximumFeeValue: BigUInt? {
        guard let gasLimit = gasLimitValue,
              !gasLimit.isZero,
              let preparedFee else { return nil }

        return preparedFee.maximumNetworkFee(gasLimit: gasLimit)
    }

    public func isReadyForApproval(on chain: EthereumNetwork) -> Bool {
        guard nonce.flatMap({
                  EthereumQuantity.parseUInt256(
                      $0,
                      allowPrefixless: true
                  )
              }) != nil,
              let gasLimit = gasLimitValue,
              !gasLimit.isZero,
              Self.isValidUInt256(gasLimit),
              let preparedFee,
              preparedFee.isStructurallyValid,
              preparedFee.maximumNetworkFee(gasLimit: gasLimit) != nil else {
            return false
        }

        if chain.rpcEndpoint.catalogFeeMarketSupport() == .eip1559 {
            guard feeBasisBaseFeePerGas != nil else { return false }
        }

        switch preparedFee {
        case .legacy(let gasPrice):
            guard accessList.isEmpty,
                  Self.isValidGasPrice(gasPrice, on: chain) else {
                return false
            }
            guard let feeBasisBaseFeePerGas else { return true }
            return preparedFee.hasSufficientEffectivePriorityFee(
                baseFeePerGas: feeBasisBaseFeePerGas
            )
        case .eip1559:
            guard let feeBasisBaseFeePerGas else { return true }
            return preparedFee.hasSufficientEffectivePriorityFee(
                baseFeePerGas: feeBasisBaseFeePerGas
            )
        }
    }

    public static let maximumUInt256 = BigUInt(
        data: Data(repeating: 0xff, count: 32)
    )

    public static func isValidUInt256(_ value: BigUInt) -> Bool {
        value <= maximumUInt256
    }

    public static func isValidGasPrice(_ gasPrice: BigUInt, on chain: EthereumNetwork) -> Bool {
        guard isValidUInt256(gasPrice) else { return false }
        return !chain.isEthMainnet || !gasPrice.isZero
    }
    
    @discardableResult
    public mutating func apply(_ edits: Edits) -> Bool {
        guard edits.preparedFee?.isStructurallyValid != false else { return false }

        let feeChanged = edits.preparedFee.map { $0 != preparedFee } ?? false
        let feeProvenanceChanged = edits.replacementFeeProvenance.map {
            $0 != feeProvenance
        } ?? false
        let nonceChanged = edits.nonce.map { $0 != nonce.flatMap(UInt.init(hexString:)) } ?? false
        guard feeChanged || feeProvenanceChanged || nonceChanged else { return false }

        if feeChanged || feeProvenanceChanged,
           let preparedFee = edits.preparedFee {
            if let replacementFeeProvenance =
                edits.replacementFeeProvenance {
                replacePreparedFee(
                    preparedFee,
                    provenance: replacementFeeProvenance
                )
            } else if feeChanged {
                applyEditedFee(
                    preparedFee,
                    sourceForChangedValues: edits.feeSource ?? .manual
                )
            }
        }
        if nonceChanged, let nonce = edits.nonce {
            self.nonce = String.hex(nonce)
        }
        id = UUID()
        return true
    }

    private mutating func applyEditedFee(
        _ fee: PreparedTransactionFee,
        sourceForChangedValues source: TransactionFeeSource
    ) {
        let previousFee = preparedFee
        let previousProvenance = feeProvenance
        let updatedProvenance: TransactionFeeProvenance

        switch (previousFee, fee) {
        case let (
            .some(.legacy(previousGasPrice)),
            .legacy(gasPrice)
        ):
            updatedProvenance = TransactionFeeProvenance(
                gasPrice: gasPrice == previousGasPrice
                    ? previousProvenance.gasPrice ?? source
                    : source
            )
        case let (
            .some(.eip1559(previousPriority, previousCap)),
            .eip1559(priority, cap)
        ):
            updatedProvenance = TransactionFeeProvenance(
                maxPriorityFeePerGas: priority == previousPriority
                    ? previousProvenance.maxPriorityFeePerGas ?? source
                    : source,
                maxFeePerGas: cap == previousCap
                    ? previousProvenance.maxFeePerGas ?? source
                    : source
            )
        default:
            updatedProvenance = TransactionFeeProvenance(
                source: source,
                for: fee
            )
        }
        replacePreparedFee(
            fee,
            provenance: updatedProvenance
        )
    }
    
    public mutating func setFeeForSpeed(
        value: Double,
        inRelationTo info: GasPriceInfo
    ) {
        guard let priorityFee = Self.interpolatedFee(
            at: value,
            inRelationTo: info
        ) else { return }

        switch preparedFee {
        case .some(.legacy):
            let gasPrice: BigUInt
            if let feeBasisBaseFeePerGas {
                gasPrice = feeBasisBaseFeePerGas + priorityFee
            } else {
                gasPrice = priorityFee
            }
            guard Self.isValidUInt256(gasPrice) else { return }
            setPreparedFee(
                .legacy(gasPrice: gasPrice),
                source: .slider,
                preservingExistingSources: false
            )
        case .some(.eip1559):
            guard let feeBasisBaseFeePerGas,
                  let fee = PreparedTransactionFee.recommendedEIP1559(
                      baseFeePerGas: feeBasisBaseFeePerGas,
                      maxPriorityFeePerGas: priorityFee
                  ) else { return }
            setPreparedFee(
                fee,
                source: .slider,
                preservingExistingSources: false
            )
        case .none:
            if case .legacy = feeIntent {
                let gasPrice = (feeBasisBaseFeePerGas ?? BigUInt()) + priorityFee
                guard Self.isValidUInt256(gasPrice) else { return }
                setPreparedFee(
                    .legacy(gasPrice: gasPrice),
                    source: .slider,
                    preservingExistingSources: false
                )
            } else {
                guard let feeBasisBaseFeePerGas,
                      let fee = PreparedTransactionFee.recommendedEIP1559(
                          baseFeePerGas: feeBasisBaseFeePerGas,
                          maxPriorityFeePerGas: priorityFee
                      ) else { return }
                setPreparedFee(
                    fee,
                    source: .slider,
                    preservingExistingSources: false
                )
            }
        }
    }

    public func currentFeeInRelationTo(info: GasPriceInfo) -> Double {
        guard let current = speedPriorityFeePerGas else { return 0 }
        return Self.sliderPosition(
            for: current,
            inRelationTo: info
        )
    }

    public var speedPriorityFeePerGas: BigUInt? {
        switch preparedFee {
        case .legacy(let gasPrice):
            if let feeBasisBaseFeePerGas, gasPrice >= feeBasisBaseFeePerGas {
                return gasPrice - feeBasisBaseFeePerGas
            }
            return gasPrice
        case .eip1559(let maxPriorityFeePerGas, _):
            return maxPriorityFeePerGas
        case .none:
            return nil
        }
    }

    public var speedPriorityFeeSource: TransactionFeeSource {
        switch preparedFee {
        case .some(.legacy):
            return feeProvenance.gasPrice ?? .automatic
        case .some(.eip1559):
            return feeProvenance.maxPriorityFeePerGas ?? .automatic
        case .none:
            switch feeIntent {
            case .legacy:
                return feeProvenance.gasPrice ?? .automatic
            case .eip1559:
                return feeProvenance.maxPriorityFeePerGas ?? .automatic
            case .automatic:
                return .automatic
            }
        }
    }

    public static func priorityFee(
        atSpeed value: Double,
        inRelationTo info: GasPriceInfo
    ) -> BigUInt? {
        interpolatedFee(
            at: value,
            inRelationTo: info
        )
    }

    private static func interpolatedFee(
        at value: Double,
        inRelationTo info: GasPriceInfo
    ) -> BigUInt? {
        let minimum = info.minimumSliderPriorityFee
        let recommended = info.recommendedPriorityFee
        let maximum = info.maximumSliderPriorityFee
        guard value.isFinite,
              value >= 0,
              value <= GasSpeedConfiguration.maximumSliderPosition,
              isValidUInt256(minimum),
              isValidUInt256(recommended),
              isValidUInt256(maximum),
              minimum <= recommended,
              recommended <= maximum
        else { return nil }

        switch value {
        case 0:
            return minimum
        case GasSpeedConfiguration.recommendedSliderPosition:
            return recommended
        case GasSpeedConfiguration.maximumSliderPosition:
            return maximum
        case ..<GasSpeedConfiguration.recommendedSliderPosition:
            return interpolatedFee(
                from: minimum,
                to: recommended,
                segmentPosition: value
            )
        default:
            return interpolatedFee(
                from: recommended,
                to: maximum,
                segmentPosition:
                    value - GasSpeedConfiguration.recommendedSliderPosition
            )
        }
    }

    private static func interpolatedFee(
        from lower: BigUInt,
        to upper: BigUInt,
        segmentPosition: Double
    ) -> BigUInt? {
        let segmentScale = sliderSegmentScale
        let scaledPosition = (
            segmentPosition * Double(segmentScale) /
                GasSpeedConfiguration.sliderSegmentWidth
        ).rounded()
        guard scaledPosition.isFinite,
              scaledPosition >= 0,
              scaledPosition <= Double(segmentScale),
              lower <= upper else { return nil }
        let segmentUnits = UInt32(scaledPosition)
        let distance = upper - lower
        let offset = interpolatedOffset(
            distance: distance,
            units: segmentUnits
        )
        let result = lower + offset
        return isValidUInt256(result) ? min(result, upper) : nil
    }
    
    public static func gasPriceWei(fromGwei text: String) -> BigUInt? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !text.isEmpty,
              parts.count <= 2,
              parts.allSatisfy({ part in
                  part.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
              }),
              parts.contains(where: { !$0.isEmpty }) else { return nil }

        let wholeText = parts[0].isEmpty ? String.zero : String(parts[0])
        guard let whole = BigUInt(decimalString: wholeText) else { return nil }
        var wei = whole * BigUInt(1_000_000_000)

        guard parts.count == 2, !parts[1].isEmpty else { return wei }
        let fraction = parts[1]
        let retained = fraction.prefix(9)
        let padded = String(retained) + String(repeating: "0", count: 9 - retained.count)
        guard let fractionalWei = BigUInt(decimalString: padded) else { return nil }
        wei = wei + fractionalWei

        let discarded = fraction.dropFirst(9)
        if let firstDiscarded = discarded.first {
            let followingHasValue = discarded.dropFirst().contains(where: { $0 != "0" })
            let retainedIsOdd = retained.last.map { $0.wholeNumberValue?.isMultiple(of: 2) == false } ?? false
            let shouldRoundUp = firstDiscarded > "5" ||
                (firstDiscarded == "5" && (followingHasValue || retainedIsOdd))
            if shouldRoundUp {
                wei = wei + BigUInt(1)
            }
        }
        return wei
    }

    public static func feeWei(fromGwei text: String) -> BigUInt? {
        guard let value = gasPriceWei(fromGwei: text),
              isValidUInt256(value) else { return nil }
        return value
    }
    
    private static let maximumExactGweiTextLength =
        editableGwei(fromWei: maximumUInt256)?.utf8.count ?? 0

    public static func exactFeeWei(fromGwei rawText: String) -> BigUInt? {
        let text = rawText.replacingOccurrences(of: ",", with: ".")
        guard text.utf8.count <= maximumExactGweiTextLength else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count < 2 || parts[1].count <= 9 else { return nil }
        return feeWei(fromGwei: text)
    }

    private static func sliderPosition(
        for current: BigUInt,
        inRelationTo info: GasPriceInfo
    ) -> Double {
        let minimum = info.minimumSliderPriorityFee
        let recommended = info.recommendedPriorityFee
        let maximum = info.maximumSliderPriorityFee
        guard isValidUInt256(minimum),
              isValidUInt256(recommended),
              isValidUInt256(maximum),
              minimum <= recommended,
              recommended <= maximum else { return 0 }

        if current == recommended {
            return GasSpeedConfiguration.recommendedSliderPosition
        } else if current <= minimum {
            return 0
        } else if current >= maximum {
            return GasSpeedConfiguration.maximumSliderPosition
        } else if current < recommended {
            return sliderSegmentPosition(
                numerator: current - minimum,
                denominator: recommended - minimum
            )
        }

        return GasSpeedConfiguration.recommendedSliderPosition +
            sliderSegmentPosition(
                numerator: current - recommended,
                denominator: maximum - recommended
            )
    }

    private static func sliderSegmentPosition(
        numerator: BigUInt,
        denominator: BigUInt
    ) -> Double {
        let units = closestSliderUnits(
            numerator: numerator,
            denominator: denominator
        )
        return Double(units) / Double(sliderSegmentScale) *
            GasSpeedConfiguration.sliderSegmentWidth
    }

    private static let sliderSegmentScale: UInt32 = 1_000_000

    private static func closestSliderUnits(
        numerator: BigUInt,
        denominator: BigUInt
    ) -> UInt32 {
        guard !denominator.isZero,
              numerator < denominator else { return sliderSegmentScale }

        var lower: UInt32 = 0
        var upper = sliderSegmentScale
        while lower < upper {
            let distance = UInt64(upper) - UInt64(lower)
            let midpoint = lower + UInt32(distance / 2)
            if interpolatedOffset(
                distance: denominator,
                units: midpoint
            ) < numerator {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }

        guard lower > 0 else { return lower }
        let lowerUnits = lower - 1
        let lowerFee = interpolatedOffset(
            distance: denominator,
            units: lowerUnits
        )
        let upperFee = interpolatedOffset(
            distance: denominator,
            units: lower
        )
        return numerator - lowerFee <= upperFee - numerator
            ? lowerUnits
            : lower
    }

    private static func interpolatedOffset(
        distance: BigUInt,
        units: UInt32
    ) -> BigUInt {
        (distance * BigUInt(UInt64(units))).quotientAndRemainder(
            dividingBy: sliderSegmentScale
        ).quotient
    }
    
}
