// ∅ 2026 lil org

import CryptoKit
import Dispatch
import Foundation
import XCTest
@testable import Big_Wallet

final class NetworkCatalogTests: XCTestCase {

    func testCatalogInventoryGoldenSHA256() throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .map { String($0.chainId) }

        XCTAssertEqual(
            sha256(rows: rows),
            "b3eb33f4e72a267b87895d64dd2e72868e49f88a6db190efaae1cdaa896e2b25"
        )
    }

    func testCatalogAlchemyMappingGoldenSHA256() throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .compactMap { record -> String? in
                guard let alchemyNetwork = record.alchemyNetwork else { return nil }
                return "\(record.chainId)\t\(alchemyNetwork)"
            }

        XCTAssertEqual(
            sha256(rows: rows),
            "f6c0d0d20aa3bcb5a6c913ea65eaa821ed92724683d0be289817d0c04985816c"
        )
    }

    func testCatalogFallbackMappingGoldenSHA256() throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .compactMap { record -> String? in
                guard let fallbackRPCURL = record.fallbackRPCURL else { return nil }
                return "\(record.chainId)\t\(fallbackRPCURL)"
            }

        XCTAssertEqual(
            sha256(rows: rows),
            "665511e15a30321ff180683365e97931a354f3d2c2ddf1c2331ac21810ee2ef9"
        )
    }

    func testCatalogMetadataGoldenSHA256() throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .map { record in
                return [
                    String(record.chainId),
                    record.name,
                    record.nativeCurrency.name,
                    record.nativeCurrency.symbol,
                    String(record.nativeCurrency.decimals),
                    record.explorerURL ?? "<nil>",
                    String(record.isTestnet),
                    String(record.displayPrice),
                ].joined(separator: "\t")
            }

        XCTAssertEqual(
            sha256(rows: rows),
            "1017eb02c357fea08af83279c48e9931ad750da4ce8735e4311eae01f62e2913"
        )
    }

    func testCatalogSemanticInvariantsAndNetworkProjection() throws {
        let catalog = try loadedCatalog()
        let records = catalog.records
        let testAPIKey = "catalog-semantic-test-key"

        XCTAssertEqual(records.map(\.chainId), records.map(\.chainId).sorted())
        XCTAssertEqual(Set(records.map(\.chainId)).count, records.count)

        for record in records {
            XCTAssertGreaterThan(record.chainId, 0, "Invalid chain ID for \(record.name)")
            XCTAssertEqual(record.name, record.name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(record.name.isEmpty, "Missing name for chain \(record.chainId)")
            XCTAssertEqual(
                record.nativeCurrency.name,
                record.nativeCurrency.name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            XCTAssertFalse(record.nativeCurrency.name.isEmpty, "Missing currency name for chain \(record.chainId)")
            XCTAssertEqual(
                record.nativeCurrency.symbol,
                record.nativeCurrency.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            XCTAssertFalse(record.nativeCurrency.symbol.isEmpty, "Missing currency symbol for chain \(record.chainId)")
            XCTAssertTrue(
                (0...255).contains(record.nativeCurrency.decimals),
                "Invalid decimals for chain \(record.chainId)"
            )
            XCTAssertTrue(record.hasExactlyOneEndpoint, "Ambiguous endpoint for chain \(record.chainId)")

            let rpcURL = try XCTUnwrap(
                record.rpcURL(alchemyAPIKey: testAPIKey),
                "Could not resolve chain \(record.chainId)"
            )
            XCTAssertEqual(rpcURL.scheme, "https")
            XCTAssertNotNil(rpcURL.host)

            if let alchemyNetwork = record.alchemyNetwork {
                XCTAssertNil(record.fallbackRPCURL)
                XCTAssertNil(record.accountDisabledAlchemyNetwork)
                XCTAssertNotNil(
                    alchemyNetwork.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression),
                    "Invalid Alchemy slug for chain \(record.chainId)"
                )
                XCTAssertEqual(rpcURL.host, "\(alchemyNetwork).g.alchemy.com")
                XCTAssertEqual(rpcURL.path, "/v2/\(testAPIKey)")
            } else {
                XCTAssertEqual(rpcURL.absoluteString, record.fallbackRPCURL)
            }
            if let accountDisabledAlchemyNetwork = record.accountDisabledAlchemyNetwork {
                XCTAssertNil(record.alchemyNetwork)
                XCTAssertNotNil(record.fallbackRPCURL)
                XCTAssertNotNil(
                    accountDisabledAlchemyNetwork.range(
                        of: #"^[a-z0-9-]+$"#,
                        options: .regularExpression
                    )
                )
            }

            if let explorerURL = record.explorerURL {
                let explorer = try XCTUnwrap(URL(string: explorerURL))
                XCTAssertTrue(["http", "https"].contains(explorer.scheme?.lowercased() ?? ""))
                XCTAssertNotNil(explorer.host)
            }

            let network = record.ethereumNetwork(rpcURL: rpcURL)
            XCTAssertEqual(network.chainId, record.chainId)
            XCTAssertEqual(network.name, record.name)
            XCTAssertEqual(network.symbol, record.nativeCurrency.symbol)
            XCTAssertEqual(network.nodeURLString, rpcURL.absoluteString)
            XCTAssertEqual(network.isTestnet, record.isTestnet)
            XCTAssertEqual(network.mightShowPrice, record.displayPrice)
            XCTAssertEqual(network.explorer, record.explorerURL)
        }
    }

    func testEveryCatalogEndpointHasOneOwner() throws {
        let catalog = try loadedCatalog()
        var ownerByEndpoint: [String: Int] = [:]

        for record in catalog.records {
            let endpoint: String
            if let alchemyNetwork = record.alchemyNetwork {
                endpoint = "alchemy:\(alchemyNetwork)"
            } else {
                endpoint = "fallback:\(try XCTUnwrap(record.fallbackRPCURL))"
            }
            XCTAssertNil(
                ownerByEndpoint.updateValue(record.chainId, forKey: endpoint),
                "Endpoint \(endpoint) is assigned to more than one chain"
            )
        }

        XCTAssertEqual(ownerByEndpoint.count, catalog.records.count)
    }

    func testBundledNetworkOwnershipMatchesCatalogExactly() throws {
        let catalog = try loadedCatalog()
        let catalogChainIds = Set(catalog.records.map(\.chainId))

        XCTAssertEqual(BundledNetworkOwnership.chainIds, catalogChainIds)
        XCTAssertEqual(BundledNetworkOwnership.chainIds.count, 184)
        XCTAssertFalse(BundledNetworkOwnership.chainIds.contains(64240))
    }

    func testPinnedNetworkOrderRemainsStable() {
        XCTAssertEqual(
            Networks.pinned.map(\.chainId),
            [1, 7777777, 10, 8453, 42161]
        )
    }

    func testAcceptedConflictRecordsHaveExactOwnersAndMetadata() throws {
        let catalog = try loadedCatalog()
        let expectations: [Int: ConflictExpectation] = [
            300: ConflictExpectation(
                alchemyNetwork: "zksync-sepolia",
                name: "ZKsync Sepolia",
                symbol: "ETH",
                isTestnet: true
            ),
            998: ConflictExpectation(
                alchemyNetwork: "hyperliquid-testnet",
                name: "Hyperliquid Testnet",
                symbol: "HYPE",
                isTestnet: true
            ),
            999: ConflictExpectation(
                alchemyNetwork: "hyperliquid-mainnet",
                name: "Hyperliquid Mainnet",
                symbol: "HYPE",
                isTestnet: false
            ),
            6900: ConflictExpectation(
                alchemyNetwork: "anime-sepolia",
                name: "Anime Sepolia",
                symbol: "ANIME",
                isTestnet: true
            ),
            99999: ConflictExpectation(
                alchemyNetwork: "adi-testnet",
                name: "ADI Testnet AB",
                symbol: "ADI",
                isTestnet: true
            ),
        ]

        for (chainId, expectation) in expectations {
            let record = try XCTUnwrap(catalog.record(chainId: chainId))
            XCTAssertEqual(record.alchemyNetwork, expectation.alchemyNetwork)
            XCTAssertNil(record.fallbackRPCURL)
            XCTAssertEqual(record.name, expectation.name)
            XCTAssertEqual(record.nativeCurrency.symbol, expectation.symbol)
            XCTAssertEqual(record.isTestnet, expectation.isTestnet)
        }
    }

    func testBundledCatalogInventoryAndEndpointDescriptors() throws {
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

    func testAccountDisabledAlchemyNetworksAreExplicitFallbackExceptions() throws {
        let exceptions = try loadedCatalog().records.filter {
            $0.accountDisabledAlchemyNetwork != nil
        }

        XCTAssertEqual(exceptions.count, 1)
        let taiko = try XCTUnwrap(exceptions.first)
        XCTAssertEqual(taiko.chainId, 167000)
        XCTAssertEqual(taiko.accountDisabledAlchemyNetwork, "taiko-mainnet")
        XCTAssertEqual(taiko.fallbackRPCURL, "https://rpc.mainnet.taiko.xyz")
        XCTAssertNil(taiko.alchemyNetwork)
    }

    func testKaiaRecordsUseCurrentNetworkMetadata() throws {
        let catalog = try loadedCatalog()
        let kairos = try XCTUnwrap(catalog.record(chainId: 1001))
        let mainnet = try XCTUnwrap(catalog.record(chainId: 8217))

        XCTAssertEqual(kairos.name, "Kaia Kairos")
        XCTAssertEqual(kairos.nativeCurrency.name, "KAIA")
        XCTAssertEqual(kairos.nativeCurrency.symbol, "KAIA")
        XCTAssertEqual(kairos.explorerURL, "https://kairos.kaiascan.io")
        XCTAssertTrue(kairos.isTestnet)

        XCTAssertEqual(mainnet.name, "Kaia Mainnet")
        XCTAssertEqual(mainnet.nativeCurrency.name, "KAIA")
        XCTAssertEqual(mainnet.nativeCurrency.symbol, "KAIA")
        XCTAssertEqual(mainnet.explorerURL, "https://kaiascan.io")
        XCTAssertFalse(mainnet.isTestnet)
    }

    func testAlchemyKeyLoadingAndURLConstruction() throws {
        try withFixtureBundle(apiKeyContents: "fixture-key\r\n") { bundle in
            XCTAssertTrue(AlchemyRPC.apiKey(in: bundle) == "fixture-key")
        }
        try withFixtureBundle(apiKeyContents: "invalid key") { bundle in
            XCTAssertNil(AlchemyRPC.apiKey(in: bundle))
        }

        let url = try XCTUnwrap(AlchemyRPC.url(network: "eth-mainnet", apiKey: "unit-test-key"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "eth-mainnet.g.alchemy.com")
        XCTAssertEqual(url.pathComponents.dropLast().last, "v2")
        XCTAssertTrue(url.lastPathComponent == "unit-test-key")
        XCTAssertNil(AlchemyRPC.url(network: "invalid/network", apiKey: "unit-test-key"))
        XCTAssertNil(AlchemyRPC.url(network: "eth-mainnet", apiKey: "invalid key"))
    }

    func testAlchemyNetworkNameValidationIsStrictlyASCII() {
        XCTAssertTrue(AlchemyRPC.isValidNetworkName("eth-mainnet"))
        XCTAssertTrue(AlchemyRPC.isValidNetworkName("network-123"))
        XCTAssertTrue(AlchemyRPC.isValidNetworkName("-"))

        XCTAssertFalse(AlchemyRPC.isValidNetworkName(""))
        XCTAssertFalse(AlchemyRPC.isValidNetworkName("Eth-mainnet"))
        XCTAssertFalse(AlchemyRPC.isValidNetworkName("eth_mainnet"))
        XCTAssertFalse(AlchemyRPC.isValidNetworkName("eth/mainnet"))
        XCTAssertFalse(AlchemyRPC.isValidNetworkName("eth mainnet"))
        XCTAssertFalse(AlchemyRPC.isValidNetworkName("éth-mainnet"))
    }

    func testResolverPrecedenceAndSourceOwnership() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        var customSnapshotCount = 0
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: {
                customSnapshotCount += 1
                return customSnapshot
            }
        )

        let alchemy = try XCTUnwrap(resolver.resolve(chainId: 1).resolvedNetwork)
        XCTAssertEqual(alchemy.source, .alchemy)
        XCTAssertEqual(alchemy.rpcURL.host, "eth-mainnet.g.alchemy.com")
        XCTAssertEqual(customSnapshotCount, 0)

        let fallback = try XCTUnwrap(resolver.resolve(chainId: 40).resolvedNetwork)
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.rpcURL.absoluteString, "https://fallback.example")
        XCTAssertEqual(customSnapshotCount, 0)

        let custom = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom.source, .custom)
        XCTAssertEqual(custom.rpcURL.absoluteString, "https://custom-64240.example")
        XCTAssertEqual(customSnapshotCount, 1)

        XCTAssertEqual(resolver.resolve(chainId: 123456789), .unknown)
        XCTAssertEqual(customSnapshotCount, 2)
    }

    func testMissingAlchemyKeyDoesNotReviveAnArchivedCustomEndpoint() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshot = CustomNetworkSnapshot(
            records: [
                customRecord(
                    chainId: 1,
                    name: "Archived Ethereum",
                    rpcURL: "https://archived-custom-mainnet.example"
                ),
            ],
            nodeURLForChainId: { _ in nil }
        )
        var customSnapshotCount = 0
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            alchemyAPIKey: nil,
            customSnapshot: {
                customSnapshotCount += 1
                return customSnapshot
            }
        )

        XCTAssertEqual(resolver.resolve(chainId: 1), .catalogOwnedButUnavailable)
        XCTAssertNil(resolver.rpcURL(chainId: 1))
        XCTAssertNil(resolver.network(chainId: 1))
        XCTAssertEqual(customSnapshotCount, 0)

        let fallback = try XCTUnwrap(resolver.resolve(chainId: 40).resolvedNetwork)
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.rpcURL.absoluteString, "https://fallback.example")
        XCTAssertEqual(customSnapshotCount, 0)
    }

    func testFallbackOverlapRemainsDormantAndCatalogOwned() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://bundled-fallback.example"),
        ])
        let records = [
            customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            customRecord(chainId: 40, name: "User Telos", rpcURL: "https://custom-telos.example"),
            customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
        ]
        let snapshot = CustomNetworkSnapshot(
            records: records,
            nodeURLForChainId: { chainId in
                return chainId == 40 ? "https://stored-custom-telos.example" : nil
            }
        )
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: { snapshot }
        )

        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
        XCTAssertEqual(resolver.resolve(chainId: 1).resolvedNetwork?.source, .alchemy)
        XCTAssertEqual(resolver.resolve(chainId: 40).resolvedNetwork?.source, .fallback)
        XCTAssertEqual(
            resolver.rpcURL(chainId: 40)?.absoluteString,
            "https://bundled-fallback.example"
        )
    }

    func testCustom64240SurvivesLegacyNodeRemovalAndUsesLastWrite() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
        ])
        let records = [
            customRecord(chainId: 64240, name: "First 64240", rpcURL: "https://first-64240.example"),
            customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            customRecord(chainId: 64240, name: "Last 64240", rpcURL: "https://last-64240.example"),
        ]
        let snapshot = CustomNetworkSnapshot(
            records: records,
            nodeURLForChainId: { _ in nil }
        )
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: { snapshot }
        )

        let custom64240 = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom64240.network.name, "Last 64240")
        XCTAssertEqual(custom64240.rpcURL.absoluteString, "https://last-64240.example")
        XCTAssertEqual(custom64240.source, .custom)
        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
        XCTAssertEqual(resolver.resolve(chainId: 123456789), .unknown)

        let storedNodeSnapshot = CustomNetworkSnapshot(
            records: records,
            nodeURLForChainId: { chainId in
                return chainId == 64240 ? "https://stored-64240.example" : "https://orphaned.example"
            }
        )
        let storedNodeResolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: { storedNodeSnapshot }
        )
        XCTAssertEqual(
            storedNodeResolver.rpcURL(chainId: 64240)?.absoluteString,
            "https://stored-64240.example"
        )
        XCTAssertEqual(storedNodeResolver.resolve(chainId: 123456789), .unknown)
    }

    func testArchivedCustomNetworkEncodingStillDecodes() throws {
        let archivedData = Data(
            """
            [
              {
                "chainId": "0xfaf0",
                "rpcUrls": ["https://archived-64240.example"],
                "blockExplorerUrls": [],
                "nativeCurrency": {
                  "decimals": 18,
                  "name": "Archived Coin",
                  "symbol": "ARCH"
                },
                "chainName": "Archived 64240"
              }
            ]
            """.utf8
        )
        let records = try JSONDecoder().decode([EthereumNetworkFromDapp].self, from: archivedData)
        let snapshot = CustomNetworkSnapshot(records: records, nodeURLForChainId: { _ in nil })

        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64240])
        XCTAssertEqual(
            snapshot.entriesByChainId[64240]?.rpcURL.absoluteString,
            "https://archived-64240.example"
        )
        XCTAssertEqual(snapshot.entriesByChainId[64240]?.resolvedNetwork.network.symbol, "ARCH")
    }

    func testCustomRPCURLsAllowHTTPButRejectUnsupportedOrRelativeURLs() throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 64240, name: "Local HTTP", rpcURL: "http://localhost:8545"),
                customRecord(chainId: 64241, name: "Relative", rpcURL: "relative-endpoint"),
                customRecord(chainId: 64242, name: "WebSocket", rpcURL: "ws://localhost:8546"),
                customRecord(chainId: 64243, name: "File", rpcURL: "file:///tmp/rpc"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: []),
            catalogOwnedChainIds: [],
            alchemyAPIKey: nil,
            customSnapshot: { snapshot }
        )

        XCTAssertEqual(resolver.rpcURL(chainId: 64240)?.absoluteString, "http://localhost:8545")
        XCTAssertEqual(resolver.resolve(chainId: 64241), .unknown)
        XCTAssertEqual(resolver.resolve(chainId: 64242), .unknown)
        XCTAssertEqual(resolver.resolve(chainId: 64243), .unknown)
    }

    func testMissingOrInvalidCatalogNeverRevivesCatalogOwnedCustomRecords() throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        var customSnapshotCount = 0
        let resolver = NetworkResolver(
            catalog: nil,
            catalogOwnedChainIds: [1, 40],
            decodedChainIds: [300],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: {
                customSnapshotCount += 1
                return snapshot
            }
        )

        XCTAssertFalse(resolver.catalogIsAvailable)
        XCTAssertEqual(resolver.resolve(chainId: 1), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 40), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 300), .catalogOwnedButUnavailable)
        XCTAssertEqual(customSnapshotCount, 0)

        let custom64240 = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom64240.source, .custom)
        XCTAssertEqual(customSnapshotCount, 1)
        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
    }

    func testIDMismatchedCatalogDisablesAllBundledRecordsAndGuardsUnexpectedIDs() throws {
        let mismatchedCatalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 300, alchemyNetwork: "zksync-sepolia"),
        ])
        let snapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        let resolver = NetworkResolver(
            catalog: mismatchedCatalog,
            catalogOwnedChainIds: [1, 40],
            alchemyAPIKey: "unit-test-key",
            customSnapshot: { snapshot }
        )

        XCTAssertFalse(resolver.catalogIsAvailable)
        XCTAssertTrue(resolver.bundledNetworks.isEmpty)
        XCTAssertEqual(resolver.resolve(chainId: 1), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 40), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 300), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 64240).resolvedNetwork?.source, .custom)
        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
    }

    func testInvalidCatalogRecoversUnexpectedIDAndSuppressesItsCustomFallback() throws {
        let unexpectedChainId = 987_654_321
        let invalidCatalogData = try JSONEncoder().encode([
            record(
                chainId: unexpectedChainId,
                name: " Invalid Network",
                alchemyNetwork: "unexpected-mainnet"
            ),
        ])
        var recoveredChainIds = Set<Int>()

        try withFixtureBundle(catalogData: invalidCatalogData) { bundle in
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
                customRecord(
                    chainId: unexpectedChainId,
                    name: "Dormant Unexpected Network",
                    rpcURL: "https://unexpected-custom.example"
                ),
                customRecord(
                    chainId: 64240,
                    name: "Custom 64240",
                    rpcURL: "https://custom-64240.example"
                ),
            ],
            nodeURLForChainId: { _ in nil }
        )
        var customSnapshotCount = 0
        let resolver = NetworkResolver(
            catalog: nil,
            catalogOwnedChainIds: [1],
            decodedChainIds: recoveredChainIds,
            alchemyAPIKey: "unit-test-key",
            customSnapshot: {
                customSnapshotCount += 1
                return snapshot
            }
        )

        XCTAssertEqual(
            resolver.resolve(chainId: unexpectedChainId),
            .catalogOwnedButUnavailable
        )
        XCTAssertNil(resolver.rpcURL(chainId: unexpectedChainId))
        XCTAssertEqual(customSnapshotCount, 0)
        XCTAssertEqual(resolver.resolve(chainId: 64240).resolvedNetwork?.source, .custom)
        XCTAssertEqual(customSnapshotCount, 1)
    }

    func testCatalogPreservesInputOrderAndBundledProjectionUsesNameThenChainIDOrdering() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 30, name: "Zulu", fallbackRPCURL: "https://zulu.example"),
            record(chainId: 20, name: "Alpha", fallbackRPCURL: "https://alpha-20.example"),
            record(chainId: 10, name: "Alpha", fallbackRPCURL: "https://alpha-10.example"),
        ])
        XCTAssertEqual(catalog.records.map(\.chainId), [30, 20, 10])

        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [10, 20, 30],
            alchemyAPIKey: nil,
            customSnapshot: { .empty }
        )

        XCTAssertEqual(resolver.bundledNetworks.map(\.chainId), [10, 20, 30])
    }

    func testCatalogResolutionAvoidsCustomStorageAcrossRepeatedLookups() throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        var customSnapshotCount = 0
        var catalogURLBuildCountByChainId: [Int: Int] = [:]
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            alchemyAPIKey: "unit-test-key",
            catalogURLBuilder: { record, apiKey in
                catalogURLBuildCountByChainId[record.chainId, default: 0] += 1
                return record.rpcURL(alchemyAPIKey: apiKey)
            },
            customSnapshot: {
                customSnapshotCount += 1
                return .empty
            }
        )
        XCTAssertEqual(resolver.bundledNetworks.map(\.chainId), [1, 40])
        XCTAssertEqual(resolver.bundledNetworks.map(\.chainId), [1, 40])
        var checksum = 0

        for index in 0..<20_000 {
            let chainId = index.isMultiple(of: 2) ? 1 : 40
            guard let rpcURL = resolver.rpcURL(chainId: chainId) else {
                XCTFail("Catalog-owned chain \(chainId) unexpectedly failed to resolve")
                return
            }
            checksum &+= rpcURL.absoluteString.utf8.count
        }

        XCTAssertGreaterThan(checksum, 0)
        XCTAssertEqual(customSnapshotCount, 0)
        XCTAssertEqual(catalogURLBuildCountByChainId, [1: 1, 40: 1])
    }

    func testCustomNetworkCacheLoadsOnceUntilInvalidated() throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        var loadCount = 0
        let cache = CustomNetworkCache(loader: {
            loadCount += 1
            return snapshot
        })
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: []),
            catalogOwnedChainIds: [],
            alchemyAPIKey: nil,
            customSnapshot: { cache.snapshot() }
        )
        var checksum = 0

        for _ in 0..<20_000 {
            guard let rpcURL = resolver.rpcURL(chainId: 64240) else {
                XCTFail("Custom chain 64240 unexpectedly failed to resolve")
                return
            }
            checksum &+= rpcURL.absoluteString.utf8.count
        }

        XCTAssertGreaterThan(checksum, 0)
        XCTAssertEqual(loadCount, 1)

        cache.invalidate()
        XCTAssertNotNil(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(loadCount, 2)
    }

    func testCustomNetworkCacheInvalidationPublishesNewGenerationToConcurrentReaders() {
        let generationA = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 64240, name: "Generation A", rpcURL: "https://generation-a.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        let generationB = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 64240, name: "Generation B", rpcURL: "https://generation-b.example"),
            ],
            nodeURLForChainId: { _ in nil }
        )
        let stateLock = NSLock()
        var activeGeneration = generationA
        var loadCount = 0
        var invalidSnapshotCount = 0
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let allowFirstLoadToFinish = DispatchSemaphore(value: 0)
        let cache = CustomNetworkCache(loader: {
            stateLock.lock()
            loadCount += 1
            let currentLoadCount = loadCount
            let snapshot = activeGeneration
            stateLock.unlock()

            if currentLoadCount == 1 {
                firstLoadStarted.signal()
                _ = allowFirstLoadToFinish.wait(timeout: .now() + 5)
            }
            return snapshot
        })

        let initialReadFinished = expectation(description: "Initial cache read finished")
        DispatchQueue.global().async {
            _ = cache.snapshot()
            initialReadFinished.fulfill()
        }
        XCTAssertEqual(firstLoadStarted.wait(timeout: .now() + 5), .success)

        stateLock.lock()
        activeGeneration = generationB
        stateLock.unlock()

        let invalidationStarted = DispatchSemaphore(value: 0)
        let invalidationFinished = expectation(description: "Concurrent invalidation finished")
        DispatchQueue.global().async {
            invalidationStarted.signal()
            cache.invalidate()
            invalidationFinished.fulfill()
        }
        XCTAssertEqual(invalidationStarted.wait(timeout: .now() + 5), .success)
        allowFirstLoadToFinish.signal()
        wait(for: [initialReadFinished, invalidationFinished], timeout: 5)

        DispatchQueue.concurrentPerform(iterations: 512) { _ in
            let loaded = cache.snapshot()
            if loaded.entriesByChainId[64240]?.rpcURL.absoluteString != "https://generation-b.example" {
                stateLock.lock()
                invalidSnapshotCount += 1
                stateLock.unlock()
            }
        }

        stateLock.lock()
        let finalLoadCount = loadCount
        let finalInvalidSnapshotCount = invalidSnapshotCount
        stateLock.unlock()

        XCTAssertEqual(finalInvalidSnapshotCount, 0)
        XCTAssertEqual(finalLoadCount, 2)
        XCTAssertEqual(
            cache.snapshot().entriesByChainId[64240]?.resolvedNetwork.network.name,
            "Generation B"
        )
    }

    func testCatalogRejectsMalformedRecords() {
        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 1, fallbackRPCURL: "https://fallback.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .duplicateChainId(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1,
                   alchemyNetwork: "eth-mainnet",
                   fallbackRPCURL: "https://fallback.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, fallbackRPCURL: "http://insecure.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidFallbackRPCURL(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, fallbackRPCURL: "relative-endpoint"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidFallbackRPCURL(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "eth/mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidAlchemyNetwork(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, alchemyNetwork: "same-slug"),
            record(chainId: 2, alchemyNetwork: "same-slug"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .duplicateAlchemyNetwork("same-slug"))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(
                chainId: 1,
                alchemyNetwork: "eth-mainnet",
                accountDisabledAlchemyNetwork: "eth-mainnet"
            ),
        ])) { error in
            XCTAssertEqual(
                error as? NetworkCatalogError,
                .invalidAccountDisabledAlchemyNetwork(1)
            )
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, accountDisabledAlchemyNetwork: "taiko-mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(
                chainId: 1,
                fallbackRPCURL: "https://fallback.example",
                accountDisabledAlchemyNetwork: "invalid/network"
            ),
        ])) { error in
            XCTAssertEqual(
                error as? NetworkCatalogError,
                .invalidAccountDisabledAlchemyNetwork(1)
            )
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 0, alchemyNetwork: "invalid-chain"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidChainId(0))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(chainId: 1, name: " Test Network", alchemyNetwork: "eth-mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidName(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(
                chainId: 1,
                nativeCurrency: NetworkCatalogNativeCurrency(name: "Ether", symbol: "", decimals: 18),
                alchemyNetwork: "eth-mainnet"
            ),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidNativeCurrency(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(
                chainId: 1,
                explorerURL: "relative-explorer",
                alchemyNetwork: "eth-mainnet"
            ),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidExplorerURL(1))
        }
    }

    func testCatalogDataRejectsInvalidJSONAndMissingRequiredFields() {
        XCTAssertThrowsError(try NetworkCatalog(data: Data("not-json".utf8)))
        XCTAssertThrowsError(try NetworkCatalog(data: Data(
            """
            [
              {
                "chainId": 1,
                "name": "Missing required fields"
              }
            ]
            """.utf8
        )))
    }

    func testCatalogLoaderThrowsForMissingAndInvalidResources() throws {
        try withFixtureBundle { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(error as? NetworkCatalogLoadError, .missingResource)
            }
        }

        try withFixtureBundle(catalogData: Data("not-json".utf8)) { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(
                    error as? NetworkCatalogLoadError,
                    .invalidCatalog(decodedChainIds: [])
                )
            }
        }

        let invalidCatalogData = try JSONEncoder().encode([
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 1, fallbackRPCURL: "https://duplicate.example"),
        ])
        try withFixtureBundle(catalogData: invalidCatalogData) { bundle in
            XCTAssertThrowsError(try NetworkCatalog.load(in: bundle)) { error in
                XCTAssertEqual(
                    error as? NetworkCatalogLoadError,
                    .invalidCatalog(decodedChainIds: [1])
                )
            }
        }
    }

    func testAlchemyKeyLoaderReturnsNilForMissingEmptyAndInvalidResources() throws {
        try withFixtureBundle { bundle in
            XCTAssertNil(AlchemyRPC.apiKey(in: bundle))
        }
        try withFixtureBundle(apiKeyContents: "\r\n") { bundle in
            XCTAssertNil(AlchemyRPC.apiKey(in: bundle))
        }
        try withFixtureBundle(apiKeyContents: "two words") { bundle in
            XCTAssertNil(AlchemyRPC.apiKey(in: bundle))
        }
    }

    func testSafariRPCClientRoutesReversedConcurrentResponsesToTheirOwnCompletions() throws {
        let requestCount = 32
        let malformedIndex = 11
        let allRequestsStarted = expectation(description: "All RPC requests started")
        allRequestsStarted.expectedFulfillmentCount = requestCount
        let allRequestsCompleted = expectation(description: "All RPC requests completed")
        allRequestsCompleted.expectedFulfillmentCount = requestCount
        SafariRPCClientURLProtocol.reset {
            allRequestsStarted.fulfill()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariRPCClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SafariRPCClientURLProtocol.reset()
        }
        let client = SafariRPCClient(urlSession: session)
        let resultLock = NSLock()
        var failures = [String]()

        for index in 0..<requestCount {
            let url = try XCTUnwrap(URL(string: "https://rpc.example/request-\(index)"))
            let body = try JSONSerialization.data(withJSONObject: ["request": index])
            client.send(url: url, body: body) { response in
                resultLock.lock()
                defer {
                    resultLock.unlock()
                    allRequestsCompleted.fulfill()
                }

                if index == malformedIndex {
                    if response != nil {
                        failures.append("Malformed response \(index) unexpectedly parsed")
                    }
                    return
                }

                guard let responseIndex = (response?["request"] as? NSNumber)?.intValue else {
                    failures.append("Request \(index) received no parsed response")
                    return
                }
                if responseIndex != index {
                    failures.append("Request \(index) received response \(responseIndex)")
                }
            }
        }

        wait(for: [allRequestsStarted], timeout: 5)

        let requests = SafariRPCClientURLProtocol.pendingRequests
        XCTAssertEqual(requests.count, requestCount)
        XCTAssertEqual(
            Set(requests.compactMap(\.url?.absoluteString)),
            Set((0..<requestCount).map { "https://rpc.example/request-\($0)" })
        )
        XCTAssertTrue(requests.allSatisfy { request in
            return request.httpMethod == "POST"
                && request.value(forHTTPHeaderField: "Accept") == "application/json"
                && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
                && (request.httpBody != nil || request.httpBodyStream != nil)
        })

        SafariRPCClientURLProtocol.completePendingRequestsInReverse { request in
            guard let pathComponent = request.url?.lastPathComponent else { return nil }
            guard pathComponent == "request-\(malformedIndex)" else {
                guard pathComponent.hasPrefix("request-"),
                      let index = Int(pathComponent.dropFirst("request-".count)) else {
                    return nil
                }
                return try? JSONSerialization.data(withJSONObject: ["request": index])
            }
            return Data("not-json".utf8)
        }

        wait(for: [allRequestsCompleted], timeout: 5)
        resultLock.lock()
        let recordedFailures = failures
        resultLock.unlock()
        XCTAssertTrue(recordedFailures.isEmpty, recordedFailures.joined(separator: "\n"))
    }

    private struct ConflictExpectation {
        let alchemyNetwork: String
        let name: String
        let symbol: String
        let isTestnet: Bool
    }

    private func loadedCatalog() throws -> NetworkCatalog {
        return try NetworkCatalog.load(in: .main)
    }

    private func sha256(rows: [String]) -> String {
        let canonicalText = rows.joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonicalText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func record(chainId: Int,
                        name: String = "Test Network",
                        nativeCurrency: NetworkCatalogNativeCurrency = NetworkCatalogNativeCurrency(
                            name: "Ether",
                            symbol: "ETH",
                            decimals: 18
                        ),
                        explorerURL: String? = nil,
                        alchemyNetwork: String? = nil,
                        fallbackRPCURL: String? = nil,
                        accountDisabledAlchemyNetwork: String? = nil) -> NetworkCatalogRecord {
        return NetworkCatalogRecord(
            chainId: chainId,
            name: name,
            nativeCurrency: nativeCurrency,
            explorerURL: explorerURL,
            isTestnet: false,
            displayPrice: false,
            alchemyNetwork: alchemyNetwork,
            fallbackRPCURL: fallbackRPCURL,
            accountDisabledAlchemyNetwork: accountDisabledAlchemyNetwork
        )
    }

    private func customRecord(chainId: Int,
                              name: String,
                              rpcURL: String) -> EthereumNetworkFromDapp {
        return EthereumNetworkFromDapp(
            chainId: String.hex(chainId, withPrefix: true),
            rpcUrls: [rpcURL],
            blockExplorerUrls: [],
            nativeCurrency: EthereumNetworkFromDapp.Currency(
                decimals: 18,
                name: "\(name) Coin",
                symbol: "CUSTOM"
            ),
            chainName: name
        )
    }

    private func withFixtureBundle(apiKeyContents: String? = nil,
                                   catalogData: Data? = nil,
                                   body: (Bundle) throws -> Void) throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let infoDictionary: [String: Any] = [
            "CFBundleIdentifier": "org.lil.wallet.tests.\(UUID().uuidString)",
            "CFBundleName": "Alchemy API Key Fixture",
            "CFBundlePackageType": "BNDL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: infoDictionary,
            format: .xml,
            options: 0
        )
        try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        if let apiKeyContents {
            try Data(apiKeyContents.utf8)
                .write(to: bundleURL.appendingPathComponent(AlchemyRPC.apiKeyResourceName))
        }
        if let catalogData {
            try catalogData.write(
                to: bundleURL
                    .appendingPathComponent(NetworkCatalog.resourceName)
                    .appendingPathExtension("json")
            )
        }

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        try body(bundle)
    }

}

private final class SafariRPCClientURLProtocol: URLProtocol {

    private static let pendingLock = NSLock()
    private static var pending = [SafariRPCClientURLProtocol]()
    private static var requestStarted: (() -> Void)?

    static var pendingRequests: [URLRequest] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending.map(\.request)
    }

    static func reset(requestStarted: (() -> Void)? = nil) {
        pendingLock.lock()
        pending = []
        Self.requestStarted = requestStarted
        pendingLock.unlock()
    }

    static func completePendingRequestsInReverse(responseData: (URLRequest) -> Data?) {
        pendingLock.lock()
        let protocols = Array(pending.reversed())
        pending = []
        requestStarted = nil
        pendingLock.unlock()

        for urlProtocol in protocols {
            guard let url = urlProtocol.request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                  ),
                  let data = responseData(urlProtocol.request) else {
                urlProtocol.client?.urlProtocol(
                    urlProtocol,
                    didFailWithError: URLError(.cannotParseResponse)
                )
                continue
            }
            urlProtocol.client?.urlProtocol(
                urlProtocol,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            urlProtocol.client?.urlProtocol(urlProtocol, didLoad: data)
            urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.pendingLock.lock()
        Self.pending.append(self)
        let requestStarted = Self.requestStarted
        Self.pendingLock.unlock()
        requestStarted?()
    }

    override func stopLoading() {}

}
