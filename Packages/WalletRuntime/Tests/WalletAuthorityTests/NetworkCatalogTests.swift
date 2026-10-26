import CryptoKit
import Dispatch
import Foundation
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class NetworkCatalogTests: XCTestCase {
    func testCatalogInventoryGoldenSHA256() async throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .map { String($0.chainId) }

        XCTAssertEqual(
            RuntimeTestCatalog.sha256(rows: rows),
            "b3eb33f4e72a267b87895d64dd2e72868e49f88a6db190efaae1cdaa896e2b25"
        )
    }

    func testCatalogAlchemyMappingGoldenSHA256() async throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .compactMap { record -> String? in
                guard let alchemyNetwork = record.alchemyNetwork else { return nil }
                return "\(record.chainId)\t\(alchemyNetwork)"
            }

        XCTAssertEqual(
            RuntimeTestCatalog.sha256(rows: rows),
            "f6c0d0d20aa3bcb5a6c913ea65eaa821ed92724683d0be289817d0c04985816c"
        )
    }

    func testCatalogFallbackMappingGoldenSHA256() async throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .compactMap { record -> String? in
                guard let fallbackRPCURL = record.fallbackRPCURL else { return nil }
                return "\(record.chainId)\t\(fallbackRPCURL)"
            }

        XCTAssertEqual(
            RuntimeTestCatalog.sha256(rows: rows),
            "665511e15a30321ff180683365e97931a354f3d2c2ddf1c2331ac21810ee2ef9"
        )
    }

    func testCatalogMetadataGoldenSHA256() async throws {
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
            RuntimeTestCatalog.sha256(rows: rows),
            "1017eb02c357fea08af83279c48e9931ad750da4ce8735e4311eae01f62e2913"
        )
    }

    func testCatalogSemanticInvariantsAndNetworkProjection() async throws {
        let catalog = try loadedCatalog()
        let records = catalog.records

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
                record.rpcURL(),
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
                XCTAssertEqual(rpcURL.path, "/v2")
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
            XCTAssertEqual(
                network.allowsAlchemyAuthorization,
                record.alchemyNetwork != nil
            )
            XCTAssertEqual(
                network.rpcEndpoint.feeMarketHint,
                record.feeMarketHint
            )
        }
    }

    func testCatalogFeeMarketHintsAreRequiredExactAndConservative() async throws {
        let catalog = try loadedCatalog()
        let ethereum = try XCTUnwrap(catalog.record(chainId: 1))
        let gnosis = try XCTUnwrap(catalog.record(chainId: 100))

        XCTAssertEqual(ethereum.feeMarketHint.support, .eip1559)
        XCTAssertEqual(gnosis.feeMarketHint.support, .eip1559)

        for record in catalog.records {
            let rpcURL = try XCTUnwrap(record.rpcURL())
            XCTAssertEqual(
                record.feeMarketHint.observedEndpoint,
                rpcURL.absoluteString
            )
            XCTAssertNotNil(record.feeMarketHint.checkedAtDate)
        }
    }

    func testFeeMarketHintProjectionAndEndpointIdentity() async throws {
        let checkedAt = "2026-07-23T00:00:00Z"
        let canonicalURL = try XCTUnwrap(
            AlchemyRPC.url(network: "eth-mainnet")
        )
        let hint = EthereumFeeMarketHint(
            support: .eip1559,
            checkedAt: checkedAt,
            observedEndpoint: canonicalURL.absoluteString
        )
        let endpoint = EthereumRPCEndpoint.catalog(
            canonicalURL,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: hint
        )

        XCTAssertEqual(endpoint.catalogFeeMarketObservation(), .eip1559)
        XCTAssertEqual(endpoint.catalogFeeMarketSupport(), .eip1559)
        XCTAssertFalse(endpoint.requiresFeeMarketDetection())

        let unknownEndpoint = EthereumRPCEndpoint.catalog(
            canonicalURL,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: EthereumFeeMarketHint(
                support: .unknown,
                checkedAt: checkedAt,
                observedEndpoint: canonicalURL.absoluteString
            )
        )
        XCTAssertNil(unknownEndpoint.catalogFeeMarketSupport())
        XCTAssertTrue(unknownEndpoint.requiresFeeMarketDetection())

        let legacyEndpoint = EthereumRPCEndpoint.catalog(
            canonicalURL,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: EthereumFeeMarketHint(
                support: .legacy,
                checkedAt: checkedAt,
                observedEndpoint: canonicalURL.absoluteString
            )
        )
        XCTAssertEqual(
            legacyEndpoint.catalogFeeMarketObservation(),
            .legacy
        )
        XCTAssertNil(legacyEndpoint.catalogFeeMarketSupport())
        XCTAssertTrue(legacyEndpoint.requiresFeeMarketDetection())

        let mismatchedURL = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2?other=1")
        )
        let mismatchedEndpoint = EthereumRPCEndpoint.catalog(
            mismatchedURL,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: hint
        )
        XCTAssertNil(mismatchedEndpoint.feeMarketHint)
        XCTAssertTrue(mismatchedEndpoint.requiresFeeMarketDetection())
    }

    func testEndpointEqualityAndHashIgnoreFeeMarketTimestamp() async throws {
        let url = try XCTUnwrap(AlchemyRPC.url(network: "eth-mainnet"))
        let first = EthereumRPCEndpoint.catalog(
            url,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: EthereumFeeMarketHint(
                support: .eip1559,
                checkedAt: "2026-07-23T00:00:00Z",
                observedEndpoint: url.absoluteString
            )
        )
        let second = EthereumRPCEndpoint.catalog(
            url,
            alchemyNetwork: "eth-mainnet",
            feeMarketHint: EthereumFeeMarketHint(
                support: .legacy,
                checkedAt: "2026-07-24T00:00:00Z",
                observedEndpoint: url.absoluteString
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    func testEveryCatalogEndpointHasOneOwner() async throws {
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

    func testBundledNetworkOwnershipMatchesCatalogExactly() async throws {
        let catalog = try loadedCatalog()
        let catalogChainIds = Set(catalog.records.map(\.chainId))

        XCTAssertEqual(BundledNetworkOwnership.chainIds, catalogChainIds)
        XCTAssertEqual(BundledNetworkOwnership.chainIds.count, 184)
        XCTAssertFalse(BundledNetworkOwnership.chainIds.contains(64240))
    }

    func testPinnedNetworkOrderRemainsStable() async {
        XCTAssertEqual(
            AuthorityTestNetworks.pinned.map(\.chainId),
            [1, 7777777, 10, 8453, 42161]
        )
    }

    func testEveryNetworkListSharesOneOrder() async {
        let ordered = AuthorityTestNetworks.ordered
        XCTAssertEqual(
            ordered.prefix(AuthorityTestNetworks.pinned.count).map(\.chainId),
            AuthorityTestNetworks.pinned.map(\.chainId)
        )
        XCTAssertEqual(
            ordered.suffix(AuthorityTestNetworks.testnets.count).map(\.chainId),
            AuthorityTestNetworks.testnets.map(\.chainId)
        )
        XCTAssertEqual(
            ordered.count,
            AuthorityTestNetworks.pinned.count + AuthorityTestNetworks.custom.count + AuthorityTestNetworks.mainnets.count + AuthorityTestNetworks.testnets.count
        )
    }

    func testAcceptedConflictRecordsHaveExactOwnersAndMetadata() async throws {
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

    func testAccountDisabledAlchemyNetworksAreExplicitFallbackExceptions() async throws {
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

    func testKaiaRecordsUseCurrentNetworkMetadata() async throws {
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

    func testTempoNetworksSuppressNativeBalance() async throws {
        let catalog = try loadedCatalog()
        let rpcURL = try XCTUnwrap(URL(string: "https://rpc.example"))
        let tempoNetworks = [
            (chainId: 4_217, name: "Tempo Mainnet Presto"),
            (chainId: 42_431, name: "Tempo Moderato"),
        ]

        for tempoNetwork in tempoNetworks {
            let record = try XCTUnwrap(catalog.record(chainId: tempoNetwork.chainId))
            XCTAssertEqual(record.name, tempoNetwork.name)
            XCTAssertEqual(record.nativeCurrency.name, "No native currency")
            XCTAssertEqual(record.nativeCurrency.symbol, "USD")
            XCTAssertFalse(record.ethereumNetwork(rpcURL: rpcURL).supportsNativeBalance)
        }

        let ethereum = try XCTUnwrap(catalog.record(chainId: EthereumNetwork.ethMainnetChainId))
            .ethereumNetwork(rpcURL: rpcURL)
        XCTAssertTrue(ethereum.supportsNativeBalance)

        let unrelatedUSDNetwork = EthereumNetwork(
            chainId: 999_999,
            name: "Unrelated USD Network",
            symbol: "USD",
            rpcEndpoint: .unauthenticated(rpcURL),
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
        XCTAssertTrue(unrelatedUSDNetwork.supportsNativeBalance)
    }

    func testAlchemyKeylessURLConstruction() async throws {
        let url = try XCTUnwrap(AlchemyRPC.url(network: "eth-mainnet"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "eth-mainnet.g.alchemy.com")
        XCTAssertEqual(url.path, "/v2")
        XCTAssertEqual(url.absoluteString, "https://eth-mainnet.g.alchemy.com/v2")
        XCTAssertNil(AlchemyRPC.url(network: "invalid/network"))
    }

    func testAlchemyNetworkNameValidationIsStrictlyASCII() async {
        for network in [
            "a",
            "1",
            "eth-mainnet",
            "network-123",
            String(repeating: "a", count: 63),
        ] {
            XCTAssertTrue(AlchemyRPC.isValidNetworkName(network), network)
        }

        for network in [
            "",
            "-eth",
            "eth-",
            "-",
            String(repeating: "a", count: 64),
            "Eth-mainnet",
            "eth.mainnet",
            "eth_mainnet",
            "eth/mainnet",
            "eth mainnet",
            "éth-mainnet",
        ] {
            XCTAssertFalse(AlchemyRPC.isValidNetworkName(network), network)
        }
    }

    func testResolverPrecedenceAndSourceOwnership() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                RuntimeTestCatalog.customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let customSnapshotCount = LockedTestValue(0)
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            customSnapshot: {
                _ = customSnapshotCount.increment()
                return customSnapshot
            }
        )

        let alchemy = try XCTUnwrap(resolver.resolve(chainId: 1).resolvedNetwork)
        XCTAssertEqual(alchemy.source, .alchemy)
        XCTAssertEqual(alchemy.rpcURL.host, "eth-mainnet.g.alchemy.com")
        XCTAssertTrue(alchemy.allowsAlchemyAuthorization)
        XCTAssertEqual(customSnapshotCount.value, 0)

        let fallback = try XCTUnwrap(resolver.resolve(chainId: 40).resolvedNetwork)
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.rpcURL.absoluteString, "https://fallback.example")
        XCTAssertFalse(fallback.allowsAlchemyAuthorization)
        XCTAssertEqual(customSnapshotCount.value, 0)

        let custom = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom.source, .custom)
        XCTAssertEqual(custom.rpcURL.absoluteString, "https://custom-64240.example")
        XCTAssertFalse(custom.allowsAlchemyAuthorization)
        XCTAssertEqual(customSnapshotCount.value, 1)

        XCTAssertEqual(resolver.resolve(chainId: 123456789), .unknown)
        XCTAssertEqual(customSnapshotCount.value, 2)
    }

    func testKeylessAlchemyEndpointDoesNotReviveAnArchivedCustomEndpoint() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(
                    chainId: 1,
                    name: "Archived Ethereum",
                    rpcURL: "https://archived-custom-mainnet.example"
                ),
            ]
        )
        let customSnapshotCount = LockedTestValue(0)
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            customSnapshot: {
                _ = customSnapshotCount.increment()
                return customSnapshot
            }
        )

        let alchemy = try XCTUnwrap(resolver.resolve(chainId: 1).resolvedNetwork)
        XCTAssertEqual(alchemy.source, .alchemy)
        XCTAssertEqual(alchemy.rpcURL.absoluteString, "https://eth-mainnet.g.alchemy.com/v2")
        XCTAssertEqual(resolver.network(chainId: 1)?.chainId, 1)
        XCTAssertEqual(customSnapshotCount.value, 0)

        let fallback = try XCTUnwrap(resolver.resolve(chainId: 40).resolvedNetwork)
        XCTAssertEqual(fallback.source, .fallback)
        XCTAssertEqual(fallback.rpcURL.absoluteString, "https://fallback.example")
        XCTAssertEqual(customSnapshotCount.value, 0)
    }

    func testCatalogAlchemyAuthorizationRequiresItsExactCanonicalEndpoint() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
        ])
        let differentAlchemyURL = try XCTUnwrap(
            URL(string: "https://eth-sepolia.g.alchemy.com/v2")
        )
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1],
            catalogURLBuilder: { _ in differentAlchemyURL },
            customSnapshot: { .empty }
        )

        let resolved = try XCTUnwrap(
            resolver.resolve(chainId: 1).resolvedNetwork
        )
        XCTAssertEqual(resolved.source, .alchemy)
        XCTAssertEqual(resolved.rpcURL, differentAlchemyURL)
        XCTAssertFalse(resolved.allowsAlchemyAuthorization)
    }

    func testEthereumRPCEndpointTrustCannotBeSeparatedFromItsURL() async throws {
        let canonicalURL = try XCTUnwrap(
            AlchemyRPC.url(network: "eth-mainnet")
        )
        let differentURL = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2?redirected=1")
        )
        let malformedURL = try XCTUnwrap(URL(string: "relative-endpoint"))

        XCTAssertTrue(
            EthereumRPCEndpoint.catalog(
                canonicalURL,
                alchemyNetwork: "eth-mainnet"
            ).allowsAlchemyAuthorization
        )
        XCTAssertFalse(
            EthereumRPCEndpoint.unauthenticated(canonicalURL)
                .allowsAlchemyAuthorization
        )
        XCTAssertFalse(
            EthereumRPCEndpoint.catalog(
                differentURL,
                alchemyNetwork: "eth-mainnet"
            ).allowsAlchemyAuthorization
        )
        XCTAssertFalse(
            EthereumRPCEndpoint.unauthenticated(malformedURL)
                .allowsAlchemyAuthorization
        )
    }

    func testDecodedEthereumNetworkAlwaysLosesRuntimeEndpointTrust() async throws {
        let catalogRecord = RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet")
        let rpcURL = try XCTUnwrap(catalogRecord.rpcURL())
        let network = catalogRecord.ethereumNetwork(rpcURL: rpcURL)
        XCTAssertTrue(network.allowsAlchemyAuthorization)

        let encoded = try JSONEncoder().encode(network)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["nodeURLString"] as? String, rpcURL.absoluteString)
        XCTAssertNil(object["rpcEndpoint"])
        XCTAssertNil(object["allowsAlchemyAuthorization"])
        XCTAssertNil(object["feeMarketHint"])

        let decoded = try JSONDecoder().decode(
            EthereumNetwork.self,
            from: encoded
        )
        XCTAssertEqual(decoded.nodeURLString, rpcURL.absoluteString)
        XCTAssertFalse(decoded.allowsAlchemyAuthorization)
        XCTAssertNil(decoded.rpcEndpoint.feeMarketHint)
        XCTAssertTrue(decoded.rpcEndpoint.requiresFeeMarketDetection())
    }

    func testFallbackOverlapRemainsDormantAndCatalogOwned() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 40, fallbackRPCURL: "https://bundled-fallback.example"),
        ])
        let records = [
            RuntimeTestCatalog.customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            RuntimeTestCatalog.customRecord(chainId: 40, name: "User Telos", rpcURL: "https://custom-telos.example"),
            RuntimeTestCatalog.customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
        ]
        let snapshot = CustomNetworkSnapshot(records: records)
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
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

    func testCustom64240SurvivesLegacyNodeRemovalAndUsesLastWrite() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
        ])
        let records = [
            RuntimeTestCatalog.customRecord(chainId: 64240, name: "First 64240", rpcURL: "https://first-64240.example"),
            RuntimeTestCatalog.customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            RuntimeTestCatalog.customRecord(chainId: 64240, name: "Last 64240", rpcURL: "https://last-64240.example"),
        ]
        let snapshot = CustomNetworkSnapshot(records: records)
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1],
            customSnapshot: { snapshot }
        )

        let custom64240 = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom64240.network.name, "Last 64240")
        XCTAssertEqual(custom64240.rpcURL.absoluteString, "https://last-64240.example")
        XCTAssertEqual(custom64240.source, .custom)
        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
        XCTAssertEqual(resolver.resolve(chainId: 123456789), .unknown)

    }

    func testArchivedCustomNetworkEncodingStillDecodes() async throws {
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
        let snapshot = CustomNetworkSnapshot(records: records)

        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64240])
        XCTAssertEqual(
            snapshot.entriesByChainId[64240]?.rpcURL.absoluteString,
            "https://archived-64240.example"
        )
        XCTAssertEqual(snapshot.entriesByChainId[64240]?.resolvedNetwork.network.symbol, "ARCH")
    }

    func testStoredCustomRPCURLsRetainLegacyHTTPAndPrivateEndpoints() async throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Public HTTPS", rpcURL: "https://rpc.example:8545"),
                RuntimeTestCatalog.customRecord(chainId: 64241, name: "Relative", rpcURL: "relative-endpoint"),
                RuntimeTestCatalog.customRecord(chainId: 64242, name: "WebSocket", rpcURL: "ws://localhost:8546"),
                RuntimeTestCatalog.customRecord(chainId: 64243, name: "File", rpcURL: "file:///tmp/rpc"),
                RuntimeTestCatalog.customRecord(chainId: 64244, name: "Localhost", rpcURL: "http://localhost:8545"),
                RuntimeTestCatalog.customRecord(chainId: 64245, name: "Private IPv4", rpcURL: "https://10.0.0.1"),
                RuntimeTestCatalog.customRecord(chainId: 64246, name: "Local IPv6", rpcURL: "https://[fe80::1]"),
                RuntimeTestCatalog.customRecord(chainId: 64247, name: "Public Literal HTTP", rpcURL: "http://1.1.1.1:8545"),
                RuntimeTestCatalog.customRecord(chainId: 64248, name: "Insecure Hostname", rpcURL: "http://rpc.example:8545"),
            ]
        )
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: []),
            catalogOwnedChainIds: [],
            customSnapshot: { snapshot }
        )

        XCTAssertEqual(resolver.rpcURL(chainId: 64240)?.absoluteString, "https://rpc.example:8545")
        XCTAssertEqual(resolver.resolve(chainId: 64241), .unknown)
        XCTAssertEqual(resolver.resolve(chainId: 64242), .unknown)
        XCTAssertEqual(resolver.resolve(chainId: 64243), .unknown)
        XCTAssertEqual(
            resolver.rpcURL(chainId: 64244)?.absoluteString,
            "http://localhost:8545"
        )
        XCTAssertEqual(
            resolver.rpcURL(chainId: 64245)?.absoluteString,
            "https://10.0.0.1"
        )
        XCTAssertEqual(
            resolver.rpcURL(chainId: 64246)?.absoluteString,
            "https://[fe80::1]"
        )
        XCTAssertEqual(resolver.rpcURL(chainId: 64247)?.absoluteString, "http://1.1.1.1:8545")
        XCTAssertEqual(
            resolver.rpcURL(chainId: 64248)?.absoluteString,
            "http://rpc.example:8545"
        )
    }

    func testMissingOrInvalidCatalogNeverRevivesCatalogOwnedCustomRecords() async throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                RuntimeTestCatalog.customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                RuntimeTestCatalog.customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let customSnapshotCount = LockedTestValue(0)
        let resolver = NetworkResolver(
            catalog: nil,
            catalogOwnedChainIds: [1, 40],
            decodedChainIds: [300],
            customSnapshot: {
                _ = customSnapshotCount.increment()
                return snapshot
            }
        )

        XCTAssertFalse(resolver.catalogIsAvailable)
        XCTAssertEqual(resolver.resolve(chainId: 1), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 40), .catalogOwnedButUnavailable)
        XCTAssertEqual(resolver.resolve(chainId: 300), .catalogOwnedButUnavailable)
        XCTAssertEqual(customSnapshotCount.value, 0)

        let custom64240 = try XCTUnwrap(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(custom64240.source, .custom)
        XCTAssertEqual(customSnapshotCount.value, 1)
        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
    }

    func testIDMismatchedCatalogDisablesAllBundledRecordsAndGuardsUnexpectedIDs() async throws {
        let mismatchedCatalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 300, alchemyNetwork: "zksync-sepolia"),
        ])
        let snapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                RuntimeTestCatalog.customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                RuntimeTestCatalog.customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let resolver = NetworkResolver(
            catalog: mismatchedCatalog,
            catalogOwnedChainIds: [1, 40],
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

    func testCatalogPreservesInputOrderAndBundledProjectionUsesNameThenChainIDOrdering() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 30, name: "Zulu", fallbackRPCURL: "https://zulu.example"),
            RuntimeTestCatalog.record(chainId: 20, name: "Alpha", fallbackRPCURL: "https://alpha-20.example"),
            RuntimeTestCatalog.record(chainId: 10, name: "Alpha", fallbackRPCURL: "https://alpha-10.example"),
        ])
        XCTAssertEqual(catalog.records.map(\.chainId), [30, 20, 10])

        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [10, 20, 30],
            customSnapshot: { .empty }
        )

        XCTAssertEqual(resolver.bundledNetworks.map(\.chainId), [10, 20, 30])
    }

    func testCatalogResolutionAvoidsCustomStorageAcrossRepeatedLookups() async throws {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshotCount = LockedTestValue(0)
        var catalogURLBuildCountByChainId: [Int: Int] = [:]
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1, 40],
            catalogURLBuilder: { record in
                catalogURLBuildCountByChainId[record.chainId, default: 0] += 1
                return record.rpcURL()
            },
            customSnapshot: {
                _ = customSnapshotCount.increment()
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
        XCTAssertEqual(customSnapshotCount.value, 0)
        XCTAssertEqual(catalogURLBuildCountByChainId, [1: 1, 40: 1])
    }

    func testCustomNetworkCacheLoadsOnceUntilInvalidated() async throws {
        let snapshot = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let loadCount = LockedTestValue(0)
        let cache = CustomNetworkCache(loader: {
            _ = loadCount.increment()
            return .loaded(snapshot)
        })
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: []),
            catalogOwnedChainIds: [],
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
        XCTAssertEqual(loadCount.value, 1)

        cache.invalidate()
        XCTAssertNotNil(resolver.resolve(chainId: 64240).resolvedNetwork)
        XCTAssertEqual(loadCount.value, 2)
    }

    func testApprovalNetworkResolutionUsesFreshStatusInsteadOfCachedCustomRoutes() throws {
        let snapshot = CustomNetworkSnapshot(records: [
            RuntimeTestCatalog.customRecord(chainId: 64_240, name: "Reviewed", rpcURL: "https://reviewed.example"),
        ])
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: []), catalogOwnedChainIds: [],
            customSnapshot: {
                XCTFail("Approval resolution must not use the UI snapshot")
                return snapshot
            }
        )
        XCTAssertEqual(resolver.approvalResolution(chainId: 64_240, freshCustomSnapshot: { .unavailable }), .unavailable)
        XCTAssertEqual(resolver.approvalResolution(chainId: 64_240, freshCustomSnapshot: { .corrupt }), .unavailable)
        XCTAssertEqual(resolver.approvalResolution(chainId: 64_240, freshCustomSnapshot: { .loaded(.empty) }), .missing)
        let expected = try XCTUnwrap(snapshot.entriesByChainId[64_240]?.resolvedNetwork)
        XCTAssertEqual(resolver.approvalResolution(chainId: 64_240, freshCustomSnapshot: { .loaded(snapshot) }), .resolved(expected))
    }

    func testApprovalNetworkResolutionKeepsBundledRoutesIndependentOfCustomStorage() throws {
        let catalog = try NetworkCatalog(records: [RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet")])
        let resolver = NetworkResolver(catalog: catalog, catalogOwnedChainIds: [1], customSnapshot: { .empty })
        let result = resolver.approvalResolution(chainId: 1, freshCustomSnapshot: {
            XCTFail("A bundled network must not depend on custom storage")
            return .unavailable
        })
        guard case .resolved(let network) = result else { return XCTFail("Expected the bundled route") }
        XCTAssertEqual(network.network.chainId, 1)
        let unavailable = NetworkResolver(catalog: nil, catalogOwnedChainIds: [1], customSnapshot: { .empty })
        XCTAssertEqual(unavailable.approvalResolution(chainId: 1, freshCustomSnapshot: {
            XCTFail("Missing bundled configuration must not fall back to a custom route")
            return .loaded(.empty)
        }), .unavailable)
    }

    func testCustomNetworkCacheRetainsLastGoodSnapshotAfterReloadFailure() async throws {
        let snapshot = CustomNetworkSnapshot(records: [
            RuntimeTestCatalog.customRecord(
                chainId: 64_240,
                name: "Custom 64240",
                rpcURL: "https://custom-64240.example"
            ),
        ])
        let shouldFail = Mutex(false)
        let cache = CustomNetworkCache(loader: {
            return shouldFail.withLock { $0 } ? .unavailable : .loaded(snapshot)
        })

        XCTAssertEqual(
            cache.snapshot().entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://custom-64240.example"
        )
        shouldFail.withLock { $0 = true }
        cache.invalidate()
        XCTAssertEqual(
            cache.snapshot().entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://custom-64240.example"
        )
    }

    func testCustomNetworkCacheRetriesUnavailableInitialLoad() async {
        let snapshot = CustomNetworkSnapshot(records: [
            RuntimeTestCatalog.customRecord(
                chainId: 64_240,
                name: "Custom 64240",
                rpcURL: "https://custom-64240.example"
            ),
        ])
        let loadCount = LockedTestValue(0)
        let cache = CustomNetworkCache(loader: {
            _ = loadCount.increment()
            return loadCount.value == 1 ? .unavailable : .loaded(snapshot)
        })

        XCTAssertTrue(cache.snapshot().orderedEntries.isEmpty)
        XCTAssertNotNil(cache.snapshot().entriesByChainId[64_240])
        XCTAssertEqual(loadCount.value, 2)
    }

    func testCustomNetworkCacheFailsClosedAfterCorruptReload() async {
        let snapshot = CustomNetworkSnapshot(records: [
            RuntimeTestCatalog.customRecord(
                chainId: 64_240,
                name: "Custom 64240",
                rpcURL: "https://custom-64240.example"
            ),
        ])
        let loadCount = LockedTestValue(0)
        let isCorrupt = Mutex(false)
        let cache = CustomNetworkCache(loader: {
            _ = loadCount.increment()
            return isCorrupt.withLock { $0 } ? .corrupt : .loaded(snapshot)
        })

        XCTAssertNotNil(cache.snapshot().entriesByChainId[64_240])
        isCorrupt.withLock { $0 = true }
        cache.invalidate()
        XCTAssertTrue(cache.snapshot().orderedEntries.isEmpty)
        XCTAssertTrue(cache.snapshot().orderedEntries.isEmpty)
        XCTAssertEqual(loadCount.value, 2)
    }

    func testCustomNetworkCacheInvalidationPublishesNewGenerationToConcurrentReaders() async {
        let generationA = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Generation A", rpcURL: "https://generation-a.example"),
            ]
        )
        let generationB = CustomNetworkSnapshot(
            records: [
                RuntimeTestCatalog.customRecord(chainId: 64240, name: "Generation B", rpcURL: "https://generation-b.example"),
            ]
        )
        let generationState = Mutex((generation: generationA, loadCount: 0, invalidSnapshotCount: 0))
        let firstLoadStarted = DispatchSemaphore(value: 0)
        let allowFirstLoadToFinish = DispatchSemaphore(value: 0)
        let cache = CustomNetworkCache(loader: {
            let (currentLoadCount, snapshot) = generationState.withLock { state in
                state.loadCount += 1
                return (state.loadCount, state.generation)
            }

            if currentLoadCount == 1 {
                firstLoadStarted.signal()
                _ = allowFirstLoadToFinish.wait(timeout: .now() + 5)
            }
            return .loaded(snapshot)
        })

        let initialReadFinished = expectation(description: "Initial cache read finished")
        DispatchQueue.global().async {
            _ = cache.snapshot()
            initialReadFinished.fulfill()
        }
        XCTAssertEqual(firstLoadStarted.wait(timeout: .now() + 5), .success)

        generationState.withLock { $0.generation = generationB }

        let invalidationStarted = DispatchSemaphore(value: 0)
        let invalidationFinished = expectation(description: "Concurrent invalidation finished")
        DispatchQueue.global().async {
            invalidationStarted.signal()
            cache.invalidate()
            invalidationFinished.fulfill()
        }
        XCTAssertEqual(invalidationStarted.wait(timeout: .now() + 5), .success)
        allowFirstLoadToFinish.signal()
        await fulfillment(of: [initialReadFinished, invalidationFinished], timeout: 5)

        DispatchQueue.concurrentPerform(iterations: 512) { _ in
            let loaded = cache.snapshot()
            if loaded.entriesByChainId[64240]?.rpcURL.absoluteString != "https://generation-b.example" {
                generationState.withLock { $0.invalidSnapshotCount += 1 }
            }
        }

        let (finalLoadCount, finalInvalidSnapshotCount) = generationState.withLock {
            ($0.loadCount, $0.invalidSnapshotCount)
        }

        XCTAssertEqual(finalInvalidSnapshotCount, 0)
        XCTAssertEqual(finalLoadCount, 2)
        XCTAssertEqual(
            cache.snapshot().entriesByChainId[64240]?.resolvedNetwork.network.name,
            "Generation B"
        )
    }

    func testCatalogRejectsMalformedRecords() async {
        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            RuntimeTestCatalog.record(chainId: 1, fallbackRPCURL: "https://fallback.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .duplicateChainId(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1,
                   alchemyNetwork: "eth-mainnet",
                   fallbackRPCURL: "https://fallback.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, fallbackRPCURL: "http://insecure.example"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidFallbackRPCURL(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, fallbackRPCURL: "relative-endpoint"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidFallbackRPCURL(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "eth/mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidAlchemyNetwork(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, alchemyNetwork: "same-slug"),
            RuntimeTestCatalog.record(chainId: 2, alchemyNetwork: "same-slug"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .duplicateAlchemyNetwork("same-slug"))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
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
            RuntimeTestCatalog.record(chainId: 1, accountDisabledAlchemyNetwork: "taiko-mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidEndpointDescriptor(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
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
            RuntimeTestCatalog.record(chainId: 0, alchemyNetwork: "invalid-chain"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidChainId(0))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(chainId: 1, name: " Test Network", alchemyNetwork: "eth-mainnet"),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidName(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
                chainId: 1,
                nativeCurrency: NetworkCatalogNativeCurrency(name: "Ether", symbol: "", decimals: 18),
                alchemyNetwork: "eth-mainnet"
            ),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidNativeCurrency(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
                chainId: 1,
                explorerURL: "relative-explorer",
                alchemyNetwork: "eth-mainnet"
            ),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidExplorerURL(1))
        }

        XCTAssertThrowsError(try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
                chainId: 1,
                alchemyNetwork: "eth-mainnet",
                feeMarketCheckedAt: "not-an-iso8601-date"
            ),
        ])) { error in
            XCTAssertEqual(error as? NetworkCatalogError, .invalidFeeMarketHint(1))
        }
    }

    func testEndpointMismatchedFeeMarketHintDoesNotDisableCatalog()
        async throws
    {
        let catalog = try NetworkCatalog(records: [
            RuntimeTestCatalog.record(
                chainId: 1,
                alchemyNetwork: "eth-mainnet",
                feeMarketSupport: .eip1559,
                feeMarketObservedEndpoint: "https://rpc.example"
            ),
        ])
        let resolver = NetworkResolver(
            catalog: catalog,
            catalogOwnedChainIds: [1],
            customSnapshot: { .empty }
        )

        XCTAssertTrue(resolver.catalogIsAvailable)
        let resolved = try XCTUnwrap(
            resolver.resolve(chainId: 1).resolvedNetwork
        )
        XCTAssertNil(resolved.rpcEndpoint.feeMarketHint)
        XCTAssertTrue(
            resolved.rpcEndpoint.requiresFeeMarketDetection()
        )
        XCTAssertTrue(resolved.allowsAlchemyAuthorization)
        XCTAssertEqual(
            resolved.rpcURL.absoluteString,
            "https://eth-mainnet.g.alchemy.com/v2"
        )
    }

    func testCatalogDataRejectsInvalidJSONAndMissingRequiredFields() async {
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

    private struct ConflictExpectation {
        let alchemyNetwork: String
        let name: String
        let symbol: String
        let isTestnet: Bool
    }

    private func loadedCatalog() throws -> NetworkCatalog { try RuntimeTestCatalog.load() }
}
