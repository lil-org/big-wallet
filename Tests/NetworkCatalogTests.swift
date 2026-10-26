import Foundation
import WalletDomain
import XCTest
@testable import Big_Wallet

@MainActor
final class NetworkCatalogResourceTests: XCTestCase {
    func testBundledCatalogInventoryAndEndpointDescriptors() async throws {
        let catalog = try NetworkCatalog.load(in: .main)
        let chainIds = catalog.records.map(\.chainId)
        let alchemyRecords = catalog.records.filter { $0.alchemyNetwork != nil }
        let fallbackRecords = catalog.records.filter { $0.fallbackRPCURL != nil }

        XCTAssertEqual(catalog.records.count, 184)
        XCTAssertEqual(Set(chainIds).count, 184)
        XCTAssertEqual(alchemyRecords.count, 131)
        XCTAssertEqual(fallbackRecords.count, 53)
        XCTAssertEqual(catalog.records.filter(\.isTestnet).count, 83)
        XCTAssertEqual(catalog.records.filter { !$0.isTestnet }.count, 101)
        XCTAssertTrue(catalog.records.allSatisfy(\.hasExactlyOneEndpoint))
        XCTAssertFalse(chainIds.contains(64240))
    }

    func testInvalidCatalogRecoversUnexpectedIDAndSuppressesItsCustomFallback() async throws {
        let unexpectedChainId = 987_654_321
        let invalidCatalogData = try JSONEncoder().encode([
            RuntimeTestCatalog.record(
                chainId: unexpectedChainId,
                name: " Invalid Network",
                alchemyNetwork: "unexpected-mainnet"
            ),
        ])
        var recoveredChainIds = Set<Int>()

        try RuntimeTestCatalog.withFixtureBundle(catalogData: invalidCatalogData) { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                guard case let NetworkCatalogLoadError.invalidCatalog(decodedChainIds) = error else {
                    XCTFail("Expected invalid catalog, got \(error)")
                    return
                }
                recoveredChainIds = decodedChainIds
            }
        }

        XCTAssertEqual(recoveredChainIds, [unexpectedChainId])

        let snapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(
                    chainId: unexpectedChainId,
                    name: "Dormant Unexpected Network",
                    rpcURL: "https://unexpected-custom.example"
                ),
                RuntimeTestCatalog.customRecord(
                    chainId: 64240,
                    name: "Custom 64240",
                    rpcURL: "https://custom-64240.example"
                ),
            ]
        )
        let customSnapshotCount = LockedTestValue(0)
        let resolver = NetworkResolver(
            catalog: nil,
            catalogOwnedChainIds: [1],
            decodedChainIds: recoveredChainIds,
            customSnapshot: {
                _ = customSnapshotCount.increment()
                return snapshot
            }
        )

        XCTAssertEqual(
            resolver.resolve(chainId: unexpectedChainId),
            .catalogOwnedButUnavailable
        )
        XCTAssertNil(resolver.rpcURL(chainId: unexpectedChainId))
        XCTAssertEqual(customSnapshotCount.value, 0)
        XCTAssertEqual(resolver.resolve(chainId: 64240).resolvedNetwork?.source, .custom)
        XCTAssertEqual(customSnapshotCount.value, 1)
    }

    func testCatalogLoaderThrowsForMissingAndInvalidResources() async throws {
        try RuntimeTestCatalog.withFixtureBundle { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(error as? NetworkCatalogLoadError, .missingResource)
            }
        }

        try RuntimeTestCatalog.withFixtureBundle(catalogData: Data("not-json".utf8)) { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(
                    error as? NetworkCatalogLoadError,
                    .invalidCatalog(decodedChainIds: [])
                )
            }
        }

        let invalidCatalogData = try JSONEncoder().encode([
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 1, fallbackRPCURL: "https://duplicate.example"),
        ])
        try RuntimeTestCatalog.withFixtureBundle(catalogData: invalidCatalogData) { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(
                    error as? NetworkCatalogLoadError,
                    .invalidCatalog(decodedChainIds: [1])
                )
            }
        }
    }

}
