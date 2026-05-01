// ∅ 2026 lil org

import Foundation
import WalletCore
import XCTest
@testable import Big_Wallet

final class WalletsManagerPreviewTests: XCTestCase {

    private enum PreviewTestError: Error {
        case failed
    }

    private let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    func testEthereumPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .ethereum)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .ethereum })
    }

    func testSolanaPreviewReturnsPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertEqual(accounts[0].derivation, .solanaSolana)
        XCTAssertEqual(accounts[0].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[1].derivation, .custom)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/1'/0'")
        XCTAssertFalse(accounts[0].address.isEmpty)
        XCTAssertNotEqual(accounts[0].address, accounts[1].address)
    }

    func testSolanaPreviewReturnsNextPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 1, coin: .solana)

        XCTAssertEqual(accounts.count, 11)
        XCTAssertTrue(accounts.allSatisfy { $0.coin == .solana })
        XCTAssertEqual(accounts.first?.derivation, .custom)
        XCTAssertEqual(accounts.first?.derivationPath, "m/44'/501'/11'/0'")
        XCTAssertEqual(accounts.first?.address.isEmpty, false)
    }

    func testMulticoinPreviewReturnsInterleavedPageOfAccounts() throws {
        let accounts = try WalletsManager.shared.previewAccounts(hdWallet: testHDWallet(), page: 0, coin: nil)

        XCTAssertEqual(accounts.count, 22)
        XCTAssertEqual(accounts.filter { $0.coin == .ethereum }.count, 11)
        XCTAssertEqual(accounts.filter { $0.coin == .solana }.count, 11)
        XCTAssertEqual(accounts[0].coin, .ethereum)
        XCTAssertEqual(accounts[0].derivationPath, DerivationPath(purpose: .bip44, coin: CoinType.ethereum.slip44Id, account: 0, change: 0, address: 0).description)
        XCTAssertEqual(accounts[1].coin, .solana)
        XCTAssertEqual(accounts[1].derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(accounts[2].coin, .ethereum)
        XCTAssertEqual(accounts[2].derivationPath, DerivationPath(purpose: .bip44, coin: CoinType.ethereum.slip44Id, account: 0, change: 0, address: 1).description)
        XCTAssertEqual(accounts[3].coin, .solana)
        XCTAssertEqual(accounts[3].derivationPath, "m/44'/501'/1'/0'")
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
        let ethereumAccount = Account(address: "0x0000000000000000000000000000000000000001",
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

    private func testHDWallet(file: StaticString = #filePath, line: UInt = #line) throws -> HDWallet {
        guard let wallet = HDWallet(mnemonic: mnemonic, passphrase: "") else {
            XCTFail("Expected test mnemonic to create HD wallet", file: file, line: line)
            throw PreviewTestError.failed
        }

        return wallet
    }

}
