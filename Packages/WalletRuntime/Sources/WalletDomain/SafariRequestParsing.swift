// ∅ 2026 lil org

import Foundation

public enum TransactionParsingError: Error, Equatable, Sendable {
    case invalidParameters
    case unsupportedTransactionType
}

extension SafariRequest.Ethereum {
    
    public var message: Data? {
        if let dataString = parameters?["data"] as? String {
            if let data = WalletEncoding.hexData(string: dataString) {
                return data
            } else {
                return dataString.data(using: .utf8)
            }
        } else {
            return nil
        }
    }
    
    public var transactionParsingResult: Result<Transaction, TransactionParsingError> {
        do {
            return .success(try parsedTransaction())
        } catch let error as TransactionParsingError {
            return .failure(error)
        } catch {
            return .failure(.invalidParameters)
        }
    }

    private func parsedTransaction() throws -> Transaction {
        guard let parameters = parameters else {
            throw TransactionParsingError.invalidParameters
        }
        try validateTransactionSource(in: parameters)

        let data: String
        if parameters.keys.contains("data") {
            guard let suppliedData = parameters["data"] as? String,
                  WalletEncoding.hexData(
                      string: suppliedData.cleanEvenHex
                  ) != nil else {
                throw TransactionParsingError.invalidParameters
            }
            data = suppliedData
        } else {
            data = "0x"
        }
        guard let to = transactionDestination(parameters: parameters, data: data) else {
            throw TransactionParsingError.invalidParameters
        }

        let gas = try quantity(named: "gas", in: parameters)
        let value = try quantity(named: "value", in: parameters)
        let transactionType = try transactionType(in: parameters)
        let gasPrice = try quantity(named: "gasPrice", in: parameters)
        let maxFeePerGas = try quantity(named: "maxFeePerGas", in: parameters)
        let maxPriorityFeePerGas = try quantity(
            named: "maxPriorityFeePerGas",
            in: parameters
        )
        let transactionChainID = try quantity(named: "chainId", in: parameters)
        let accessList = try accessList(in: parameters)

        if let transactionChainID = transactionChainID.value?.value {
            guard let currentChainId,
                  currentChainId > 0,
                  transactionChainID == BigUInt(UInt64(currentChainId)) else {
                throw TransactionParsingError.invalidParameters
            }
        }

        let hasLegacyFee = gasPrice.isPresent
        let hasDynamicFee = maxFeePerGas.isPresent || maxPriorityFeePerGas.isPresent
        let hasAccessList = accessList.isPresent

        guard !(hasLegacyFee && hasDynamicFee) else {
            throw TransactionParsingError.invalidParameters
        }
        let dynamicFeeIntent = TransactionFeeIntent.eip1559(
            maxPriorityFeePerGas: maxPriorityFeePerGas.value?.value,
            maxFeePerGas: maxFeePerGas.value?.value
        )
        guard dynamicFeeIntent.isStructurallyValid else {
            throw TransactionParsingError.invalidParameters
        }

        let feeIntent: TransactionFeeIntent
        switch transactionType {
        case .some(.legacy):
            guard !hasDynamicFee, !hasAccessList else {
                throw TransactionParsingError.invalidParameters
            }
            feeIntent = .legacy(gasPrice: gasPrice.value?.value)
        case .some(.eip1559):
            guard !hasLegacyFee else {
                throw TransactionParsingError.invalidParameters
            }
            feeIntent = dynamicFeeIntent
        case .none:
            if hasLegacyFee {
                guard !hasDynamicFee, !hasAccessList else {
                    throw TransactionParsingError.invalidParameters
                }
                feeIntent = .legacy(gasPrice: gasPrice.value?.value)
            } else if hasDynamicFee || hasAccessList {
                feeIntent = dynamicFeeIntent
            } else {
                feeIntent = .automatic
            }
        case .some(.unsupported):
            throw TransactionParsingError.unsupportedTransactionType
        }
        guard feeIntent.isStructurallyValid else {
            throw TransactionParsingError.invalidParameters
        }

        return Transaction(
            from: address,
            to: to,
            nonce: nil,
            gasPrice: gasPrice.value?.encoded,
            gas: gas.value?.encoded,
            value: value.value?.encoded ?? String.hexPrefix,
            data: data,
            feeIntent: feeIntent,
            preparedFee: feeIntent.preparedFee,
            feeSource: .dapp,
            accessList: accessList.value ?? []
        )
    }

    private func validateTransactionSource(
        in parameters: [String: Any]
    ) throws {
        guard parameters.keys.contains("from") else { return }
        guard let suppliedAddress = parameters["from"] as? String,
              let suppliedAddressData = EthereumCodec.parseAddress(
                suppliedAddress
              ),
              let selectedAddressData = EthereumCodec.parseAddress(address),
              suppliedAddressData == selectedAddressData else {
            throw TransactionParsingError.invalidParameters
        }
    }

    private func transactionDestination(parameters: [String: Any], data: String) -> String? {
        let rawDestination = parameters["to"]
        if let destination = rawDestination as? String {
            guard !destination.isEmpty else {
                return hasContractCreationInitcode(data) ? "" : nil
            }
            return EthereumCodec.parseAddress(destination) == nil
                ? nil
                : destination
        }
        guard rawDestination == nil || rawDestination is NSNull else { return nil }
        return hasContractCreationInitcode(data) ? "" : nil
    }

    private func hasContractCreationInitcode(_ data: String) -> Bool {
        return WalletEncoding.isValidNonEmptyHexData(data)
    }

    private enum ParsedTransactionType {
        case legacy
        case eip1559
        case unsupported
    }

    private enum ParsedParameter<Value> {
        case absent
        case present(Value)

        var isPresent: Bool {
            if case .present = self { return true }
            return false
        }

        var value: Value? {
            guard case .present(let value) = self else { return nil }
            return value
        }
    }

    private struct ParsedQuantity {
        let encoded: String
        let value: BigUInt
    }

    private func transactionType(
        in parameters: [String: Any]
    ) throws -> ParsedTransactionType? {
        guard parameters.keys.contains("type") else {
            return nil
        }
        guard let rawValue = parameters["type"] as? String,
              let value = EthereumQuantity.parseUInt256(rawValue) else {
            throw TransactionParsingError.invalidParameters
        }

        switch value {
        case BigUInt(0):
            return .legacy
        case BigUInt(2):
            return .eip1559
        default:
            return .unsupported
        }
    }

    private func quantity(
        named name: String,
        in parameters: [String: Any]
    ) throws -> ParsedParameter<ParsedQuantity> {
        guard parameters.keys.contains(name) else {
            return .absent
        }
        guard let stringValue = parameters[name] as? String,
              let value = EthereumQuantity.parseUInt256(stringValue) else {
            throw TransactionParsingError.invalidParameters
        }
        return .present(
            ParsedQuantity(encoded: stringValue, value: value)
        )
    }

    private func accessList(
        in parameters: [String: Any]
    ) throws -> ParsedParameter<[EthereumAccessListEntry]> {
        guard parameters.keys.contains("accessList") else {
            return .absent
        }
        guard let rawEntries = parameters["accessList"] as? [Any] else {
            throw TransactionParsingError.invalidParameters
        }

        var entries = [EthereumAccessListEntry]()
        entries.reserveCapacity(rawEntries.count)
        for rawEntry in rawEntries {
            guard let entry = rawEntry as? [String: Any],
                  let address = entry["address"] as? String,
                  let storageKeys = entry["storageKeys"] as? [String],
                  let accessListEntry = EthereumAccessListEntry(
                      address: address,
                      storageKeys: storageKeys
                  ) else {
                throw TransactionParsingError.invalidParameters
            }
            entries.append(accessListEntry)
        }
        return .present(entries)
    }
    
    public var signatureAndMessage: (signature: Data, message: Data)? {
        if let signatureHexString = parameters?["signature"] as? String,
           let signatureData = WalletEncoding.hexData(string: signatureHexString),
           let messageHexString = parameters?["message"] as? String,
           let messageData = WalletEncoding.hexData(string: messageHexString) {
            return (signatureData, messageData)
        } else {
            return nil
        }
    }
    
    public var raw: String? {
        return parameters?["raw"] as? String
    }
    
}
