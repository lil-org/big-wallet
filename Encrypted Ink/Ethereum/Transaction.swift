// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift

struct Transaction {
    let from: String
    let to: String
    var nonce: String?
    var gasPrice: String?
    var gas: String?
    let value: String?
    let data: String
    
    var weiAmount: EthNumber {
        if let value = value {
            return EthNumber(hex: value)
        } else {
            return EthNumber(value: 0)
        }
    }
    
    var hasFee: Bool {
        return gas != nil && gasPrice != nil
    }
    
    var gasPriceGwei: Int? {
        guard let gasPrice = gasPrice,
              let currentAsDecimal = try? EthNumber(hex: gasPrice).value().toDecimal() else { return nil }
        let current = NSDecimalNumber(decimal: currentAsDecimal).uintValue / 1_000_000_000
        return Int(current)
    }
    
    func description(ethPrice: Double?) -> String {
        // TODO: use eth price
        
        let value = ethString(hex: try? weiAmount.value().toHexString())
        let fee: String
        if let gasPrice = gasPrice,
           let gas = gas,
           let a = try? EthNumber(hex: gasPrice).value().toNormalizedDecimal(power: 18),
           let b = try? EthNumber(hex: gas).value().toDecimal() {
            let c = NSDecimalNumber(decimal: a).multiplying(by: NSDecimalNumber(decimal: b))
            fee = c.stringValue.prefix(8) + " ETH"
        } else {
            fee = "Calculating…"
        }
        var result = [String]()
        if let value = value {
            result.append("\(value) ETH")
        }
        result.append("Fee: " + fee)
        result.append("Data: " + data)
        
        return result.joined(separator: "\n\n")
    }
    
    private func ethString(hex: String?) -> String? {
        guard let hex = hex, let decimal = try? EthNumber(hex: hex).value().toNormalizedDecimal(power: 18) else { return nil }
        let formatter = NumberFormatter()
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = 12
        return formatter.string(from: NSDecimalNumber(decimal: decimal))
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
        gasPrice = try? EthNumber(decimal: String(value)).value().toHexString()
    }
    
    func currentGasInRelationTo(info: GasService.Info) -> Double {
        guard let gasPrice = gasPrice,
              let currentAsDecimal = try? EthNumber(hex: gasPrice).value().toDecimal() else { return 0 }
        
        let current = NSDecimalNumber(decimal: currentAsDecimal).uintValue
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
