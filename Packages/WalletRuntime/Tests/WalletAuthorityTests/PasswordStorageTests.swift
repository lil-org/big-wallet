import Foundation
import Security
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority
import WalletRuntimeTestSupport

@MainActor
final class PasswordStorageTests: XCTestCase {
    func testPasswordReadDistinguishesMissingUnavailableAndCorruptData() throws {
        let fixture = PasswordKeychainFixture()
        XCTAssertNil(try fixture.keychain.readPassword())
        XCTAssertEqual(try fixture.keychain.passwordState(), .missing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            fixture.readStatus = status
            XCTAssertThrowsError(try fixture.keychain.passwordState()) { error in
                guard case WalletCredentialError.failedToRead(let actual) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actual, status)
            }
        }
        fixture.readStatus = nil
        for data in [Data(), Data([0xff, 0xfe]), Data([0xef, 0xbb, 0xbf])] {
            fixture.passwordData = data
            XCTAssertThrowsError(try fixture.keychain.readPasswordData()) { error in
                guard case WalletCredentialError.invalidPasswordData = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        fixture.wrongReturnType = true
        XCTAssertThrowsError(try fixture.keychain.readPassword()) { error in
            guard case WalletCredentialError.failedToRead(errSecDecode) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testExistingShortAndUnicodePasswordsRemainReadableAndVerifiable() throws {
        let fixture = PasswordKeychainFixture()
        for password in ["x", "пароль🔐"] {
            fixture.passwordData = Data(password.utf8)
            XCTAssertEqual(try fixture.keychain.readPassword(), password)
            XCTAssertEqual(try fixture.keychain.passwordState(), .present)
            XCTAssertTrue(try fixture.verify(password: password))
            XCTAssertFalse(try fixture.verify(password: "different"))
        }
        fixture.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.verify(password: "different"))
        fixture.readStatus = nil
        fixture.passwordData = nil
        XCTAssertThrowsError(try fixture.verify(password: ""))
    }

    func testInitialCreationNeverDeletesOrUpdatesAnExistingPassword() throws {
        let fixture = PasswordKeychainFixture()
        var invalidations = 0
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("first", beforeInsert: {
            invalidations += 1
        }), .created)
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("second", beforeInsert: {
            invalidations += 1
        }), .alreadyExists)
        XCTAssertEqual(try fixture.keychain.readPassword(), "first")
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testPasswordWithUTF8BOMKeepsExistingDecodingWithoutRewritingStorage() throws {
        let fixture = PasswordKeychainFixture()
        for count in 1...2 {
            let original = String(repeating: "\u{feff}", count: count) + "password"
            let expected = String(repeating: "\u{feff}", count: count - 1) + "password"
            let stored = Data(original.utf8)
            fixture.passwordData = stored

            XCTAssertEqual(try fixture.keychain.readPassword(), expected)
            XCTAssertTrue(try fixture.verify(password: expected))
            XCTAssertFalse(try fixture.verify(password: original))
            XCTAssertEqual(try fixture.keychain.readPasswordData(), Data(expected.utf8))
            XCTAssertEqual(fixture.passwordData, stored)
        }
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testCanonicalUnicodePasswordComparisonDoesNotRewriteKDFBytes() throws {
        let fixture = PasswordKeychainFixture()
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        for stored in [composed, decomposed] {
            let bytes = Data(stored.utf8)
            fixture.passwordData = bytes
            XCTAssertTrue(try fixture.verify(password: composed))
            XCTAssertTrue(try fixture.verify(password: decomposed))
            XCTAssertFalse(try fixture.verify(password: "cafe"))
            let secret = try XCTUnwrap(fixture.keychain.readPasswordSecret())
            defer { secret.invalidate() }
            XCTAssertEqual(secret.testData, bytes)
            XCTAssertEqual(fixture.passwordData, bytes)
        }
    }

    func testPasswordCreationFailsBeforeInvalidationForUnreadableCorruptOrOrphanedStorage() throws {
        let fixture = PasswordKeychainFixture()
        let beforeInsert = { XCTFail("Storage must be checked before invalidating the vault") }
        fixture.readStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.readStatus = nil
        fixture.passwordData = Data([0xff])
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.passwordData = nil
        fixture.walletIDs = ["retained-wallet"]
        XCTAssertThrowsError(try fixture.keychain.passwordState()) { error in
            guard case WalletCredentialError.orphanedWallets = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        fixture.walletIDs = []
        fixture.inventoryStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: beforeInsert))
        XCTAssertEqual(fixture.addCount, 0)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testDuplicateBetweenRecheckAndInsertPreservesWinningPassword() throws {
        let fixture = PasswordKeychainFixture()
        let result = try fixture.keychain.createPasswordIfMissing("loser", beforeInsert: {
            fixture.passwordData = Data("winner".utf8)
        })
        XCTAssertEqual(result, .alreadyExists)
        XCTAssertEqual(try fixture.keychain.readPassword(), "winner")
        XCTAssertEqual(fixture.addCount, 1)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testFailedInvalidationAndFailedInsertPreserveStorageAndAllowRetry() throws {
        let fixture = PasswordKeychainFixture()
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {
            throw CocoaError(.fileWriteUnknown)
        }))
        XCTAssertEqual(fixture.addCount, 0)
        fixture.addStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {})) { error in
            guard case WalletCredentialError.failedToSave(errSecInteractionNotAllowed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNil(fixture.passwordData)
        fixture.addStatus = nil
        XCTAssertEqual(try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {}), .created)
        XCTAssertEqual(fixture.deleteCount, 0)
    }

    func testConcurrentInitialCreationHasOneWinner() async throws {
        let fixture = PasswordKeychainFixture()
        let results = try await withThrowingTaskGroup(of: WalletPasswordCreationResult.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try fixture.keychain.createPasswordIfMissing("password-\(index)", beforeInsert: {})
                }
            }
            var results = [WalletPasswordCreationResult]()
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 == .created }.count, 1)
        XCTAssertEqual(results.filter { $0 == .alreadyExists }.count, 15)
        XCTAssertTrue(try XCTUnwrap(fixture.keychain.readPassword()).hasPrefix("password-"))
        XCTAssertEqual(fixture.deleteCount, 0)
        XCTAssertEqual(fixture.updateCount, 0)
    }

    func testCancelledCreationDoesNotInvalidateOrInsert() async {
        let fixture = PasswordKeychainFixture()
        let task = Task {
            try fixture.keychain.createPasswordIfMissing("password", beforeInsert: {
                XCTFail("Canceled creation must not invalidate the vault")
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fixture.addCount, 0)
    }

}
