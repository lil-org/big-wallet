// ∅ 2026 lil org

import CryptoKit
import Dispatch
import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class NetworkCatalogTests: XCTestCase {

    func testCatalogInventoryGoldenSHA256() async throws {
        let rows = try loadedCatalog().records
            .sorted { $0.chainId < $1.chainId }
            .map { String($0.chainId) }

        XCTAssertEqual(
            sha256(rows: rows),
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
            sha256(rows: rows),
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
            sha256(rows: rows),
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
            sha256(rows: rows),
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
            Networks.pinned.map(\.chainId),
            [1, 7777777, 10, 8453, 42161]
        )
    }

    func testEveryNetworkListSharesOneOrder() async {
        let ordered = Networks.ordered
        XCTAssertEqual(
            ordered.prefix(Networks.pinned.count).map(\.chainId),
            Networks.pinned.map(\.chainId)
        )
        XCTAssertEqual(
            ordered.suffix(Networks.testnets.count).map(\.chainId),
            Networks.testnets.map(\.chainId)
        )
        XCTAssertEqual(
            ordered.count,
            Networks.pinned.count + Networks.custom.count + Networks.mainnets.count + Networks.testnets.count
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let customSnapshotCount = LockedNetworkCatalogCounter()
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
            ]
        )
        let customSnapshotCount = LockedNetworkCatalogCounter()
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
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
        let catalogRecord = record(chainId: 1, alchemyNetwork: "eth-mainnet")
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://bundled-fallback.example"),
        ])
        let records = [
            customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            customRecord(chainId: 40, name: "User Telos", rpcURL: "https://custom-telos.example"),
            customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
        ])
        let records = [
            customRecord(chainId: 64240, name: "First 64240", rpcURL: "https://first-64240.example"),
            customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
            customRecord(chainId: 64240, name: "Last 64240", rpcURL: "https://last-64240.example"),
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
                customRecord(chainId: 64240, name: "Public HTTPS", rpcURL: "https://rpc.example:8545"),
                customRecord(chainId: 64241, name: "Relative", rpcURL: "relative-endpoint"),
                customRecord(chainId: 64242, name: "WebSocket", rpcURL: "ws://localhost:8546"),
                customRecord(chainId: 64243, name: "File", rpcURL: "file:///tmp/rpc"),
                customRecord(chainId: 64244, name: "Localhost", rpcURL: "http://localhost:8545"),
                customRecord(chainId: 64245, name: "Private IPv4", rpcURL: "https://10.0.0.1"),
                customRecord(chainId: 64246, name: "Local IPv6", rpcURL: "https://[fe80::1]"),
                customRecord(chainId: 64247, name: "Public Literal HTTP", rpcURL: "http://1.1.1.1:8545"),
                customRecord(chainId: 64248, name: "Insecure Hostname", rpcURL: "http://rpc.example:8545"),
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
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let customSnapshotCount = LockedNetworkCatalogCounter()
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 300, alchemyNetwork: "zksync-sepolia"),
        ])
        let snapshot = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 1, name: "Archived Ethereum", rpcURL: "https://custom-ethereum.example"),
                customRecord(chainId: 40, name: "Archived Telos", rpcURL: "https://custom-telos.example"),
                customRecord(chainId: 300, name: "Archived ZKsync", rpcURL: "https://custom-zksync.example"),
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
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

    func testInvalidCatalogRecoversUnexpectedIDAndSuppressesItsCustomFallback() async throws {
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
            ]
        )
        let customSnapshotCount = LockedNetworkCatalogCounter()
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

    func testCatalogPreservesInputOrderAndBundledProjectionUsesNameThenChainIDOrdering() async throws {
        let catalog = try NetworkCatalog(records: [
            record(chainId: 30, name: "Zulu", fallbackRPCURL: "https://zulu.example"),
            record(chainId: 20, name: "Alpha", fallbackRPCURL: "https://alpha-20.example"),
            record(chainId: 10, name: "Alpha", fallbackRPCURL: "https://alpha-10.example"),
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
            record(chainId: 1, alchemyNetwork: "eth-mainnet"),
            record(chainId: 40, fallbackRPCURL: "https://fallback.example"),
        ])
        let customSnapshotCount = LockedNetworkCatalogCounter()
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
                customRecord(chainId: 64240, name: "Custom 64240", rpcURL: "https://custom-64240.example"),
            ]
        )
        let loadCount = LockedNetworkCatalogCounter()
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
            customRecord(chainId: 64_240, name: "Reviewed", rpcURL: "https://reviewed.example"),
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
        let catalog = try NetworkCatalog(records: [record(chainId: 1, alchemyNetwork: "eth-mainnet")])
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
            customRecord(
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
            customRecord(
                chainId: 64_240,
                name: "Custom 64240",
                rpcURL: "https://custom-64240.example"
            ),
        ])
        let loadCount = LockedNetworkCatalogCounter()
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
            customRecord(
                chainId: 64_240,
                name: "Custom 64240",
                rpcURL: "https://custom-64240.example"
            ),
        ])
        let loadCount = LockedNetworkCatalogCounter()
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
                customRecord(chainId: 64240, name: "Generation A", rpcURL: "https://generation-a.example"),
            ]
        )
        let generationB = CustomNetworkSnapshot(
            records: [
                customRecord(chainId: 64240, name: "Generation B", rpcURL: "https://generation-b.example"),
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

        XCTAssertThrowsError(try NetworkCatalog(records: [
            record(
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
            record(
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

    func testCatalogLoaderThrowsForMissingAndInvalidResources() async throws {
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

    func testSafariRPCClientRoutesReversedConcurrentResponsesToTheirOwnCompletions() async throws {
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
        var failures = [String]()

        for index in 0..<requestCount {
            let url = try XCTUnwrap(URL(string: "https://rpc.example/request-\(index)"))
            let body = try JSONSerialization.data(withJSONObject: ["request": index])
            Task { @MainActor in
                let response =
                    (try? await client.send(endpoint: .unauthenticated(url), body: body, expectedResponseID: index))?
                    .json
                defer {
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

        await fulfillment(of: [allRequestsStarted], timeout: 5)

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

        await fulfillment(of: [allRequestsCompleted], timeout: 5)
        let recordedFailures = failures
        XCTAssertTrue(recordedFailures.isEmpty, recordedFailures.joined(separator: "\n"))
    }

    func testSafariRPCClientAttachesDynamicAlchemyAuthorization() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let session = makeSafariAuthorizationSession { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token"
            )
            return (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(token: "current-token")
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Authorized Safari RPC completed")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), body: Data(#"{"method":"eth_chainId"}"#.utf8), expectedResponseID: 1
                ))?.json
            XCTAssertEqual(response?["result"] as? String, "ok")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testSafariRPCClientRetriesOnceWithReplacementAuthorizationAfter401() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            if attempt == 1 {
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer rejected-token"
                )
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer replacement-token"
            )
            return (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Safari RPC recovered from 401")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), body: Data(#"{"method":"eth_chainId"}"#.utf8), expectedResponseID: 1
                ))?.json
            XCTAssertEqual(response?["result"] as? String, "ok")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCClientNeverReplaysRawTransactionAfter401() async throws {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), body)
            return (
                401,
                Data(
                    #"[{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"FeeTooLow","data":{"reason":"EffectivePriorityFeePerGas too low"}}}]"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "raw transaction rejection returned without replay"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: 1))?
                .json
            XCTAssertEqual(response?["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(response?["id"] as? Int, 1)
            let error = response?["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32_000)
            XCTAssertEqual(error?["message"] as? String, "FeeTooLow")
            let data = error?["data"] as? [String: Any]
            XCTAssertEqual(
                data?["reason"] as? String,
                "EffectivePriorityFeePerGas too low"
            )
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
    }

    func testSafariRPCClientReturnsUniqueMatchingDictionaryFromArrayResponse()
        async throws
    {
        let url = try XCTUnwrap(URL(string: "https://rpc.example"))
        let session = makeSafariAuthorizationSession { _ in
            return (
                200,
                Data(
                    #"[{"jsonrpc":"2.0","id":3,"result":"wrong"},null,{"jsonrpc":"2.0","id":2,"result":"matched"}]"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session)
        let completion = expectation(
            description: "Safari RPC returned the matching array dictionary"
        )

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: .unauthenticated(url),
                    body: Data(#"{"jsonrpc":"2.0","id":2,"method":"eth_chainId"}"#.utf8), expectedResponseID: 2))?.json
            XCTAssertEqual(response?["id"] as? Int, 2)
            XCTAssertEqual(response?["result"] as? String, "matched")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
    }

    func testSafariRPCClientRejectsMismatchedAndAmbiguousResponseIDs()
        async throws
    {
        let fixtures: [(path: String, response: String)] = [
            (
                "wrong-top-level",
                #"{"jsonrpc":"2.0","id":3,"result":"wrong"}"#
            ),
            (
                "no-array-match",
                #"[{"jsonrpc":"2.0","id":3,"result":"wrong"}]"#
            ),
            (
                "duplicate-array-match",
                #"[{"jsonrpc":"2.0","id":1,"result":"first"},{"jsonrpc":"2.0","id":1,"result":"second"}]"#
            ),
            (
                "boolean-top-level",
                #"{"jsonrpc":"2.0","id":true,"result":"wrong"}"#
            ),
            (
                "string-mismatch",
                #"{"jsonrpc":"2.0","id":"3","result":"wrong"}"#
            ),
            (
                "non-numeric-string",
                #"{"jsonrpc":"2.0","id":"abc","result":"wrong"}"#
            ),
            (
                "duplicate-mixed-type-match",
                #"[{"jsonrpc":"2.0","id":1,"result":"first"},{"jsonrpc":"2.0","id":"1","result":"second"}]"#
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session)

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC rejected \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        body: Data(
                            #"{"jsonrpc":"2.0","id":1,"method":"eth_chainId"}"#.utf8
                        ), expectedResponseID: 1))?.json
                XCTAssertNil(response, fixture.path)
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientAcceptsMissingAndNullTopLevelResponseIDs()
        async throws
    {
        let fixtures: [(path: String, response: String)] = [
            ("missing", #"{"jsonrpc":"2.0","result":"ok"}"#),
            (
                "null",
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session)

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC accepted \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        body: Data(
                            #"{"jsonrpc":"2.0","id":2,"method":"eth_chainId"}"#.utf8
                        ), expectedResponseID: 2))?.json
                XCTAssertNotNil(response, fixture.path)
                XCTAssertEqual(
                    response?["id"] as? Int,
                    2,
                    fixture.path
                )
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientAcceptsStringResponseIDs() async throws {
        let fixtures: [(path: String, response: String, result: String)] = [
            (
                "string-single",
                #"{"jsonrpc":"2.0","id":"2","result":"ok"}"#,
                "ok"
            ),
            (
                "string-batch",
                #"[{"jsonrpc":"2.0","id":"3","result":"wrong"},{"jsonrpc":"2.0","id":"2","result":"matched"}]"#,
                "matched"
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session)

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC accepted \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        body: Data(
                            #"{"jsonrpc":"2.0","id":2,"method":"eth_chainId"}"#.utf8
                        ), expectedResponseID: 2))?.json
                XCTAssertNotNil(response, fixture.path)
                XCTAssertEqual(
                    response?["id"] as? Int,
                    2,
                    fixture.path
                )
                XCTAssertEqual(
                    response?["result"] as? String,
                    fixture.result,
                    fixture.path
                )
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientRejectsAllRedirects() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://rpc.example/source"))
        let redirectURL = try XCTUnwrap(URL(string: "https://rpc.example/redirect"))

        let session = URLSession(configuration: .ephemeral)
        defer {
            session.invalidateAndCancel()
        }
        let task = session.dataTask(with: sourceURL)
        let delegate = NoRedirectSessionDelegate()

        for statusCode in [307, 308] {
            let completion = expectation(
                description: "Redirect \(statusCode) was rejected"
            )
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: sourceURL,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": redirectURL.absoluteString]
                )
            )
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: redirectURL)
            ) { request in
                XCTAssertNil(request)
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 1)
        }
    }

    func testSafariRPCClientRejectsRedirectResponseBody() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://rpc.example/source"))
        let redirectURL = try XCTUnwrap(URL(string: "https://rpc.example/redirect"))
        SafariRedirectURLProtocol.configure(
            sourceURL: sourceURL,
            redirectURL: redirectURL,
            statusCode: 307,
            responseData: Data(
                #"{"jsonrpc":"2.0","id":1,"result":"source"}"#.utf8
            )
        )
        defer {
            SafariRedirectURLProtocol.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariRedirectURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let client = SafariRPCClient(urlSession: session)
        let completion = expectation(
            description: "Replay-safe redirect rejected"
        )

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: .unauthenticated(sourceURL),
                    body: Data(
                        #"{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}"#.utf8
                    ), expectedResponseID: 1))?.json
            XCTAssertNil(response)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(SafariRedirectURLProtocol.requestCount, 1)
        XCTAssertEqual(
            SafariRedirectURLProtocol.requestedURLs,
            [sourceURL]
        )
    }

    func testSafariRPCClientDoesNotReplayRawTransactionWhenReplacementIsUnavailable()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), body)
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "Unavailable replacement authorization returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: 1))?
                .json
            XCTAssertEqual(response?["error"] as? String, "unauthorized")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
    }

    func testSafariRPCClientReplaysSupportedReadOnlyMethodsAfter401() async throws {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            XCTAssertLessThanOrEqual(attempt, 2)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer replacement-token"
            )
            if attempt == 1 {
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }
            return (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "supported read-only Safari RPCs recovered from 401"
        )
        completion.assertForOverFulfill = true
        let body = Data(
            #"[{"jsonrpc":"2.0","id":1,"method":"eth_blobBaseFee","params":[]},{"jsonrpc":"2.0","id":2,"method":"eth_estimateUserOperationGas","params":[]},{"jsonrpc":"2.0","id":3,"method":"eth_supportedEntryPoints","params":[]},{"jsonrpc":"2.0","id":4,"method":"txpool_contentFrom","params":[]}]"#.utf8
        )

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: 1))?
                .json
            XCTAssertEqual(response?["result"] as? String, "ok")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCClientFailsClosedForUnknownAndMixedBatchMethodsAfter401()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "unused-replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let bodies = [
            Data(
                #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransactionSync","params":["0x01"]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":2,"method":"vendor_unknownMutation","params":[]}"#.utf8
            ),
            Data(
                #"[{"jsonrpc":"2.0","id":3,"method":"eth_sendRawTransaction","params":["0x02"]}]"#.utf8
            ),
            Data(
                #"[{"jsonrpc":"2.0","id":4,"method":"eth_chainId","params":[]},{"jsonrpc":"2.0","id":5,"method":"eth_sendRawTransaction","params":["0x03"]}]"#.utf8
            ),
        ]

        for (index, body) in bodies.enumerated() {
            let completion = expectation(
                description: "non-replayable Safari RPC \(index) completed"
            )
            completion.assertForOverFulfill = true
            Task { @MainActor in
                let response =
                    (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: index + 1))?
                    .json
                XCTAssertEqual(response?["error"] as? String, "unauthorized")
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }

        XCTAssertEqual(requestCount.value, bodies.count)
        XCTAssertEqual(
            authorizationProvider.authorizationCallCount,
            bodies.count
        )
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(
            authorizationProvider.invalidationCallCount,
            bodies.count
        )
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            [String](repeating: "rejected-token", count: bodies.count)
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs,
            [URL](repeating: url, count: bodies.count)
        )
    }

    func testSafariRPCClientInvalidatesRejectedRawTransactionAuthorizationWithoutReplay()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), body)
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "persistent Safari authorization failure returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: 1))?
                .json
            XCTAssertEqual(response?["error"] as? String, "unauthorized")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
        XCTAssertEqual(authorizationProvider.invalidationURLs, [url])
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationAfter403() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token"
            )
            return (403, Data(#"{"error":"forbidden"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Safari RPC returned forbidden response")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), body: Data(#"{"method":"eth_chainId"}"#.utf8), expectedResponseID: 1
                ))?.json
            XCTAssertEqual(response?["error"] as? String, "forbidden")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCCancellationSurvivesUncooperativeAuthorizationSteps() async throws {
        let cases: [(SafariAuthorizationProviderStub.Checkpoint, String?)] = [
            (.authorization, "replacement"),
            (.replacement, "replacement"),
            (.replacement, nil),
            (.invalidation, "replacement")
        ]
        for (checkpoint, replacement) in cases {
            let gate = SafariAuthorizationSuspension()
            let reachedCheckpoint = expectation(description: "Reached \(checkpoint)")
            let requestCount = LockedNetworkCatalogCounter()
            let provider = SafariAuthorizationProviderStub(
                token: "rejected", replacementToken: replacement,
                pause: { point in
                    guard point == checkpoint else { return }
                    reachedCheckpoint.fulfill()
                    await gate.wait()
                }
            )
            let session = makeSafariAuthorizationSession { _ in
                requestCount.increment()
                return (401, Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"rejected"}}"#.utf8))
            }
            defer {
                gate.resume()
                session.invalidateAndCancel()
                SafariAuthorizationURLProtocol.removeRequestHandler()
            }
            let client = SafariRPCClient(urlSession: session, authorizationProvider: provider)
            let endpoint = alchemyEndpoint(try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2")))
            let method = checkpoint == .invalidation ? "eth_sendRawTransaction" : "eth_chainId"
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method])
            let task = Task { try await client.send(endpoint: endpoint, body: body, expectedResponseID: 1) }
            await fulfillment(of: [reachedCheckpoint], timeout: 2)
            task.cancel()
            gate.resume()
            switch await task.result {
            case .success:
                XCTFail("Canceled request accepted a response after \(checkpoint)")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)")
            }
            XCTAssertEqual(requestCount.value, checkpoint == .authorization ? 0 : 1)
            XCTAssertEqual(provider.replacementCallCount, checkpoint == .replacement ? 1 : 0)
            XCTAssertEqual(provider.invalidationCallCount, checkpoint == .invalidation ? 1 : 0)
        }
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationAfterNetworkFailure()
        async throws
    {
        try await assertSafariRawSendDoesNotRecoverAuthorization(
            response: { _ in
                throw URLError(.networkConnectionLost)
            },
            validate: { response in
                XCTAssertNil(response)
            }
        )
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationForHTTP200RPCError()
        async throws
    {
        try await assertSafariRawSendDoesNotRecoverAuthorization(
            response: { _ in
                return (
                    200,
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"already processed"}}"#.utf8
                    )
                )
            },
            validate: { response in
                let error = response?["error"] as? [String: Any]
                XCTAssertEqual(error?["code"] as? Int, -32_002)
                XCTAssertEqual(error?["message"] as? String, "already processed")
            }
        )
    }

    func testSafariRPCClientNeverAttachesAuthorizationToCustomOrKeyedURLs() async throws {
        let keylessCustomURL = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let urls = try [
            XCTUnwrap(URL(string: "https://rpc.example/custom")),
            keylessCustomURL,
            XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2/embedded-key")),
        ]
        let authorizationProvider = SafariAuthorizationProviderStub(token: "alchemy-only-token")
        for url in urls {
            let session = makeSafariAuthorizationSession { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"result":"ok"}"#.utf8))
            }
            let client = SafariRPCClient(
                urlSession: session,
                authorizationProvider: authorizationProvider
            )
            let completion = expectation(description: "Unauthenticated RPC completed for \(url)")

            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url), body: Data(#"{"method":"eth_chainId"}"#.utf8),
                        expectedResponseID: 1))?.json
                XCTAssertEqual(response?["result"] as? String, "ok")
                completion.fulfill()
            }

            await fulfillment(of: [completion], timeout: 2)
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }

        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
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

    private func alchemyEndpoint(_ url: URL) -> EthereumRPCEndpoint {
        return .catalog(url, alchemyNetwork: "eth-mainnet")
    }

    private func sha256(rows: [String]) -> String {
        let canonicalText = rows.joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonicalText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeSafariAuthorizationSession(
        requestHandler: @escaping SafariAuthorizationURLProtocol.RequestHandler
    ) -> URLSession {
        SafariAuthorizationURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariAuthorizationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func assertSafariRawSendDoesNotRecoverAuthorization(
        response: @escaping SafariAuthorizationURLProtocol.RequestHandler,
        validate: @escaping ([String: Any]?) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2"),
            file: file,
            line: line
        )
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Self.bodyData(from: request),
                body,
                file: file,
                line: line
            )
            return try response(request)
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "Non-401 Safari raw-send failure returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let result = (try? await client.send(endpoint: alchemyEndpoint(url), body: body, expectedResponseID: 1))?
                .json
            validate(result)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1, file: file, line: line)
        XCTAssertEqual(
            authorizationProvider.authorizationCallCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.replacementCallCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.invalidationCallCount,
            0,
            file: file,
            line: line
        )
    }

    nonisolated private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
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
                        accountDisabledAlchemyNetwork: String? = nil,
                        feeMarketSupport: EthereumFeeMarketSupport = .unknown,
                        feeMarketCheckedAt: String = "2026-07-23T00:00:00Z",
                        feeMarketObservedEndpoint: String? = nil) -> NetworkCatalogRecord {
        let derivedEndpoint = alchemyNetwork.flatMap(AlchemyRPC.url(network:))?
            .absoluteString ?? fallbackRPCURL ?? "https://invalid.example"
        return NetworkCatalogRecord(
            chainId: chainId,
            name: name,
            nativeCurrency: nativeCurrency,
            explorerURL: explorerURL,
            isTestnet: false,
            displayPrice: false,
            alchemyNetwork: alchemyNetwork,
            fallbackRPCURL: fallbackRPCURL,
            accountDisabledAlchemyNetwork: accountDisabledAlchemyNetwork,
            feeMarketHint: EthereumFeeMarketHint(
                support: feeMarketSupport,
                checkedAt: feeMarketCheckedAt,
                observedEndpoint: feeMarketObservedEndpoint ?? derivedEndpoint
            )
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

    private func withFixtureBundle(catalogData: Data? = nil,
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

private final class SafariAuthorizationProviderStub: AlchemyAuthorizationProviding {
    enum Checkpoint: Equatable, Sendable { case authorization, replacement, invalidation }
    private struct State: Sendable {
        var authorizationCallCount = 0
        var replacementCallCount = 0
        var invalidatedTokens = [String]()
        var invalidationURLs = [URL]()
    }
    private let state = Mutex(State())
    private let token: String?
    private let replacementToken: String?
    private let pause: @Sendable (Checkpoint) async -> Void

    init(
        token: String? = nil,
        replacementToken: String? = nil,
        pause: @escaping @Sendable (Checkpoint) async -> Void = { _ in }
    ) {
        self.token = token
        self.replacementToken = replacementToken
        self.pause = pause
    }

    var authorizationCallCount: Int { state.withLock { $0.authorizationCallCount } }
    var replacementCallCount: Int { state.withLock { $0.replacementCallCount } }
    var invalidationCallCount: Int { state.withLock { $0.invalidatedTokens.count } }
    var invalidatedTokens: [String] { state.withLock { $0.invalidatedTokens } }
    var invalidationURLs: [URL] { state.withLock { $0.invalidationURLs } }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.authorizationCallCount += 1 }
        await pause(.authorization)
        return AlchemyJWTProvider.isAlchemyRPCURL(url) ? token.map { AlchemyAuthorization(token: $0) } : nil
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.replacementCallCount += 1 }
        await pause(.replacement)
        return AlchemyJWTProvider.isAlchemyRPCURL(url) ? replacementToken.map { AlchemyAuthorization(token: $0) } : nil
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        state.withLock { state in
            state.invalidatedTokens.append(rejected.token)
            state.invalidationURLs.append(url)
        }
        await pause(.invalidation)
    }
}

private final class SafariAuthorizationSuspension: Sendable {
    private struct State {
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
    }
    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state in
                guard !state.released else { return true }
                state.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func resume() {
        let continuation = state.withLock { state in
            state.released = true
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class LockedNetworkCatalogCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    @discardableResult
    func increment() -> Int {
        count.withLock {
            $0 += 1; return $0
        }
    }
}

private final class SafariAuthorizationURLProtocol: URLProtocol {

    typealias RequestHandler = @Sendable (URLRequest) throws -> (statusCode: Int, data: Data)

    private static let requestHandler = Mutex<RequestHandler?>(nil)
    static func setRequestHandler(_ handler: @escaping RequestHandler) { requestHandler.withLock { $0 = handler } }
    static func removeRequestHandler() { requestHandler.withLock { $0 = nil } }
    private static func currentRequestHandler() -> RequestHandler? { requestHandler.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let requestHandler = Self.currentRequestHandler(),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let result = try requestHandler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

}

private final class SafariRedirectURLProtocol: URLProtocol {

    private struct Configuration: Sendable {
        var sourceURL: URL?
        var redirectURL: URL?
        var statusCode = 307
        var responseData = Data()
        var recordedURLs = [URL]()
    }
    private static let configuration = Mutex(Configuration())
    static var requestCount: Int { configuration.withLock { $0.recordedURLs.count } }
    static var requestedURLs: [URL] { configuration.withLock { $0.recordedURLs } }

    static func configure(sourceURL: URL, redirectURL: URL, statusCode: Int, responseData: Data) {
        configuration.withLock { $0 = Configuration(sourceURL: sourceURL, redirectURL: redirectURL, statusCode: statusCode, responseData: responseData) }
    }
    static func reset() { configuration.withLock { $0 = Configuration() } }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        let (sourceURL, redirectURL, statusCode, responseData) = Self.configuration.withLock { configuration in
            configuration.recordedURLs.append(url)
            return (configuration.sourceURL, configuration.redirectURL, configuration.statusCode, configuration.responseData)
        }

        guard url == sourceURL,
              let redirectURL,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
              ) else {
            respondWithSuccess(for: url)
            return
        }

        var redirectRequest = request
        redirectRequest.url = redirectURL
        client?.urlProtocol(
            self,
            wasRedirectedTo: redirectRequest,
            redirectResponse: response
        )
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respondWithSuccess(for url: URL) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"jsonrpc":"2.0","id":1,"result":"redirected"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

}

private final class SafariRPCClientURLProtocol: URLProtocol {
    // Only terminal delivery crosses the Foundation boundary; each loader gates completion and cancellation.
    private final class ResponseEndpoint: @unchecked Sendable {
        private weak var owner: SafariRPCClientURLProtocol?
        let identifier: ObjectIdentifier
        let request: URLRequest

        init(_ owner: SafariRPCClientURLProtocol) {
            self.owner = owner
            identifier = ObjectIdentifier(owner)
            request = owner.request
        }

        func complete(data: Data?) { owner?.completeResponse(data: data) }
    }

    private struct State: Sendable {
        var pending = [ResponseEndpoint]()
        var requestStarted: (@Sendable () -> Void)?
    }
    private static let state = Mutex(State())
    private let responseFinished = Mutex(false)

    static var pendingRequests: [URLRequest] {
        state.withLock { $0.pending.map(\.request) }
    }

    static func reset(requestStarted: (@Sendable () -> Void)? = nil) {
        state.withLock { $0 = State(requestStarted: requestStarted) }
    }

    static func completePendingRequestsInReverse(responseData: (URLRequest) -> Data?) {
        let endpoints = state.withLock { state in
            let endpoints = Array(state.pending.reversed())
            state.pending.removeAll()
            state.requestStarted = nil
            return endpoints
        }
        for endpoint in endpoints { endpoint.complete(data: responseData(endpoint.request)) }
    }

    private func completeResponse(data: Data?) {
        let canFinish = responseFinished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard canFinish else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]),
              let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let endpoint = ResponseEndpoint(self)
        let started = Self.state.withLock { state in
            state.pending.append(endpoint)
            return state.requestStarted
        }
        started?()
    }

    override func stopLoading() {
        responseFinished.withLock { $0 = true }
        let identifier = ObjectIdentifier(self)
        Self.state.withLock { $0.pending.removeAll { $0.identifier == identifier } }
    }
}
