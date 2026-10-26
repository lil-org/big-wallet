import Foundation
import Security
import WalletDomain
import XCTest
@testable import WalletAuthority

final class WalletSourceIsolationTests: XCTestCase {
    func testMissingMutationDependencyFailsBeforeReadingOrChangingWalletStorage() async {
        let repository = WalletRepository(keychain: Keychain(
            copyMatching: { _, _ in XCTFail("Missing mutation dependency must not read wallet storage"); return errSecParam },
            add: { _, _ in XCTFail("Missing mutation dependency must not add wallet data"); return errSecParam },
            update: { _, _ in XCTFail("Missing mutation dependency must not update wallet data"); return errSecParam },
            delete: { _ in XCTFail("Missing mutation dependency must not delete wallet data"); return errSecParam }
        ))
        let wallet = WalletSnapshot(id: "fixture", isMnemonic: true, accounts: [])
        do {
            _ = try await repository.update(wallet: wallet, enabledAccounts: [], willMutateSource: {
                XCTFail("Missing mutation dependency must not invalidate source storage")
            })
            XCTFail("A mutation requires explicit storage ownership")
        } catch {
            guard case .keychainAccessFailure? = error as? WalletsManager.Error else {
                return XCTFail("Expected unavailable source mutation, got \(error)")
            }
        }
    }
}
