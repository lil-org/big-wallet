// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension SafariRequest.Ethereum {
    
    var message: Data? {
        if let dataString = parameters?["data"] as? String {
            if let data = Data(hexString: dataString) {
                return data
            } else {
                return dataString.data(using: .utf8)
            }
        } else {
            return nil
        }
    }
    
    // TODO: support new transaction type
    var transaction: Transaction? {
        if let parameters = parameters, let to = parameters["to"] as? String {
            let data = (parameters["data"] as? String) ?? "0x"
            let value = (parameters["value"] as? String) ?? "0x"
            let gas = parameters["gas"] as? String
            let gasPrice = parameters["gasPrice"] as? String
            // type: '0x0'
            // maxFeePerGas: '0x2540be400',
            // maxPriorityFeePerGas: '0x3b9aca00',
            return Transaction(from: address, to: to, nonce: nil, gasPrice: gasPrice, gas: gas, value: value, data: data)
        } else {
            return nil
        }
    }
    
    var signatureAndMessage: (signature: Data, message: Data)? {
        if let signatureHexString = parameters?["signature"] as? String,
           let signatureData = Data(hexString: signatureHexString),
           let messageHexString = parameters?["message"] as? String,
           let messageData = Data(hexString: messageHexString) {
            return (signatureData, messageData)
        } else {
            return nil
        }
    }
    
    var raw: String? {
        return parameters?["raw"] as? String
    }
    
}
