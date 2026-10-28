import Foundation
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority

@MainActor
final class SecretBytesTests: XCTestCase {
    func testInvalidationRetiresEveryAliasAndWipesExactlyOnce() throws {
        let wipes = Mutex([Bool]())
        let secret = SecretBytes(count: 32, onWipe: { bytes in
            wipes.withLock { $0.append(bytes.allSatisfy { $0 == 0 }) }
        }) { $0.initializeMemory(as: UInt8.self, repeating: 0x7f) }
        let alias = secret
        XCTAssertEqual(try alias.withUnsafeBytes { $0.count }, 32)

        secret.invalidate()
        alias.invalidate()

        XCTAssertThrowsError(try alias.withUnsafeBytes { _ in XCTFail("Retired alias was borrowed") })
        XCTAssertEqual(wipes.withLock { $0 }, [true])
    }

    func testInvalidationDoesNotBlockAnActiveBorrowAndWipesAfterItEnds() async throws {
        let entered = expectation(description: "Borrow started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let wipes = Mutex([Bool]())
        let secret = SecretBytes(count: 32, onWipe: { bytes in
            wipes.withLock { $0.append(bytes.allSatisfy { $0 == 0 }) }
        }) { $0.initializeMemory(as: UInt8.self, repeating: 42) }
        let borrow = Task.detached {
            try secret.withUnsafeBytes { bytes in
                entered.fulfill()
                release.wait()
                return bytes.allSatisfy { $0 == 42 }
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        secret.invalidate()
        XCTAssertTrue(wipes.withLock { $0.isEmpty })
        XCTAssertThrowsError(try secret.withUnsafeBytes { _ in XCTFail("Invalidated owner admitted another borrow") })
        release.signal()

        let completed = try await borrow.value
        XCTAssertTrue(completed)
        XCTAssertEqual(wipes.withLock { $0 }, [true])
    }

    func testCancellationDuringBorrowWipesBeforeFreeAndDiscardsTheResult() async throws {
        let entered = expectation(description: "Cancelable secret borrow started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let wipes = Mutex([Bool]())
        let secret = SecretBytes(count: 48, onWipe: { bytes in
            wipes.withLock { $0.append(bytes.allSatisfy { $0 == 0 }) }
        }) { $0.initializeMemory(as: UInt8.self, repeating: 0x62) }
        let operation = Task.detached {
            try await withTaskCancellationHandler {
                let value = try secret.withUnsafeBytes { bytes in
                    entered.fulfill()
                    release.wait()
                    return bytes.allSatisfy { $0 == 0x62 }
                }
                try Task.checkCancellation()
                return value
            } onCancel: {
                secret.invalidate()
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        operation.cancel()

        XCTAssertFalse(secret.isAvailable)
        XCTAssertTrue(wipes.withLock { $0.isEmpty })
        release.signal()
        do {
            _ = try await operation.value
            XCTFail("Canceled work published its result")
        } catch is CancellationError {}
        XCTAssertEqual(wipes.withLock { $0 }, [true])
    }

    func testThrowingInitializationAndFinalReleaseWipeTheirAllocations() {
        enum Failure: Error { case expected }
        let wipes = Mutex([Bool]())
        XCTAssertThrowsError(try SecretBytes(count: 17, onWipe: { bytes in
            wipes.withLock { $0.append(bytes.allSatisfy { $0 == 0 }) }
        }) { output in
            output.initializeMemory(as: UInt8.self, repeating: 9)
            throw Failure.expected
        })
        var secret: SecretBytes? = SecretBytes(count: 17, onWipe: { bytes in
            wipes.withLock { $0.append(bytes.allSatisfy { $0 == 0 }) }
        }) { $0.initializeMemory(as: UInt8.self, repeating: 5) }
        XCTAssertNotNil(secret)
        secret = nil
        XCTAssertEqual(wipes.withLock { $0 }, [true, true])
    }

    func testExportAliasesCannotReadAfterInvalidation() {
        let secret = WalletExportedSecret(text: "test export")
        let alias = secret
        var rendered: String?
        XCTAssertTrue(secret.withText { rendered = $0 })
        XCTAssertEqual(rendered, "test export")
        alias.invalidate()
        XCTAssertFalse(secret.withText { _ in XCTFail("Retired export was rendered") })
    }

    func testPrivateKeyAndSeedAliasesLoseSigningAndDerivationAccess() throws {
        let key = try XCTUnwrap(WalletPrivateKey(data: WalletCoreProxyTestVectors.onePrivateKey))
        let retainedKey = key
        key.invalidate()
        XCTAssertTrue(retainedKey.publicKeyData(coin: .ethereum).isEmpty)
        XCTAssertNil(retainedKey.sign(digest: Data(repeating: 1, count: 32), coin: .ethereum))

        let wallet = try XCTUnwrap(WalletHDWallet(mnemonic: WalletCoreProxyTestVectors.abandonMnemonic, passphrase: ""))
        let retainedWallet = wallet
        wallet.invalidate()
        XCTAssertNil(retainedWallet.ethereumPreviewAccounts(accountRange: 0..<1))
        XCTAssertNil(retainedWallet.solanaPreviewAccounts(accountRange: 0..<1))
    }

    func testMnemonicDerivationBorrowsItsOwnerAndKeepsAnIndependentSeed() throws {
        let vectors = WalletCoreProxyTestVectors.self
        let mnemonic = SecretBytes(utf8: vectors.abandonMnemonic)
        let wallet = try XCTUnwrap(WalletHDWallet(mnemonic: mnemonic, passphrase: ""))
        defer { wallet.invalidate(); mnemonic.invalidate() }
        XCTAssertEqual(mnemonic.testData, Data(vectors.abandonMnemonic.utf8))

        mnemonic.invalidate()

        XCTAssertNil(WalletHDWallet(mnemonic: mnemonic, passphrase: ""))
        XCTAssertNil(WalletHDWallet(storedMnemonic: mnemonic))
        let key = try XCTUnwrap(wallet.privateKey(coin: .ethereum, derivationPath: "m/44'/60'/0'/0/0"))
        defer { key.invalidate() }
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(key.publicKeyData(coin: .ethereum), coin: .ethereum),
                       vectors.abandonEthereumAddress)
    }
}
