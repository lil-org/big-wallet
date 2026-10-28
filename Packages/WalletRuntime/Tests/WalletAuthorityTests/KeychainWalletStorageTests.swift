import Foundation
import Security
import Synchronization
import XCTest
@testable import WalletAuthority

final class KeychainWalletStorageTests: XCTestCase {
    func testNewWalletInsertionDoesNotDeleteOrUpdateOtherRecords() throws {
        let fixture = WalletInsertionKeychainFixture()
        let existing = Data("existing wallet".utf8)
        let inserted = Data("new wallet".utf8)
        fixture.seed(id: "existing", data: existing)

        try fixture.keychain.saveWallet(id: "new", data: inserted)

        XCTAssertEqual(try fixture.keychain.readWalletData(id: "existing"), existing)
        XCTAssertEqual(try fixture.keychain.readWalletData(id: "new"), inserted)
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testDuplicateInsertionPreservesOriginalWalletBytes() throws {
        let fixture = WalletInsertionKeychainFixture()
        let original = Data("original wallet".utf8)
        fixture.seed(id: "wallet", data: original)

        XCTAssertThrowsError(try fixture.keychain.saveWallet(id: "wallet", data: Data("replacement".utf8))) { error in
            guard case WalletCredentialError.failedToSave(errSecDuplicateItem) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.keychain.readWalletData(id: "wallet"), original)
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testFailedInsertionPreservesStorageAndAllowsRetry() throws {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecIO] {
            let fixture = WalletInsertionKeychainFixture()
            let original = Data("original wallet".utf8)
            let inserted = Data("new wallet".utf8)
            fixture.seed(id: "existing", data: original)
            fixture.addStatus = status

            for id in ["existing", "new"] {
                XCTAssertThrowsError(try fixture.keychain.saveWallet(id: id, data: inserted)) { error in
                    guard case WalletCredentialError.failedToSave(let actual) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(actual, status)
                }
            }
            XCTAssertEqual(try fixture.keychain.readWalletData(id: "existing"), original)
            XCTAssertNil(try fixture.keychain.readWalletData(id: "new"))

            fixture.addStatus = errSecSuccess
            try fixture.keychain.saveWallet(id: "new", data: inserted)

            XCTAssertEqual(try fixture.keychain.readWalletData(id: "new"), inserted)
            XCTAssertEqual(try fixture.keychain.readWalletData(id: "existing"), original)
            XCTAssertEqual(fixture.addCount, 3)
            XCTAssertEqual(fixture.deleteCount, 0)
            XCTAssertEqual(fixture.updateCount, 0)
        }
    }

    func testConcurrentInsertionsHaveOneWinnerAndPreserveItsBytes() async throws {
        let fixture = WalletInsertionKeychainFixture()
        let results = await withTaskGroup(of: (Int, OSStatus).self) { group in
            for index in 0..<16 {
                group.addTask {
                    do {
                        try fixture.keychain.saveWallet(id: "wallet", data: Data("wallet-\(index)".utf8))
                        return (index, errSecSuccess)
                    } catch WalletCredentialError.failedToSave(let status) {
                        return (index, status)
                    } catch {
                        return (index, errSecInternalComponent)
                    }
                }
            }
            var results = [(Int, OSStatus)]()
            for await result in group { results.append(result) }
            return results
        }

        let winners = results.filter { $0.1 == errSecSuccess }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(results.filter { $0.1 == errSecDuplicateItem }.count, 15)
        let winner = try XCTUnwrap(winners.first)
        XCTAssertEqual(try fixture.keychain.readWalletData(id: "wallet"), Data("wallet-\(winner.0)".utf8))
        XCTAssertEqual(fixture.addCount, 16)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testExistingWalletUpdateUsesUpdateWithoutDeleteOrInsert() throws {
        let fixture = WalletInsertionKeychainFixture()
        let updated = Data("updated wallet".utf8)
        fixture.seed(id: "wallet", data: Data("original wallet".utf8))

        try fixture.keychain.updateWallet(id: "wallet", data: updated)

        XCTAssertEqual(try fixture.keychain.readWalletData(id: "wallet"), updated)
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 1)
    }
}

private final class WalletInsertionKeychainFixture: Sendable {
    private struct State {
        var items = [String: Data]()
        var addStatus: OSStatus = errSecSuccess
        var addCount = 0
        var deleteCount = 0
        var updateCount = 0
    }

    private let state = Mutex(State())

    var addStatus: OSStatus {
        get { state.withLock { $0.addStatus } }
        set { state.withLock { $0.addStatus = newValue } }
    }
    var addCount: Int { state.withLock { $0.addCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }
    var updateCount: Int { state.withLock { $0.updateCount } }

    func seed(id: String, data: Data) {
        state.withLock { $0.items["org.lil.wallet.wallet." + id] = data }
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] query, result in
            guard let account = (query as NSDictionary)[kSecAttrAccount as String] as? String,
                  let data = state.withLock({ $0.items[account] }) else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }, add: { [self] query, _ in
            let query = query as NSDictionary
            guard let account = query[kSecAttrAccount as String] as? String,
                  let data = query[kSecValueData as String] as? Data else { return errSecParam }
            return state.withLock { state in
                state.addCount += 1
                guard state.addStatus == errSecSuccess else { return state.addStatus }
                guard state.items[account] == nil else { return errSecDuplicateItem }
                state.items[account] = data
                return errSecSuccess
            }
        }, update: { [self] query, attributes in
            guard let account = (query as NSDictionary)[kSecAttrAccount as String] as? String,
                  let data = (attributes as NSDictionary)[kSecValueData as String] as? Data else { return errSecParam }
            return state.withLock { state in
                state.updateCount += 1
                guard state.items[account] != nil else { return errSecItemNotFound }
                state.items[account] = data
                return errSecSuccess
            }
        }, delete: { [self] query in
            guard let account = (query as NSDictionary)[kSecAttrAccount as String] as? String else { return errSecParam }
            return state.withLock { state in
                state.deleteCount += 1
                return state.items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
            }
        })
    }
}
