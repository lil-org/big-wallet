import Foundation
import XCTest
import WalletDomain
@testable import WalletAuthority

@MainActor
final class EthereumSigningTests: XCTestCase {
    private let rpcURL = "https://rpc.example"
    private func endpoint(_ value: String) -> EthereumRPCEndpoint {
        .unauthenticated(URL(string: value)!)
    }
    private func makeNetwork(chainID: Int, rpcURL: String? = nil, mightShowPrice: Bool = false) -> EthereumNetwork {
        EthereumNetwork(chainId: chainID, name: "Test", symbol: "ETH", rpcEndpoint: endpoint(rpcURL ?? self.rpcURL), isTestnet: false, mightShowPrice: mightShowPrice, explorer: nil)
    }
    func testEthereumSignsCanonicalNonemptyAccessListFixedVector()
        async throws
    {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: try XCTUnwrap(
                    WalletCrypto.hexData(
                        "608dcb1742bb3fb7aec002074e3420e4fab7d00cced79ccdac53ed5b27138151"
                    )
                )
            )
        )
        let accessList = [
            try XCTUnwrap(
                EthereumAccessListEntry(
                    address:
                        "0x0000000000000000000000000000000000000101",
                    storageKeys: [
                        "0x" + String(repeating: "0", count: 64),
                        "0x" + String(repeating: "0", count: 60) + "60a7",
                    ]
                )
            ),
            try XCTUnwrap(
                EthereumAccessListEntry(
                    address:
                        "0x1111111111111111111111111111111111111111",
                    storageKeys: []
                )
            ),
        ]
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x3535353535353535353535353535353535353535",
            nonce: "0x6",
            gas: "0x186a0",
            value: "0x1",
            data: "0xdeadbeef",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: try XCTUnwrap(
                    BigUInt(hexString: "59682f00")
                ),
                maxFeePerGas: try XCTUnwrap(
                    BigUInt(hexString: "09502f9000")
                )
            ),
            feeSource: .dapp,
            accessList: accessList,
            currentBaseFeePerGas: 1,
            nextBaseFeePerGas: 1
        )
        let signedTransaction = try EthereumSigner.signedTransaction(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 8_453)
        ).get()

        XCTAssertEqual(
            signedTransaction,
            "0x02f8e5822105068459682f008509502f9000830186a09435353535353535353535353535353535353535350184deadbeeff872f859940000000000000000000000000000000000000101f842a00000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000060a7d6941111111111111111111111111111111111111111c080a014dd6d80870ac4a49e57ae811431fb78be23f11b96846631f823204cf892f6c9a026e1a1ce4bf3cc048eb39089271fc8e1bab0eb75e16630737e8f3fc827f4b1dd"
        )
    }

    func testSigningDistinguishesInvalidPrivateKeyFromInvalidTransaction() async throws {
        let privateKeyData = Data(repeating: 0xff, count: 32)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: privateKeyData))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(privateKeyData, coin: .ethereum))
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .legacy(gasPrice: 1),
            feeSource: .dapp
        )
        let network = makeNetwork(chainID: 100)
        XCTAssertTrue(transaction.isReadyForApproval(on: network))
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: network
            ),
            .failure(.failedToSign)
        )
    }

    func testSigningRejectsUnsafeType2Fee() async throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 305
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 306,
            nextBaseFeePerGas: 306
        )
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: makeNetwork(chainID: 100)
            ),
            .failure(.invalidTransaction)
        )
    }

    func testZeroEffectiveTipDappFeeSigns() async throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 306
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 306,
            nextBaseFeePerGas: 306
        )
        let signedTransaction = try EthereumSigner.signedTransaction(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 100)
        ).get()

        XCTAssertTrue(signedTransaction.hasPrefix("0x02"))
    }

    func testSigningRejectsLegacyFeeWithAccessList() async throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let accessListEntry = try XCTUnwrap(
            EthereumAccessListEntry(
                address: Data(repeating: 0, count: 20),
                storageKeys: []
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .legacy(gasPrice: 1),
            feeSource: .dapp,
            accessList: [accessListEntry]
        )
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: makeNetwork(chainID: 100)
            ),
            .failure(.invalidTransaction)
        )
    }

    func testSigningUsesOnlyAuthoritativeCatalogFeeMarketCapability()
        async throws
    {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let url = try XCTUnwrap(URL(string: rpcURL + "/hinted-send"))
        let checkedAt = ISO8601DateFormatter().string(from: Date())

        func network(
            support: EthereumFeeMarketSupport
        ) -> EthereumNetwork {
            EthereumNetwork(
                chainId: 100,
                name: "Hinted",
                symbol: "XDAI",
                rpcEndpoint: .catalog(
                    url,
                    alchemyNetwork: nil,
                    feeMarketHint: EthereumFeeMarketHint(
                        support: support,
                        checkedAt: checkedAt,
                        observedEndpoint: url.absoluteString
                    )
                ),
                isTestnet: false,
                mightShowPrice: false,
                explorer: nil
            )
        }

        let legacyTransaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0",
            gas: "5208",
            value: "0",
            data: "0x",
            preparedFee: .legacy(gasPrice: 1),
            feeSource: .dapp
        )
        let type2Transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 1
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 0,
            nextBaseFeePerGas: 0
        )
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: legacyTransaction,
                privateKey: privateKey,
                network: network(support: .eip1559)
            ),
            .failure(.invalidTransaction)
        )
        let signedTransaction = try EthereumSigner.signedTransaction(
            transaction: type2Transaction,
            privateKey: privateKey,
            network: network(support: .legacy)
        ).get()

        XCTAssertTrue(signedTransaction.hasPrefix("0x02"))
    }

    func testSigningRejectsUInt256MaximumFeeProduct() async throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x2",
            value: "0x0",
            data: "0x",
            preparedFee: .legacy(gasPrice: maximum),
            feeSource: .dapp
        )
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: makeNetwork(chainID: 1)
            ),
            .failure(.invalidTransaction)
        )
    }

    func testSigningRejectsZeroLegacyGasOnlyOnMainnet() async throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gasPrice: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x"
        )
        XCTAssertEqual(
            EthereumSigner.signedTransaction(
                transaction: transaction,
                privateKey: privateKey,
                network: makeNetwork(
                    chainID: EthereumNetwork.ethMainnetChainId
                )
            ),
            .failure(.invalidTransaction)
        )
        let signedTransaction = try EthereumSigner.signedTransaction(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 10)
        ).get()

        XCTAssertFalse(signedTransaction.isEmpty)
    }
}
