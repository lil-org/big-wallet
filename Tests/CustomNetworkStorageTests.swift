// ∅ 2026 lil org

import Dispatch
import Foundation
import XCTest
@testable import Big_Wallet

final class CustomNetworkStorageTests: XCTestCase {

    func testCorruptArchiveIsQuarantinedAndAdditionRepairsStorage() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let corruptArchive = Data([0x7b])
        let existingChainId = 64240
        let addedChainId = 64241
        let existingNodeKey = SharedDefaults.customEthereumNetworkNodeKey(chainId: existingChainId)
        defaults.set(corruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set("https://unchanged.example", forKey: existingNodeKey)

        XCTAssertTrue(SharedDefaults.addNetwork(
            customNetwork(chainId: addedChainId, rpcURLs: ["https://added.example"]),
            to: defaults
        ))
        let quarantineKey = try XCTUnwrap(quarantineKeys(in: defaults).first)
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptArchive)
        XCTAssertEqual(defaults.string(forKey: existingNodeKey), "https://unchanged.example")
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: addedChainId)),
            "https://added.example"
        )

        let records = try storedNetworks(in: defaults)
        XCTAssertEqual(records.map(\.chainId), [String.hex(addedChainId, withPrefix: true)])
        XCTAssertEqual(
            SharedDefaults.loadCustomNetworkSnapshot(from: defaults).orderedEntries.map(\.chainId),
            [addedChainId]
        )

        XCTAssertTrue(SharedDefaults.addNetwork(
            customNetwork(chainId: 64242, rpcURLs: ["https://second.example"]),
            to: defaults
        ))
        XCTAssertEqual(quarantineKeys(in: defaults), [quarantineKey])
        XCTAssertEqual(defaults.data(forKey: quarantineKey), corruptArchive)
    }

    func testPartiallyCorruptArchiveKeepsValidRecordsAndIsRewrittenOnAddition() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = customNetwork(
            chainId: 64240,
            name: "Existing",
            rpcURLs: ["https://existing.example"]
        )
        let existingObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(existing))
        let archive = try JSONSerialization.data(withJSONObject: [
            ["chainId": "0xfaf1", "chainName": "Missing required fields"],
            existingObject,
        ])
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)

        let recoveredSnapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        XCTAssertEqual(recoveredSnapshot.orderedEntries.map(\.chainId), [64240])
        XCTAssertTrue(quarantineKeys(in: defaults).isEmpty)

        let added = customNetwork(
            chainId: 64242,
            name: "Added",
            rpcURLs: ["https://added.example"]
        )
        XCTAssertTrue(SharedDefaults.addNetwork(added, to: defaults))

        let quarantineKey = try XCTUnwrap(quarantineKeys(in: defaults).first)
        XCTAssertEqual(defaults.data(forKey: quarantineKey), archive)
        let repairedRecords = try storedNetworks(in: defaults)
        XCTAssertEqual(repairedRecords.map(\.chainId), [existing.chainId, added.chainId])
        XCTAssertEqual(repairedRecords.map(\.chainName), ["Existing", "Added"])
    }

    func testInvalidAdditionDoesNotQuarantineOrReplaceCorruptArchive() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let corruptArchive = Data([0x7b])
        defaults.set(corruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)

        XCTAssertFalse(SharedDefaults.addNetwork(
            customNetwork(chainId: 64240, rpcURLs: ["relative-endpoint"]),
            to: defaults
        ))
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), corruptArchive)
        XCTAssertTrue(quarantineKeys(in: defaults).isEmpty)
    }

    func testWrongTypedArchiveIsQuarantinedVerbatimAndRepaired() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let corruptArchive = "legacy-incompatible-value"
        defaults.set(corruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)

        XCTAssertTrue(SharedDefaults.addNetwork(
            customNetwork(chainId: 64240, rpcURLs: ["https://added.example"]),
            to: defaults
        ))

        let quarantineKey = try XCTUnwrap(quarantineKeys(in: defaults).first)
        XCTAssertEqual(defaults.string(forKey: quarantineKey), corruptArchive)
        XCTAssertEqual(try storedNetworks(in: defaults).map(\.chainId), ["0xfaf0"])
    }

    func testSeparateCorruptionsKeepDistinctQuarantineCopies() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstCorruptArchive = Data([0x7b])
        defaults.set(firstCorruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)
        XCTAssertTrue(SharedDefaults.addNetwork(
            customNetwork(chainId: 64240, rpcURLs: ["https://first.example"]),
            to: defaults
        ))

        let secondCorruptArchive = Data([0x5b])
        defaults.set(secondCorruptArchive, forKey: SharedDefaults.customEthereumNetworksKey)
        XCTAssertTrue(SharedDefaults.addNetwork(
            customNetwork(chainId: 64241, rpcURLs: ["https://second.example"]),
            to: defaults
        ))

        let quarantinedData = quarantineKeys(in: defaults).compactMap {
            defaults.data(forKey: $0)
        }
        XCTAssertEqual(quarantinedData.count, 2)
        XCTAssertEqual(Set(quarantinedData), [firstCorruptArchive, secondCorruptArchive])
    }

    func testMissingAndValidArchivesAppendWithoutRewritingExistingRecords() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = customNetwork(chainId: 64240, name: "First", rpcURLs: ["https://first.example"])
        let second = customNetwork(chainId: 64241, name: "Second", rpcURLs: ["http://localhost:8545"])

        XCTAssertTrue(SharedDefaults.addNetwork(first, to: defaults))
        XCTAssertTrue(SharedDefaults.addNetwork(second, to: defaults))

        let records = try storedNetworks(in: defaults)
        XCTAssertEqual(records.map(\.chainId), [first.chainId, second.chainId])
        XCTAssertEqual(records.map(\.chainName), ["First", "Second"])
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64240)),
            "https://first.example"
        )
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64241)),
            "http://localhost:8545"
        )
    }

    func testInvalidChainAndRPCURLsAreRejectedWithoutWrites() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let invalidNetworks = [
            customNetwork(chainId: 0, rpcURLs: ["https://valid.example"]),
            customNetwork(chainId: -1, rpcURLs: ["https://valid.example"]),
            customNetwork(chainId: 64240, rpcURLs: []),
            customNetwork(chainId: 64240, rpcURLs: ["relative-endpoint"]),
            customNetwork(chainId: 64240, rpcURLs: ["ws://localhost:8546"]),
            customNetwork(chainId: 64240, rpcURLs: ["file:///tmp/rpc"]),
            customNetwork(chainId: 64240, rpcURLs: ["https:///missing-host"]),
            EthereumNetworkFromDapp(
                chainId: "not-a-chain-id",
                rpcUrls: ["https://valid.example"],
                blockExplorerUrls: [],
                nativeCurrency: currency(),
                chainName: "Invalid Chain"
            ),
        ]

        for network in invalidNetworks {
            XCTAssertFalse(SharedDefaults.addNetwork(network, to: defaults))
        }

        XCTAssertNil(defaults.object(forKey: SharedDefaults.customEthereumNetworksKey))
        XCTAssertNil(defaults.object(
            forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64240)
        ))

        let valid = customNetwork(chainId: 64240, rpcURLs: ["https://unchanged.example"])
        XCTAssertTrue(SharedDefaults.addNetwork(valid, to: defaults))
        let validArchive = defaults.data(forKey: SharedDefaults.customEthereumNetworksKey)

        XCTAssertFalse(SharedDefaults.addNetwork(
            customNetwork(chainId: 64240, rpcURLs: ["ws://localhost:8546"]),
            to: defaults
        ))
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), validArchive)
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64240)),
            "https://unchanged.example"
        )
    }

    func testRPCSelectionPrefersFirstValidHTTPSOtherwiseFirstValidHTTP() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let secure = customNetwork(
            chainId: 64240,
            rpcURLs: [
                "http://localhost:8545",
                "relative-endpoint",
                "https://secure-first.example",
                "https://secure-second.example",
            ]
        )
        let local = customNetwork(
            chainId: 64241,
            rpcURLs: ["ws://localhost:8546", "http://localhost:9545"]
        )

        XCTAssertEqual(secure.defaultRpcUrl, "https://secure-first.example")
        XCTAssertEqual(local.defaultRpcUrl, "http://localhost:9545")
        XCTAssertTrue(SharedDefaults.addNetwork(secure, to: defaults))
        XCTAssertTrue(SharedDefaults.addNetwork(local, to: defaults))
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64240)),
            secure.defaultRpcUrl
        )
        XCTAssertEqual(
            defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 64241)),
            local.defaultRpcUrl
        )
    }

    func testSnapshotUsesLastRecordOrderAndStoredNodeOverride() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let records = [
            customNetwork(chainId: 100, name: "First 100", rpcURLs: ["https://first-100.example"]),
            customNetwork(chainId: 200, name: "Only 200", rpcURLs: ["https://record-200.example"]),
            customNetwork(chainId: 100, name: "Last 100", rpcURLs: ["https://last-100.example"]),
            customNetwork(chainId: 300, name: "Only 300", rpcURLs: ["https://record-300.example"]),
            customNetwork(chainId: 400, name: "Invalid Override", rpcURLs: ["https://record-400.example"]),
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: SharedDefaults.customEthereumNetworksKey)
        defaults.set(
            "https://stored-100.example",
            forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 100)
        )
        defaults.set(
            "ws://localhost:8546",
            forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 400)
        )
        defaults.set(
            "https://orphan.example",
            forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: 999)
        )

        let snapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)

        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [200, 100, 300])
        XCTAssertEqual(snapshot.entriesByChainId[100]?.resolvedNetwork.network.name, "Last 100")
        XCTAssertEqual(
            snapshot.entriesByChainId[100]?.rpcURL.absoluteString,
            "https://stored-100.example"
        )
        XCTAssertNil(snapshot.entriesByChainId[400])
        XCTAssertNil(snapshot.entriesByChainId[999])
    }

    func testSnapshotIgnoresArchivedNonPositiveChainIDsWithoutMutatingStorage() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let records = [
            customNetwork(chainId: 0, name: "Zero", rpcURLs: ["https://zero-record.example"]),
            customNetwork(chainId: -1, name: "Negative", rpcURLs: ["https://negative-record.example"]),
            customNetwork(chainId: 64240, name: "Valid", rpcURLs: ["https://valid-record.example"]),
        ]
        let archive = try JSONEncoder().encode(records)
        let nodeValues = [
            0: "http://localhost:8000",
            -1: "https://negative-node.example",
            64240: "http://localhost:8545",
        ]
        defaults.set(archive, forKey: SharedDefaults.customEthereumNetworksKey)
        for (chainId, value) in nodeValues {
            defaults.set(value, forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: chainId))
        }

        let snapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)

        XCTAssertEqual(snapshot.orderedEntries.map(\.chainId), [64240])
        XCTAssertEqual(Set(snapshot.entriesByChainId.keys), [64240])
        XCTAssertEqual(snapshot.entriesByChainId[64240]?.resolvedNetwork.network.name, "Valid")
        XCTAssertEqual(snapshot.entriesByChainId[64240]?.rpcURL.absoluteString, nodeValues[64240])
        XCTAssertEqual(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey), archive)
        for (chainId, value) in nodeValues {
            XCTAssertEqual(
                defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: chainId)),
                value
            )
        }
    }

    func testCatalogOverlapsStayDormantWhileCustom64240Resolves() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let records = [
            customNetwork(chainId: 1, name: "Dormant Ethereum", rpcURLs: ["https://custom-mainnet.example"]),
            customNetwork(chainId: 64240, name: "Custom 64240", rpcURLs: ["https://custom-64240.example"]),
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: SharedDefaults.customEthereumNetworksKey)
        let snapshot = SharedDefaults.loadCustomNetworkSnapshot(from: defaults)
        let resolver = NetworkResolver(
            catalog: try NetworkCatalog(records: [
                catalogRecord(chainId: 1, alchemyNetwork: "eth-mainnet"),
            ]),
            catalogOwnedChainIds: [1],
            customSnapshot: { snapshot }
        )

        XCTAssertEqual(resolver.visibleCustomNetworks.map(\.chainId), [64240])
        XCTAssertEqual(resolver.resolve(chainId: 1).resolvedNetwork?.source, .alchemy)
        XCTAssertEqual(resolver.resolve(chainId: 64240).resolvedNetwork?.source, .custom)
        XCTAssertEqual(
            resolver.rpcURL(chainId: 64240)?.absoluteString,
            "https://custom-64240.example"
        )
    }

    func testConcurrentInProcessWritesPreserveEveryUniqueNetwork() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let count = 64
        let failuresLock = NSLock()
        var failedChainIds: [Int] = []

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let chainId = 70_000 + index
            let network = customNetwork(
                chainId: chainId,
                rpcURLs: ["https://rpc-\(chainId).example"]
            )
            if !SharedDefaults.addNetwork(network, to: defaults) {
                failuresLock.lock()
                failedChainIds.append(chainId)
                failuresLock.unlock()
            }
        }

        XCTAssertTrue(failedChainIds.isEmpty)
        let records = try storedNetworks(in: defaults)
        XCTAssertEqual(records.count, count)
        XCTAssertEqual(
            Set(records.compactMap { Int(hexString: $0.chainId) }),
            Set((0..<count).map { 70_000 + $0 })
        )
        for chainId in 70_000..<(70_000 + count) {
            XCTAssertEqual(
                defaults.string(forKey: SharedDefaults.customEthereumNetworkNodeKey(chainId: chainId)),
                "https://rpc-\(chainId).example"
            )
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "org.lil.wallet.tests.custom-networks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func storedNetworks(in defaults: UserDefaults) throws -> [EthereumNetworkFromDapp] {
        let data = try XCTUnwrap(defaults.data(forKey: SharedDefaults.customEthereumNetworksKey))
        return try JSONDecoder().decode([EthereumNetworkFromDapp].self, from: data)
    }

    private func quarantineKeys(in defaults: UserDefaults) -> [String] {
        return defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(SharedDefaults.corruptCustomEthereumNetworksKeyPrefix) }
            .sorted()
    }

    private func customNetwork(chainId: Int,
                               name: String = "Custom",
                               rpcURLs: [String]) -> EthereumNetworkFromDapp {
        return EthereumNetworkFromDapp(
            chainId: String.hex(chainId, withPrefix: true),
            rpcUrls: rpcURLs,
            blockExplorerUrls: [],
            nativeCurrency: currency(),
            chainName: name
        )
    }

    private func currency() -> EthereumNetworkFromDapp.Currency {
        return EthereumNetworkFromDapp.Currency(
            decimals: 18,
            name: "Custom Coin",
            symbol: "CUSTOM"
        )
    }

    private func catalogRecord(chainId: Int,
                               alchemyNetwork: String) -> NetworkCatalogRecord {
        return NetworkCatalogRecord(
            chainId: chainId,
            name: "Catalog \(chainId)",
            nativeCurrency: NetworkCatalogNativeCurrency(
                name: "Ether",
                symbol: "ETH",
                decimals: 18
            ),
            explorerURL: "https://explorer.example",
            isTestnet: false,
            displayPrice: false,
            alchemyNetwork: alchemyNetwork,
            fallbackRPCURL: nil,
            accountDisabledAlchemyNetwork: nil
        )
    }

}
