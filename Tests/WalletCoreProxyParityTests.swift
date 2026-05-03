// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletCoreProxyCoinAndCryptoTests: XCTestCase {

    func testCoinConstantsMatchWalletCoreContract() {
        XCTAssertEqual(WalletCoin.ethereum.rawValue, 60)
        XCTAssertEqual(WalletCoin.solana.rawValue, 501)

        XCTAssertEqual(WalletCoin.ethereum.slip44Id, 60)
        XCTAssertEqual(WalletCoin.solana.slip44Id, 501)
    }

    func testMnemonicValidationAliases() {
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.abandonMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(mnemonic: Vectors.abandonMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(mnemonic: "THIS IS AN INVALID MNEMONIC"))
    }

    func testMnemonicValidationPinsLengthsChecksumAndNormalization() {
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.abandonMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.walletCoreHDMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.valid18WordMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.valid21WordMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.zeroEntropy24WordMnemonic))

        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidChecksumMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidWordCountMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidWordMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.uppercaseMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.mixedWhitespaceMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(""))
    }

    func testBIP44DerivationPathAndPreviewIndexContract() {
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0), "m/44'/60'/0'/0/0")
        XCTAssertEqual(WalletCrypto.bip44DerivationPath(coin: .solana, account: 11, change: 0, address: 7), "m/44'/501'/11'/0/7")

        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/60'/0'/0/13", coin: .ethereum), 13)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/501'/11'/0'", coin: .solana), 11)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "44'/60'/0'/0/13", coin: .ethereum), 13)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/501'/11'/0/7", coin: .solana), 11)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "not a derivation path", coin: .ethereum), 0)
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/60''/", coin: .ethereum), 0)
    }

    func testHexParsingMatchesWalletCoreSemantics() {
        XCTAssertEqual(WalletCrypto.hexData(""), Data())
        XCTAssertEqual(WalletCrypto.hexData(string: "0x00aF"), Data([0x00, 0xaf]))
        XCTAssertEqual(WalletCrypto.hexData("ABCDEF"), Data([0xab, 0xcd, 0xef]))
        XCTAssertEqual(WalletCrypto.hexData("000001"), Data([0x00, 0x00, 0x01]))
        XCTAssertEqual(WalletCrypto.hexData("0x0000ff"), Data([0x00, 0x00, 0xff]))
        XCTAssertEqual(WalletCrypto.hexData("abcdefABCDEF"), Data([0xab, 0xcd, 0xef, 0xab, 0xcd, 0xef]))
        XCTAssertEqual(WalletCrypto.hexData("0x"), Data())
        XCTAssertEqual(WalletCrypto.hexString(Data([0x00, 0xaf, 0xff])), "00afff")
        XCTAssertEqual(WalletCrypto.hexString(data: Data()), "")

        XCTAssertNil(WalletCrypto.hexData("0"))
        XCTAssertNil(WalletCrypto.hexData("+1"))
        XCTAssertNil(WalletCrypto.hexData(string: "0xzz"))
        XCTAssertNil(WalletCrypto.hexData("0X00"))
        XCTAssertNil(WalletCrypto.hexData(" 00"))
        XCTAssertNil(WalletCrypto.hexData("00 "))
        XCTAssertNil(WalletCrypto.hexData("\n00"))
        XCTAssertNil(WalletCrypto.hexData("00\n"))
        XCTAssertNil(WalletCrypto.hexData("00\t"))
        XCTAssertNil(WalletCrypto.hexData("0x0"))
    }

    func testBase58RoundTripsAndRejectsInvalidAlphabet() throws {
        let systemProgram = "11111111111111111111111111111111"
        XCTAssertEqual(WalletCrypto.base58Decode(systemProgram), Data(repeating: 0, count: 32))
        XCTAssertEqual(WalletCrypto.base58Encode(data: Data([0, 0, 0, 1])), "1112")
        XCTAssertEqual(WalletCrypto.base58Encode(Data()), "")
        XCTAssertNil(WalletCrypto.base58Decode(""))
        XCTAssertEqual(WalletCrypto.base58Decode("1"), Data([0]))
        XCTAssertEqual(WalletCrypto.base58Decode("111"), Data(repeating: 0, count: 3))
        XCTAssertEqual(WalletCrypto.base58Encode(Data([0xff])), "5Q")
        XCTAssertEqual(WalletCrypto.base58Encode(Data([0, 0, 0, 0xff])), "1115Q")

        for vector in Vectors.base58KnownVectors {
            XCTAssertEqual(WalletCrypto.base58Encode(vector.data), vector.encoded)
            XCTAssertEqual(WalletCrypto.base58Decode(vector.encoded), vector.data)
        }

        let payload = Vectors.data(hex: "00010203040506070809")
        let encoded = WalletCrypto.base58Encode(payload)
        XCTAssertEqual(WalletCrypto.base58Decode(string: encoded), payload)
        for invalidBase58 in ["0", "O", "I", "l", "0OIl", " ", "\n", "abc\n", "abc\t"] {
            XCTAssertNil(WalletCrypto.base58Decode(invalidBase58), invalidBase58)
        }
    }

    func testKeccakKnownVectors() {
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.keccak256(data: Data())),
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: Data("hello".utf8))),
                       "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
        XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: Data("Ethereum".utf8))),
                       "564ccaf7594d66b1eaaea24fe01f0585bf52ee70852af4eac0cc4b04711cd0e2")
        XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: Data("The quick brown fox jumps over the lazy dog".utf8))),
                       "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15")
        for vector in Vectors.keccakBinaryVectors {
            XCTAssertEqual(WalletCrypto.hexString(data: WalletCrypto.keccak256(data: vector.data)),
                           vector.digest,
                           vector.name)
        }
    }

}

final class WalletCoreProxyPrivateKeyTests: XCTestCase {

    func testPrivateKeyValidationAndRawDataAccess() throws {
        XCTAssertNil(WalletPrivateKey(data: Data([0xde, 0xad, 0xbe, 0xef])))
        XCTAssertNil(WalletPrivateKey(data: Data(repeating: 1, count: 31)))
        XCTAssertNil(WalletPrivateKey(data: Data(repeating: 1, count: 33)))
        XCTAssertNil(WalletPrivateKey(data: Vectors.zeroPrivateKey))
        XCTAssertNotNil(WalletPrivateKey(data: Vectors.onePrivateKey))
        XCTAssertNotNil(WalletPrivateKey(data: Vectors.secp256k1PrivateKeyBelowCurveOrder))
        XCTAssertNotNil(WalletPrivateKey(data: Vectors.secp256k1PrivateKeyAtCurveOrder))
        XCTAssertNotNil(WalletPrivateKey(data: Vectors.secp256k1PrivateKeyAboveCurveOrder))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.sequentialPrivateKey, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(data: Vectors.sequentialPrivateKey, coin: .solana))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Data([1, 2, 3]), coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Data(repeating: 1, count: 31), coin: .solana))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Data(repeating: 1, count: 33), coin: .solana))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.zeroPrivateKey, coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.zeroPrivateKey, coin: .solana))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyBelowCurveOrder, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyBelowCurveOrder, coin: .solana))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAtCurveOrder, coin: .ethereum))
        XCTAssertFalse(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAboveCurveOrder, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAtCurveOrder, coin: .solana))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.secp256k1PrivateKeyAboveCurveOrder, coin: .solana))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.onePrivateKey, coin: .ethereum))
        XCTAssertTrue(WalletCrypto.isValidPrivateKeyData(Vectors.onePrivateKey, coin: .solana))

        let privateKey = try requirePrivateKey(Vectors.sequentialPrivateKey)
        privateKey.withData {
            XCTAssertEqual($0, Vectors.sequentialPrivateKey)
        }
    }

    func testSequentialPrivateKeyDerivesPinnedEthereumAndSolanaIdentities() throws {
        let privateKey = try requirePrivateKey(Vectors.sequentialPrivateKey)

        XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum), Vectors.sequentialEthereumPublicKey)
        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .ethereum)), Vectors.sequentialEthereumPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.sequentialEthereumPublicKey, coin: .ethereum),
                       Vectors.sequentialEthereumAddress)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), Vectors.sequentialSolanaPublicKey)
        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .solana)), Vectors.sequentialSolanaPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.sequentialSolanaPublicKey, coin: .solana),
                       Vectors.sequentialSolanaAddress)
    }

    func testOnePrivateKeyDerivesPinnedAddressesForBothCurves() throws {
        let privateKey = try requirePrivateKey(Vectors.onePrivateKey)

        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .ethereum), coin: .ethereum),
                       Vectors.oneEthereumAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .solana), coin: .solana),
                       Vectors.oneSolanaAddress)
    }

    func testPrivateKeyJustBelowSecp256k1OrderDerivesPinnedIdentitiesForBothCurves() throws {
        let privateKey = try requirePrivateKey(Vectors.secp256k1PrivateKeyBelowCurveOrder)

        XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum),
                       Vectors.secp256k1PrivateKeyBelowCurveOrderEthereumPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .ethereum),
                                                                    coin: .ethereum),
                       Vectors.secp256k1PrivateKeyBelowCurveOrderEthereumAddress)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana),
                       Vectors.secp256k1PrivateKeyBelowCurveOrderSolanaPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .solana),
                                                                    coin: .solana),
                       Vectors.secp256k1PrivateKeyBelowCurveOrderSolanaAddress)
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

    func testEthereumRawSigningPinsWalletCoreSecp256k1Vector() throws {
        let privateKey = try requirePrivateKey(Vectors.secpPrivateKey)
        let rawSignature = try XCTUnwrap(privateKey.sign(digest: Vectors.ethereumHelloRawSignDigest, coin: .ethereum))

        XCTAssertEqual(WalletCrypto.hexString(rawSignature), Vectors.ethereumHelloRawWalletCoreSignature)
        XCTAssertEqual(try Ethereum.shared.sign(data: Vectors.ethereumHelloRawSignDigest, privateKey: privateKey),
                       Vectors.ethereumHelloRawSignature)
        XCTAssertNil(privateKey.sign(digest: Data([1, 2, 3]), coin: .ethereum))
    }

    func testEd25519PublicKeysAndAddressesMatchWalletCoreVectors() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaAddressPrivateKey)
        let solanaPublicKey = privateKey.publicKeyData(coin: .solana)

        XCTAssertEqual(WalletCrypto.hexString(solanaPublicKey), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), Vectors.solanaAddressPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(solanaPublicKey, coin: .solana), Vectors.solanaAddressFromPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.solanaAddressPublicKey, coin: .solana),
                       Vectors.solanaAddressFromPublicKey)
    }

    func testSolanaSigningMatchesWalletCoreMessageSignerVector() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let signature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaMessage, coin: .solana))
        let emptySignature = try XCTUnwrap(privateKey.sign(digest: Data(), coin: .solana))
        let zeroMessageSignature = try XCTUnwrap(privateKey.sign(digest: Data(repeating: 0, count: 32), coin: .solana))
        let binarySignature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaBinaryMessage, coin: .solana))
        let longSignature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaLongMessage, coin: .solana))

        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .solana)), Vectors.solanaSigningPublicKey)
        XCTAssertEqual(WalletCrypto.base58Encode(signature), Vectors.solanaMessageSignature)
        XCTAssertEqual(WalletCrypto.base58Encode(emptySignature), Vectors.solanaEmptyMessageSignature)
        XCTAssertEqual(WalletCrypto.base58Encode(zeroMessageSignature), Vectors.solanaZeroMessageSignature)
        XCTAssertEqual(WalletCrypto.base58Encode(binarySignature), Vectors.solanaBinaryMessageSignature)
        XCTAssertEqual(WalletCrypto.base58Encode(longSignature), Vectors.solanaLongMessageSignature)
        XCTAssertNil(privateKey.sign(digest: Data([1, 2, 3]), coin: .ethereum))
    }

    func testEthereumPersonalSigningAndRecoveryMatchWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)
        let signatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumPersonalMessage, privateKey: privateKey)
        let emptySignatureHex = try Ethereum.shared.signPersonalMessage(data: Data(), privateKey: privateKey)
        let binarySignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumBinaryPersonalMessage, privateKey: privateKey)
        let newlineSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumNewlinePersonalMessage, privateKey: privateKey)
        let longSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumLongPersonalMessage, privateKey: privateKey)
        let signature = try XCTUnwrap(WalletCrypto.hexData(String(signatureHex.dropFirst(2))))
        let emptySignature = try XCTUnwrap(WalletCrypto.hexData(String(emptySignatureHex.dropFirst(2))))
        let binarySignature = try XCTUnwrap(WalletCrypto.hexData(String(binarySignatureHex.dropFirst(2))))
        let newlineSignature = try XCTUnwrap(WalletCrypto.hexData(String(newlineSignatureHex.dropFirst(2))))
        let longSignature = try XCTUnwrap(WalletCrypto.hexData(String(longSignatureHex.dropFirst(2))))

        XCTAssertEqual(signatureHex, Vectors.ethereumPersonalMessageSignature)
        XCTAssertEqual(emptySignatureHex, Vectors.ethereumEmptyPersonalMessageSignature)
        XCTAssertEqual(binarySignatureHex, Vectors.ethereumBinaryPersonalMessageSignature)
        XCTAssertEqual(newlineSignatureHex, Vectors.ethereumNewlinePersonalMessageSignature)
        XCTAssertEqual(longSignatureHex, Vectors.ethereumLongPersonalMessageSignature)
        XCTAssertEqual(Ethereum.shared.recover(signature: signature, message: Vectors.ethereumPersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: emptySignature, message: Data()),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: binarySignature, message: Vectors.ethereumBinaryPersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: newlineSignature, message: Vectors.ethereumNewlinePersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: longSignature, message: Vectors.ethereumLongPersonalMessage),
                       Vectors.ethereumSignerAddress)
    }

    func testEthereumRawAndTypedSigningMatchMigrationVectors() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)

        XCTAssertEqual(try Ethereum.shared.sign(data: Vectors.ethereumRawSignDigest, privateKey: privateKey),
                       Vectors.ethereumRawSignature)
        XCTAssertEqual(try Ethereum.shared.sign(data: Vectors.ethereumMaxRawSignDigest, privateKey: privateKey),
                       Vectors.ethereumMaxRawSignature)
        XCTAssertNil(privateKey.sign(digest: Vectors.ethereumZeroRawSignDigest, coin: .ethereum))
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.typedDataJSON, privateKey: privateKey),
                       Vectors.ethereumTypedDataSignature)
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.permitTypedDataJSON, privateKey: privateKey),
                       Vectors.permitTypedDataSignature)
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.complexTypedDataJSON, privateKey: privateKey),
                       Vectors.complexTypedDataSignature)
        XCTAssertThrowsError(try Ethereum.shared.sign(data: Data([1, 2, 3]), privateKey: privateKey)) {
            guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                XCTFail("Expected failedToSign for short raw signing input, got \($0)")
                return
            }
        }
        XCTAssertThrowsError(try Ethereum.shared.sign(data: Vectors.ethereumZeroRawSignDigest, privateKey: privateKey)) {
            guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                XCTFail("Expected failedToSign for zero raw signing input, got \($0)")
                return
            }
        }
        XCTAssertThrowsError(try Ethereum.shared.sign(data: Vectors.ethereumOverlongRawSignDigest, privateKey: privateKey)) {
            guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                XCTFail("Expected failedToSign for overlong raw signing input, got \($0)")
                return
            }
        }
        XCTAssertThrowsError(try Ethereum.shared.sign(typedData: Vectors.malformedTypedDataJSON, privateKey: privateKey)) {
            guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                XCTFail("Expected failedToSign for malformed typed data, got \($0)")
                return
            }
        }
    }

    func testInvalidPublicKeyInputsReturnEmptyAddresses() {
        let prefixedPublicKeyAddress = WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.secpPublicKey, coin: .ethereum)
        let solanaPrefixedPublicKey = Data([1]) + Data(repeating: 1, count: 32)
        let invalidSolanaPrefixedPublicKey = Data([2]) + Data(repeating: 1, count: 32)

        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("not hex", coin: .ethereum), "")
        XCTAssertFalse(prefixedPublicKeyAddress.isEmpty)
        XCTAssertEqual(prefixedPublicKeyAddress,
                       WalletCrypto.addressFromPublicKeyDescription(Vectors.secpPublicKey, coin: .ethereum))
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.solanaAddressPublicKey, coin: .solana),
                       Vectors.solanaAddressFromPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.secpCompressedPublicKey, coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.secpCompressedPublicKey, coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(String(Vectors.secpPublicKey.dropLast(2)), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(Data(repeating: 1, count: 31)), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(solanaPrefixedPublicKey),
                                                                    coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(invalidSolanaPrefixedPublicKey),
                                                                    coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data([1, 2, 3]), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(repeating: 1, count: 31), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(solanaPrefixedPublicKey, coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(invalidSolanaPrefixedPublicKey, coin: .solana), "")
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
    }

    func testHDWalletDerivesPinnedEthereumAndSolanaKeysAcrossPreviewIndexes() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)

        XCTAssertEqual(Vectors.abandonEthereumHDVectors.map { $0.index }, Array(0...21))
        XCTAssertEqual(Vectors.abandonSolanaHDVectors.map { $0.index }, Array(0...21))

        for vector in Vectors.abandonEthereumHDVectors {
            let privateKey = wallet.getKey(coin: .ethereum, derivationPath: vector.path)
            privateKey.withData {
                XCTAssertEqual($0, vector.privateKey, "Ethereum private key mismatch at index \(vector.index)")
            }
            XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum), vector.publicKey)
            XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(vector.publicKey, coin: .ethereum), vector.address)
        }

        for vector in Vectors.abandonSolanaHDVectors {
            let privateKey = wallet.getKey(coin: .solana, derivationPath: vector.path)
            privateKey.withData {
                XCTAssertEqual($0, vector.privateKey, "Solana private key mismatch at index \(vector.index)")
            }
            XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), vector.publicKey)
            XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(vector.publicKey, coin: .solana), vector.address)
        }
    }

    func testPassphraseAffectsHDWalletDerivation() throws {
        let trezorWallet = try requireHDWallet(mnemonic: Vectors.walletCoreHDMnemonic, passphrase: "TREZOR")
        let noPassphraseWallet = try requireHDWallet(mnemonic: Vectors.walletCoreHDMnemonic)
        let trezorKey = trezorWallet.getKey(coin: .ethereum, derivationPath: "m/44'/60'/0'/0/0")
        let noPassphraseKey = noPassphraseWallet.getKey(coin: .ethereum, derivationPath: "m/44'/60'/0'/0/0")

        XCTAssertEqual(derivedAddress(wallet: trezorWallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"),
                       Vectors.walletCoreHDEthereumAddress)
        XCTAssertEqual(derivedAddress(wallet: noPassphraseWallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"),
                       Vectors.walletCoreHDNoPassphraseEthereumAddress)
        XCTAssertNotEqual(derivedAddress(wallet: noPassphraseWallet, coin: .ethereum, path: "m/44'/60'/0'/0/0"),
                          Vectors.walletCoreHDEthereumAddress)
        trezorKey.withData {
            XCTAssertEqual($0, Vectors.walletCoreHDEthereumPrivateKey)
        }
        noPassphraseKey.withData {
            XCTAssertEqual($0, Vectors.walletCoreHDNoPassphraseEthereumPrivateKey)
        }
    }

    func testLeadingZeroEthereumDerivationMatchesWalletCoreVector() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.leadingZeroEthereumMnemonic)
        let firstKey = wallet.getKey(coin: .ethereum, derivationPath: Vectors.leadingZeroEthereumDerivationPath)
        let secondKey = wallet.getKey(coin: .ethereum, derivationPath: Vectors.leadingZeroEthereumDerivationPath)
        let firstAddress = WalletCrypto.addressFromPublicKeyDescription(firstKey.publicKeyDescription(coin: .ethereum),
                                                                        coin: .ethereum)
        let secondAddress = WalletCrypto.addressFromPublicKeyDescription(secondKey.publicKeyDescription(coin: .ethereum),
                                                                         coin: .ethereum)

        XCTAssertEqual(firstAddress, Vectors.leadingZeroEthereumAddress)
        XCTAssertEqual(secondAddress, Vectors.leadingZeroEthereumAddress)
        XCTAssertEqual(firstKey.publicKeyDescription(coin: .ethereum), secondKey.publicKeyDescription(coin: .ethereum))
        firstKey.withData { firstData in
            secondKey.withData { secondData in
                XCTAssertEqual(firstData, secondData)
            }
        }
    }

    func testExtendedPublicKeyDerivesEthereumAccounts() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let defaultDerivationXpub = wallet.extendedPublicKeyDerivation(coin: .ethereum, derivation: .default)
        let accountOneXpub = wallet.extendedPublicKeyAccount(coin: .ethereum, derivation: .default, account: 1)
        let firstPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)
        let secondPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 1)
        let changeZeroPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 1, address: 0)
        let changeOnePath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 1, address: 1)
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
        let changeZeroAccount = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                                        coin: .ethereum,
                                                                                        derivation: .custom,
                                                                                        derivationPath: changeZeroPath))
        let changeOneAccount = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                                       coin: .ethereum,
                                                                                       derivation: .custom,
                                                                                       derivationPath: changeOnePath))
        let accountOne = try XCTUnwrap(WalletCrypto.accountFromExtendedPublicKey(extended: accountOneXpub,
                                                                                 coin: .ethereum,
                                                                                 derivation: .custom,
                                                                                 derivationPath: accountOnePath))

        XCTAssertEqual(xpub, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(defaultDerivationXpub, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(accountOneXpub, Vectors.abandonEthereumAccountOneExtendedPublicKey)
        XCTAssertEqual(wallet.extendedPublicKeyAccount(coin: .ethereum, derivation: .default, account: 2),
                       Vectors.abandonEthereumAccountTwoExtendedPublicKey)
        XCTAssertEqual(firstPublicKey, firstAccount.publicKey)
        XCTAssertEqual(firstAccount.address, Vectors.abandonEthereumAddress)
        XCTAssertEqual(firstAccount.coin, .ethereum)
        XCTAssertEqual(firstAccount.derivation, .custom)
        XCTAssertEqual(firstAccount.derivationPath, firstPath)
        XCTAssertEqual(firstAccount.extendedPublicKey, Vectors.abandonEthereumExtendedPublicKey)
        XCTAssertEqual(secondAccount.address, Vectors.abandonEthereumSecondAddress)
        XCTAssertEqual(secondAccount.publicKey, Vectors.abandonEthereumSecondPublicKey)
        XCTAssertEqual(changeZeroAccount.address, Vectors.abandonEthereumChangeZeroAddress)
        XCTAssertEqual(changeZeroAccount.publicKey, Vectors.abandonEthereumChangeZeroPublicKey)
        XCTAssertEqual(changeOneAccount.address, Vectors.abandonEthereumChangeOneAddress)
        XCTAssertEqual(changeOneAccount.publicKey, Vectors.abandonEthereumChangeOnePublicKey)
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

    func testExtendedPublicKeyRejectsMalformedDerivationPathsBeforeWalletCore() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let invalidPaths = [
            "not a derivation path",
            "m/44'/60'/0'/0/not-number",
            "m/44'//0",
            "m/44'/60'/0'/0/-1",
        ]

        for path in invalidPaths {
            XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                       coin: .ethereum,
                                                                       derivationPath: path),
                         path)
            XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                   coin: .ethereum,
                                                                   derivation: .custom,
                                                                   derivationPath: path),
                         path)
        }
    }

    func testEthereumExtendedPublicKeyPinsWalletCorePathMismatchQuirks() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let firstPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)
        let mismatchedAccountPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 1, change: 0, address: 0)
        let mismatchedCoinPath = "m/44'/501'/0'/0'"
        let firstPublicKey = try XCTUnwrap(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                                         coin: .ethereum,
                                                                                         derivationPath: firstPath))

        XCTAssertEqual(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                     coin: .ethereum,
                                                                     derivationPath: mismatchedAccountPath),
                       firstPublicKey)
        XCTAssertEqual(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                 coin: .ethereum,
                                                                 derivation: .custom,
                                                                 derivationPath: mismatchedAccountPath)?.address,
                       Vectors.abandonEthereumAddress)
        XCTAssertEqual(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                     coin: .ethereum,
                                                                     derivationPath: mismatchedCoinPath),
                       firstPublicKey)
        XCTAssertEqual(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                 coin: .ethereum,
                                                                 derivation: .custom,
                                                                 derivationPath: mismatchedCoinPath)?.address,
                       Vectors.abandonEthereumAddress)
    }

    func testEd25519ExtendedPublicKeyVariantsPinWalletCoreQuirks() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let solanaDefaultExtended = wallet.extendedPublicKey(coin: .solana)
        let solanaDerivationExtended = wallet.extendedPublicKeyDerivation(coin: .solana, derivation: .solanaSolana)
        let solanaAccountExtended = wallet.extendedPublicKeyAccount(coin: .solana, derivation: .solanaSolana, account: 1)
        let solanaDefaultPath = "m/44'/501'/0'"
        let solanaSolanaPath = "m/44'/501'/0'/0'"

        XCTAssertEqual(solanaDefaultExtended, Vectors.abandonSolanaDefaultExtendedPublicKey)
        XCTAssertEqual(solanaDerivationExtended, "")
        XCTAssertEqual(solanaAccountExtended, "")

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

    func testImportsWalletCorePrivateKeyJSONVariantFixtures() throws {
        let expectedAccount = WalletAccount(address: Vectors.secpEthereumAddress,
                                            coin: .ethereum,
                                            derivation: .default,
                                            derivationPath: "m/44'/60'/0'/0/0",
                                            publicKey: "",
                                            extendedPublicKey: "")

        for fixture in Vectors.walletCoreJSONVariantPrivateKeyFixtures {
            let key = try XCTUnwrap(WalletStoredKey.importJSON(json: fixture.json), fixture.name)
            let account = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: nil), fixture.name)
            let privateKey = try XCTUnwrap(key.privateKey(coin: .ethereum,
                                                          password: Vectors.walletCoreJSONPBKDF2PrivateKeyPassword),
                                           fixture.name)

            XCTAssertFalse(key.isMnemonic, fixture.name)
            XCTAssertEqual(key.accountCount, 1, fixture.name)
            XCTAssertEqual(key.account(index: 0), expectedAccount, fixture.name)
            XCTAssertEqual(account, expectedAccount, fixture.name)
            XCTAssertEqual(key.decryptPrivateKey(password: Vectors.walletCoreJSONPBKDF2PrivateKeyPassword),
                           Vectors.secpPrivateKey,
                           fixture.name)
            XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword), fixture.name)
            XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword), fixture.name)
            XCTAssertNil(key.wallet(password: Vectors.walletCoreJSONPBKDF2PrivateKeyPassword), fixture.name)
            XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(privateKey.publicKeyDescription(coin: .ethereum),
                                                                        coin: .ethereum),
                           Vectors.secpEthereumAddress,
                           fixture.name)
        }
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
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))

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

        XCTAssertEqual(reimported.name, key.name)
        XCTAssertTrue(reimported.isMnemonic)
        XCTAssertEqual(reimported.accountCount, 0)
        XCTAssertEqual(reimported.decryptMnemonic(password: Vectors.password), mnemonic)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), decryptedPayload)
        XCTAssertNotNil(reimported.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertNil(reimported.decryptMnemonic(password: Vectors.wrongPassword))
    }

    func testStoredKeysRoundTripEmptyPasswords() throws {
        let privateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: Vectors.secpPrivateKey,
                                                                        name: "empty-private-password",
                                                                        password: Data(),
                                                                        coin: .ethereum))
        let privateKeyJSON = try XCTUnwrap(privateKey.exportJSON())
        let reimportedPrivateKey = try XCTUnwrap(WalletStoredKey.importJSON(json: privateKeyJSON))

        XCTAssertEqual(privateKey.decryptPrivateKey(password: Data()), Vectors.secpPrivateKey)
        XCTAssertNil(privateKey.decryptPrivateKey(password: Vectors.password))
        XCTAssertEqual(reimportedPrivateKey.decryptPrivateKey(password: Data()), Vectors.secpPrivateKey)
        XCTAssertNotNil(reimportedPrivateKey.privateKey(coin: .ethereum, password: Data()))
        XCTAssertNil(reimportedPrivateKey.privateKey(coin: .ethereum, password: Vectors.password))

        let mnemonicKey = try XCTUnwrap(WalletStoredKey.importHDWallet(mnemonic: Vectors.multiAccountMnemonic,
                                                                       name: "empty-mnemonic-password",
                                                                       password: Data(),
                                                                       coin: .solana))
        let mnemonicJSON = try XCTUnwrap(mnemonicKey.exportJSON())
        let reimportedMnemonicKey = try XCTUnwrap(WalletStoredKey.importJSON(json: mnemonicJSON))
        let wallet = try XCTUnwrap(reimportedMnemonicKey.wallet(password: Data()))
        let solanaAccount = try XCTUnwrap(reimportedMnemonicKey.accountForCoin(coin: .solana, wallet: wallet))

        XCTAssertEqual(mnemonicKey.decryptMnemonic(password: Data()), Vectors.multiAccountMnemonic)
        XCTAssertNil(mnemonicKey.decryptMnemonic(password: Vectors.password))
        XCTAssertEqual(reimportedMnemonicKey.decryptMnemonic(password: Data()), Vectors.multiAccountMnemonic)
        XCTAssertNil(reimportedMnemonicKey.wallet(password: Vectors.password))
        XCTAssertEqual(solanaAccount.derivationPath, "m/44'/501'/0'")
        XCTAssertEqual(reimportedMnemonicKey.accountForCoin(coin: .solana, wallet: wallet), solanaAccount)
        XCTAssertEqual(reimportedMnemonicKey.accountCount, 1)
    }

    func testGeneratedStoredKeysUseFreshMnemonicEntropy() throws {
        let firstKey = WalletStoredKey(name: "generated", password: Vectors.password)
        let secondKey = WalletStoredKey(name: "generated", password: Vectors.password)
        let firstMnemonic = try XCTUnwrap(firstKey.decryptMnemonic(password: Vectors.password))
        let secondMnemonic = try XCTUnwrap(secondKey.decryptMnemonic(password: Vectors.password))
        let firstPayload = try XCTUnwrap(firstKey.decryptPrivateKey(password: Vectors.password))
        let secondPayload = try XCTUnwrap(secondKey.decryptPrivateKey(password: Vectors.password))
        let firstJSON = try XCTUnwrap(firstKey.exportJSON())
        let secondJSON = try XCTUnwrap(secondKey.exportJSON())
        let firstReimported = try XCTUnwrap(WalletStoredKey.importJSON(json: firstJSON))
        let secondReimported = try XCTUnwrap(WalletStoredKey.importJSON(json: secondJSON))

        XCTAssertTrue(firstKey.isMnemonic)
        XCTAssertTrue(secondKey.isMnemonic)
        XCTAssertTrue(WalletCrypto.isValidMnemonic(firstMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(secondMnemonic))
        XCTAssertEqual(firstPayload, Data(firstMnemonic.utf8))
        XCTAssertEqual(secondPayload, Data(secondMnemonic.utf8))
        XCTAssertNotEqual(firstMnemonic, secondMnemonic)
        XCTAssertNotEqual(firstPayload, secondPayload)
        XCTAssertEqual(firstReimported.decryptMnemonic(password: Vectors.password), firstMnemonic)
        XCTAssertEqual(secondReimported.decryptMnemonic(password: Vectors.password), secondMnemonic)
        XCTAssertNotNil(firstReimported.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertNotNil(secondReimported.privateKey(coin: .ethereum, password: Vectors.password))
    }

    func testGeneratedStoredKeyDerivesAndPersistsDefaultMnemonicAccounts() throws {
        let key = WalletStoredKey(name: "generated", password: Vectors.password)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))

        XCTAssertNil(key.accountForCoinDerivation(coin: .ethereum, derivation: .default, wallet: nil))
        XCTAssertNil(key.accountForCoinDerivation(coin: .solana, derivation: .solanaSolana, wallet: nil))

        let ethereumAccount = try XCTUnwrap(key.accountForCoinDerivation(coin: .ethereum,
                                                                         derivation: .default,
                                                                         wallet: wallet))
        let solanaAccount = try XCTUnwrap(key.accountForCoinDerivation(coin: .solana,
                                                                       derivation: .solanaSolana,
                                                                       wallet: wallet))

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 0), ethereumAccount)
        XCTAssertEqual(key.account(index: 1), solanaAccount)
        assertGeneratedMnemonicAccount(ethereumAccount,
                                       coin: .ethereum,
                                       derivation: .default,
                                       derivationPath: "m/44'/60'/0'/0/0",
                                       wallet: wallet)
        assertGeneratedMnemonicAccount(solanaAccount,
                                       coin: .solana,
                                       derivation: .solanaSolana,
                                       derivationPath: "m/44'/501'/0'/0'",
                                       wallet: wallet)

        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))
        XCTAssertEqual(reimported.accountCount, 2)
        XCTAssertEqual(reimported.account(index: 0), ethereumAccount)
        XCTAssertEqual(reimported.account(index: 1), solanaAccount)
    }

    func testStoredKeyImportsRejectInvalidInputs() {
        let shortPrivateKey = Data(repeating: 1, count: 31)
        let longPrivateKey = Data(repeating: 1, count: 33)

        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: Vectors.zeroPrivateKey,
                                                      name: "zero",
                                                      password: Vectors.password,
                                                      coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: Vectors.zeroPrivateKey,
                                                      name: "zero",
                                                      password: Vectors.password,
                                                      coin: .solana))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: shortPrivateKey,
                                                      name: "short",
                                                      password: Vectors.password,
                                                      coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: shortPrivateKey,
                                                      name: "short",
                                                      password: Vectors.password,
                                                      coin: .solana))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: longPrivateKey,
                                                      name: "long",
                                                      password: Vectors.password,
                                                      coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: longPrivateKey,
                                                      name: "long",
                                                      password: Vectors.password,
                                                      coin: .solana))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: Vectors.secp256k1PrivateKeyAtCurveOrder,
                                                      name: "curve-order",
                                                      password: Vectors.password,
                                                      coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importPrivateKey(privateKey: Vectors.secp256k1PrivateKeyAboveCurveOrder,
                                                      name: "above-curve-order",
                                                      password: Vectors.password,
                                                      coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importHDWallet(mnemonic: Vectors.invalidMnemonic,
                                                    name: "invalid",
                                                    password: Vectors.password,
                                                    coin: .ethereum))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data()))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("[]".utf8)))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("{}".utf8)))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("not json".utf8)))
    }

    func testStoredKeyImportRejectsMalformedAndCannotDecryptCorruptedJSON() throws {
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("{".utf8)))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data("{\"crypto\":true}".utf8)))
        XCTAssertNil(WalletStoredKey.importJSON(json: Data(Vectors.walletCoreJSONPrivateKeyFixture.prefix(32))))

        try assertCorruptedPrivateKeyJSONIsNotUsable(replacing: "\"cipher\": \"aes-128-ctr\"",
                                                     with: "\"cipher\": \"aes-192-ctr\"")
        try assertCorruptedPrivateKeyJSONIsNotUsable(replacing: "d172bf743a674da9cdad04534d56926ef8358534d458fffccd4e6ad2fbde479c",
                                                     with: "0000000000000000000000000000000000000000000000000000000000000000")
        try assertCorruptedPrivateKeyJSONIsNotUsable(replacing: "2103ac29920d71da29f15d75b4a16dbe95cfd7ff8faea1056c33131d846e3097",
                                                     with: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
        try assertCorruptedPrivateKeyJSONIsNotUsable(replacing: "ab0c7876052600dd703518d6fc3fe8984592145b591fc8fb5c6d43190334ba19",
                                                     with: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    }

    func testStoredKeyImportsSolanaSeedsAtSecp256k1CurveOrderBoundary() throws {
        try assertStoredSolanaPrivateKeyImport(privateKeyData: Vectors.secp256k1PrivateKeyBelowCurveOrder,
                                               expectedPublicKey: Vectors.secp256k1PrivateKeyBelowCurveOrderSolanaPublicKey,
                                               expectedAddress: Vectors.secp256k1PrivateKeyBelowCurveOrderSolanaAddress)
        try assertStoredSolanaPrivateKeyImport(privateKeyData: Vectors.secp256k1PrivateKeyAtCurveOrder,
                                               expectedPublicKey: Vectors.secp256k1PrivateKeyAtCurveOrderSolanaPublicKey,
                                               expectedAddress: Vectors.secp256k1PrivateKeyAtCurveOrderSolanaAddress)
        try assertStoredSolanaPrivateKeyImport(privateKeyData: Vectors.secp256k1PrivateKeyAboveCurveOrder,
                                               expectedPublicKey: Vectors.secp256k1PrivateKeyAboveCurveOrderSolanaPublicKey,
                                               expectedAddress: Vectors.secp256k1PrivateKeyAboveCurveOrderSolanaAddress)
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

    func testImportSolanaPrivateKeyPinsAccountAndJSONRoundTrip() throws {
        let expectedAccount = WalletAccount(address: Vectors.solanaAddressFromPublicKey,
                                            coin: .solana,
                                            derivation: .default,
                                            derivationPath: "m/44'/501'/0'",
                                            publicKey: Vectors.solanaAddressPublicKey,
                                            extendedPublicKey: "")
        let key = try requireStoredPrivateKey(privateKey: Vectors.solanaAddressPrivateKey,
                                              coin: .solana)
        let privateKey = try XCTUnwrap(key.privateKey(coin: .solana, password: Vectors.password))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))

        XCTAssertEqual(key.name, "private")
        XCTAssertFalse(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), expectedAccount)
        XCTAssertEqual(key.accountForCoin(coin: .solana, wallet: nil), expectedAccount)
        XCTAssertEqual(key.decryptPrivateKey(password: Vectors.password), Vectors.solanaAddressPrivateKey)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), Vectors.solanaAddressPublicKey)
        XCTAssertNil(key.privateKey(coin: .solana, password: Vectors.wrongPassword))

        XCTAssertEqual(reimported.accountCount, key.accountCount)
        XCTAssertEqual(reimported.account(index: 0), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .solana, wallet: nil), expectedAccount)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), Vectors.solanaAddressPrivateKey)
    }

    func testStoredKeyRoundTripsLongPasswordsForPrivateKeyAndMnemonicImports() throws {
        let privateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: Vectors.secpPrivateKey,
                                                                        name: "long-private",
                                                                        password: Vectors.longPassword,
                                                                        coin: .ethereum))
        let privateKeyJSON = try XCTUnwrap(privateKey.exportJSON())
        let reimportedPrivateKey = try XCTUnwrap(WalletStoredKey.importJSON(json: privateKeyJSON))

        XCTAssertEqual(privateKey.decryptPrivateKey(password: Vectors.longPassword), Vectors.secpPrivateKey)
        XCTAssertNil(privateKey.decryptPrivateKey(password: Vectors.password))
        XCTAssertEqual(reimportedPrivateKey.decryptPrivateKey(password: Vectors.longPassword), Vectors.secpPrivateKey)
        XCTAssertNil(reimportedPrivateKey.privateKey(coin: .ethereum, password: Vectors.password))

        let mnemonicKey = try XCTUnwrap(WalletStoredKey.importHDWallet(mnemonic: Vectors.multiAccountMnemonic,
                                                                       name: "long-mnemonic",
                                                                       password: Vectors.longPassword,
                                                                       coin: .ethereum))
        let mnemonicJSON = try XCTUnwrap(mnemonicKey.exportJSON())
        let reimportedMnemonicKey = try XCTUnwrap(WalletStoredKey.importJSON(json: mnemonicJSON))

        XCTAssertEqual(mnemonicKey.decryptMnemonic(password: Vectors.longPassword), Vectors.multiAccountMnemonic)
        XCTAssertEqual(mnemonicKey.decryptPrivateKey(password: Vectors.longPassword), Data(Vectors.multiAccountMnemonic.utf8))
        XCTAssertNil(mnemonicKey.decryptMnemonic(password: Vectors.password))
        XCTAssertEqual(reimportedMnemonicKey.decryptMnemonic(password: Vectors.longPassword), Vectors.multiAccountMnemonic)
        XCTAssertNil(reimportedMnemonicKey.wallet(password: Vectors.password))
    }

    func testImportEthereumHDWalletPinsInitialAccountAndMnemonicRoundTrip() throws {
        let expectedAccount = WalletAccount(address: Vectors.multiAccountEthereumAddress,
                                            coin: .ethereum,
                                            derivation: .default,
                                            derivationPath: "m/44'/60'/0'/0/0",
                                            publicKey: Vectors.multiAccountEthereumPublicKey,
                                            extendedPublicKey: "")
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let storedAccount = try XCTUnwrap(key.account(index: 0))
        let account = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: nil))
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let privateKey = wallet.getKey(coin: .ethereum, derivationPath: expectedAccount.derivationPath)
        let keyPrivateKey = try XCTUnwrap(key.privateKey(coin: .ethereum, password: Vectors.password))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))

        XCTAssertEqual(key.name, "mnemonic")
        XCTAssertTrue(key.isMnemonic)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(storedAccount, expectedAccount)
        XCTAssertEqual(account, expectedAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), expectedAccount)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.decryptMnemonic(password: Vectors.password), Vectors.multiAccountMnemonic)
        XCTAssertEqual(key.decryptPrivateKey(password: Vectors.password), Data(Vectors.multiAccountMnemonic.utf8))
        XCTAssertNil(key.decryptMnemonic(password: Vectors.wrongPassword))
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.wrongPassword))
        XCTAssertNil(key.wallet(password: Vectors.wrongPassword))
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.wrongPassword))

        privateKey.withData {
            XCTAssertEqual($0, Vectors.multiAccountEthereumPrivateKey)
        }
        keyPrivateKey.withData {
            XCTAssertEqual($0, Vectors.multiAccountEthereumPrivateKey)
        }
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum), Vectors.multiAccountEthereumPublicKey)
        XCTAssertEqual(keyPrivateKey.publicKeyDescription(coin: .ethereum), Vectors.multiAccountEthereumPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.multiAccountEthereumPublicKey, coin: .ethereum),
                       Vectors.multiAccountEthereumAddress)

        let reimportedWallet = try XCTUnwrap(reimported.wallet(password: Vectors.password))
        XCTAssertEqual(reimported.accountCount, 1)
        XCTAssertEqual(reimported.account(index: 0), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .ethereum, wallet: nil), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .ethereum, wallet: reimportedWallet), expectedAccount)
        XCTAssertEqual(reimported.decryptMnemonic(password: Vectors.password), Vectors.multiAccountMnemonic)
        XCTAssertNil(reimported.decryptMnemonic(password: Vectors.wrongPassword))
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

    func testRepeatedAccountLookupsDoNotDuplicateStoredAccounts() throws {
        let key = try requireStoredMnemonicKey(coin: .solana)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let initialAccount = try XCTUnwrap(key.account(index: 0))

        for _ in 0..<5 {
            XCTAssertEqual(key.accountForCoin(coin: .solana, wallet: wallet), initialAccount)
            XCTAssertEqual(key.accountForCoinDerivation(coin: .solana, derivation: .default, wallet: wallet), initialAccount)
            XCTAssertEqual(key.accountCount, 1)
        }

        let ethereumAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))
        for _ in 0..<5 {
            XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), ethereumAccount)
            XCTAssertEqual(key.accountForCoinDerivation(coin: .ethereum, derivation: .default, wallet: wallet), ethereumAccount)
            XCTAssertEqual(key.accountCount, 2)
        }
    }

    func testAddAndRemoveAccountsByCoinAndDerivationPath() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let firstAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))
        let solanaAccount = WalletAccount(address: Vectors.solanaAddressFromPublicKey,
                                          coin: .solana,
                                          derivation: .custom,
                                          derivationPath: "m/44'/501'/0'",
                                          publicKey: Vectors.solanaAddressPublicKey,
                                          extendedPublicKey: "")

        key.addAccountDerivation(address: solanaAccount.address,
                                 coin: solanaAccount.coin,
                                 derivation: solanaAccount.derivation,
                                 derivationPath: solanaAccount.derivationPath,
                                 publicKey: solanaAccount.publicKey,
                                 extendedPublicKey: solanaAccount.extendedPublicKey)

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 1), solanaAccount)
        XCTAssertEqual(key.accountForCoin(coin: .solana, wallet: nil), solanaAccount)

        key.removeAccountForCoinDerivationPath(coin: .solana, derivationPath: "m/44'/501'/9'")
        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.accountForCoin(coin: .solana, wallet: nil), solanaAccount)

        key.removeAccountForCoinDerivationPath(coin: .solana, derivationPath: "m/44'/501'/0'")
        XCTAssertNil(key.accountForCoin(coin: .solana, wallet: nil))
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil)?.address, firstAccount.address)

        key.removeAccountForCoinDerivationPath(coin: .solana, derivationPath: "m/44'/501'/0'")
        XCTAssertEqual(key.accountCount, 1)
        key.removeAccountForCoin(coin: .solana)
        XCTAssertEqual(key.accountCount, 1)

        key.removeAccountForCoin(coin: .ethereum)
        XCTAssertNil(key.accountForCoin(coin: .ethereum, wallet: nil))
        XCTAssertEqual(key.accountCount, 0)
    }

    func testAccountOrderAfterRemoveAddAndReimport() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let ethereumAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))
        let solanaAccount = try XCTUnwrap(key.accountForCoin(coin: .solana, wallet: wallet))

        XCTAssertEqual(key.account(index: 0), ethereumAccount)
        XCTAssertEqual(key.account(index: 1), solanaAccount)

        key.removeAccountForCoin(coin: .ethereum)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), solanaAccount)

        let readdedEthereumAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: wallet))
        XCTAssertEqual(readdedEthereumAccount, ethereumAccount)
        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 0), solanaAccount)
        XCTAssertEqual(key.account(index: 1), readdedEthereumAccount)

        let exportedJSON = try XCTUnwrap(key.exportJSON())
        let reimported = try XCTUnwrap(WalletStoredKey.importJSON(json: exportedJSON))
        XCTAssertEqual(reimported.accountCount, 2)
        XCTAssertEqual(reimported.account(index: 0), solanaAccount)
        XCTAssertEqual(reimported.account(index: 1), readdedEthereumAccount)
    }

    #if DEBUG
    func testWalletCoreJSONFixtureUnsupportedAccountsStayHiddenButAreCopied() throws {
        let expectedEthereumAccount = WalletAccount(address: Vectors.walletCoreJSONMixedAccountEthereumAddress,
                                                    coin: .ethereum,
                                                    derivation: .default,
                                                    derivationPath: "m/44'/60'/0'/0/0",
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

        XCTAssertEqual(source.accountCount, 3)
        XCTAssertEqual(source.decryptMnemonic(password: Vectors.walletCoreJSONMixedAccountPassword),
                       Vectors.walletCoreJSONMixedAccountMnemonic)
        XCTAssertNil(source.account(index: 0))
        XCTAssertEqual(source.account(index: 1), expectedEthereumAccount)
        XCTAssertNil(source.account(index: 2))
        XCTAssertEqual(source.rawAccountForTesting(index: 0), expectedBitcoinAccount)
        XCTAssertEqual(source.rawAccountForTesting(index: 2), expectedBinanceAccount)
        XCTAssertEqual(WalletContainer(id: "source", key: source).accounts, [expectedEthereumAccount])

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

    private func assertCorruptedPrivateKeyJSONIsNotUsable(replacing target: String,
                                                          with replacement: String,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) throws {
        let fixture = try XCTUnwrap(String(data: Vectors.walletCoreJSONPrivateKeyFixture, encoding: .utf8),
                                    file: file,
                                    line: line)
        let json = Data(fixture.replacingOccurrences(of: target, with: replacement).utf8)
        guard let key = WalletStoredKey.importJSON(json: json) else { return }

        XCTAssertNil(key.decryptPrivateKey(password: Vectors.walletCoreJSONPrivateKeyPassword), file: file, line: line)
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.walletCoreJSONPrivateKeyPassword), file: file, line: line)
    }

}

private func assertStoredSolanaPrivateKeyImport(privateKeyData: Data,
                                                expectedPublicKey: String,
                                                expectedAddress: String,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) throws {
    let key = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: privateKeyData,
                                                            name: "solana",
                                                            password: Vectors.password,
                                                            coin: .solana),
                            file: file,
                            line: line)
    let account = try XCTUnwrap(key.accountForCoin(coin: .solana, wallet: nil), file: file, line: line)
    let privateKey = try XCTUnwrap(key.privateKey(coin: .solana, password: Vectors.password), file: file, line: line)

    XCTAssertEqual(key.accountCount, 1, file: file, line: line)
    XCTAssertEqual(account.coin, .solana, file: file, line: line)
    XCTAssertEqual(account.derivation, .default, file: file, line: line)
    XCTAssertEqual(account.derivationPath, "m/44'/501'/0'", file: file, line: line)
    XCTAssertEqual(account.publicKey, expectedPublicKey, file: file, line: line)
    XCTAssertEqual(account.address, expectedAddress, file: file, line: line)
    XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), expectedPublicKey, file: file, line: line)
    XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(expectedPublicKey, coin: .solana), expectedAddress, file: file, line: line)
    XCTAssertEqual(key.decryptPrivateKey(password: Vectors.password), privateKeyData, file: file, line: line)
    privateKey.withData {
        XCTAssertEqual($0, privateKeyData, file: file, line: line)
    }
}

private func assertGeneratedMnemonicAccount(_ account: WalletAccount,
                                            coin: WalletCoin,
                                            derivation: WalletDerivation,
                                            derivationPath: String,
                                            wallet: WalletHDWallet,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
    let privateKey = wallet.getKey(coin: coin, derivationPath: derivationPath)
    let publicKey = privateKey.publicKeyDescription(coin: coin)

    XCTAssertEqual(account.coin, coin, file: file, line: line)
    XCTAssertEqual(account.derivation, derivation, file: file, line: line)
    XCTAssertEqual(account.derivationPath, derivationPath, file: file, line: line)
    XCTAssertEqual(account.publicKey, publicKey, file: file, line: line)
    XCTAssertEqual(account.address,
                   WalletCrypto.addressFromPublicKeyDescription(publicKey, coin: coin),
                   file: file,
                   line: line)
    XCTAssertEqual(account.extendedPublicKey, "", file: file, line: line)
    XCTAssertFalse(account.address.isEmpty, file: file, line: line)
    XCTAssertFalse(account.publicKey.isEmpty, file: file, line: line)
}

final class WalletCoreProxyEthereumTests: XCTestCase {

    func testTypedDataDigestMatchesWalletCoreVector() {
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.typedDataJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.decimalStringChainIDTypedDataJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.permitTypedDataJSON)),
                       Vectors.permitTypedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.complexTypedDataJSON)),
                       Vectors.complexTypedDataDigest)
        XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.malformedTypedDataJSON),
                       Vectors.malformedTypedDataDigest)
        for fixture in Vectors.invalidTypedDataJSONFixtures {
            XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: fixture.json),
                           Data(),
                           fixture.name)
        }
    }

    func testTypedDataSigningRejectsMalformedShapesAndAcceptsDecimalChainID() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)

        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.decimalStringChainIDTypedDataJSON, privateKey: privateKey),
                       Vectors.ethereumTypedDataSignature)
        for fixture in Vectors.invalidTypedDataJSONFixtures {
            XCTAssertThrowsError(try Ethereum.shared.sign(typedData: fixture.json, privateKey: privateKey), fixture.name) {
                guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                    XCTFail("Expected failedToSign for \(fixture.name), got \($0)")
                    return
                }
            }
        }
    }

    func testDecodeEthereumCallMatchesWalletCoreVector() {
        XCTAssertEqual(WalletCrypto.decodeEthereumCall(data: Vectors.abiEncodedCall, abi: Vectors.abiJSON),
                       Vectors.abiDecodedCall)
        for fixture in Vectors.abiDecodeFixtures {
            XCTAssertEqual(WalletCrypto.decodeEthereumCall(data: fixture.data, abi: fixture.abi),
                           fixture.decoded,
                           fixture.name)
        }
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Data(), abi: Vectors.abiJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "ffffffff"), abi: Vectors.abiJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f0027"), abi: Vectors.abiJSON))
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
        for invalidAddress in [
            "0xdeadbeef",
            "deadbeef",
            "0x000000000000000000000000000000000000000g",
            "0x00000000000000000000000000000000000000001",
        ] {
            XCTAssertTrue(WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                               nonce: Data(),
                                                               gasPrice: Vectors.data(hex: "01"),
                                                               gasLimit: Vectors.data(hex: "5208"),
                                                               toAddress: invalidAddress,
                                                               privateKey: privateKey,
                                                               amount: Data(),
                                                               data: Data()).isEmpty,
                          invalidAddress)
        }
    }

    func testSignLegacyTransactionPinsDataAndAlternateChainIDVectors() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let dataOnlyTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                                       nonce: Data(),
                                                                       gasPrice: Vectors.data(hex: "09c7652400"),
                                                                       gasLimit: Vectors.data(hex: "0130b9"),
                                                                       toAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
                                                                       privateKey: privateKey,
                                                                       amount: Data(),
                                                                       data: Vectors.data(hex: "deadbeef"))
        let alternateChainIDTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "03"),
                                                                               nonce: Vectors.data(hex: "06"),
                                                                               gasPrice: Vectors.data(hex: "04a817c800"),
                                                                               gasLimit: Vectors.data(hex: "5208"),
                                                                               toAddress: "0x3535353535353535353535353535353535353535",
                                                                               privateKey: privateKey,
                                                                               amount: Vectors.data(hex: "01"),
                                                                               data: Data())

        XCTAssertEqual(WalletCrypto.hexString(dataOnlyTransaction), Vectors.signedDataOnlyTransaction)
        XCTAssertEqual(WalletCrypto.hexString(alternateChainIDTransaction), Vectors.signedChainThreeOneWeiTransaction)
    }

    func testSignLegacyTransactionPinsMultiByteChainIDVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "2105"),
                                                                     nonce: Vectors.data(hex: "06"),
                                                                     gasPrice: Vectors.data(hex: "04a817c800"),
                                                                     gasLimit: Vectors.data(hex: "5208"),
                                                                     toAddress: "0x3535353535353535353535353535353535353535",
                                                                     privateKey: privateKey,
                                                                     amount: Vectors.data(hex: "01"),
                                                                     data: Data())

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedBaseChainOneWeiTransaction)
    }

    func testSignLegacyTransactionNormalizesLeadingZeroQuantityFields() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let leadingZeroEmptySend = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "0001"),
                                                                        nonce: Vectors.data(hex: "00"),
                                                                        gasPrice: Vectors.data(hex: "0001"),
                                                                        gasLimit: Vectors.data(hex: "005208"),
                                                                        toAddress: "0x0000000000000000000000000000000000000001",
                                                                        privateKey: privateKey,
                                                                        amount: Vectors.data(hex: "0000"),
                                                                        data: Data())
        let leadingZeroOneWei = WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "0001"),
                                                                     nonce: Vectors.data(hex: "00"),
                                                                     gasPrice: Vectors.data(hex: "0001"),
                                                                     gasLimit: Vectors.data(hex: "005208"),
                                                                     toAddress: "0x0000000000000000000000000000000000000001",
                                                                     privateKey: privateKey,
                                                                     amount: Vectors.data(hex: "0001"),
                                                                     data: Data())

        XCTAssertEqual(WalletCrypto.hexString(leadingZeroEmptySend), Vectors.signedEmptySendTransaction)
        XCTAssertEqual(WalletCrypto.hexString(leadingZeroOneWei), Vectors.signedOneWeiTransaction)
    }

    func testSignLegacyTransactionPinsEmptyChainIDWalletCoreBehavior() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = WalletCrypto.signEthereumTransaction(chainID: Data(),
                                                                     nonce: Data(),
                                                                     gasPrice: Vectors.data(hex: "01"),
                                                                     gasLimit: Vectors.data(hex: "5208"),
                                                                     toAddress: "0x0000000000000000000000000000000000000001",
                                                                     privateKey: privateKey,
                                                                     amount: Data(),
                                                                     data: Data())

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedEmptyChainIDTransaction)
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

final class WalletCoreProxySolanaCallSiteTests: XCTestCase {

    func testSolanaMessageSigningWrappersPinRawBase58HexAndInvalidDecodeBehavior() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let binaryBase58 = WalletCrypto.base58Encode(data: Vectors.solanaBinaryMessage)
        let binaryHex = WalletCrypto.hexString(data: Vectors.solanaBinaryMessage)
        let longBase58 = WalletCrypto.base58Encode(data: Vectors.solanaLongMessage)
        let longHex = WalletCrypto.hexString(data: Vectors.solanaLongMessage)

        XCTAssertEqual(Solana.shared.decodeMessage(binaryBase58, asHex: false), Vectors.solanaBinaryMessage)
        XCTAssertEqual(Solana.shared.decodeMessage(binaryHex, asHex: true), Vectors.solanaBinaryMessage)
        XCTAssertEqual(Solana.shared.sign(messageData: Vectors.solanaBinaryMessage, privateKey: privateKey),
                       Vectors.solanaBinaryMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: binaryBase58, asHex: false, privateKey: privateKey),
                       Vectors.solanaBinaryMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: binaryHex, asHex: true, privateKey: privateKey),
                       Vectors.solanaBinaryMessageSignature)
        XCTAssertEqual(Solana.shared.sign(messageData: Vectors.solanaLongMessage, privateKey: privateKey),
                       Vectors.solanaLongMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: longBase58, asHex: false, privateKey: privateKey),
                       Vectors.solanaLongMessageSignature)
        XCTAssertEqual(Solana.shared.sign(message: longHex, asHex: true, privateKey: privateKey),
                       Vectors.solanaLongMessageSignature)
        XCTAssertEqual(Solana.shared.decodeMessage("1", asHex: false), Data([0]))
        XCTAssertEqual(Solana.shared.decodeMessage("111", asHex: false), Data(repeating: 0, count: 3))
        XCTAssertEqual(Solana.shared.decodeMessage("0x00", asHex: true), Data([0]))
        XCTAssertEqual(Solana.shared.decodeMessage("ABCDEF", asHex: true), Vectors.data(hex: "abcdef"))
        XCTAssertEqual(Solana.shared.sign(message: WalletCrypto.base58Encode(data: Data()), asHex: false, privateKey: privateKey),
                       nil)
        XCTAssertEqual(Solana.shared.sign(message: "", asHex: true, privateKey: privateKey),
                       Vectors.solanaEmptyMessageSignature)

        XCTAssertEqual(Solana.shared.decodeMessage("", asHex: true), Data())
        XCTAssertNil(Solana.shared.decodeMessage("", asHex: false))
        XCTAssertNil(Solana.shared.decodeMessage("0OIl", asHex: false))
        XCTAssertNil(Solana.shared.decodeMessage("abc", asHex: true))
        XCTAssertNil(Solana.shared.decodeMessage("0X00", asHex: true))
        XCTAssertNil(Solana.shared.decodeMessage("00\n", asHex: true))
        XCTAssertNil(Solana.shared.sign(message: "0OIl", asHex: false, privateKey: privateKey))
        XCTAssertNil(Solana.shared.sign(message: "abc", asHex: true, privateKey: privateKey))
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
