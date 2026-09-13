// ∅ 2026 lil org

import Foundation

enum DappApprovalDecision: Codable, Equatable, Sendable {

    struct AccountIdentity: Codable, Equatable, Sendable {
        let walletID: String
        let address: String
        let provider: InpageProvider
        let derivationPath: String

        init(
            walletID: String,
            address: String,
            provider: InpageProvider,
            derivationPath: String
        ) {
            self.walletID = walletID
            self.address = address
            self.provider = provider
            self.derivationPath = derivationPath
        }
    }

    struct AccountSelection: Codable, Equatable, Sendable {
        let accounts: [AccountIdentity]
        let ethereumChainID: String?

        init(accounts: [AccountIdentity], ethereumChainID: String?) {
            self.accounts = accounts
            self.ethereumChainID = ethereumChainID
        }
    }

    struct MessageApproval: Codable, Equatable, Sendable {
        let solanaCluster: Solana.Cluster?

        init(solanaCluster: Solana.Cluster?) {
            self.solanaCluster = solanaCluster
        }
    }

    enum TransactionFee: Codable, Equatable, Sendable {
        case legacy(gasPrice: String)
        case eip1559(maxPriorityFeePerGas: String, maxFeePerGas: String)

        private enum CodingKeys: String, CodingKey {
            case kind, gasPrice, maxPriorityFeePerGas, maxFeePerGas
        }

        private enum Kind: String, Codable {
            case legacy, eip1559
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .legacy:
                self = .legacy(
                    gasPrice: try container.decode(String.self, forKey: .gasPrice)
                )
            case .eip1559:
                self = .eip1559(
                    maxPriorityFeePerGas: try container.decode(
                        String.self,
                        forKey: .maxPriorityFeePerGas
                    ),
                    maxFeePerGas: try container.decode(
                        String.self,
                        forKey: .maxFeePerGas
                    )
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .legacy(let gasPrice):
                try container.encode(Kind.legacy, forKey: .kind)
                try container.encode(gasPrice, forKey: .gasPrice)
            case .eip1559(let priority, let maximum):
                try container.encode(Kind.eip1559, forKey: .kind)
                try container.encode(priority, forKey: .maxPriorityFeePerGas)
                try container.encode(maximum, forKey: .maxFeePerGas)
            }
        }
    }

    struct NetworkIdentity: Codable, Equatable, Sendable {

        enum Source: String, Codable, Equatable, Sendable {
            case alchemy, fallback, custom

            init(_ source: RPCSource) {
                switch source {
                case .alchemy:
                    self = .alchemy
                case .fallback:
                    self = .fallback
                case .custom:
                    self = .custom
                }
            }
        }

        let chainID: Int
        let source: Source
        let canonicalRPCURL: String
        let allowsAlchemyAuthorization: Bool

        init?(_ network: ResolvedEthereumNetwork) {
            guard network.network.chainId > 0,
                  let canonicalRPCURL = Self.canonicalRPCURL(
                    network.rpcURL
                  ) else { return nil }
            chainID = network.network.chainId
            source = .init(network.source)
            self.canonicalRPCURL = canonicalRPCURL
            allowsAlchemyAuthorization = network.allowsAlchemyAuthorization
        }

        fileprivate var isValid: Bool {
            guard chainID > 0,
                  let url = URL(string: canonicalRPCURL),
                  let normalized = Self.canonicalRPCURL(url) else {
                return false
            }
            return normalized == canonicalRPCURL
        }

        private static func canonicalRPCURL(_ url: URL) -> String? {
            guard var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ), let scheme = components.scheme?.lowercased(),
               let host = components.host?.lowercased(),
               !scheme.isEmpty,
               !host.isEmpty else { return nil }
            components.scheme = scheme
            components.host = host
            if (scheme == "http" && components.port == 80)
                || (scheme == "https" && components.port == 443) {
                components.port = nil
            }
            components.fragment = nil
            if components.percentEncodedPath.isEmpty {
                components.percentEncodedPath = "/"
            }
            return components.string
        }
    }

    struct TransactionExecution: Codable, Equatable, Sendable {
        let nonce: String
        let gasLimit: String
        let fee: TransactionFee
        let feeProvenance: TransactionFeeProvenance
        let feeBasisBaseFeePerGas: String?
        let reviewedNetwork: NetworkIdentity

        init?(
            _ transaction: Transaction,
            reviewedNetwork: ResolvedEthereumNetwork
        ) {
            guard let nonce = transaction.nonce.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let gasLimit = transaction.gas.flatMap({
                      EthereumQuantity.parseUInt256($0, allowPrefixless: true)
                  }),
                  let preparedFee = transaction.preparedFee,
                  let networkIdentity = NetworkIdentity(reviewedNetwork) else {
                return nil
            }
            self.nonce = nonce.toHexString(withPrefix: true)
            self.gasLimit = gasLimit.toHexString(withPrefix: true)
            switch preparedFee {
            case .legacy(let gasPrice):
                fee = .legacy(gasPrice: gasPrice.toHexString(withPrefix: true))
            case .eip1559(let priority, let maximum):
                fee = .eip1559(
                    maxPriorityFeePerGas: priority.toHexString(withPrefix: true),
                    maxFeePerGas: maximum.toHexString(withPrefix: true)
                )
            }
            feeProvenance = transaction.feeProvenance
            feeBasisBaseFeePerGas = transaction.feeBasisBaseFeePerGas?
                .toHexString(withPrefix: true)
            self.reviewedNetwork = networkIdentity
        }

        func applying(to action: SendTransactionAction) -> Transaction? {
            guard let currentNetwork = NetworkIdentity(action.resolvedNetwork),
                  reviewedNetwork == currentNetwork else { return nil }
            return applyingTransactionFields(to: action.transaction)
        }

        fileprivate var isValid: Bool {
            guard reviewedNetwork.isValid else { return false }
            return applyingTransactionFields(to: Transaction(
                from: "0x0000000000000000000000000000000000000000",
                to: "0x0000000000000000000000000000000000000000",
                value: "0x0",
                data: "0x"
            )) != nil
        }

        private func applyingTransactionFields(
            to transaction: Transaction
        ) -> Transaction? {
            guard Self.uint256(nonce) != nil,
                  let gasLimitValue = Self.uint256(gasLimit),
                  !gasLimitValue.isZero else { return nil }
            let preparedFee: PreparedTransactionFee
            switch fee {
            case .legacy(let gasPrice):
                guard let value = Self.uint256(gasPrice),
                      feeProvenance.maxPriorityFeePerGas == nil,
                      feeProvenance.maxFeePerGas == nil else { return nil }
                preparedFee = .legacy(gasPrice: value)
            case .eip1559(let priority, let maximum):
                guard let priorityValue = Self.uint256(priority),
                      let maximumValue = Self.uint256(maximum),
                      maximumValue >= priorityValue,
                      feeProvenance.gasPrice == nil else { return nil }
                preparedFee = .eip1559(
                    maxPriorityFeePerGas: priorityValue,
                    maxFeePerGas: maximumValue
                )
            }
            guard preparedFee.isStructurallyValid else { return nil }
            let feeBasis: BigUInt?
            if let rawFeeBasis = feeBasisBaseFeePerGas {
                guard let value = Self.uint256(rawFeeBasis) else { return nil }
                feeBasis = value
            } else {
                feeBasis = nil
            }
            var result = transaction
            result.nonce = nonce
            result.gas = gasLimit
            result.replacePreparedFee(
                preparedFee,
                provenance: feeProvenance
            )
            result.currentBaseFeePerGas = feeBasis
            result.nextBaseFeePerGas = nil
            return result
        }

        private static func uint256(_ value: String) -> BigUInt? {
            guard value.count <= 66 else { return nil }
            return EthereumQuantity.parseUInt256(value, allowPrefixless: true)
        }
    }

    case accountSelection(AccountSelection)
    case message(MessageApproval)
    case transaction(TransactionExecution)
    case addEthereumChain

    private enum CodingKeys: String, CodingKey {
        case kind, accountSelection, message, transaction
    }

    private enum Kind: String, Codable {
        case accountSelection, message, transactionV2,
             addEthereumChain
    }

    static let maximumEncodedBytes = 32 * 1024

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .accountSelection:
            self = .accountSelection(try container.decode(
                AccountSelection.self,
                forKey: .accountSelection
            ))
        case .message:
            self = .message(try container.decode(
                MessageApproval.self,
                forKey: .message
            ))
        case .transactionV2:
            self = .transaction(try container.decode(
                TransactionExecution.self,
                forKey: .transaction
            ))
        case .addEthereumChain:
            self = .addEthereumChain
        }
        guard isValid else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid decision")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "invalid decision")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accountSelection(let selection):
            try container.encode(Kind.accountSelection, forKey: .kind)
            try container.encode(selection, forKey: .accountSelection)
        case .message(let message):
            try container.encode(Kind.message, forKey: .kind)
            try container.encode(message, forKey: .message)
        case .transaction(let transaction):
            try container.encode(Kind.transactionV2, forKey: .kind)
            try container.encode(transaction, forKey: .transaction)
        case .addEthereumChain:
            try container.encode(Kind.addEthereumChain, forKey: .kind)
        }
    }

    var boundedData: Data? {
        guard let data = try? JSONEncoder().encode(self),
              data.count <= Self.maximumEncodedBytes else { return nil }
        return data
    }

    static func decodeBounded(_ data: Data) -> Self? {
        guard !data.isEmpty,
              data.count <= maximumEncodedBytes else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    private var isValid: Bool {
        switch self {
        case .accountSelection(let selection):
            guard selection.accounts.count <= InpageProvider.allCases.count,
                  Set(selection.accounts.map(\.provider)).count ==
                    selection.accounts.count,
                  selection.accounts.allSatisfy({
                      !$0.walletID.isEmpty && $0.walletID.count <= 256 &&
                        !$0.address.isEmpty && $0.address.count <= 256 &&
                        !$0.derivationPath.isEmpty && $0.derivationPath.count <= 1_024 &&
                        $0.provider != .unknown && $0.provider != .multiple
                  }) else { return false }
            return selection.ethereumChainID.map {
                !$0.isEmpty && $0.count <= 128
            } ?? true
        case .message:
            return true
        case .transaction(let execution):
            return execution.isValid
        case .addEthereumChain:
            return true
        }
    }
}
