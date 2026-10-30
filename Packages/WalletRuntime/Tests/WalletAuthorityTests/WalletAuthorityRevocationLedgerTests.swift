import Foundation
import Synchronization
import XCTest
@testable import WalletAuthority
import WalletDomain
import WalletRuntimeTestSupport

final class WalletAuthorityRevocationLedgerTests: XCTestCase {
    private let epoch = UUID(uuidString: "123e4567-e89b-12d3-a456-426614174000")!

    func testEmptyBatchesDoNotAdvanceTheCursorAndEachNonemptyBatchAdvancesOnce() throws {
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        XCTAssertTrue(ledger.isValid)
        XCTAssertEqual(ledger.cursor, .init(epoch: epoch, sequence: 0))
        XCTAssertFalse(try ledger.record([]))
        XCTAssertFalse(try ledger.record([.accounts([])]))
        XCTAssertEqual(ledger.sequence, 0)

        let account = descriptor()
        XCTAssertTrue(try ledger.record([
            .wallet(id: "other-wallet"), .accounts([account]), .accounts([account]),
        ]))
        XCTAssertEqual(ledger.cursor, .init(epoch: epoch, sequence: 1))
        XCTAssertEqual(ledger.walletRemovals.count, 1)
        XCTAssertEqual(ledger.accountRemovals, [.init(account: account, sequence: 1)])
        XCTAssertTrue(ledger.removals(after: 1).isEmpty)
    }

    func testRepeatedAccountRemovalCoalescesWhileRemainingVisibleToAlreadyCaughtUpProfiles() throws {
        let first = descriptor()
        let retained = descriptor(address: "0x0000000000000000000000000000000000000002")
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.accounts([first, retained])])
        let applied = ledger.cursor
        try ledger.record([.accounts([first])])

        XCTAssertEqual(ledger.sequence, 2)
        XCTAssertEqual(ledger.accountRemovals.count, 2)
        XCTAssertEqual(Set(ledger.accountRemovals.filter { $0.sequence == 2 }.map(\.account)), [first])
        let unseen = ledger.removals(after: applied.sequence)
        XCTAssertTrue(unseen.contains { $0.matches(first) })
        XCTAssertFalse(unseen.contains { $0.matches(retained) })
        XCTAssertTrue(ledger.removals(after: 0).contains { $0.matches(retained) })
        XCTAssertTrue(ledger.removals(after: ledger.sequence).isEmpty)
        XCTAssertTrue(ledger.isValid)
    }

    func testAccountRemovalMatchesTheExactWalletAddressAndDerivationPath() throws {
        let removed = descriptor()
        let unrelated = [
            descriptor(walletID: "other-wallet"),
            descriptor(address: "0x0000000000000000000000000000000000000002"),
            descriptor(path: "m/44'/60'/0'/0/1"),
            descriptor(coin: .solana, address: String(repeating: "1", count: 32), path: "m/44'/501'/0'/0'"),
        ]
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.accounts([removed])])
        let pending = ledger.removals(after: 0)

        XCTAssertTrue(pending.contains { $0.matches(removed) })
        for account in unrelated {
            XCTAssertTrue(account.isValid)
            XCTAssertFalse(pending.contains { $0.matches(account) }, "Unexpected revocation: \(account)")
        }
    }

    func testWalletRemovalSubsumesOlderAccountsButRetainsLaterAccountRevocations() throws {
        let removed = descriptor()
        let sibling = descriptor(path: "m/44'/60'/0'/0/1")
        let unrelated = descriptor(walletID: "other-wallet")
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.accounts([removed, unrelated])])
        try ledger.record([.wallet(id: removed.walletID), .accounts([sibling])])

        XCTAssertEqual(ledger.walletRemovals, [.init(walletID: removed.walletID, sequence: 2)])
        XCTAssertEqual(ledger.accountRemovals, [.init(account: unrelated, sequence: 1)])
        XCTAssertTrue(ledger.removals(after: 1).contains { $0.matches(removed) })
        XCTAssertTrue(ledger.removals(after: 1).contains { $0.matches(sibling) })
        XCTAssertFalse(ledger.removals(after: 1).contains { $0.matches(unrelated) })

        try ledger.record([.accounts([removed])])
        XCTAssertEqual(ledger.accountRemovals.first { $0.account == removed }?.sequence, 3)
        let afterWalletRemoval = ledger.removals(after: 2)
        XCTAssertTrue(afterWalletRemoval.contains { $0.matches(removed) })
        XCTAssertFalse(afterWalletRemoval.contains { $0.matches(sibling) })
        XCTAssertFalse(afterWalletRemoval.contains { $0.matches(unrelated) })
        XCTAssertTrue(ledger.isValid)
    }

    func testEncodingIsDeterministicAcrossBatchOrderAndRoundTripsAsBinaryPlist() throws {
        let first = descriptor()
        let second = descriptor(walletID: "second-wallet")
        var left = WalletAuthorityRevocationLedger(epoch: epoch)
        var right = WalletAuthorityRevocationLedger(epoch: epoch)
        try left.record([.wallet(id: "z-wallet"), .accounts([first, second]), .wallet(id: "a-wallet")])
        try right.record([.wallet(id: "a-wallet"), .accounts([second]), .accounts([first]), .wallet(id: "z-wallet")])
        try left.record([.accounts([first])])
        try right.record([.accounts([first])])

        let data = try left.encoded()
        XCTAssertEqual(left, right)
        XCTAssertEqual(data, try right.encoded())
        XCTAssertEqual(data.prefix(8), Data("bplist00".utf8))
        let restored = try XCTUnwrap(WalletAuthorityRevocationLedger.decode(data))
        XCTAssertEqual(restored, left)
        XCTAssertEqual(try restored.encoded(), data)
        XCTAssertEqual(restored.cursor, left.cursor)
    }

    func testInvalidBatchLeavesExistingRevocationsAndCursorUnchanged() throws {
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.accounts([descriptor()])])
        let before = ledger
        for removals: [WalletAuthorityRemoval] in [
            [.wallet(id: "valid-wallet"), .wallet(id: "")],
            [.wallet(id: "valid-wallet"), .accounts([descriptor(address: "invalid")])],
        ] {
            XCTAssertThrowsError(try ledger.record(removals)) { error in
                guard case WalletAuthorityRevocationLedger.Error.invalidRemoval = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(ledger, before)
        }
    }

    func testDecodeRejectsCorruptOrInconsistentRevocationHistory() throws {
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.wallet(id: "other-wallet"), .accounts([descriptor()])])
        let mutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("unsupported schema", { $0["schemaVersion"] = 2 }),
            ("invalid epoch", { $0["epoch"] = "invalid" }),
            ("negative cursor", { $0["sequence"] = -1 }),
            ("cursor ahead of history", { $0["sequence"] = 2 }),
            ("missing history", { $0["walletRemovals"] = []; $0["accountRemovals"] = [] }),
            ("duplicate wallet", { raw in
                var entries = try XCTUnwrap(raw["walletRemovals"] as? [[String: Any]])
                entries.append(entries[0])
                raw["walletRemovals"] = entries
            }),
            ("duplicate account", { raw in
                var entries = try XCTUnwrap(raw["accountRemovals"] as? [[String: Any]])
                entries.append(entries[0])
                raw["accountRemovals"] = entries
            }),
            ("invalid wallet identity", { raw in
                var entries = try XCTUnwrap(raw["walletRemovals"] as? [[String: Any]])
                entries[0]["walletID"] = ""
                raw["walletRemovals"] = entries
            }),
            ("invalid account identity", { raw in
                var entries = try XCTUnwrap(raw["accountRemovals"] as? [[String: Any]])
                var account = try XCTUnwrap(entries[0]["account"] as? [String: Any])
                account["normalizedAddress"] = "invalid"
                entries[0]["account"] = account
                raw["accountRemovals"] = entries
            }),
            ("account already subsumed by wallet", { raw in
                let entries = try XCTUnwrap(raw["accountRemovals"] as? [[String: Any]])
                let account = try XCTUnwrap(entries[0]["account"] as? [String: Any])
                raw["walletRemovals"] = [["walletID": try XCTUnwrap(account["walletID"]), "sequence": 1]]
            }),
        ]
        for (name, mutate) in mutations {
            XCTAssertNil(try WalletAuthorityRevocationLedger.decode(corrupted(ledger, mutate)), name)
        }
        for field in ["walletRemovals", "accountRemovals"] {
            for sequence in [-1, 0, 2] {
                let data = try corrupted(ledger) { raw in
                    var entries = try XCTUnwrap(raw[field] as? [[String: Any]])
                    entries[0]["sequence"] = sequence
                    raw[field] = entries
                }
                XCTAssertNil(try WalletAuthorityRevocationLedger.decode(data), "\(field) sequence \(sequence)")
            }
        }
        XCTAssertNil(try WalletAuthorityRevocationLedger.decode(Data("not a plist".utf8)))
    }

    func testEntryLimitAcceptsTheBoundaryAndRejectsGrowthWithoutChangingTheLedger() throws {
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        let removals = (0..<WalletAuthorityRevocationLedger.maximumEntries).map {
            WalletAuthorityRemoval.wallet(id: "wallet-\($0)")
        }
        try ledger.record(removals)
        XCTAssertTrue(ledger.isValid)
        XCTAssertEqual(try WalletAuthorityRevocationLedger.decode(ledger.encoded()), ledger)

        let before = ledger
        assertCapacityExceeded { try ledger.record([.accounts([self.descriptor()])]) }
        XCTAssertEqual(ledger, before)
        XCTAssertTrue(try ledger.record([removals[0]]))
        XCTAssertEqual(ledger.walletRemovals.count, WalletAuthorityRevocationLedger.maximumEntries)
        XCTAssertEqual(ledger.sequence, 2)
    }

    func testEntryLimitCountsWalletsAndAccountsTogetherBeforeDecodingElements() throws {
        let invalidEntry: [String: Any] = ["not": "a removal"]
        for (walletCount, accountCount) in [
            (WalletAuthorityRevocationLedger.maximumEntries + 1, 0),
            (1, WalletAuthorityRevocationLedger.maximumEntries),
            (0, WalletAuthorityRevocationLedger.maximumEntries + 1),
        ] {
            let raw: [String: Any] = [
                "schemaVersion": 1, "epoch": epoch.uuidString, "sequence": 1,
                "walletRemovals": Array(repeating: invalidEntry, count: walletCount),
                "accountRemovals": Array(repeating: invalidEntry, count: accountCount),
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
            XCTAssertLessThan(data.count, WalletAuthorityRevocationLedger.maximumEncodedBytes)
            assertCapacityExceeded { _ = try WalletAuthorityRevocationLedger.decode(data) }
        }
    }

    func testByteLimitAcceptsTheExactBoundaryAndRejectsOneExtraByte() throws {
        let ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        var raw = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: ledger.encoded(), options: [], format: nil
        ) as? [String: Any])
        let limit = WalletAuthorityRevocationLedger.maximumEncodedBytes
        var padding = limit
        var data = Data()
        for _ in 0..<4 {
            raw["padding"] = String(repeating: "x", count: padding)
            data = try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
            if data.count == limit { break }
            padding += limit - data.count
        }
        XCTAssertEqual(data.count, limit)
        XCTAssertEqual(try WalletAuthorityRevocationLedger.decode(data), ledger)
        data.append(0)
        assertCapacityExceeded { _ = try WalletAuthorityRevocationLedger.decode(data) }
    }

    func testDecodingRejectsRepeatedOversizedStringsWithinFileAndEntryLimits() throws {
        for (field, entry) in oversizedRemovalEntries() {
            let data = try corrupted(WalletAuthorityRevocationLedger(epoch: epoch)) {
                $0["sequence"] = 1
                $0[field] = Array(repeating: entry, count: 1_024)
            }
            XCTAssertLessThan(data.count, 256 * 1_024, "Repeated values must share binary-plist references")
            XCTAssertLessThan(data.count, WalletAuthorityRevocationLedger.maximumEncodedBytes)
            XCTAssertLessThan(1_024, WalletAuthorityRevocationLedger.maximumEntries)
            assertInvalidRemovalDecoding(data)
            XCTAssertNil(try WalletAuthorityRevocationLedger.decode(data))
        }
    }

    func testDecodingRejectsOversizedEntryBeforeReadingMalformedFollowingEntry() throws {
        for (field, entry) in oversizedRemovalEntries() {
            let data = try corrupted(WalletAuthorityRevocationLedger(epoch: epoch)) {
                $0["sequence"] = 1
                $0[field] = [entry, ["not": "a removal"]]
            }
            assertInvalidRemovalDecoding(data)
        }
    }

    func testEncodedByteLimitIsIndependentOfEntryLimit() throws {
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        let removals = (0..<32_768).map { index in
            WalletAuthorityRemoval.wallet(id: String(repeating: "x", count: 240) + String(index))
        }
        try ledger.record(removals)
        XCTAssertLessThan(ledger.walletRemovals.count, WalletAuthorityRevocationLedger.maximumEntries)
        XCTAssertTrue(ledger.isValid)
        assertCapacityExceeded { _ = try ledger.encoded() }
    }

    func testWholeWalletSubsumptionFitsAtEntryCapacity() throws {
        let accounts = Set((0..<WalletAuthorityRevocationLedger.maximumEntries).map {
            descriptor(path: "m/44'/60'/0'/0/\($0)")
        })
        var ledger = WalletAuthorityRevocationLedger(epoch: epoch)
        try ledger.record([.accounts(accounts)])
        try ledger.record([.wallet(id: "wallet")])
        XCTAssertEqual(ledger.walletRemovals, [.init(walletID: "wallet", sequence: 2)])
        XCTAssertTrue(ledger.accountRemovals.isEmpty)
        XCTAssertEqual(ledger.epoch, epoch)
    }

    func testIndependentConcurrentStoresPublishEveryBatchBeforeCommittingSource() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wallet-revocations-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let ledgerURL = rootURL.appendingPathComponent("wallet-authority-revocations.state")
        let results = ConcurrentResults()

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let walletID = "whole-wallet-\(index)"
            let account = WalletAccountDescriptor(
                walletID: "account-wallet-\(index)", coin: .ethereum,
                normalizedAddress: "0x0000000000000000000000000000000000000001",
                derivationPath: "m/44'/60'/0'/0/0"
            )
            let store = ExtensionRequestFileStore(
                rootURL: rootURL, directoryBoundary: rootURL,
                dependencies: .init(crossProcessLockTimeoutNanoseconds: 10_000_000_000)
            )
            do {
                try store.perform(preparing: {
                    PreparedWalletSourceMutation(
                        payload: index, authorityRemovals: [.wallet(id: walletID), .accounts([account])]
                    )
                }, beforeCommit: {}, commit: { writer in
                    guard let published = try WalletAuthorityRevocationLedger.decode(Data(contentsOf: ledgerURL)),
                          let walletRemoval = published.walletRemovals.first(where: { $0.walletID == walletID }),
                          let accountRemoval = published.accountRemovals.first(where: { $0.account == account }),
                          walletRemoval.sequence == accountRemoval.sequence else {
                        results.fail("Writer \(writer) reached source commit before its full batch was published")
                        return
                    }
                    results.didCommit(writer)
                })
            } catch {
                results.fail("Writer \(index) failed: \(error)")
            }
        }

        let outcome = results.snapshot()
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.committed.sorted(), Array(0..<8))
        let ledger = try XCTUnwrap(WalletAuthorityRevocationLedger.decode(Data(contentsOf: ledgerURL)))
        XCTAssertEqual(ledger.sequence, 8)
        XCTAssertEqual(Set(ledger.walletRemovals.map(\.walletID)), Set((0..<8).map { "whole-wallet-\($0)" }))
        XCTAssertEqual(Set(ledger.accountRemovals.map { $0.account.walletID }), Set((0..<8).map { "account-wallet-\($0)" }))
        XCTAssertEqual(Set(ledger.walletRemovals.map(\.sequence)), Set(1...8))
        XCTAssertEqual(Set(ledger.accountRemovals.map(\.sequence)), Set(1...8))
    }

    private final class ConcurrentResults: Sendable {
        private struct State {
            var committed = [Int]()
            var failures = [String]()
        }
        private let state = Mutex(State())
        func didCommit(_ writer: Int) { state.withLock { $0.committed.append(writer) } }
        func fail(_ message: String) { state.withLock { $0.failures.append(message) } }
        func snapshot() -> (committed: [Int], failures: [String]) {
            state.withLock { ($0.committed, $0.failures) }
        }
    }

    private func assertCapacityExceeded(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case WalletAuthorityRevocationLedger.Error.capacityExceeded = error else {
                return XCTFail("Expected capacityExceeded, received \(error)", file: file, line: line)
            }
        }
    }

    private func oversizedRemovalEntries() -> [(String, [String: Any])] {
        let oversized = String(repeating: "x", count: 64 * 1_024)
        var entries: [(String, [String: Any])] = [
            ("walletRemovals", ["walletID": oversized, "sequence": 1]),
        ]
        for field in ["walletID", "normalizedAddress", "derivationPath"] {
            var account: [String: Any] = [
                "walletID": "wallet", "coin": WalletCoin.ethereum.rawValue,
                "normalizedAddress": "0x0000000000000000000000000000000000000001",
                "derivationPath": "m/44'/60'/0'/0/0",
            ]
            account[field] = oversized
            entries.append(("accountRemovals", ["account": account, "sequence": 1]))
        }
        return entries
    }

    private func assertInvalidRemovalDecoding(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PropertyListDecoder().decode(WalletAuthorityRevocationLedger.self, from: data), file: file, line: line) {
            guard case WalletAuthorityRevocationLedger.Error.invalidRemoval = $0 else {
                return XCTFail("Expected invalidRemoval before decoding later entries, received \($0)", file: file, line: line)
            }
        }
    }

    private func descriptor(
        walletID: String = "wallet",
        coin: WalletCoin = .ethereum,
        address: String = "0x0000000000000000000000000000000000000001",
        path: String = "m/44'/60'/0'/0/0"
    ) -> WalletAccountDescriptor {
        WalletAccountDescriptor(walletID: walletID, coin: coin, normalizedAddress: address, derivationPath: path)
    }

    private func corrupted(
        _ ledger: WalletAuthorityRevocationLedger,
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var raw = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: ledger.encoded(), options: [], format: nil
        ) as? [String: Any])
        try mutate(&raw)
        return try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0)
    }
}
