import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Foundation

enum EthereumTransactionSigner {
    private static let eip1559TransactionType: UInt8 = 0x02

    static func signLegacy(chainID: Data,
                           nonce: Data,
                           gasPrice: Data,
                           gasLimit: Data,
                           toAddress: String,
                           privateKey: WalletPrivateKey,
                           amount: Data,
                           data: Data) -> Data? {
        let to: Data
        if toAddress.isEmpty {
            to = Data()
        } else {
            guard let parsedTo = EthereumCodec.parseAddress(toAddress) else { return nil }
            to = parsedTo
        }

        let chain = chainID.removingLeadingZeroBytes()
        let signingFields: [RLP.Item] = [
            RLP.integer(nonce),
            RLP.integer(gasPrice),
            RLP.integer(gasLimit),
            RLP.bytes(to),
            RLP.integer(amount),
            RLP.bytes(data),
            RLP.integer(chain),
            RLP.bytes(Data()),
            RLP.bytes(Data()),
        ]

        let digest = WalletCrypto.keccak256(data: RLP.encode(.list(signingFields)))
        guard let signature = privateKey.sign(digest: digest, coin: .ethereum), signature.count == 65 else { return nil }
        let recovery = UInt64(signature[signature.index(signature.startIndex, offsetBy: 64)])
        guard let v = legacySignatureV(chainID: chain, recovery: recovery) else { return nil }
        let signedFields: [RLP.Item] = [
            RLP.integer(nonce),
            RLP.integer(gasPrice),
            RLP.integer(gasLimit),
            RLP.bytes(to),
            RLP.integer(amount),
            RLP.bytes(data),
            RLP.integer(v),
            RLP.integer(signature.prefixData(32)),
            RLP.integer(Data(signature.dropFirst(32).prefix(32))),
        ]
        return RLP.encode(.list(signedFields))
    }

    static func signEIP1559(chainID: Data,
                            nonce: Data,
                            maxPriorityFeePerGas: Data,
                            maxFeePerGas: Data,
                            gasLimit: Data,
                            toAddress: String,
                            privateKey: WalletPrivateKey,
                            amount: Data,
                            data: Data,
                            accessList: [EthereumAccessListEntry]) -> Data? {
        guard let chain = normalizedUInt256(chainID),
              let normalizedNonce = normalizedUInt256(nonce),
              let normalizedMaxPriorityFeePerGas = normalizedUInt256(maxPriorityFeePerGas),
              let normalizedMaxFeePerGas = normalizedUInt256(maxFeePerGas),
              let normalizedGasLimit = normalizedUInt256(gasLimit),
              let normalizedAmount = normalizedUInt256(amount),
              BigUInt(data: normalizedMaxFeePerGas) >= BigUInt(data: normalizedMaxPriorityFeePerGas) else {
            return nil
        }

        let to: Data
        if toAddress.isEmpty {
            to = Data()
        } else {
            guard let parsedTo = EthereumCodec.parseAddress(toAddress) else { return nil }
            to = parsedTo
        }

        let accessListItem = RLP.Item.list(accessList.map { entry in
            .list([
                .bytes(entry.address),
                .list(entry.storageKeys.map(RLP.Item.bytes)),
            ])
        })
        let signingFields: [RLP.Item] = [
            RLP.integer(chain),
            RLP.integer(normalizedNonce),
            RLP.integer(normalizedMaxPriorityFeePerGas),
            RLP.integer(normalizedMaxFeePerGas),
            RLP.integer(normalizedGasLimit),
            RLP.bytes(to),
            RLP.integer(normalizedAmount),
            RLP.bytes(data),
            accessListItem,
        ]

        let signingPayload = Data([eip1559TransactionType]) + RLP.encode(.list(signingFields))
        let digest = WalletCrypto.keccak256(data: signingPayload)
        guard let signature = privateKey.sign(digest: digest, coin: .ethereum),
              signature.count == 65 else { return nil }
        let recovery = UInt64(signature[signature.index(signature.startIndex, offsetBy: 64)])
        guard let yParity = eip1559SignatureYParity(recovery: recovery) else { return nil }

        let signedFields = signingFields + [
            RLP.integer(yParity),
            RLP.integer(signature.prefixData(32)),
            RLP.integer(Data(signature.dropFirst(32).prefix(32))),
        ]
        return Data([eip1559TransactionType]) + RLP.encode(.list(signedFields))
    }

    static func legacySignatureV(chainID: Data, recovery: UInt64) -> Data? {
        guard recovery <= 1 else { return nil }
        let chain = chainID.removingLeadingZeroBytes()
        if chain.isEmpty {
            return BigUInt(27 + recovery).toData()
        }
        return ((BigUInt(data: chain) * BigUInt(2)) + BigUInt(35 + recovery)).toData()
    }

    static func eip1559SignatureYParity(recovery: UInt64) -> Data? {
        guard recovery <= 1 else { return nil }
        return BigUInt(recovery).toData()
    }

    private static func normalizedUInt256(_ value: Data) -> Data? {
        let normalized = value.removingLeadingZeroBytes()
        return normalized.count <= 32 ? normalized : nil
    }
}

