// ∅ 2026 lil org

import Foundation

extension SafariRequest.Ethereum {
    
    var message: Data? {
        if let dataString = parameters?["data"] as? String {
            if let data = WalletCrypto.hexData(string: dataString) {
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
        guard let parameters = parameters else { return nil }
        let data = (parameters["data"] as? String) ?? "0x"
        guard let to = transactionDestination(parameters: parameters, data: data) else { return nil }
        let value = (parameters["value"] as? String) ?? "0x"
        let gas = parameters["gas"] as? String
        let gasPrice = parameters["gasPrice"] as? String
        // type: '0x0'
        // maxFeePerGas: '0x2540be400',
        // maxPriorityFeePerGas: '0x3b9aca00',
        return Transaction(from: address, to: to, nonce: nil, gasPrice: gasPrice, gas: gas, value: value, data: data)
    }

    private func transactionDestination(parameters: [String: Any], data: String) -> String? {
        let rawDestination = parameters["to"]
        if let destination = rawDestination as? String {
            guard !destination.isEmpty else {
                return hasContractCreationInitcode(data) ? "" : nil
            }
            return destination
        }
        guard rawDestination == nil || rawDestination is NSNull else { return nil }
        return hasContractCreationInitcode(data) ? "" : nil
    }

    private func hasContractCreationInitcode(_ data: String) -> Bool {
        return WalletCrypto.isValidNonEmptyHexData(data)
    }
    
    var signatureAndMessage: (signature: Data, message: Data)? {
        if let signatureHexString = parameters?["signature"] as? String,
           let signatureData = WalletCrypto.hexData(string: signatureHexString),
           let messageHexString = parameters?["message"] as? String,
           let messageData = WalletCrypto.hexData(string: messageHexString) {
            return (signatureData, messageData)
        } else {
            return nil
        }
    }
    
    var raw: String? {
        return parameters?["raw"] as? String
    }
    
}
