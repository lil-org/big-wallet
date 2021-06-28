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
    
    var meta: String {
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
        // TODO: implement
        gasPrice = nil
    }
    
    func currentGasInRelationTo(info: GasService.Info) -> Double {
        // TODO: implement
        return 100
    }
    
}
