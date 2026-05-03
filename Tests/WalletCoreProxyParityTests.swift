// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletCoreProxyCoinAndCryptoTests: XCTestCase {

    func testCoinConstantsMatchWalletCoreContract() {
        XCTAssertEqual(WalletCoin.ethereum.rawValue, 60)
        XCTAssertEqual(WalletCoin.near.rawValue, 397)
        XCTAssertEqual(WalletCoin.solana.rawValue, 501)

        XCTAssertEqual(WalletCoin.ethereum.slip44Id, 60)
        XCTAssertEqual(WalletCoin.near.slip44Id, 397)
        XCTAssertEqual(WalletCoin.solana.slip44Id, 501)
    }

    func testMnemonicValidationAliases() {
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.abandonMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(mnemonic: Vectors.abandonMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(mnemonic: "THIS IS AN INVALID MNEMONIC"))
    }

    func testBIP44DerivationPathAndPreviewIndexContract() {
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0), "m/44'/60'/0'/0/0")
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .solana, account: 11, change: 0, address: 7), "m/44'/501'/11'/0/7")
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .near, account: 2, change: 3, address: 4), "m/44'/397'/2'/3/4")

        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/60'/0'/0/13", coin: .ethereum), 13)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/397'/4'/0/9", coin: .near), 9)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/501'/11'/0'", coin: .solana), 11)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "not a derivation path", coin: .ethereum), 0)
    }

    func testHexParsingMatchesWalletCoreSemantics() {
        XCTAssertEqual(WalletCrypto.hexData(""), Data())
        XCTAssertEqual(WalletCrypto.hexData(string: "0x00aF"), Data([0x00, 0xaf]))
        XCTAssertEqual(WalletCrypto.hexData("ABCDEF"), Data([0xab, 0xcd, 0xef]))
        XCTAssertEqual(WalletCrypto.hexString(Data([0x00, 0xaf, 0xff])), "00afff")
        XCTAssertEqual(WalletCrypto.hexString(data: Data()), "")

        XCTAssertNil(WalletCrypto.hexData("0"))
        XCTAssertNil(WalletCrypto.hexData(string: "0xzz"))
        XCTAssertNil(WalletCrypto.hexData("0X00"))
        XCTAssertNil(WalletCrypto.hexData(" 00"))
    }

    func testBase58RoundTripsAndRejectsInvalidAlphabet() throws {
        let systemProgram = "11111111111111111111111111111111"
        XCTAssertEqual(WalletCrypto.base58Decode(systemProgram), Data(repeating: 0, count: 32))
        XCTAssertEqual(WalletCrypto.base58Encode(data: Data([0, 0, 0, 1])), "1112")

        let payload = Vectors.data(hex: "00010203040506070809")
        let encoded = WalletCrypto.base58Encode(payload)
        XCTAssertEqual(WalletCrypto.base58Decode(string: encoded), payload)
        XCTAssertNil(WalletCrypto.base58Decode("0OIl"))
    }

    func testKeccakKnownVectors() {
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.keccak256(data: Data())),
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: Data("hello".utf8))),
                       "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

}

final class WalletCoreProxyPrivateKeyTests: XCTestCase {

    func testPrivateKeyValidationAndRawDataAccess() throws {
        XCTAssertNil(WalletPrivateKey(data: Data([0xde, 0xad, 0xbe, 0xef])))
        XCTAssertNil(WalletPrivateKey(data: Vectors.zeroPrivateKey))
        XCTAssertNotNil(WalletPrivateKey(data: Vectors.secp256k1PrivateKeyAtCurveOrder))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.sequentialPrivateKey, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(data: Vectors.sequentialPrivateKey, coin: .solana))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(data: Vectors.sequentialPrivateKey, coin: .near))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Data([1, 2, 3]), coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.zeroPrivateKey, coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.zeroPrivateKey, coin: .solana))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAtCurveOrder, coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAboveCurveOrder, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAtCurveOrder, coin: .solana))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAtCurveOrder, coin: .near))

        let privateKey = try requirePrivateKey(Vectors.sequentialPrivateKey)
        privateKey.withData {
            XCTAssertEqual($0, Vectors.sequentialPrivateKey)
        }
    }

    func testSecp256k1PublicKeyMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.secpPrivateKey)
        let publicKey = privateKey.publicKeyDescription(coin: .ethereum)

        XCTAssertEqual(publicKey, Vectors.secpPublicKey)
        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .ethereum)), Vectors.secpPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(publicKey, coin: .ethereum),
                       Vectors.secpEthereumAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(privateKey.publicKeyData(coin: .ethereum), coin: .ethereum),
                       Vectors.secpEthereumAddress)
    }

    func testEd25519PublicKeysAndAddressesMatchWalletCoreVectors() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaAddressPrivateKey)
        let solanaPublicKey = privateKey.publicKeyData(coin: .solana)
        let nearPublicKey = privateKey.publicKeyData(coin: .near)

        XCTAssertEqual(WalletCrypto.hexString(solanaPublicKey), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(solanaPublicKey, coin: .solana), Vectors.solanaAddressFromPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.solanaAddressPublicKey, coin: .solana),
                       Vectors.solanaAddressFromPublicKey)

        XCTAssertEqual(WalletCrypto.hexString(nearPublicKey), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(nearPublicKey, coin: .near), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.solanaAddressPublicKey, coin: .near),
                       Vectors.solanaAddressPublicKey)
    }

    func testSolanaSigningMatchesWalletCoreMessageSignerVector() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let signature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaMessage, coin: .solana))

        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .solana)), Vectors.solanaSigningPublicKey)
        XCTAssertEqual(WalletCrypto.base58Encode(signature), Vectors.solanaMessageSignature)
    }

    func testNearSigningMatchesWalletCoreEd25519Vector() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let signature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaMessage, coin: .near))

        XCTAssertEqual(WalletCrypto.base58Encode(signature), Vectors.nearMessageSignature)
    }

    func testEthereumPersonalSigningAndRecoveryMatchWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)
        let signatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumPersonalMessage, privateKey: privateKey)
        let signature = try XCTUnwrap(WalletCrypto.hexData(String(signatureHex.dropFirst(2))))

        XCTAssertEqual(signatureHex, Vectors.ethereumPersonalMessageSignature)
        XCTAssertEqual(Ethereum.shared.recover(signature: signature, message: Vectors.ethereumPersonalMessage),
                       Vectors.ethereumSignerAddress)
    }

    func testInvalidPublicKeyInputsReturnEmptyAddresses() {
        let prefixedPublicKeyAddress = WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.secpPublicKey, coin: .ethereum)

        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("not hex", coin: .ethereum), "")
        XCTAssertFalse(prefixedPublicKeyAddress.isEmpty)
        XCTAssertEqual(prefixedPublicKeyAddress,
                       WalletCrypto.addressFromPublicKeyDescription(Vectors.secpPublicKey, coin: .ethereum))
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data([1, 2, 3]), coin: .solana), "")
    }

}

final class WalletCoreProxyHDWalletTests: XCTestCase {

    func testWalletCreationRejectsInvalidMnemonic() {
        XCTAssertNotNil(WalletHDWallet(mnemonic: Vectors.abandonMnemonic, passphrase: ""))
        XCTAssertNil(WalletHDWallet(mnemonic: Vectors.invalidMnemonic, passphrase: ""))
    }

    func testDerivesSupportedCoinAddressesFromWalletCoreAddressVectors() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.coinAddressMnemonic)

        XCTAssertEqual(derivedAddress(wallet: wallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"), Vectors.coinAddressEthereumAddress)
        XCTAssertEqual(derivedAddress(wallet: wallet, coin: .solana, path: "m/44'/501'/0'"), Vectors.coinAddressSolanaAddress)
        XCTAssertEqual(derivedAddress(wallet: wallet, coin: .near, path: "m/44'/397'/0'"), Vectors.coinAddressNearAddress)
    }

    func testPassphraseAffectsHDWalletDerivation() throws {
        let trezorWallet = try requireHDWallet(mnemonic: Vectors.walletCoreHDMnemonic, passphrase: "TREZOR")
        let noPassphraseWallet = try requireHDWallet(mnemonic: Vectors.walletCoreHDMnemonic)

        XCTAssertEqual(derivedAddress(wallet: trezorWallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"),
                       Vectors.walletCoreHDEthereumAddress)
        XCTAssertNotEqual(derivedAddress(wallet: noPassphraseWallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"),
                          Vectors.walletCoreHDEthereumAddress)
    }

    func testExtendedPublicKeyDerivesEthereumAccounts() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let defaultDerivationXpub = wallet.extendedPublicKeyDerivation(coin: .ethereum, derivation: .default)
        let accountOneXpub = wallet.extendedPublicKeyAccount(coin: .ethereum, derivation: .default, account: 1)
        let firstPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)
        let secondPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 1)
        let accountOnePath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 1, change: 0, address: 0)

        let firstPublicKey = try XCTUnwrap(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                                         coin: .ethereum,
                                                                                         derivationPath: firstPath))
        let firstAccount = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                                   coin: .ethereum,
                                                                                   derivation: .custom,
                                                                                   derivationPath: firstPath))
        let secondAccount = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                                    coin: .ethereum,
                                                                                    derivation: .custom,
                                                                                    derivationPath: secondPath))
        let accountOne = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: accountOneXpub,
                                                                                 coin: .ethereum,
                                                                                 derivation: .custom,
                                                                                 derivationPath: accountOnePath))

        XCTAssertEqual(xpub, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(defaultDerivationXpub, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(accountOneXpub, Vectors.abandonEthereumAccountOneExtendedPublicKey)
        XCTAssertEqual(firstPublicKey, firstAccount.publicKey)
        XCTAssertEqual(firstAccount.address, Vectors.abandonEthereumAddress)
        XCTAssertEqual(firstAccount.coin, .ethereum)
        XCTAssertEqual(firstAccount.derivation, .custom)
        XCTAssertEqual(firstAccount.derivationPath, firstPath)
        XCTAssertEqual(firstAccount.extendedPublicKey, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(secondAccount.address, Vectors.abandonEthereumSecondAddress)
        XCTAssertEqual(secondAccount.publicKey, Vectors.abandonEthereumSecondPublicKey)
        XCTAssertEqual(accountOne.address, Vectors.abandonEthereumAccountOneAddress)
        XCTAssertEqual(accountOne.extendedPublicKey, Vectors.abandonEthereumAccountOneExtendedPublicKey)

        XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: "not an xpub",
                                                                   coin: .ethereum,
                                                                   derivationPath: firstPath))
        XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: "not an xpub",
                                                               coin: .ethereum,
                                                               derivation: .custom,
                                                               derivationPath: firstPath))
    }

    func testEd25519ExtendedPublicKeyVariantsPinWalletCoreQuirks() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let solanaDefaultExtended = wallet.extendedPublicKey(coin: .solana)
        let solanaDerivationExtended = wallet.extendedPublicKeyDerivation(coin: .solana, derivation: .solanaSolana)
        let solanaAccountExtended = wallet.extendedPublicKeyAccount(coin: .solana, derivation: .solanaSolana, account: 1)
        let nearDefaultExtended = wallet.extendedPublicKey(coin: .near)
        let nearDerivationExtended = wallet.extendedPublicKeyDerivation(coin: .near, derivation: .default)
        let nearAccountExtended = wallet.extendedPublicKeyAccount(coin: .near, derivation: .default, account: 1)
        let solanaDefaultPath = "m/44'/501'/0'"
        let solanaSolanaPath = "m/44'/501'/0'/0'"
        let nearDefaultPath = "m/44'/397'/0'"

        XCTAssertEqual(solanaDefaultExtended, Vectors.abandonSolanaDefaultExtendedPublicKey)
        XCTAssertEqual(solanaDerivationExtended, "")
        XCTAssertEqual(solanaAccountExtended, "")
        XCTAssertEqual(nearDefaultExtended, Vectors.abandonNearDefaultExtendedPublicKey)
        XCTAssertEqual(nearDerivationExtended, "")
        XCTAssertEqual(nearAccountExtended, "")

        XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: solanaDefaultExtended,
                                                                   coin: .solana,
                                                                   derivationPath: solanaDefaultPath))
        XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: solanaDefaultExtended,
                                                               coin: .solana,
                                                               derivation: .default,
                                                               derivationPath: solanaDefaultPath))
        XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: solanaDefaultExtended,
                                                                   coin: .solana,
                                                                   derivationPath: solanaSolanaPath))
        XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: solanaDefaultExtended,
                                                               coin: .solana,
                                                               derivation: .solanaSolana,
                                                               derivationPath: solanaSolanaPath))
        XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: nearDefaultExtended,
                                                                   coin: .near,
                                                                   derivationPath: nearDefaultPath))
        XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: nearDefaultExtended,
                                                               coin: .near,
                                                               derivation: .default,
                                                               derivationPath: nearDefaultPath))
    }

    private func derivedAddress(wallet: WalletHDWallet, coin: WalletCoin, path: String) -> String {
        let privateKey = wallet.getKey(coin: coin, derivationPath: path)
        return WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: coin), coin: coin)
    }

}

final class WalletCoreProxyStoredKeyTests: XCTestCase {

    func testImportsWalletCorePrivateKeyJSONFixture() throws {
        let expectedAccount = WalletAccount(address: Vectors.walletCoreJSONPrivateKeyAddress,
                                            coin: .ethereum,
                                            derivation: .default,
                                            derivationPath: "m/44'/60'/0'/0/0",
                                            publicKey: "",
                                            extendedPublicKey: "")
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONPrivateKeyFixture))
        let account = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: nil))
        let privateKey = try XCTUnwrap(key.privateKey(coin: .ethereum, password: Vectors.walletCoreJSONPrivateKeyPassword))

        XCTAssertEqual(key.name, "")
        XCTAssertFalse(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), expectedAccount)
        XCTAssertEqual(account, expectedAccount)
        XCTAssertEqual(key.decryptPrivateKey(password: Vectors.walletCoreJSONPrivateKeyPassword),
                       Vectors.walletCoreJSONPrivateKeyData)
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword))
        XCTAssertNil(key.wallet(password: Vectors.walletCoreJSONPrivateKeyPassword))
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .ethereum),
                                                                    coin: .ethereum),
                       Vectors.walletCoreJSONPrivateKeyAddress)
    }

    func testImportsWalletCoreMnemonicJSONFixture() throws {
        let storedAccount = WalletAccount(address: Vectors.walletCoreJSONMnemonicStoredEthereumAddress,
                                          coin: .ethereum,
                                          derivation: .default,
                                          derivationPath: "m/44'/60'/0'/0/0",
                                          publicKey: "",
                                          extendedPublicKey: "")
        let derivedAccount = WalletAccount(address: Vectors.walletCoreJSONMnemonicDerivedEthereumAddress,
                                           coin: .ethereum,
                                           derivation: .default,
                                           derivationPath: "m/44'/60'/0'/0/0",
                                           publicKey: Vectors.walletCoreJSONMnemonicDerivedEthereumPublicKey,
                                           extendedPublicKey: "")
        let key = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))

        XCTAssertEqual(key.name, "")
        XCTAssertTrue(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), storedAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), storedAccount)
        XCTAssertEqual(key.decryptMnemonic(password: Vectors.walletCoreJSONMnemonicPassword),
                       Vectors.walletCoreJSONMnemonic)
        XCTAssertEqual(key.decryptPrivateKey(password: Vectors.walletCoreJSONMnemonicPassword),
                       Data(Vectors.walletCoreJSONMnemonic.utf8))
        XCTAssertNil(key.decryptMnemonic(password: Vectors.wrongPassword))
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.wallet(password: Vectors.wrongPassword))
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword))

        let wallet = try XCTUnwrap(key.wallet(password: Vectors.walletCoreJSONMnemonicPassword))
        let privateKey = try XCTUnwrap(key.privateKey(coin: .ethereum, password: Vectors.walletCoreJSONMnemonicPassword))
        let publicKey = privateKey.publicKeyDescription(coin: .ethereum)
        let derivedAddress = WalletCrypto.addressFromPublicKeyDescription(publicKey, coin: .ethereum)

        XCTAssertEqual(publicKey, Vectors.walletCoreJSONMnemonicDerivedEthereumPublicKey)
        XCTAssertEqual(derivedAddress, Vectors.walletCoreJSONMnemonicDerivedEthereumAddress)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), derivedAccount)
        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 1), derivedAccount)
    }

    func testGeneratedStoredKeyPropertiesAndFailures() throws {
        let key = WalletStoredKey(name: "empty", password: Vectors.password)
        let mnemonic = try XCTUnwrap(key.decryptMnemonic(password: Vectors.password))
        let decryptedPayload = try XCTUnwrap(key.decryptPrivateKey(password: Vectors.password))

        XCTAssertEqual(key.name, "empty")
        XCTAssertTrue(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 0)
        XCTAssertNil(key.account(index: 0))
        XCTAssertEqual(decryptedPayload, Data(mnemonic.utf8))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(mnemonic))
        XCTAssertNotNil(key.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.decryptMnemonic(password: Vectors.wrongPassword))
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword))
    }

    func testImportEthereumPrivateKeyPinsAccountAndJSONRoundTrip() throws {
        let expectedAccount = WalletAccount(address: Vectors.secpEthereumAddress,
                                            coin: .ethereum,
                                            derivation: .default,
                                            derivationPath: "m/44'/60'/0'/0/0",
                                            publicKey: Vectors.secpPublicKey,
                                            extendedPublicKey: "")
        let key = try requireStoredPrivateKey(privateKey: Vectors.secpPrivateKey, coin: .ethereum)
        let account = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: nil))
        let decryptedPrivateKey = try XCTUnwrap(key.decryptPrivateKey(password: Vectors.password))
        let privateKey = try XCTUnwrap(key.privateKey(coin: .ethereum, password: Vectors.password))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))

        XCTAssertEqual(key.name, "private")
        XCTAssertFalse(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(account, expectedAccount)
        XCTAssertEqual(key.account(index: 0), expectedAccount)
        XCTAssertEqual(decryptedPrivateKey, Vectors.secpPrivateKey)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum), Vectors.secpPublicKey)
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword))

        XCTAssertEqual(reimported.accountCount, key.accountCount)
        XCTAssertEqual(reimported.account(index: 0), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .ethereum, wallet: nil), expectedAccount)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), Vectors.secpPrivateKey)
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("{}".utf8)))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("not json".utf8)))
    }

    func testImportEd25519PrivateKeysPinSolanaAndNearAccountsAndJSONRoundTrip() throws {
        let cases = [
            (coin: WalletCoin.solana,
             expectedAccount: WalletAccount(address: Vectors.solanaAddressFromPublicKey,
                                            coin: .solana,
                                            derivation: .default,
                                            derivationPath: "m/44'/501'/0'",
                                            publicKey: Vectors.solanaAddressPublicKey,
                                            extendedPublicKey: "")),
            (coin: WalletCoin.near,
             expectedAccount: WalletAccount(address: Vectors.solanaAddressPublicKey,
                                            coin: .near,
                                            derivation: .default,
                                            derivationPath: "m/44'/397'/0'",
                                            publicKey: Vectors.solanaAddressPublicKey,
                                            extendedPublicKey: "")),
        ]

        for testCase in cases {
            let key = try requireStoredPrivateKey(privateKey: Vectors.solanaAddressPrivateKey,
                                                  coin: testCase.coin)
            let privateKey = try XCTUnwrap(key.privateKey(coin: testCase.coin, password: Vectors.password))
            let exportedJSON = try XCTUnwrap(key.exportJSON())
            let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))

            XCTAssertEqual(key.name, "private")
            XCTAssertFalse(key.isMnemonic)
            XCTAssertEqual(key.accountCount, 1)
            XCTAssertEqual(key.account(index: 0), testCase.expectedAccount)
            XCTAssertEqual(key.accountForCoin(coin: testCase.coin, wallet: nil), testCase.expectedAccount)
            XCTAssertEqual(key.decryptPrivateKey(password: Vectors.password), Vectors.solanaAddressPrivateKey)
            XCTAssertEqual(privateKey.publicKeyDescription(coin: testCase.coin), Vectors.solanaAddressPublicKey)
            XCTAssertNil(key.privateKey(coin: testCase.coin, password: Vectors.wrongPassword))

            XCTAssertEqual(reimported.accountCount, key.accountCount)
            XCTAssertEqual(reimported.account(index: 0), testCase.expectedAccount)
            XCTAssertEqual(reimported.accountForCoin(coin: testCase.coin, wallet: nil), testCase.expectedAccount)
            XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), Vectors.solanaAddressPrivateKey)
        }
    }

    func testImportHDWalletAccountsAndMnemonicRoundTrip() throws {
        let key = try requireStoredMnemonicKey(coin: .solana)
        XCTAssertNil(key.accountForCoinDerivation(coin: .solana, derivation: .default, wallet: nil))
        XCTAssertNil(key.accountForCoinDerivation(coin: .solana, derivation: .solanaSolana, wallet: nil))

        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let defaultAccount = try XCTUnwrap(key.accountForCoin(coin: .solana, wallet: wallet))
        let solanaAccount = try XCTUnwrap(key.accountForCoinDerivation(coin: .solana,
                                                                        derivation: .solanaSolana,
                                                                        wallet: wallet))
        XCTAssertNil(key.accountForCoinDerivation(coin: .solana, derivation: .solanaSolana, wallet: nil))

        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))
        let decryptedMnemonicPayload = try XCTUnwrap(key.decryptPrivateKey(password: Vectors.password))
        let reimportedMnemonicPayload = try XCTUnwrap(reimported.decryptPrivateKey(password: Vectors.password))

        XCTAssertEqual(key.name, "mnemonic")
        XCTAssertTrue(key.isMnemonic)
        XCTAssertEqual(key.decryptMnemonic(password: Vectors.password), Vectors.multiAccountMnemonic)
        XCTAssertEqual(decryptedMnemonicPayload, Data(Vectors.multiAccountMnemonic.utf8))
        XCTAssertNil(key.decryptMnemonic(password: Vectors.wrongPassword))
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.wallet(password: Vectors.wrongPassword))

        XCTAssertEqual(defaultAccount.address, "HiipoCKL8hX2RVmJTz3vaLy34hS2zLhWWMkUWtw85TmZ")
        XCTAssertEqual(defaultAccount.derivation, .default)
        XCTAssertEqual(defaultAccount.derivationPath, "m/44'/501'/0'")
        XCTAssertEqual(solanaAccount.address, "CgWJeEWkiYqosy1ba7a3wn9HAQuHyK48xs3LM4SSDc1C")
        XCTAssertEqual(solanaAccount.derivation, .solanaSolana)
        XCTAssertEqual(solanaAccount.derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(reimported.decryptMnemonic(password: Vectors.password), Vectors.multiAccountMnemonic)
        XCTAssertEqual(reimportedMnemonicPayload, Data(Vectors.multiAccountMnemonic.utf8))
        XCTAssertEqual(reimported.accountCount, key.accountCount)
        XCTAssertEqual(reimported.account(index: 0), defaultAccount)
        XCTAssertEqual(reimported.account(index: 1), solanaAccount)

        let reimportedWallet = try XCTUnwrap(reimported.wallet(password: Vectors.password))
        XCTAssertEqual(reimported.accountForCoin(coin: .solana, wallet: reimportedWallet), defaultAccount)
        XCTAssertNil(reimported.accountForCoinDerivation(coin: .solana, derivation: .solanaSolana, wallet: nil))
        XCTAssertEqual(reimported.accountForCoinDerivation(coin: .solana,
                                                           derivation: .solanaSolana,
                                                           wallet: reimportedWallet),
                       solanaAccount)
    }

    func testAccountForCoinCreatesAndPersistsMissingMnemonicAccountsWhenWalletProvided() throws {
        let key = try requireStoredMnemonicKey(coin: .solana)

        XCTAssertEqual(key.accountCount, 1)
        XCTAssertNil(key.accountForCoin(coin: .ethereum, wallet: nil))

        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let ethereumAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(ethereumAccount.address, Vectors.multiAccountEthereumAddress)
        XCTAssertEqual(ethereumAccount.coin, .ethereum)
        XCTAssertEqual(ethereumAccount.derivation, .default)
        XCTAssertEqual(ethereumAccount.derivationPath, "m/44'/60'/0'/0/0")
        XCTAssertEqual(ethereumAccount.publicKey, Vectors.multiAccountEthereumPublicKey)
        XCTAssertEqual(ethereumAccount.extendedPublicKey, "")
        XCTAssertEqual(key.account(index: 1), ethereumAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), ethereumAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), ethereumAccount)
        XCTAssertEqual(key.accountCount, 2)
    }

    func testAddAndRemoveAccountsByCoinAndDerivationPath() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let firstAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))
        let nearAccount = WalletAccount(address: Vectors.coinAddressNearAddress,
                                        coin: .near,
                                        derivation: .custom,
                                        derivationPath: "m/44'/397'/0'",
                                        publicKey: Vectors.coinAddressNearAddress,
                                        extendedPublicKey: "")

        key.addAccountDerivation(address: nearAccount.address,
                                 coin: nearAccount.coin,
                                 derivation: nearAccount.derivation,
                                 derivationPath: nearAccount.derivationPath,
                                 publicKey: nearAccount.publicKey,
                                 extendedPublicKey: nearAccount.extendedPublicKey)

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 1), nearAccount)
        XCTAssertEqual(key.accountForCoin(coin: .near, wallet: nil), nearAccount)

        key.removeAccountForCoinDerivationPath(coin: .near, derivationPath: "m/44'/397'/0'")
        XCTAssertNil(key.accountForCoin(coin: .near, wallet: nil))
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil)?.address, firstAccount.address)

        key.removeAccountForCoin(coin: .ethereum)
        XCTAssertNil(key.accountForCoin(coin: .ethereum, wallet: nil))
        XCTAssertEqual(key.accountCount, 0)
    }

    #if DEBUG
    func testWalletCoreJSONFixtureUnsupportedAccountsStayHiddenButAreCopied() throws {
        let expectedEthereumAccount = WalletAccount(address: Vectors.walletCoreJSONMixedAccountEthereumAddress,
                                                    coin: .ethereum,
                                                    derivation: .default,
                                                    derivationPath: "m/44'/60'/0'/0/0",
                                                    publicKey: "",
                                                    extendedPublicKey: "")
        let expectedNearAccount = WalletAccount(address: Vectors.walletCoreJSONMixedAccountNearAddress,
                                                coin: .near,
                                                derivation: .default,
                                                derivationPath: "m/44'/397'/0'",
                                                publicKey: "",
                                                extendedPublicKey: "")
        let expectedBitcoinAccount = WalletRawAccountForTesting(address: "bc1q4zehq85jqx9zzgzvzn9t64yjy66nunn3vehuv6",
                                                                coinRawValue: 0,
                                                                derivationRawValue: 0,
                                                                derivationPath: "m/84'/0'/0'/0/0",
                                                                publicKey: "",
                                                                extendedPublicKey: "zpub6qMRMrwcEYaqjf8wSpNqtBfUee6MqpQjrZNKfj5a48EUFUx2yUmfkDJMdHwWvkg8SjdS3ua6dy9ofMrzrytTfdyy2pXg344yFwm2Ta9cm6Q")
        let expectedBinanceAccount = WalletRawAccountForTesting(address: "bnb1njuczq3hgvupu2vnczrjz7rc8x4uxlmhjyq95z",
                                                                coinRawValue: 714,
                                                                derivationRawValue: 0,
                                                                derivationPath: "m/44'/714'/0'/0/0",
                                                                publicKey: "",
                                                                extendedPublicKey: "")
        let source = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMixedAccountFixture))
        let replacement = try XCTUnwrap(WalletStoredKey.importJSON(json: Vectors.walletCoreJSONMnemonicFixture))
        replacement.removeAccountForCoin(coin: .ethereum)

        XCTAssertEqual(source.accountCount, 4)
        XCTAssertEqual(source.decryptMnemonic(password: Vectors.walletCoreJSONMixedAccountPassword),
                       Vectors.walletCoreJSONMixedAccountMnemonic)
        XCTAssertNil(source.account(index: 0))
        XCTAssertEqual(source.account(index: 1), expectedEthereumAccount)
        XCTAssertNil(source.account(index: 2))
        XCTAssertEqual(source.account(index: 3), expectedNearAccount)
        XCTAssertEqual(source.rawAccountForTesting(index: 0), expectedBitcoinAccount)
        XCTAssertEqual(source.rawAccountForTesting(index: 2), expectedBinanceAccount)
        XCTAssertEqual(WalletContainer(id: "source", key: source).accounts, [expectedEthereumAccount, expectedNearAccount])

        XCTAssertEqual(replacement.accountCount, 0)
        replacement.copyUnsupportedAccounts(from: source)

        XCTAssertEqual(replacement.accountCount, 2)
        XCTAssertNil(replacement.account(index: 0))
        XCTAssertNil(replacement.account(index: 1))
        XCTAssertEqual(replacement.rawAccountForTesting(index: 0), expectedBitcoinAccount)
        XCTAssertEqual(replacement.rawAccountForTesting(index: 1), expectedBinanceAccount)
        XCTAssertTrue(WalletContainer(id: "replacement", key: replacement).accounts.isEmpty)

        let reimportedReplacement = try reimportExportedKey(replacement)
        XCTAssertEqual(reimportedReplacement.accountCount, 2)
        XCTAssertNil(reimportedReplacement.account(index: 0))
        XCTAssertNil(reimportedReplacement.account(index: 1))
        XCTAssertEqual(reimportedReplacement.rawAccountForTesting(index: 0), expectedBitcoinAccount)
        XCTAssertEqual(reimportedReplacement.rawAccountForTesting(index: 1), expectedBinanceAccount)
        XCTAssertEqual(reimportedReplacement.decryptMnemonic(password: Vectors.walletCoreJSONMnemonicPassword),
                       Vectors.walletCoreJSONMnemonic)
        XCTAssertTrue(WalletContainer(id: "reimported-replacement", key: reimportedReplacement).accounts.isEmpty)
    }

    func testUnsupportedAccountsStayHiddenButAreCopied() throws {
        let source = try requireStoredMnemonicKey(coin: .ethereum)
        let expectedUnsupportedAccount = WalletRawAccountForTesting(address: "LcHKpCqvAWDFNQBNSRShZchQyJY1mA6DUV",
                                                                    coinRawValue: 2,
                                                                    derivationRawValue: 5,
                                                                    derivationPath: "m/44'/2'/0'/0/3",
                                                                    publicKey: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
                                                                    extendedPublicKey: "xpub-unsupported-litecoin")
        source.addUnsupportedAccountForTesting(expectedUnsupportedAccount)
        let sourceWallet = WalletContainer(id: "source", key: source)

        XCTAssertEqual(source.accountCount, 2)
        XCTAssertEqual(source.account(index: 1), nil)
        XCTAssertEqual(source.rawAccountForTesting(index: 1), expectedUnsupportedAccount)
        XCTAssertEqual(sourceWallet.accounts.count, 1)
        XCTAssertEqual(sourceWallet.accounts.first?.coin, .ethereum)

        let replacement = try requireStoredMnemonicKey(coin: .ethereum)
        replacement.removeAccountForCoin(coin: .ethereum)
        replacement.copyUnsupportedAccounts(from: source)

        XCTAssertEqual(replacement.accountCount, 1)
        XCTAssertNil(replacement.account(index: 0))
        XCTAssertEqual(replacement.rawAccountForTesting(index: 0), expectedUnsupportedAccount)
        XCTAssertTrue(WalletContainer(id: "replacement", key: replacement).accounts.isEmpty)

        let reimportedReplacement = try reimportExportedKey(replacement)
        XCTAssertEqual(reimportedReplacement.accountCount, 1)
        XCTAssertNil(reimportedReplacement.account(index: 0))
        XCTAssertEqual(reimportedReplacement.rawAccountForTesting(index: 0), expectedUnsupportedAccount)
        XCTAssertTrue(WalletContainer(id: "reimported-replacement", key: reimportedReplacement).accounts.isEmpty)
    }
    #endif

}

final class WalletCoreProxyEthereumTests: XCTestCase {

    func testTypedDataDigestMatchesWalletCoreVector() {
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.typedDataJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.malformedTypedDataJSON),
                       Vectors.malformedTypedDataDigest)
    }

    func testDecodeEthereumCallMatchesWalletCoreVector() {
        XCTAssertEqual(WalletCrypto.decodeEthereumCall(data: Vectors.abiEncodedCall, abi: Vectors.abiJSON),
                       Vectors.abiDecodedCall)
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f002700"), abi: ",,"))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f002700"), abi: "{}"))
    }

    func testSignLegacyERC20TransactionMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                                     nonce: Data(),
                                                                     gasPrice: Vectors.data(hex: "09c7652400"),
                                                                     gasLimit: Vectors.data(hex: "0130b9"),
                                                                     toAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
                                                                     privateKey: privateKey,
                                                                     amount: Data(),
                                                                     data: Vectors.data(hex: "a9059cbb0000000000000000000000005322b34c88ed0691971bf52a7047448f0f4efc840000000000000000000000000000000000000000000000001bc16d674ec80000"))
        let emptySendTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                                        nonce: Data(),
                                                                        gasPrice: Vectors.data(hex: "01"),
                                                                        gasLimit: Vectors.data(hex: "5208"),
                                                                        toAddress: "0x0000000000000000000000000000000000000001",
                                                                        privateKey: privateKey,
                                                                        amount: Data(),
                                                                        data: Data())

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedERC20Transaction)
        XCTAssertEqual(WalletCrypto.hexString(emptySendTransaction), Vectors.signedEmptySendTransaction)
        XCTAssertTrue(WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                           nonce: Data(),
                                                           gasPrice: Vectors.data(hex: "01"),
                                                           gasLimit: Vectors.data(hex: "5208"),
                                                           toAddress: "0xdeadbeef",
                                                           privateKey: privateKey,
                                                           amount: Data(),
                                                           data: Data()).isEmpty)
    }

    func testSignLegacyNativeTransferMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumNativeTransferPrivateKey)
        let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                                     nonce: Vectors.data(hex: "09"),
                                                                     gasPrice: Vectors.data(hex: "04a817c800"),
                                                                     gasLimit: Vectors.data(hex: "5208"),
                                                                     toAddress: "0x3535353535353535353535353535353535353535",
                                                                     privateKey: privateKey,
                                                                     amount: Vectors.data(hex: "0de0b6b3a7640000"),
                                                                     data: Data())

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedNativeTransferTransaction)
    }

    func testSignLegacyTransactionAmountBoundaryCases() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)

        func signAmount(_ amount: Data) -> Data {
            return WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                        nonce: Data(),
                                                        gasPrice: Vectors.data(hex: "01"),
                                                        gasLimit: Vectors.data(hex: "5208"),
                                                        toAddress: "0x0000000000000000000000000000000000000001",
                                                        privateKey: privateKey,
                                                        amount: amount,
                                                        data: Data())
        }

        let emptyAmountTransaction = signAmount(Data())
        let zeroAmountTransaction = signAmount(Vectors.data(hex: "00"))
        let oneWeiTransaction = signAmount(Vectors.data(hex: "01"))
        let leadingZeroOneWeiTransaction = signAmount(Vectors.data(hex: "0001"))

        XCTAssertEqual(WalletCrypto.hexString(emptyAmountTransaction), Vectors.signedEmptySendTransaction)
        XCTAssertEqual(zeroAmountTransaction, emptyAmountTransaction)
        XCTAssertEqual(WalletCrypto.hexString(oneWeiTransaction), Vectors.signedOneWeiTransaction)
        XCTAssertEqual(leadingZeroOneWeiTransaction, oneWeiTransaction)
    }

    func testRecoverEthereumAddressRejectsMalformedInputs() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)
        var signatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumPersonalMessage, privateKey: privateKey)
        signatureHex.removeFirst(2)
        let signature = try XCTUnwrap(WalletCrypto.hexData(signatureHex))
        let hash = WalletCrypto.keccak256(data: Data("\u{19}Ethereum Signed Message:\n3Foo".utf8))
        let malformedSignature = Vectors.data(hex: "deadbeef")
        var corruptedSignature = signature
        corruptedSignature[0] ^= 0xff
        var invalidRecoveryIDSignature = signature
        invalidRecoveryIDSignature[64] = 4
        let zeroScalarSignature = Data(repeating: 0, count: signature.count)

        XCTAssertEqual(WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: hash), Vectors.ethereumSignerAddress)
        if let corruptedAddress = WalletCrypto.recoverEthereumAddress(signature: corruptedSignature, messageHash: hash) {
            XCTAssertNotEqual(corruptedAddress, Vectors.ethereumSignerAddress)
        }
        XCTAssertNil(WalletCrypto.recoverEthereumAddress(signature: invalidRecoveryIDSignature, messageHash: hash))
        XCTAssertNil(WalletCrypto.recoverEthereumAddress(signature: zeroScalarSignature, messageHash: hash))
        XCTAssertNil(WalletCrypto.recoverEthereumAddress(signature: malformedSignature, messageHash: hash))
        XCTAssertNil(WalletCrypto.recoverEthereumAddress(signature: malformedSignature, messageHash: malformedSignature))
        XCTAssertNil(WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: malformedSignature))
    }

}

private func requirePrivateKey(_ data: Data,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> WalletPrivateKey {
    guard let privateKey = WalletPrivateKey(data: data) else {
        XCTFail("Expected valid private key", file: file, line: line)
        throw WalletKeyStoreError.invalidKey
    }

    return privateKey
}

private func requireHDWallet(mnemonic: String,
                             passphrase: String = "",
                             file: StaticString = #filePath,
                             line: UInt = #line) throws -> WalletHDWallet {
    guard let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: passphrase) else {
        XCTFail("Expected valid HD wallet", file: file, line: line)
        throw WalletKeyStoreError.invalidMnemonic
    }

    return wallet
}

private func requireStoredPrivateKey(privateKey: Data,
                                     coin: WalletCoin,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws -> WalletStoredKey {
    guard let key = WalletStoredKey.importPrivateKey(privateKey: privateKey,
                                                     name: "private",
                                                     password: Vectors.password,
                                                     coin: coin) else {
        XCTFail("Expected private key import to succeed", file: file, line: line)
        throw WalletKeyStoreError.invalidKey
    }

    return key
}

private func requireStoredMnemonicKey(coin: WalletCoin,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws -> WalletStoredKey {
    guard let key = WalletStoredKey.importHDWallet(mnemonic: Vectors.multiAccountMnemonic,
                                                   name: "mnemonic",
                                                   password: Vectors.password,
                                                   coin: coin) else {
        XCTFail("Expected mnemonic import to succeed", file: file, line: line)
        throw WalletKeyStoreError.invalidMnemonic
    }

    return key
}

#if DEBUG
private func reimportExportedKey(_ key: WalletStoredKey,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws -> WalletStoredKey {
    let exportedJSON = try XCTUnwrap(key.exportJSON(), file: file, line: line)
    return try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON), file: file, line: line)
}
#endif
