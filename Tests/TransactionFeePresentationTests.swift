import Foundation
import XCTest
import WalletDomain
@testable import Big_Wallet

@MainActor
final class TransactionFeePresentationTests: XCTestCase {
    private let rpcURL = "https://rpc.example"
    private func endpoint(_ value: String) -> EthereumRPCEndpoint {
        .unauthenticated(URL(string: value)!)
    }
    private func makeNetwork(chainID: Int, rpcURL: String? = nil, mightShowPrice: Bool = false) -> EthereumNetwork {
        EthereumNetwork(chainId: chainID, name: "Test", symbol: "ETH", rpcEndpoint: endpoint(rpcURL ?? self.rpcURL), isTestnet: false, mightShowPrice: mightShowPrice, explorer: nil)
    }
    func testEIP1559FeeSummaryDisplaysOnlyMaximumFee() async throws {
        let chain = makeNetwork(
            chainID: EthereumNetwork.ethMainnetChainId,
            mightShowPrice: true
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gas: String.hex(21_000),
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: BigUInt(1_000_000_000),
                maxFeePerGas: BigUInt(10_000_000_000)
            ),
            currentBaseFeePerGas: BigUInt(1_000_000_000)
        )

        XCTAssertNotEqual(
            transaction.estimatedFeeValue,
            transaction.maximumFeeValue
        )
        let maximumFee = try XCTUnwrap(transaction.maximumFeeValue)
        let lines = transaction.feeSummaryLines(chain: chain, price: 200)
        let expectedPrefix =
            "\(Strings.fee): \(maximumFee.eth(shortest: true)) \(chain.symbol)"

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix(expectedPrefix))
        XCTAssertTrue(lines[0].contains("≈ $"))
    }

    func testEIP1559FeeSummaryDisplaysSingleCalculatingFee() async {
        let chain = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gas: String.hex(21_000),
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: nil
            )
        )

        XCTAssertEqual(
            transaction.feeSummaryLines(chain: chain, price: nil),
            ["\(Strings.fee): \(Strings.calculating.withEllipsis)"]
        )
    }

    func testLegacyFeeSummaryRemainsUnchanged() async {
        let chain = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0x3b9aca00",
            gas: String.hex(21_000),
            value: nil,
            data: "0x"
        )

        XCTAssertEqual(
            transaction.feeSummaryLines(chain: chain, price: nil),
            [
                transaction.feeWithSymbol(chain: chain, price: nil),
                transaction.gasPriceWithLabel(chain: chain),
            ]
        )
    }
}
