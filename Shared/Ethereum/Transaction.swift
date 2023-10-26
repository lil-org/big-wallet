// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

struct Transaction {
    let from: String
    let to: String
    var nonce: String?
    var gasPrice: String?
    var gas: String?
    let value: String?
    let data: String
    
    var hasFee: Bool {
        return gas != nil && gasPrice != nil
    }
    
    var gasPriceGwei: Int? {
        guard let gasPrice = gasPrice, let decimal = NSDecimalNumber(hexString: gasPrice) else { return nil }
        let gwei = decimal.multiplying(byPowerOf10: -9)
        return gwei.intValue
    }
    
    func description(chain: EthereumNetwork, ethPrice: Double?) -> String {
        var result = [String]()
        if let value = valueWithSymbol(chain: chain, ethPrice: ethPrice, withLabel: false) {
            result.append(value)
        }
        result.append(feeWithSymbol(chain: chain, ethPrice: ethPrice))
        result.append(dataWithLabel)
        
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
        return "Data: " + data
    }
    
    func gasPriceWithLabel(chain: EthereumNetwork) -> String {
        let gwei: String
        if let gasPriceGwei = gasPriceGwei {
            gwei = String(gasPriceGwei) + (chain.symbolIsETH ? " Gwei" : "")
        } else {
            gwei = Strings.calculating
        }
        return "Gas price: " + gwei
    }
    
    func feeWithSymbol(chain: EthereumNetwork, ethPrice: Double?) -> String {
        let fee: String
        if let _ = gasPrice, let _ = gas {
            let a = Decimal() // TODO: toNormalizedDecimal(power: 18)
            let b = Decimal() // TODO: toDecimal()
            let c = NSDecimalNumber(decimal: a).multiplying(by: NSDecimalNumber(decimal: b))
            let costString = chain.hasUSDPrice ? cost(value: c, price: ethPrice) : ""
            fee = c.stringValue.prefix(7) + " \(chain.symbol)" + costString
        } else {
            fee = Strings.calculating
        }
        return "Fee: " + fee
    }
    
    func valueWithSymbol(chain: EthereumNetwork, ethPrice: Double?, withLabel: Bool) -> String? {
        guard let value = value else { return nil }
        let decimal = Decimal() // TODO: toNormalizedDecimal(power: 18)
        let decimalNumber = NSDecimalNumber(decimal: decimal)
        let costString = chain.hasUSDPrice ? cost(value: decimalNumber, price: ethPrice) : ""
        if let value = ethString(decimalNumber: decimalNumber) {
            let valueString = "\(value) \(chain.symbol)" + costString
            return withLabel ? "Value: " + valueString : valueString
        } else {
            return nil
        }
    }
    
    private func cost(value: NSDecimalNumber, price: Double?) -> String {
        guard let price = price else { return "" }
        let cost = value.multiplying(by: NSDecimalNumber(value: price))
        let formatter = NumberFormatter()
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = 1
        if let costString = formatter.string(from: cost) {
            return " ≈ $\(costString)"
        } else {
            return ""
        }
    }
    
    private func ethString(decimalNumber: NSDecimalNumber) -> String? {
        let formatter = NumberFormatter()
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = 12
        return formatter.string(from: decimalNumber)
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
        // TODO: update gasPrice hex with a new value
    }
    
    func currentGasInRelationTo(info: GasService.Info) -> Double {
        guard let gasPrice = gasPrice else { return 0 }
        
        let currentAsDecimal = Decimal() // TODO: gasPrice toDecimal()
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
