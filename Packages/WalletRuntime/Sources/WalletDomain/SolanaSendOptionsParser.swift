import Foundation

public enum SolanaSendOptionsParser {
    private static let clusterHintOptionKeys = ["bigWalletCluster", "cluster"]

    public static func prepare(from rawOptions: [String: Any]?) -> Result<Solana.PreparedSendOptions, Solana.SendTransactionError> {
        let options = rawOptions ?? [:]
        switch clusterHint(from: options) {
        case .failure(let error):
            return .failure(error)
        case .success(let clusterHint):
            let parsedConfirmationCommitment: Solana.Commitment?
            switch confirmationCommitment(from: options) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                parsedConfirmationCommitment = value
            }

            var preflightCommitment: Solana.Commitment?
            var maxRetries: Int?
            var minContextSlot: Int?
            for (key, value) in options {
                switch key {
                case "skipPreflight":
                    guard let skipPreflight = value as? Bool, !skipPreflight else {
                        return .failure(.invalidSendOptions)
                    }
                case "preflightCommitment":
                    guard let rawValue = value as? String,
                          let commitment = Solana.Commitment(rawValue: rawValue) else {
                        return .failure(.invalidSendOptions)
                    }
                    preflightCommitment = commitment
                case "mode":
                    guard let mode = value as? String, mode == "serial" else {
                        return .failure(.invalidSendOptions)
                    }
                case "maxRetries":
                    guard let value = nonNegativeInt(from: value) else {
                        return .failure(.invalidSendOptions)
                    }
                    maxRetries = value
                case "minContextSlot":
                    guard let value = nonNegativeInt(from: value) else {
                        return .failure(.invalidSendOptions)
                    }
                    minContextSlot = value
                default:
                    continue
                }
            }

            return .success(Solana.PreparedSendOptions(
                clusterHint: clusterHint,
                preflightCommitment: preflightCommitment,
                maxRetries: maxRetries,
                minContextSlot: minContextSlot,
                confirmationCommitment: parsedConfirmationCommitment
            ))
        }
    }

    private static func clusterHint(from options: [String: Any]) -> Result<Solana.Cluster?, Solana.SendTransactionError> {
        var parsedHint: Solana.Cluster?
        for key in clusterHintOptionKeys {
            guard let value = options[key] else { continue }
            guard let rawValue = value as? String,
                  let cluster = Solana.Cluster(clusterHint: rawValue)
            else {
                return .failure(.invalidSendOptions)
            }

            if let parsedHint, parsedHint != cluster {
                return .failure(.invalidSendOptions)
            }
            parsedHint = cluster
        }

        return .success(parsedHint)
    }

    private static func confirmationCommitment(from options: [String: Any]) -> Result<Solana.Commitment?, Solana.SendTransactionError> {
        guard let value = options["commitment"] else { return .success(nil) }
        guard let rawValue = value as? String,
              let commitment = Solana.Commitment(rawValue: rawValue) else {
            return .failure(.invalidSendOptions)
        }
        return .success(commitment)
    }

    private static func nonNegativeInt(from value: Any) -> Int? {
        if value is Bool {
            return nil
        }

        if let intValue = value as? Int {
            return intValue >= 0 ? intValue : nil
        }

        guard let number = value as? NSNumber else {
            return nil
        }

        let doubleValue = number.doubleValue
        guard doubleValue >= 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(Int.max)
        else {
            return nil
        }

        return number.intValue
    }

}
