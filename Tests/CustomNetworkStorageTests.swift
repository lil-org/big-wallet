// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class CustomNetworkStorageTests: XCTestCase {

#if os(macOS)
    func testCustomRPCPlistsAllowHTTPAndDescribeLocalNetworkAccess() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let extensionPlists = [
            "Safari macOS/Info.plist",
            "Safari iOS/Info.plist",
            "Safari visionOS/Info.plist",
        ]
        let appPlists = [
            "App macOS/Info.plist",
            "App iOS/Info.plist",
            "App visionOS/Info.plist",
            "Big Wallet Ambient/Info.plist",
        ]

        for relativePath in extensionPlists {
            let plist = try propertyList(at: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist["NSAppTransportSecurity"] as? [String: Bool],
                ["NSAllowsArbitraryLoads": true],
                relativePath
            )
        }
        for relativePath in appPlists {
            let plist = try propertyList(at: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist["NSLocalNetworkUsageDescription"] as? String,
                "Big Wallet connects to custom blockchain RPC endpoints you choose on your local network.",
                relativePath
            )
        }
    }
#endif

    func testUnreadableArchiveFailsClosedWithoutRepair() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corruptArchive = Data([0x7b])
        defaults.set(corruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)

        guard case .corrupt = SharedDefaults.loadCustomNetworkSnapshotResult(
            from: defaults
        ) else {
            return XCTFail("Expected a corrupt snapshot load")
        }
        XCTAssertTrue(SharedDefaults.loadCustomNetworkSnapshot(from: defaults).orderedEntries.isEmpty)
        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_240, rpcURLs: ["https://rpc.example"]),
                to: defaults
            ),
            .unavailable
        )
        XCTAssertEqual(
            defaults.data(forKey: SharedDefaults.customEthereumNetworksKey),
            corruptArchive
        )
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [SharedDefaults.customEthereumNetworksKey]
        )
    }

    func testSnapshotLoadReportsSynchronizationFailure() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        guard case .unavailable = SharedDefaults.loadCustomNetworkSnapshotResult(
            from: defaults,
            synchronizeDefaults: { _ in false }
        ) else {
            return XCTFail("Expected an unavailable snapshot load")
        }
    }

    func testPartiallyCorruptArchiveSalvagesValidRecordsAndRepairsOnInsertion() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let valid = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                customNetwork(chainId: 64_240, rpcURLs: ["https://rpc.example"])
            )
        )
        let archive = try JSONSerialization.data(withJSONObject: [
            valid,
            ["chainId": "0xfaf1", "chainName": "Incomplete"],
        ])
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)

        let initialSnapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        XCTAssertEqual(initialSnapshot.orderedEntries.map(\.chainId), [64_240])
        XCTAssertEqual(
            initialSnapshot.entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://rpc.example"
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_242, rpcURLs: ["https://second.example"]),
                to: defaults
            ),
            .inserted
        )
        XCTAssertEqual(try storedNetworks(in: defaults).map(\.chainId), ["0xfaf0", "0xfaf2"])
    }

    func testMixedValidAndInvalidArchiveRetainsValidCustomNetworks() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let valid = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://valid.example"]
        )
        defaults.set(
            try JSONEncoder().encode([valid]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )
        let cache = CustomNetworkCache(loader: {
            SharedDefaults.loadCustomNetworkSnapshotResult(from: defaults)
        })
        XCTAssertNotNil(cache.snapshot().entriesByChainId[64_240])

        let invalid = customNetwork(
            chainId: 0,
            rpcURLs: ["https://invalid.example"]
        )
        defaults.set(
            try JSONEncoder().encode([valid, invalid]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )
        cache.invalidate()

        XCTAssertEqual(cache.snapshot().orderedEntries.map(\.chainId), [64_240])
        guard case .loaded(let snapshot) = SharedDefaults.loadCustomNetworkSnapshotResult(
            from: defaults
        ) else {
            return XCTFail("Expected valid records to be salvaged")
        }
        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64_240])
    }

    func testLastValidDuplicateWins() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = customNetwork(
            chainId: 64_240,
            name: "First",
            rpcURLs: ["https://first.example"]
        )
        defaults.set(
            try JSONEncoder().encode([first]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )
        let cache = CustomNetworkCache(loader: {
            SharedDefaults.loadCustomNetworkSnapshotResult(from: defaults)
        })
        XCTAssertNotNil(cache.snapshot().entriesByChainId[64_240])

        let duplicate = customNetwork(
            chainId: 64_240,
            name: "Second",
            rpcURLs: ["https://second.example"]
        )
        let invalidDuplicate = customNetwork(
            chainId: 64_240,
            name: "Invalid",
            rpcURLs: ["ws://invalid.example"]
        )
        defaults.set(
            try JSONEncoder().encode([first, duplicate, invalidDuplicate]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )
        cache.invalidate()

        XCTAssertEqual(
            cache.snapshot().entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://second.example"
        )
        guard case .loaded(let snapshot) = SharedDefaults.loadCustomNetworkSnapshotResult(
            from: defaults
        ) else {
            return XCTFail("Expected the duplicate archive to remain readable")
        }
        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64_240])
        XCTAssertEqual(snapshot.orderedEntries.first?.definition.chainName, "Second")
    }

    func testExactLegacyDuplicateRemainsReadable() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = customNetwork(
            chainId: 64_240,
            name: "Repeated",
            rpcURLs: ["https://rpc.example"]
        )
        defaults.set(
            try JSONEncoder().encode([network, network]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )

        guard case .loaded(let snapshot) =
                SharedDefaults.loadCustomNetworkSnapshotResult(from: defaults) else {
            return XCTFail("Expected an exact legacy duplicate to remain readable")
        }
        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64_240])
    }

    func testInsertionUsesOneArchiveAndSnapshotUsesArchivedRPC() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = customNetwork(
            chainId: 64_240,
            name: "First",
            rpcURLs: ["https://first.example"]
        )
        let second = customNetwork(
            chainId: 64_241,
            name: "Second",
            rpcURLs: ["http://1.1.1.1:8545"]
        )

        XCTAssertEqual(SharedDefaults.insertNetwork(first, to: defaults), .inserted)
        XCTAssertEqual(SharedDefaults.insertNetwork(second, to: defaults), .inserted)

        let records = try storedNetworks(in: defaults)
        XCTAssertEqual(records.map(\.chainName), ["First", "Second"])
        let snapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        XCTAssertEqual(snapshot.orderedEntries.map(\.rpcURL.absoluteString), [
            "https://first.example",
            "http://1.1.1.1:8545",
        ])
        XCTAssertEqual(
            Set(defaults.persistentDomain(forName: suiteName)?.keys.map { $0 } ?? []),
            [SharedDefaults.customEthereumNetworksKey]
        )
    }

    func testInsertionStoresValidHTTPAndHTTPSURLsAndReloadsPreferredEndpoint() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = customNetwork(
            chainId: 64_240,
            rpcURLs: [
                "https://10.0.0.1:8545",
                "https://safe.example",
                "http://rpc.example:8545",
                "http://1.1.1.1:8545",
                "ws://localhost:8546",
                "file:///tmp/node",
                "relative-endpoint",
            ]
        )

        XCTAssertEqual(SharedDefaults.insertNetwork(network, to: defaults), .inserted)

        let stored = try XCTUnwrap(storedNetworks(in: defaults).first)
        XCTAssertEqual(stored.rpcUrls, [
            "https://10.0.0.1:8545",
            "https://safe.example",
            "http://rpc.example:8545",
            "http://1.1.1.1:8545",
        ])
        XCTAssertEqual(
            SharedDefaults.insertNetwork(network, to: defaults),
            .matching
        )
        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://10.0.0.1:8545"
        )
    }

    func testStoredLocalPrivateAndInsecureRPCEndpointsRemainReadable() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let networks = [
            customNetwork(chainId: 64_240, rpcURLs: ["http://localhost:8545"]),
            customNetwork(chainId: 64_241, rpcURLs: ["https://10.0.0.1:8545"]),
            customNetwork(chainId: 64_242, rpcURLs: ["http://rpc.example:8545"]),
            customNetwork(
                chainId: 64_243,
                rpcURLs: ["http://localhost:9545", "https://10.0.0.2:9545"]
            ),
        ]
        let archive = try JSONEncoder().encode(networks)
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)

        let snapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)

        XCTAssertEqual(snapshot.orderedEntries.map(\.rpcURL.absoluteString), [
            "http://localhost:8545",
            "https://10.0.0.1:8545",
            "http://rpc.example:8545",
            "https://10.0.0.2:9545",
        ])
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
    }

    func testMixedArchivePrefersFirstHTTPSUnlessOverridden() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = customNetwork(
            chainId: 64_240,
            rpcURLs: [
                "https://localhost:8545",
                "https://safe.example",
            ]
        )
        let archive = try JSONEncoder().encode([network])
        let key = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_240)
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)

        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://localhost:8545"
        )

        defaults.set("http://localhost:9545", forKey: key)

        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_240]?.rpcURL.absoluteString,
            "http://localhost:9545"
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
    }

    func testLegacyNodeOverrideWinsAndInvalidOverrideFallsBack() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://archived.example"]
        )
        let archive = try JSONEncoder().encode([network])
        let key = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_240)
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set("http://localhost:9545", forKey: key)

        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_240]?.rpcURL.absoluteString,
            "http://localhost:9545"
        )

        defaults.set("ws://localhost:9546", forKey: key)

        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_240]?.rpcURL.absoluteString,
            "https://archived.example"
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
    }

    func testLegacyOverrideRescuesDamagedLastDuplicateAndSurvivesRewrite() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = customNetwork(
            chainId: 64_240,
            name: "First",
            rpcURLs: ["https://first.example"]
        )
        let damaged = customNetwork(
            chainId: 64_240,
            name: "Rescued",
            rpcURLs: ["ws://damaged.example"]
        )
        let archive = try JSONEncoder().encode([first, damaged])
        let key = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_240)
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set("http://localhost:9545", forKey: key)

        let initial = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        XCTAssertEqual(initial.entriesByChainId[64_240]?.definition.chainName, "Rescued")
        XCTAssertEqual(
            initial.entriesByChainId[64_240]?.rpcURL.absoluteString,
            "http://localhost:9545"
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)

        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_241, rpcURLs: ["https://new.example"]),
                to: defaults
            ),
            .inserted
        )
        XCTAssertEqual(try storedNetworks(in: defaults).map(\.chainName), [
            "First",
            "Rescued",
            "Custom",
        ])
        let rewritten = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        XCTAssertEqual(rewritten.entriesByChainId[64_240]?.definition.chainName, "Rescued")
        XCTAssertEqual(
            rewritten.entriesByChainId[64_240]?.rpcURL.absoluteString,
            "http://localhost:9545"
        )
    }

    func testNewInsertionRemovesOrphanLegacyOverride() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existing = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://existing.example"]
        )
        let key = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_241)
        defaults.set(
            try JSONEncoder().encode([existing]),
            forKey: SharedDefaults.customEthereumNetworksKey
        )
        defaults.set("http://localhost:8545", forKey: key)

        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_241, rpcURLs: ["https://new.example"]),
                to: defaults
            ),
            .inserted
        )

        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                .entriesByChainId[64_241]?.rpcURL.absoluteString,
            "https://new.example"
        )
    }

    func testInsertionMatchesLegacyOverrideInsteadOfArchivedEndpoint() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archived = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://archived.example"]
        )
        let matchingOverride = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://override.example"]
        )
        let archive = try JSONEncoder().encode([archived])
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set(
            "https://override.example",
            forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_240)
        )

        XCTAssertEqual(
            SharedDefaults.insertNetwork(matchingOverride, to: defaults),
            .matching
        )
        XCTAssertEqual(
            SharedDefaults.insertNetwork(archived, to: defaults),
            .conflict
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
    }

    func testStoredLocalArchiveMatchesExactlyAndStillRejectsConflicts() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existing = customNetwork(
            chainId: 64_240,
            name: "Local Development",
            rpcURLs: ["http://localhost:8545"]
        )
        let archive = try JSONEncoder().encode([existing])
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)

        XCTAssertEqual(
            SharedDefaults.insertNetwork(existing, to: defaults),
            .matching
        )
        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(
                    chainId: 64_240,
                    name: "Local Development",
                    rpcURLs: ["http://localhost:9545"]
                ),
                to: defaults
            ),
            .conflict
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
    }

    func testStoredLocalOverrideMatchesExactlyAndStillRejectsConflicts() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archived = customNetwork(
            chainId: 64_240,
            name: "Overridden Development",
            rpcURLs: ["https://archived.example"]
        )
        let archive = try JSONEncoder().encode([archived])
        let overrideKey = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_240)
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set("http://10.0.0.4:8545", forKey: overrideKey)

        let matching = customNetwork(
            chainId: 64_240,
            name: "Overridden Development",
            rpcURLs: [
                "http://10.0.0.4:8545",
                "https://archived.example",
            ]
        )
        XCTAssertEqual(SharedDefaults.insertNetwork(matching, to: defaults), .matching)

        let missingEffectiveEndpoint = customNetwork(
            chainId: 64_240,
            name: "Overridden Development",
            rpcURLs: ["https://archived.example"]
        )
        XCTAssertEqual(
            SharedDefaults.insertNetwork(missingEffectiveEndpoint, to: defaults),
            .conflict
        )

        var conflict = matching
        conflict.nativeCurrency.symbol = "DIFFERENT"
        XCTAssertEqual(SharedDefaults.insertNetwork(conflict, to: defaults), .conflict)
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
        XCTAssertEqual(defaults.string(forKey: overrideKey), "http://10.0.0.4:8545")
    }

    func testExactMatchIsIdempotentAndConflictingDefinitionIsRejected() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = customNetwork(
            chainId: 64_240,
            name: "First",
            rpcURLs: ["https://RPC.EXAMPLE:443"]
        )
        let matching = customNetwork(
            chainId: 64_240,
            name: "First",
            rpcURLs: ["https://rpc.example/"]
        )
        let conflict = customNetwork(
            chainId: 64_240,
            name: "Different",
            rpcURLs: ["https://rpc.example/"]
        )
        var currencyConflict = matching
        currencyConflict.nativeCurrency.decimals = 6

        XCTAssertEqual(SharedDefaults.insertNetwork(first, to: defaults), .inserted)
        let archive = defaults.data(forKey: SharedDefaults.customEthereumNetworksKey)
        XCTAssertEqual(SharedDefaults.insertNetwork(matching, to: defaults), .matching)
        XCTAssertEqual(SharedDefaults.insertNetwork(conflict, to: defaults), .conflict)
        XCTAssertEqual(
            SharedDefaults.insertNetwork(currencyConflict, to: defaults),
            .conflict
        )
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
        XCTAssertEqual(try storedNetworks(in: defaults).count, 1)
    }

    func testLocalAndPublicHTTPSEndpointsRoundTrip() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let urls = [
            "http://localhost:8545", "http://127.0.0.1:8545",
            "http://192.168.1.1", "https://10.0.0.1:8545",
            "https://node.local", "http://node:8545",
            "http://[::1]:8545", "https://[fd00::1]",
            "https://[2606:4700:4700::1111]", "http://rpc.example:8545",
            "https://rpc.example", "HTTP://rpc.example:8545",
        ]
        for (index, url) in urls.enumerated() {
            let chainId = 64_240 + index
            XCTAssertEqual(SharedDefaults.insertNetwork(
                customNetwork(chainId: chainId, rpcURLs: [url]),
                to: defaults
            ), .inserted, url)
            XCTAssertEqual(
                SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
                    .entriesByChainId[chainId]?.rpcURL,
                URL(string: url), url
            )
        }
        XCTAssertEqual(try storedNetworks(in: defaults).count, urls.count)
    }

    func testInvalidAndUnsupportedRPCEndpointsAreRejectedWithoutWrites() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for value in [
            "relative-endpoint", "http://", "https:///path",
            "ws://localhost:8546", "wss://rpc.example", "file:///tmp/node",
        ] {
            XCTAssertEqual(SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_240, rpcURLs: [value]),
                to: defaults
            ), .unavailable, value)
        }
        XCTAssertNil(defaults.object(forKey: SharedDefaults.customEthereumNetworksKey))
    }

    func testRPCSelectionPrefersHTTPSThenFirstHTTP() {
        let secure = customNetwork(
            chainId: 64_240,
            rpcURLs: [
                "http://localhost:8545",
                "http://1.1.1.1:8545",
                "https://secure.example",
            ]
        )
        let literalHTTP = customNetwork(
            chainId: 64_241,
            rpcURLs: ["http://192.168.1.1", "http://1.1.1.1:9545"]
        )

        XCTAssertEqual(secure.defaultRpcUrl, "https://secure.example")
        XCTAssertEqual(literalHTTP.defaultRpcUrl, "http://192.168.1.1")
    }

    func testFailedSynchronizationRestoresPreviousArchive() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let existing = customNetwork(
            chainId: 64_240,
            rpcURLs: ["https://existing.example"]
        )
        let existingArchive = try JSONEncoder().encode([existing])
        defaults.set(existingArchive, forKey: SharedDefaults.customEthereumNetworksKey)
        let overrideKey = SharedDefaults.customEthereumNetworkNodeKey(chainId: 64_241)
        defaults.set("http://localhost:8545", forKey: overrideKey)
        let synchronization = SynchronizationController(results: [true, false, true])

        XCTAssertEqual(
            SharedDefaults.insertNetwork(
                customNetwork(chainId: 64_241, rpcURLs: ["https://new.example"]),
                to: defaults,
                crossProcessLock: nil,
                synchronizeDefaults: synchronization.synchronize
            ),
            .unavailable
        )
        XCTAssertEqual(
            defaults.data(forKey: SharedDefaults.customEthereumNetworksKey),
            existingArchive
        )
        XCTAssertEqual(defaults.string(forKey: overrideKey), "http://localhost:8545")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "org.lil.wallet.tests.custom-networks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

#if os(macOS)
    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
#endif

    private func storedNetworks(
        in defaults: UserDefaults
    ) throws -> [EthereumNetworkFromDapp] {
        let data = try XCTUnwrap(
            defaults.data(forKey: SharedDefaults.customEthereumNetworksKey)
        )
        return try JSONDecoder().decode([EthereumNetworkFromDapp].self, from: data)
    }

    private func customNetwork(
        chainId: Int,
        name: String = "Custom",
        rpcURLs: [String]
    ) -> EthereumNetworkFromDapp {
        return EthereumNetworkFromDapp(
            chainId: String.hex(chainId, withPrefix: true),
            rpcUrls: rpcURLs,
            blockExplorerUrls: [],
            nativeCurrency: .init(
                decimals: 18,
                name: "Custom Coin",
                symbol: "CUSTOM"
            ),
            chainName: name
        )
    }

}

private final class SynchronizationController {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func synchronize(_ defaults: UserDefaults) -> Bool {
        guard !results.isEmpty else { return false }
        return results.removeFirst() ? defaults.synchronize() : false
    }
}
