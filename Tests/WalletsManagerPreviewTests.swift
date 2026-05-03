// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletsManagerPreviewTests: XCTestCase {

    private enum PreviewTestError: Error {
        case failed
    }

    private let mnemonic = Vectors.abandonMnemonic

    func testEthereumPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
        XCTAssertTrue(accounts.allSatisfy { !$0.address.isEmpty })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey == Vectors.abandonEthereumExtendedPublicKey })

        for accountIndex in 0...10 {
            let vector = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex],
                                 matches: vector,
                                 coin: .ethereum,
                                 derivation: .custom,
                                 extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey)
        }
    }

    func testEthereumPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey == Vectors.abandonEthereumExtendedPublicKey })
        XCTAssertEqual(accounts.map { $0.previewDerivationIndex }, Array(11...21))

        for accountIndex in 11...21 {
            let vector = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex - 11],
                                 matches: vector,
                                 coin: .ethereum,
                                 derivation: .custom,
                                 extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey)
        }
    }

    func testSolanaPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey.isEmpty })
        XCTAssertEqual(accounts[0].derivation, .solanaSolana)
        XCTAssertEqual(accounts[0].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].derivation, .custom)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/1'/0'")

        for accountIndex in 0...10 {
            let vector = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex],
                                 matches: vector,
                                 coin: .solana,
                                 derivation: vector.index == 0 ? .solanaSolana : .custom,
                                 extendedPublicKey: "")
        }
    }

    func testSolanaPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertTrue(accounts.allSatisfy { $0.extendedPublicKey.isEmpty })
        XCTAssertTrue(accounts.allSatisfy { $0.derivation == .custom })
        XCTAssertEqual(accounts.map { $0.previewDerivationIndex }, Array(11...21))

        for accountIndex in 11...21 {
            let vector = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == accountIndex })
            assertPreviewAccount(accounts[accountIndex - 11],
                                 matches: vector,
                                 coin: .solana,
                                 derivation: .custom,
                                 extendedPublicKey: "")
        }
    }

    func testMulticoinPreviewReturnsInterleavedPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: nil)
        let ethereumIndexTen = try XCTUnwrap(Vectors.abandonEthereumHDVectors.first { $0.index == 10 })
        let solanaIndexTen = try XCTUnwrap(Vectors.abandonSolanaHDVectors.first { $0.index == 10 })

        XCTAssertEqual(accounts.count, 22)
        XCTAssertEqual(accounts.filter { $0.coin == .ethereum }.count, 11)
        XCTAssertEqual(accounts.filter { $0.coin == .solana }.count, 11)
        XCTAssertTrue(accounts.allSatisfy { !$0.address.isEmpty })
        XCTAssertEqual(accounts[0].coin, .ethereum)
        XCTAssertEqual(accounts[0].derivationPath, WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0))
        XCTAssertEqual(accounts[0].address, Vectors.abandonEthereumHDVectors[0].address)
        XCTAssertEqual(accounts[0].publicKey, Vectors.abandonEthereumHDVectors[0].publicKey)
        XCTAssertEqual(accounts[1].coin, .solana)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].address, Vectors.abandonSolanaHDVectors[0].address)
        XCTAssertEqual(accounts[1].publicKey, Vectors.abandonSolanaHDVectors[0].publicKey)
        XCTAssertEqual(accounts[2].coin, .ethereum)
        XCTAssertEqual(accounts[2].derivationPath, WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 1))
        XCTAssertEqual(accounts[2].address, Vectors.abandonEthereumHDVectors[1].address)
        XCTAssertEqual(accounts[2].publicKey, Vectors.abandonEthereumHDVectors[1].publicKey)
        XCTAssertEqual(accounts[3].coin, .solana)
        XCTAssertEqual(accounts[3].derivationPath, "m/44'/501'/1'/0'")
        XCTAssertEqual(accounts[3].address, Vectors.abandonSolanaHDVectors[1].address)
        XCTAssertEqual(accounts[3].publicKey, Vectors.abandonSolanaHDVectors[1].publicKey)
        XCTAssertEqual(accounts[20].address, ethereumIndexTen.address)
        XCTAssertEqual(accounts[21].address, solanaIndexTen.address)
        XCTAssertEqual(accounts.prefix(6).map { $0.previewDerivationIndex }, [0, 0, 1, 1, 2, 2])
    }

    func testMulticoinPreviewCollectorInterleavesSuccessfulCoins() throws {
        let hdWallet = try testHDWallet()
        let ethereumAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .ethereum).prefix(2))
        let solanaAccounts = Array(try WalletsManager.shared.previewAccounts(hdWallet: hdWallet, page: 0, coin: .solana).prefix(2))

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.ethereum, .solana]) { coin in
            switch coin {
            case .ethereum:
                return ethereumAccounts
            case .solana:
                return solanaAccounts
            default:
                return []
            }
        }

        XCTAssertEqual(accounts.map { $0.previewAccountKey }, [
            ethereumAccounts[0].previewAccountKey,
            solanaAccounts[0].previewAccountKey,
            ethereumAccounts[1].previewAccountKey,
            solanaAccounts[1].previewAccountKey,
        ])
    }

    func testMulticoinPreviewPreservesSuccessfulCoinsWhenOneFails() throws {
        let ethereumAccount = WalletAccount(address: "0x0000000000000000000000000000000000000001",
                                      coin: .ethereum,
                                      derivation: .custom,
                                      derivationPath: "m/44'/60'/0'/0/0",
                                      publicKey: "public-key",
                                      extendedPublicKey: "extended-public-key")

        let accounts = try WalletsManager.collectPreviewAccounts(coins: [.solana, .ethereum]) { coin in
            if coin == .solana {
                throw PreviewTestError.failed
            }

            return [ethereumAccount]
        }

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.address, ethereumAccount.address)
    }

    func testMulticoinPreviewRethrowsWhenAllCoinsFail() {
        XCTAssertThrowsError(try WalletsManager.collectPreviewAccounts(coins: [.solana]) { _ in
            throw PreviewTestError.failed
        })
    }

    private func testHDWallet(file: StaticString = #filePath, line: UInt = #line) throws -> WalletHDWallet {
        guard let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: "") else {
            XCTFail("Expected test mnemonic to create HD wallet", file: file, line: line)
            throw PreviewTestError.failed
        }

        return wallet
    }

    private func assertPreviewAccount(_ account: WalletAccount,
                                      matches vector: (index: Int, path: String, privateKey: Data, publicKey: String, address: String),
                                      coin: WalletCoin,
                                      derivation: WalletDerivation,
                                      extendedPublicKey: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertEqual(account.address, vector.address, file: file, line: line)
        XCTAssertEqual(account.coin, coin, file: file, line: line)
        XCTAssertEqual(account.derivation, derivation, file: file, line: line)
        XCTAssertEqual(account.derivationPath, vector.path, file: file, line: line)
        XCTAssertEqual(account.publicKey, vector.publicKey, file: file, line: line)
        XCTAssertEqual(account.extendedPublicKey, extendedPublicKey, file: file, line: line)
        XCTAssertEqual(account.previewDerivationIndex, vector.index, file: file, line: line)
    }

}
