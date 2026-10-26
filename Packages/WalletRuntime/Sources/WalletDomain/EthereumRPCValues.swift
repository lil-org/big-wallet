import Foundation

public enum EthereumQuantity {

    private static let maximumHexQuantityDigits = 256

    public static func parseUInt256(
        _ value: String,
        allowPrefixless: Bool = false
    ) -> BigUInt? {
        let hasPrefix = value.hasPrefix(String.hexPrefix) || value.hasPrefix("0X")
        guard hasPrefix || allowPrefixless else { return nil }
        let prefixLength = hasPrefix ? String.hexPrefix.utf8.count : 0
        let digits = value.utf8.dropFirst(prefixLength)
        guard (1...maximumHexQuantityDigits).contains(digits.count),
              digits.allSatisfy({ byte in
                  (48...57).contains(byte)
                      || (65...70).contains(byte)
                      || (97...102).contains(byte)
              }),
              digits.drop(while: { $0 == 48 }).count <= 64 else {
            return nil
        }
        return BigUInt(hexString: value)
    }

}


public struct EthereumFeeHistory: Decodable, Equatable, Sendable {
    public let baseFeePerGas: [String]
    public let reward: [[String]]?

    public init(baseFeePerGas: [String], reward: [[String]]?) {
        self.baseFeePerGas = baseFeePerGas
        self.reward = reward
    }

    private enum CodingKeys: String, CodingKey {
        case baseFeePerGas, reward
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseFeePerGas = try container.decode([String].self, forKey: .baseFeePerGas)
        reward = try? container.decode([[String]].self, forKey: .reward)
    }
}


public struct EthereumLatestBlock: Decodable, Equatable, Sendable {

    public enum BaseFeeField: Equatable, Sendable {
        case missing
        case null
        case encoded(String)
    }

    public let number: String?
    public let baseFeeField: BaseFeeField

    public init(number: String?, baseFeeField: BaseFeeField) {
        self.number = number
        self.baseFeeField = baseFeeField
    }

    private enum CodingKeys: String, CodingKey {
        case number
        case baseFeePerGas
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(String.self, forKey: .number)
        if !container.contains(.baseFeePerGas) {
            baseFeeField = .missing
        } else if try container.decodeNil(forKey: .baseFeePerGas) {
            baseFeeField = .null
        } else {
            baseFeeField = .encoded(
                try container.decode(String.self, forKey: .baseFeePerGas)
            )
        }
    }
}


public enum EthereumRPCError: Error, Equatable, Sendable {
    case serverError(Int, String, dataJSON: String? = nil)
    case notSubmitted
    case unknown

    public var dataJSON: String? {
        guard case .serverError(_, _, let dataJSON) = self else { return nil }
        return dataJSON
    }

    public var isMethodNotFound: Bool {
        guard case .serverError(let code, _, _) = self else { return false }
        return code == -32_601
    }
}


public enum TransactionPreparationFailure: Swift.Error, Equatable, Sendable {
    case nonceUnavailable
    case gasPriceUnavailable
    case gasEstimationFailed
    case invalidTransaction
    case unsafeFees
}

public enum EthereumSendFailure: Swift.Error, Equatable, Sendable {
    case rpc(EthereumRPCError)
    case transport
}

public enum TransactionFeePreflightResult: Sendable {
    case safe(Transaction, GasEstimate)
    case walletManagedUpdated(Transaction, GasEstimate)
    case userControlledUnsafe(Transaction, GasEstimate)
    case unavailable(Transaction, GasEstimate)
}

public enum TransactionPreparationEvent: Sendable {
    case transactionUpdated(Transaction)
    case feeEstimate(GasEstimate)
    case ready(Transaction)
}

