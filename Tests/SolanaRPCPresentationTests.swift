import Foundation
import XCTest
import WalletDomain
@testable import Big_Wallet

final class SolanaRPCPresentationTests: XCTestCase {
    func testSolanaRPCSourcesUseAccurateDisplayNames() {
        XCTAssertEqual(Solana.Cluster.mainnetBeta.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.devnet.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.testnet.rpcSource, .publicFallback)
        XCTAssertEqual(Solana.RPCSource.alchemy.displayName, Strings.alchemyRPC)
        XCTAssertEqual(Solana.RPCSource.publicFallback.displayName, Strings.publicRPC)
    }
}
