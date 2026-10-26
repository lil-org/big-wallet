import Foundation
import WalletDomain

enum EthereumSigner {
    enum SigningFailure: Swift.Error, Equatable, Sendable {
        case invalidTransaction
        case failedToSign
    }

    static func signPersonalMessage(
        data: Data,
        privateKey: WalletPrivateKey
    ) throws -> String {
        guard let digest = prefixedDataHash(data: data) else { throw SigningFailure.failedToSign }
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    static func recover(signature: Data, message: Data) -> String? {
        guard let hash = Self.prefixedDataHash(data: message) else { return nil }
        return WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: hash)
    }
    
    private static func prefixedDataHash(data: Data) -> Data? {
        let prefixString = "\u{19}Ethereum Signed Message:\n" + String(data.count)
        guard let prefixData = prefixString.data(using: .utf8) else { return nil }
        return WalletCrypto.keccak256(parts: [prefixData, data])
    }
    
    private static func sign(digest: Data, privateKey: WalletPrivateKey) throws -> String {
        guard var signed = privateKey.sign(digest: digest, coin: .ethereum),
              signed.count == 65,
              signed[64] <= 1 else { throw SigningFailure.failedToSign }
        signed[64] += 27
        return WalletCrypto.hexString(data: signed).withHexPrefix
    }
    
    static func sign(typedData: String, privateKey: WalletPrivateKey) throws -> String {
        let digest = WalletCrypto.ethereumTypedDataDigest(messageJson: typedData)
        return try sign(digest: digest, privateKey: privateKey)
    }
    
    static func signedTransaction(
        transaction: Transaction,
        privateKey: WalletPrivateKey,
        network: EthereumNetwork
    ) -> Result<String, SigningFailure> {
        let parsedAmount: BigUInt?
        if transaction.value == nil || transaction.value == String.hexPrefix {
            parsedAmount = BigUInt()
        } else {
            parsedAmount = transaction.value.flatMap(
                {
                    EthereumQuantity.parseUInt256(
                        $0,
                        allowPrefixless: true
                    )
                }
            )
        }
        guard network.chainId > 0,
              transaction.isReadyForApproval(on: network),
              let nonce = transaction.nonce.flatMap(
                {
                    EthereumQuantity.parseUInt256(
                        $0,
                        allowPrefixless: true
                    )
                }
              ),
              let gasLimit = transaction.gasLimitValue,
              let amount = parsedAmount,
              let data = WalletCrypto.hexData(
                  string: transaction.data.cleanEvenHex
              ),
              let preparedFee = transaction.preparedFee,
              Transaction.isValidUInt256(amount) else {
            return .failure(.invalidTransaction)
        }

        let chainID = BigUInt(UInt64(network.chainId)).toData()
        let signedTransaction: Data?
        switch preparedFee {
        case .legacy(let gasPrice):
            signedTransaction = WalletCrypto.signEthereumTransaction(
                chainID: chainID,
                nonce: nonce.toData(),
                gasPrice: gasPrice.toData(),
                gasLimit: gasLimit.toData(),
                toAddress: transaction.to,
                privateKey: privateKey,
                amount: amount.toData(),
                data: data
            )
        case .eip1559(let maxPriorityFeePerGas, let maxFeePerGas):
            signedTransaction = WalletCrypto.signEthereumEIP1559Transaction(
                chainID: chainID,
                nonce: nonce.toData(),
                maxPriorityFeePerGas: maxPriorityFeePerGas.toData(),
                maxFeePerGas: maxFeePerGas.toData(),
                gasLimit: gasLimit.toData(),
                toAddress: transaction.to,
                privateKey: privateKey,
                amount: amount.toData(),
                data: data,
                accessList: transaction.accessList
            )
        }

        guard let signedTransaction else {
            return .failure(.failedToSign)
        }
        return .success(
            WalletCrypto.hexString(data: signedTransaction).withHexPrefix
        )
    }

    static func transactionHash(signedTransaction: String) -> String? {
        guard let data = WalletCrypto.hexData(signedTransaction), !data.isEmpty else {
            return nil
        }
        return WalletCrypto.hexString(
            data: WalletCrypto.keccak256(data: data)
        ).withHexPrefix
    }

}

