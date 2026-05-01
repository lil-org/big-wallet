// ∅ 2026 lil org

import Foundation

struct Transaction {
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
        guard let gasPrice = gasPrice, let value = BigUInt(hexString: gasPrice) else { return nil }
        return value.gwei
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
        let tickValues = info.sortedValues
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
            let current = previousTickValue + UInt((partialStep / step) * Double(nextTickValue - previousTickValue))
            setGasPrice(value: current)
            return
        }
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
    
    func currentGasInRelationTo(info: GasService.Info) -> Double {
        guard let gasPrice = gasPrice, let current = UInt(hexString: gasPrice) else { return 0 }
        let tickValues = info.sortedValues
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
