// ∅ 2026 lil org

import Foundation

struct Transaction {

    struct Edits: Equatable {
        let gasPrice: BigUInt?
        let nonce: UInt?

        init(gasPrice: BigUInt? = nil, nonce: UInt? = nil) {
            self.gasPrice = gasPrice
            self.nonce = nonce
        }

        var isEmpty: Bool {
            gasPrice == nil && nonce == nil
        }
    }

    var id = UUID()
    let from: String
    let to: String
    var nonce: String?
    var gasPrice: String?
    var gas: String?
    let value: String?
    let data: String
    var interpretation: String?
    var externalInterpretation: String?
    
    var diplayDataInterpretation: String? {
        let result = externalInterpretation?.appending("\n\n") ?? ""
        
        if let interpretation = interpretation {
            return result + interpretation
        } else if let nonEmptyDataWithLabel = nonEmptyDataWithLabel {
            return result + nonEmptyDataWithLabel
        } else {
            return externalInterpretation
        }
    }
    
    var hasFee: Bool {
        return gas != nil && gasPrice != nil
    }
    
    var decimalNonceString: String? {
        guard let nonce = nonce, let number = UInt(hexString: nonce) else { return nil }
        return String(number)
    }
    
    var gasPriceGwei: String? {
        gasPriceValue?.gwei
    }

    var editableGasPriceGwei: String? {
        guard let gasPriceValue else { return nil }
        let division = gasPriceValue.quotientAndRemainder(dividingBy: 1_000_000_000)
        guard division.remainder > 0 else { return division.quotient.description }

        let paddedFraction = String(repeating: "0", count: 9 - String(division.remainder).count) + String(division.remainder)
        let fraction = paddedFraction.reversed().drop(while: { $0 == "0" }).reversed()
        return division.quotient.description + "." + String(fraction)
    }

    var gasPriceValue: BigUInt? {
        gasPrice.flatMap(BigUInt.init(hexString:))
    }

    var gasPriceWei: UInt? {
        gasPrice.flatMap(UInt.init(hexString:))
    }

    func isReadyForApproval(on chain: EthereumNetwork) -> Bool {
        guard nonce.flatMap(UInt.init(hexString:)) != nil,
              let gasLimit = gas.flatMap(BigUInt.init(hexString:)),
              !gasLimit.isZero,
              let gasPriceValue else { return false }
        return Self.isValidGasPrice(gasPriceValue, on: chain)
    }

    static func isValidGasPrice(_ gasPrice: BigUInt, on chain: EthereumNetwork) -> Bool {
        // Legacy Ethereum transaction quantities are uint256 values. BigUInt is
        // intentionally unbounded, so enforce the protocol boundary separately.
        guard gasPrice.toData().count <= 32 else { return false }
        return !chain.isEthMainnet || !gasPrice.isZero
    }
    
    func description(chain: EthereumNetwork, price: Double?) -> String {
        var result = ["🌐 " + chain.name]
        if let value = valueWithSymbol(chain: chain, price: price, withLabel: false) {
            result.append(value)
        }
        result.append(feeWithSymbol(chain: chain, price: price))
        if let diplayDataInterpretation = diplayDataInterpretation {
            result.append(diplayDataInterpretation)
        }
        return result.joined(separator: "\n\n")
    }
    
    var nonEmptyDataWithLabel: String? {
        if data.count > 2 {
            return dataWithLabel
        } else {
            return nil
        }
    }
    
    var dataWithLabel: String {
        return "\(Strings.data): \(data)"
    }
    
    func gasPriceWithLabel(chain: EthereumNetwork) -> String {
        let gwei: String
        if let gasPriceGwei = gasPriceGwei {
            gwei = String(gasPriceGwei) + (chain.symbolIsETH ? " \(Strings.gwei)" : "")
        } else {
            gwei = Strings.calculating.withEllipsis
        }
        return "\(Strings.gasPrice): \(gwei)"
    }
    
    func feeWithSymbol(chain: EthereumNetwork, price: Double?) -> String {
        let feeString: String
        if let gasPriceString = gasPrice, let gasString = gas,
           let gasPrice = BigUInt(hexString: gasPriceString),
           let gas = BigUInt(hexString: gasString) {
            let fee = gas * gasPrice
            let costString = chain.mightShowPrice ? cost(value: fee, price: price) : ""
            feeString = fee.eth(shortest: true) + " \(chain.symbol)" + costString
        } else {
            feeString = Strings.calculating.withEllipsis
        }
        return "\(Strings.fee): " + feeString
    }
    
    mutating func setCustomNonce(value: UInt) {
        let newValue = String.hex(value)
        if newValue != nonce {
            id = UUID()
            nonce = newValue
        }
    }
    
    @discardableResult
    mutating func setCustomGasPriceGwei(value: Double) -> Bool {
        guard let wei = Self.roundedWei(fromGwei: value) else { return false }
        let hex = wei.hexString
        if gasPrice != hex {
            id = UUID()
            gasPrice = hex
        }
        return true
    }

    @discardableResult
    mutating func apply(_ edits: Edits) -> Bool {
        let gasPriceChanged = edits.gasPrice.map { $0 != gasPriceValue } ?? false
        let nonceChanged = edits.nonce.map { $0 != nonce.flatMap(UInt.init(hexString:)) } ?? false
        guard gasPriceChanged || nonceChanged else { return false }

        if gasPriceChanged, let gasPrice = edits.gasPrice {
            self.gasPrice = gasPrice.hexString
        }
        if nonceChanged, let nonce = edits.nonce {
            self.nonce = String.hex(nonce)
        }
        id = UUID()
        return true
    }
    
    func valueWithSymbol(chain: EthereumNetwork, price: Double?, withLabel: Bool) -> String? {
        guard let value = value, let value = BigUInt(hexString: value) else { return nil }
        let costString = chain.mightShowPrice ? cost(value: value, price: price) : ""
        let valueString = "\(value.eth()) \(chain.symbol)" + costString
        return withLabel ? "\(Strings.value): " + valueString : valueString
    }
    
    private func cost(value: BigUInt, price: Double?) -> String {
        guard let price = price else { return "" }
        let ethValue = value.ethDouble
        let cost = NSNumber(floatLiteral: price * ethValue)
        let formatter = NumberFormatter()
        if cost.uintValue > 0 {
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
        } else {
            formatter.minimumFractionDigits = 2
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 1
        }
        if let costString = formatter.string(from: cost) {
            let exactly = value.isZero || price.isZero
            let sign = exactly ? "=" : "≈"
            return " \(sign) $\(costString)"
        } else {
            return ""
        }
    }
    
    mutating func setGasPrice(value: Double, inRelationTo info: GasService.Info) {
        let tickValues = info.sliderValues
        let tickValuesCount = tickValues.count
        guard value >= 0, value <= 100, tickValuesCount > 1 else { return }
        
        if value.isZero, let min = tickValues.first {
            setGasPrice(value: min)
            return
        } else if value == 100, let max = tickValues.last {
            setGasPrice(value: max)
            return
        }
        
        let step = Double(100) / Double(tickValuesCount - 1)
        for i in 1..<tickValuesCount where value <= step * Double(i) {
            let partialStep = value - step * Double(i - 1)
            let previousTickValue = tickValues[i - 1]
            let nextTickValue = tickValues[i]
            guard let current = Self.interpolate(from: previousTickValue,
                                                 to: nextTickValue,
                                                 fraction: partialStep / step) else { return }
            setGasPrice(value: current)
            return
        }
    }

    private static func interpolate(from lower: UInt, to upper: UInt, fraction: Double) -> UInt? {
        guard lower <= upper, fraction.isFinite else { return nil }
        if fraction <= 0 { return lower }
        if fraction >= 1 { return upper }

        let distance = upper - lower
        let scaledDistance = fraction * Double(distance)
        guard scaledDistance.isFinite, scaledDistance > 0 else { return lower }

        // Values near UInt.max can round up to 2^UInt.bitWidth as Double, which
        // cannot be converted back to UInt. Handle that boundary first.
        if scaledDistance >= Double(distance) { return upper }
        let offset = UInt(scaledDistance)
        if offset >= distance { return upper }

        let (interpolated, overflow) = lower.addingReportingOverflow(offset)
        guard !overflow else { return upper }
        return min(interpolated, upper)
    }
    
    private mutating func setGasPrice(value: UInt) {
        gasPrice = String.hex(value)
    }

    private static func roundedWei(fromGwei value: Double) -> BigUInt? {
        guard value.isFinite, value >= 0 else { return nil }

        let rounding = NSDecimalNumberHandler(roundingMode: .bankers,
                                              scale: 0,
                                              raiseOnExactness: false,
                                              raiseOnOverflow: false,
                                              raiseOnUnderflow: false,
                                              raiseOnDivideByZero: false)
        let weiDecimal = NSDecimalNumber(value: value).multiplying(byPowerOf10: 9, withBehavior: rounding)
        guard weiDecimal != NSDecimalNumber.notANumber else { return nil }

        let roundedWei = weiDecimal.rounding(accordingToBehavior: rounding)
        guard roundedWei != NSDecimalNumber.notANumber else { return nil }
        return BigUInt(decimalString: roundedWei.stringValue)
    }

    static func gasPriceWei(fromGwei text: String) -> BigUInt? {
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
    
    func currentGasInRelationTo(info: GasService.Info) -> Double {
        guard let current = gasPriceWei else { return 0 }
        let tickValues = info.sliderValues
        let tickValuesCount = tickValues.count
        guard tickValuesCount > 1 else { return 0 }
        
        if current <= tickValues[0] {
            return 0
        } else if current >= tickValues[tickValuesCount - 1] {
            return 100
        }
        
        let step = Double(100) / Double(tickValuesCount - 1)
        
        for i in 1..<tickValuesCount where current < tickValues[i] {
            let partialStep = Double(current - tickValues[i - 1]) / Double(tickValues[i] - tickValues[i - 1])
            let fullSteps = Double(i - 1)
            return (fullSteps + partialStep) * step
        }
        
        return 0
    }
    
}
