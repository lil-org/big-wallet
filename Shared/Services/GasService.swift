// ∅ 2026 lil org

import Foundation

final class GasService {

    struct Info: Equatable {
        // Keep these values in wei so they stay comparable with Transaction.gasPrice.
        let standard: UInt
        let slow: UInt
        let fast: UInt
        let rapid: UInt

        var sliderValues: [UInt] {
            [slow, standard, fast, rapid]
        }

        static func relative(to referenceGasPrice: UInt, minimumGasPrice: UInt? = nil) -> Info? {
            guard referenceGasPrice > 0 else { return nil }

            // A gas price must remain positive. A known next base fee is a stronger floor.
            let minimumGasPrice = max(minimumGasPrice ?? 1, 1)
            let standard = max(referenceGasPrice, minimumGasPrice)

            // Reserve one representable value for each of the two faster tiers.
            guard standard <= UInt.max - 2,
                  let rawSlow = scaled(standard, by: 85, roundingUp: false) else { return nil }

            let slow = max(rawSlow, minimumGasPrice)
            let minimumFast = standard + 1
            let proportionalFast = scaled(standard, by: 120, roundingUp: true) ?? minimumFast
            let fast = min(max(proportionalFast, minimumFast), UInt.max - 1)

            let minimumRapid = fast + 1
            let proportionalRapid = scaled(standard, by: 140, roundingUp: true) ?? minimumRapid
            let rapid = max(proportionalRapid, minimumRapid)

            guard slow <= standard,
                  standard < fast,
                  fast < rapid else { return nil }

            return Info(standard: standard, slow: slow, fast: fast, rapid: rapid)
        }

        private static func scaled(_ value: UInt, by percentage: UInt, roundingUp: Bool) -> UInt? {
            let quotient = value / 100
            let remainder = value % 100
            let (whole, wholeOverflow) = quotient.multipliedReportingOverflow(by: percentage)
            let (remainderProduct, remainderOverflow) = remainder.multipliedReportingOverflow(by: percentage)
            guard !wholeOverflow, !remainderOverflow else { return nil }

            let partial: UInt
            if roundingUp, remainderProduct > 0 {
                let (adjustedRemainder, adjustmentOverflow) = remainderProduct.addingReportingOverflow(99)
                guard !adjustmentOverflow else { return nil }
                partial = adjustedRemainder / 100
            } else {
                partial = remainderProduct / 100
            }

            let (result, overflow) = whole.addingReportingOverflow(partial)
            return overflow ? nil : result
        }
    }

    struct Estimate: Equatable {
        let info: Info?
        let nextBaseFee: UInt?
    }

    static let shared = GasService()
    private static let rewardPercentiles: [Double] = [10, 25, 50, 75]

    private final class CompletionGate {
        private let lock = NSLock()
        private var didComplete = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didComplete else { return false }
            didComplete = true
            return true
        }
    }

    private let rpc: EthereumFeeHistoryRPCClient

    init(rpc: EthereumFeeHistoryRPCClient = EthereumRPC()) {
        self.rpc = rpc
    }

    func fetchEstimate(rpcUrl: String, completion: @escaping (Estimate) -> Void) {
        let completionGate = CompletionGate()
        rpc.fetchFeeHistory(rpcUrl: rpcUrl,
                            blockCount: 10,
                            rewardPercentiles: Self.rewardPercentiles) { result in
            guard completionGate.claim() else { return }

            let estimate: Estimate
            switch result {
            case .success(let history):
                estimate = Self.estimate(from: history)
            case .failure:
                estimate = Estimate(info: nil, nextBaseFee: nil)
            }

            DispatchQueue.main.async {
                completion(estimate)
            }
        }
    }

    private static func estimate(from history: EthereumFeeHistory) -> Estimate {
        guard let nextBaseFeeHex = history.baseFeePerGas.last,
              let nextBaseFee = UInt(hexString: nextBaseFeeHex) else {
            return Estimate(info: nil, nextBaseFee: nil)
        }

        let info = info(from: history, nextBaseFee: nextBaseFee)
        return Estimate(info: info, nextBaseFee: nextBaseFee)
    }

    private static func info(from history: EthereumFeeHistory, nextBaseFee: UInt) -> Info? {
        let tierCount = rewardPercentiles.count
        guard let reward = history.reward,
              !reward.isEmpty,
              history.baseFeePerGas.count == reward.count + 1 else { return nil }

        var rows = [[UInt]]()
        rows.reserveCapacity(reward.count)
        for row in reward {
            guard row.count == tierCount else { return nil }
            let values = row.compactMap(UInt.init(hexString:))
            guard values.count == tierCount,
                  zip(values, values.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
            rows.append(values)
        }

        var tierValues = [UInt]()
        tierValues.reserveCapacity(tierCount)
        for column in rewardPercentiles.indices {
            let values = rows.map { $0[column] }.sorted()
            let upperMedian = values[values.count / 2]
            let (tierValue, overflow) = nextBaseFee.addingReportingOverflow(upperMedian)
            guard !overflow else { return nil }
            tierValues.append(tierValue)
        }

        let slow = tierValues[0]
        let standard = tierValues[1]
        let fast = tierValues[2]
        let rapid = tierValues[3]
        guard slow > 0,
              slow < standard,
              standard < fast,
              fast < rapid else { return nil }

        return Info(standard: standard, slow: slow, fast: fast, rapid: rapid)
    }
}

struct GasSpeedConfiguration {

    private enum TierSource: Equatable {
        case live
        case relative(referenceGasPrice: UInt)
    }

    private(set) var info: GasService.Info?
    private(set) var didUserSetGasPrice = false
    private var tierSource: TierSource?
    private var minimumGasPrice: UInt?
    private var isTierMappingFrozen = false

    @discardableResult
    mutating func installTransactionFallback(gasPrice: UInt) -> Bool {
        guard gasPrice > 0,
              !isTierMappingFrozen,
              tierSource != .live else { return false }

        let oldInfo = info
        tierSource = .relative(referenceGasPrice: gasPrice)
        info = GasService.Info.relative(to: gasPrice, minimumGasPrice: minimumGasPrice)
        return info != oldInfo
    }

    @discardableResult
    mutating func applyFetchedEstimate(_ estimate: GasService.Estimate) -> Bool {
        let previousMinimumGasPrice = minimumGasPrice
        if let nextBaseFee = estimate.nextBaseFee {
            minimumGasPrice = nextBaseFee
        }
        let didUpdateMinimumGasPrice = minimumGasPrice != previousMinimumGasPrice
        guard !isTierMappingFrozen else { return false }

        if let fetchedInfo = estimate.info {
            let changed = tierSource != .live || info != fetchedInfo
            tierSource = .live
            info = fetchedInfo
            return changed
        }

        guard case .relative(let referenceGasPrice) = tierSource else {
            return didUpdateMinimumGasPrice
        }
        let oldInfo = info
        info = GasService.Info.relative(to: referenceGasPrice, minimumGasPrice: minimumGasPrice)
        return info != oldInfo || didUpdateMinimumGasPrice
    }

    mutating func markGasSliderInteraction() {
        isTierMappingFrozen = true
    }

    mutating func markGasSliderGasPriceChange() {
        isTierMappingFrozen = true
        didUserSetGasPrice = true
    }

    mutating func commitManualGasPrice(_ gasPrice: UInt?) {
        isTierMappingFrozen = true
        didUserSetGasPrice = true
        guard tierSource != .live else { return }

        guard let gasPrice, gasPrice > 0 else {
            tierSource = nil
            info = nil
            return
        }

        tierSource = .relative(referenceGasPrice: gasPrice)
        info = GasService.Info.relative(to: gasPrice, minimumGasPrice: minimumGasPrice)
    }

    func mergingPreparedTransaction(_ prepared: Transaction, with current: Transaction) -> Transaction {
        guard didUserSetGasPrice, let currentGasPrice = current.gasPrice else { return prepared }
        var merged = prepared
        merged.gasPrice = currentGasPrice
        return merged
    }
}
