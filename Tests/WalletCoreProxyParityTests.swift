// ∅ 2026 lil org

import Foundation
import CryptoKit
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

@_silgen_name("bw_scrypt_romix_blocks")
private func bwScryptROMixBlocks(_ inputWords: UnsafePointer<UInt32>?,
                                 _ outputWords: UnsafeMutablePointer<UInt32>?,
                                 _ n: Int,
                                 _ r: Int,
                                 _ p: Int) -> Int32

@_silgen_name("bw_scrypt_romix_blocks_range")
private func bwScryptROMixBlocksRange(_ inputWords: UnsafePointer<UInt32>?,
                                      _ outputWords: UnsafeMutablePointer<UInt32>?,
                                      _ n: Int,
                                      _ r: Int,
                                      _ blockStart: Int,
                                      _ blockCount: Int) -> Int32

private func littleEndianWords(_ data: Data) -> [UInt32] {
    precondition(data.count.isMultiple(of: 4))

    let bytes = Array(data)
    var words = [UInt32](repeating: 0, count: bytes.count / 4)
    for index in words.indices {
        let offset = index * 4
        words[index] = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
    return words
}

private func dataFromLittleEndianWords(_ words: [UInt32]) -> Data {
    var bytes = [UInt8]()
    bytes.reserveCapacity(words.count * 4)
    for word in words {
        bytes.append(UInt8(word & 0xff))
        bytes.append(UInt8((word >> 8) & 0xff))
        bytes.append(UInt8((word >> 16) & 0xff))
        bytes.append(UInt8((word >> 24) & 0xff))
    }
    return Data(bytes)
}

private func assertValidSolanaSignature(_ signature: Data,
                                        message: Data,
                                        publicKeyData: Data,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
    XCTAssertEqual(signature.count, 64, file: file, line: line)
    XCTAssertEqual(publicKeyData.count, 32, file: file, line: line)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    XCTAssertTrue(publicKey.isValidSignature(signature, for: message), file: file, line: line)
}

private func assertValidSolanaSignature(_ signature: Data?,
                                        message: Data,
                                        publicKeyHex: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
    let signature = try XCTUnwrap(signature, file: file, line: line)
    let publicKeyData = try XCTUnwrap(WalletCrypto.hexData(string: publicKeyHex), file: file, line: line)
    try assertValidSolanaSignature(signature, message: message, publicKeyData: publicKeyData, file: file, line: line)
}

private func assertValidSolanaSignature(_ signatureBase58: String?,
                                        message: Data,
                                        publicKeyHex: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) throws {
    let signatureBase58 = try XCTUnwrap(signatureBase58, file: file, line: line)
    let signature = try XCTUnwrap(WalletCrypto.base58Decode(string: signatureBase58), file: file, line: line)
    try assertValidSolanaSignature(signature, message: message, publicKeyHex: publicKeyHex, file: file, line: line)
}

final class WalletCoreProxyDependencyBoundaryTests: XCTestCase {

    func testBoundaryParserHandlesSwiftImportFormsAndIgnoresNonCodeTokens() {
        let source = """
        // import WalletCore
        let commentText = "PrivateKey WalletCore import WalletCore"
        /*
         import WalletCoreSwiftProtobuf
         StoredKey
         */
        @_implementationOnly import WalletCore
        @_exported @preconcurrency import WalletCoreSwiftProtobuf // trailing comment
        import class VSwiftProtobuf.Google_Protobuf_Any
        import struct Foundation.URL
        let realType = PrivateKey.self
        """
        let codeOnlySource = Self.sourceWithCommentsAndStringLiteralsBlanked(source)
        let detectedImports = codeOnlySource.components(separatedBy: .newlines).flatMap { line in
            ["WalletCore", "WalletCoreSwiftProtobuf", "VSwiftProtobuf"].filter { Self.isImport(line, of: $0) }
        }

        XCTAssertFalse(codeOnlySource.contains("WalletCore import WalletCore"))
        XCTAssertFalse(codeOnlySource.contains("StoredKey"))
        XCTAssertEqual(detectedImports, ["WalletCore", "WalletCoreSwiftProtobuf", "VSwiftProtobuf"])
        XCTAssertTrue(Self.isImport("@_implementationOnly import WalletCore", of: "WalletCore"))
        XCTAssertTrue(Self.isImport("@_exported @preconcurrency import WalletCoreSwiftProtobuf", of: "WalletCoreSwiftProtobuf"))
        XCTAssertTrue(Self.isImport("public import WalletCore // trailing comment", of: "WalletCore"))
        XCTAssertTrue(Self.isImport("import class VSwiftProtobuf.Google_Protobuf_Any", of: "VSwiftProtobuf"))
        XCTAssertFalse(Self.isImport("import struct Foundation.URL", of: "WalletCore"))
        XCTAssertTrue(codeOnlySource.range(of: #"(?<![A-Za-z0-9_])PrivateKey(?![A-Za-z0-9_])"#,
                                           options: .regularExpression) != nil)
    }

    func testProductionSwiftDoesNotImportWalletCore() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let walletProxyRelativeDirectory = "Shared/WalletCoreProxy/"
        let productionDirectories = [
            "App iOS",
            "App macOS",
            "App visionOS",
            "Big Wallet Ambient",
            "Safari iOS",
            "Safari macOS",
            "Safari Shared",
            "Safari visionOS",
            "Shared",
            "Tools",
        ]
        let forbiddenImports = [
            "WalletCore",
            "WalletCoreSwiftProtobuf",
            "VSwiftProtobuf",
        ]
        let forbiddenGeneratedTypeNames = [
            "AnySigner",
            "Base58",
            "CoinType",
            "Derivation",
            "DerivationPath",
            "EthereumAbi",
            "EthereumSigningInput",
            "EthereumSigningOutput",
            "EthereumTransaction",
            "Hash",
            "HDVersion",
            "HDWallet",
            "Mnemonic",
            "PrivateKey",
            "PublicKey",
            "StoredKey",
        ]
        let fileManager = FileManager.default
        var scanFailures: [String] = []
        var scannedSwiftFileCount = 0
        var foundWalletProxySource = false
        var violations: [String] = []

        for directoryName in productionDirectories {
            let directory = sourceRoot.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                scanFailures.append("Missing production directory: \(directoryName)")
                continue
            }

            guard let enumerator = fileManager.enumerator(at: directory,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else {
                scanFailures.append("Could not enumerate production directory: \(directoryName)")
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let relativePath = fileURL.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                    scanFailures.append("Could not read \(relativePath)")
                    continue
                }

                let isWalletProxySource = relativePath.hasPrefix(walletProxyRelativeDirectory)
                if isWalletProxySource { foundWalletProxySource = true }
                scannedSwiftFileCount += 1
                let codeOnlyContents = Self.sourceWithCommentsAndStringLiteralsBlanked(contents)
                for (lineIndex, line) in codeOnlyContents.components(separatedBy: .newlines).enumerated() {
                    for module in forbiddenImports where Self.isImport(line, of: module) {
                        violations.append("\(relativePath):\(lineIndex + 1) imports \(module)")
                    }
                }

                guard !isWalletProxySource else { continue }
                for typeName in forbiddenGeneratedTypeNames {
                    let pattern = #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: typeName) + #"(?![A-Za-z0-9_])"#
                    if let range = codeOnlyContents.range(of: pattern, options: .regularExpression) {
                        violations.append("\(relativePath):\(Self.lineNumber(of: range.lowerBound, in: codeOnlyContents)) references WalletCore generated type \(typeName)")
                    }
                }
            }
        }

        if !foundWalletProxySource {
            scanFailures.append("Did not find wallet proxy directory: \(walletProxyRelativeDirectory)")
        }
        if scannedSwiftFileCount == 0 {
            scanFailures.append("Scanned 0 production Swift files")
        }

        XCTAssertTrue(scanFailures.isEmpty,
                      "WalletCore dependency boundary scan did not cover expected sources:\n" + scanFailures.joined(separator: "\n"))
        XCTAssertTrue(violations.isEmpty,
                      "WalletCore imports are forbidden and generated type names must remain isolated to \(walletProxyRelativeDirectory):\n" + violations.joined(separator: "\n"))
    }

    private static func isImport(_ line: String, of module: String) -> Bool {
        let attributes = #"(?:(?:@\w+(?:\([^)]*\))?|@_\w+(?:\([^)]*\))?)\s+)*"#
        let accessLevel = #"(?:(?:private|fileprivate|internal|package|public|open)\s+)?"#
        let importKind = #"(?:(?:class|struct|enum|protocol|typealias|func|let|var)\s+)?"#
        let modulePattern = NSRegularExpression.escapedPattern(for: module)
        let pattern = #"^\s*"# + attributes + accessLevel + #"import\s+"# + importKind + modulePattern + #"(?:\s|\.|$)"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func sourceWithCommentsAndStringLiteralsBlanked(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var sanitized = String.UnicodeScalarView()
        sanitized.reserveCapacity(scalars.count)

        var index = scalars.startIndex
        var blockCommentDepth = 0
        var lineComment = false
        var stringDelimiterCount = 0
        var rawStringPoundCount = 0

        func appendBlankPreservingNewline(_ scalar: UnicodeScalar) {
            sanitized.append(scalar == "\n" ? scalar : " ")
        }

        func poundCount(before quoteIndex: Int) -> Int {
            var count = 0
            var currentIndex = quoteIndex
            while currentIndex > scalars.startIndex {
                let previousIndex = currentIndex - 1
                guard scalars[previousIndex] == "#" else { break }
                count += 1
                currentIndex = previousIndex
            }
            return count
        }

        func isEscapedQuote(at quoteIndex: Int) -> Bool {
            guard rawStringPoundCount == 0 else { return false }
            var backslashCount = 0
            var currentIndex = quoteIndex
            while currentIndex > scalars.startIndex {
                let previousIndex = currentIndex - 1
                guard scalars[previousIndex] == "\\" else { break }
                backslashCount += 1
                currentIndex = previousIndex
            }
            return !backslashCount.isMultiple(of: 2)
        }

        func rawStringHasClosingPounds(after lastQuoteIndex: Int) -> Bool {
            guard rawStringPoundCount > 0 else { return true }
            let firstPoundIndex = lastQuoteIndex + 1
            guard firstPoundIndex + rawStringPoundCount <= scalars.count else { return false }
            return scalars[firstPoundIndex..<firstPoundIndex + rawStringPoundCount].allSatisfy { $0 == "#" }
        }

        func appendBlanks(count: Int) {
            for _ in 0..<count {
                sanitized.append(" ")
            }
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = index + 1 < scalars.endIndex ? scalars[index + 1] : nil

            if lineComment {
                appendBlankPreservingNewline(scalar)
                if scalar == "\n" {
                    lineComment = false
                }
                index += 1
                continue
            }

            if blockCommentDepth > 0 {
                if scalar == "/", next == "*" {
                    appendBlanks(count: 2)
                    blockCommentDepth += 1
                    index += 2
                } else if scalar == "*", next == "/" {
                    appendBlanks(count: 2)
                    blockCommentDepth -= 1
                    index += 2
                } else {
                    appendBlankPreservingNewline(scalar)
                    index += 1
                }
                continue
            }

            if stringDelimiterCount > 0 {
                if stringDelimiterCount == 1,
                   scalar == "\"",
                   !isEscapedQuote(at: index),
                   rawStringHasClosingPounds(after: index) {
                    appendBlanks(count: 1 + rawStringPoundCount)
                    index += 1 + rawStringPoundCount
                    stringDelimiterCount = 0
                    rawStringPoundCount = 0
                } else if stringDelimiterCount == 3,
                          scalar == "\"",
                          index + 2 < scalars.endIndex,
                          scalars[index + 1] == "\"",
                          scalars[index + 2] == "\"",
                          rawStringHasClosingPounds(after: index + 2) {
                    appendBlanks(count: 3 + rawStringPoundCount)
                    index += 3 + rawStringPoundCount
                    stringDelimiterCount = 0
                    rawStringPoundCount = 0
                } else {
                    appendBlankPreservingNewline(scalar)
                    index += 1
                }
                continue
            }

            if scalar == "/", next == "/" {
                appendBlanks(count: 2)
                lineComment = true
                index += 2
            } else if scalar == "/", next == "*" {
                appendBlanks(count: 2)
                blockCommentDepth = 1
                index += 2
            } else if scalar == "\"" {
                let delimiterPoundCount = poundCount(before: index)
                let firstQuoteIndex = index
                if firstQuoteIndex + 2 < scalars.endIndex,
                   scalars[firstQuoteIndex + 1] == "\"",
                   scalars[firstQuoteIndex + 2] == "\"" {
                    appendBlanks(count: 3)
                    stringDelimiterCount = 3
                    rawStringPoundCount = delimiterPoundCount
                    index += 3
                } else if !isEscapedQuote(at: index) {
                    appendBlanks(count: 1)
                    stringDelimiterCount = 1
                    rawStringPoundCount = delimiterPoundCount
                    index += 1
                } else {
                    sanitized.append(scalar)
                    index += 1
                }
            } else {
                sanitized.append(scalar)
                index += 1
            }
        }

        return String(sanitized)
    }

    private static func lineNumber(of index: String.Index, in string: String) -> Int {
        return string[..<index].reduce(1) { count, character in
            count + (character == "\n" ? 1 : 0)
        }
    }

}

final class WalletCoreProxyCoinAndCryptoTests: XCTestCase {

    func testCoinConstantsMatchWalletCoreContract() {
        XCTAssertEqual(WalletCoin.ethereum.rawValue, 60)
        XCTAssertEqual(WalletCoin.solana.rawValue, 501)

        XCTAssertEqual(WalletCoin.ethereum.slip44Id, 60)
        XCTAssertEqual(WalletCoin.solana.slip44Id, 501)

        XCTAssertEqual(WalletDerivation.default.rawValue, 0)
        XCTAssertEqual(WalletDerivation.custom.rawValue, 1)
        XCTAssertEqual(WalletDerivation.solanaSolana.rawValue, 6)
        XCTAssertEqual(WalletDerivation(rawValue: 0), .default)
        XCTAssertEqual(WalletDerivation(rawValue: 1), .custom)
        XCTAssertEqual(WalletDerivation(rawValue: 6), .solanaSolana)
        XCTAssertEqual(WalletDerivation(rawValue: 8), .custom)
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
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.valid15WordMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.valid18WordMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.valid21WordMnemonic))
        XCTAssertTrue(WalletCrypto.isValidMnemonic(Vectors.zeroEntropy24WordMnemonic))

        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidChecksumMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidWordCountMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.invalidWordMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.uppercaseMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(Vectors.mixedWhitespaceMnemonic))
        XCTAssertFalse(WalletCrypto.isValidMnemonic(""))

        for invalidMnemonic in [
            Vectors.abandonMnemonic.uppercased(),
            "Abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            Vectors.abandonMnemonic + " ",
            "\n" + Vectors.abandonMnemonic,
            Vectors.abandonMnemonic.replacingOccurrences(of: " ", with: "  "),
            Vectors.abandonMnemonic.replacingOccurrences(of: " ", with: "\t"),
        ] {
            XCTAssertFalse(WalletCrypto.isValidMnemonic(invalidMnemonic), invalidMnemonic)
        }
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

    func testSecp256k1BackendRejectsInvalidPrivateKeys() {
        XCTAssertFalse(Secp256k1.isValidPrivateKey(Vectors.zeroPrivateKey))
        XCTAssertFalse(Secp256k1.isValidPrivateKey(Data(repeating: 1, count: 31)))
        XCTAssertFalse(Secp256k1.isValidPrivateKey(Data(repeating: 1, count: 33)))
        XCTAssertFalse(Secp256k1.isValidPrivateKey(Vectors.secp256k1PrivateKeyAtCurveOrder))
        XCTAssertFalse(Secp256k1.isValidPrivateKey(Vectors.secp256k1PrivateKeyAboveCurveOrder))
        XCTAssertNil(Secp256k1.publicKey(privateKey: Vectors.zeroPrivateKey, compressed: false))
        XCTAssertNil(Secp256k1.publicKey(privateKey: Vectors.secp256k1PrivateKeyAtCurveOrder, compressed: false))
    }

    func testSecp256k1BackendSerializesCompressedAndUncompressedPublicKeys() throws {
        let uncompressed = try XCTUnwrap(Secp256k1.publicKey(privateKey: Vectors.secpPrivateKey, compressed: false))
        let compressed = try XCTUnwrap(Secp256k1.publicKey(privateKey: Vectors.secpPrivateKey, compressed: true))

        XCTAssertEqual(WalletCrypto.hexString(uncompressed), Vectors.secpPublicKey)
        XCTAssertEqual(WalletCrypto.hexString(compressed), Vectors.secpCompressedPublicKey)
        XCTAssertEqual(Secp256k1.uncompressedPublicKey(fromCompressed: compressed), uncompressed)
        XCTAssertEqual(Secp256k1.compressedPublicKey(fromUncompressed: uncompressed), compressed)
        XCTAssertTrue(Secp256k1.isValidPublicKey(uncompressed))
        XCTAssertFalse(Secp256k1.isValidPublicKey(compressed))
    }

    func testSecp256k1BackendRecoverableSignatureShapeAndRecoveryIDNormalization() throws {
        let signature = try XCTUnwrap(Secp256k1.sign(digest: Vectors.ethereumHelloRawSignDigest,
                                                     privateKey: Vectors.secpPrivateKey))
        let publicKey = try XCTUnwrap(Secp256k1.publicKey(privateKey: Vectors.secpPrivateKey, compressed: false))

        XCTAssertEqual(signature.count, 65)
        XCTAssertLessThan(signature[64], 4)
        XCTAssertEqual(Secp256k1.recoverPublicKey(signature: signature,
                                                  digest: Vectors.ethereumHelloRawSignDigest),
                       publicKey)

        var ethereumSignature = signature
        ethereumSignature[64] += 27
        XCTAssertEqual(Secp256k1.recoverPublicKey(signature: ethereumSignature,
                                                  digest: Vectors.ethereumHelloRawSignDigest),
                       publicKey)

        var invalidRecoveryIDSignature = signature
        invalidRecoveryIDSignature[64] = 31
        XCTAssertNil(Secp256k1.recoverPublicKey(signature: invalidRecoveryIDSignature,
                                                digest: Vectors.ethereumHelloRawSignDigest))
    }

    func testSecp256k1BackendCombinesPublicKeysForXpubChildDerivation() throws {
        let privateKey = Vectors.secpPrivateKey
        let tweak = Vectors.onePrivateKey
        let publicKey = try XCTUnwrap(Secp256k1.publicKey(privateKey: privateKey, compressed: false))
        let tweakPublicKey = try XCTUnwrap(Secp256k1.publicKey(privateKey: tweak, compressed: false))
        let childPrivateKey = try XCTUnwrap(Secp256k1.addPrivateKey(privateKey, tweak: tweak))
        let expectedChildPublicKey = try XCTUnwrap(Secp256k1.publicKey(privateKey: childPrivateKey, compressed: false))

        XCTAssertEqual(Secp256k1.addPublicKeys(publicKey, tweakPublicKey), expectedChildPublicKey)
        XCTAssertNil(Secp256k1.addPrivateKey(privateKey, tweak: Vectors.secp256k1PrivateKeyAtCurveOrder))
        XCTAssertNil(Secp256k1.addPublicKeys(Data([1, 2, 3]), tweakPublicKey))
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

    func testUpstreamSolanaPrivateKeyDerivesPinnedIdentity() throws {
        let privateKeyData = try XCTUnwrap(WalletCrypto.base58Decode(Vectors.upstreamSolanaPrivateKeyBase58))
        let privateKey = try requirePrivateKey(privateKeyData)

        XCTAssertEqual(privateKeyData, Vectors.upstreamSolanaPrivateKey)
        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .solana)), Vectors.upstreamSolanaPublicKey)
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .solana), Vectors.upstreamSolanaPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.upstreamSolanaPublicKey, coin: .solana),
                       Vectors.upstreamSolanaAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(privateKey.publicKeyData(coin: .solana), coin: .solana),
                       Vectors.upstreamSolanaAddress)
    }

    func testSolanaSigningProducesValidEd25519Signatures() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let signature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaMessage, coin: .solana))
        let emptySignature = try XCTUnwrap(privateKey.sign(digest: Data(), coin: .solana))
        let zeroMessageSignature = try XCTUnwrap(privateKey.sign(digest: Data(repeating: 0, count: 32), coin: .solana))
        let binarySignature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaBinaryMessage, coin: .solana))
        let longSignature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaLongMessage, coin: .solana))

        XCTAssertEqual(WalletCrypto.hexString(privateKey.publicKeyData(coin: .solana)), Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(signature, message: Vectors.solanaMessage, publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(emptySignature, message: Data(), publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(zeroMessageSignature,
                                       message: Data(repeating: 0, count: 32),
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(binarySignature,
                                       message: Vectors.solanaBinaryMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(longSignature,
                                       message: Vectors.solanaLongMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        XCTAssertNil(privateKey.sign(digest: Data([1, 2, 3]), coin: .ethereum))
    }

    func testUpstreamSolanaRawMessageSigningProducesValidSignature() throws {
        let privateKey = try requirePrivateKey(Vectors.upstreamSolanaPrivateKey)
        let signature = try XCTUnwrap(privateKey.sign(digest: Vectors.solanaMessage, coin: .solana))

        try assertValidSolanaSignature(signature, message: Vectors.solanaMessage, publicKeyHex: Vectors.upstreamSolanaPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(messageData: Vectors.solanaMessage, privateKey: privateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.upstreamSolanaPublicKey)
    }

    func testEthereumPersonalSigningAndRecoveryMatchWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)
        let signatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumPersonalMessage, privateKey: privateKey)
        let emptySignatureHex = try Ethereum.shared.signPersonalMessage(data: Data(), privateKey: privateKey)
        let binarySignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumBinaryPersonalMessage, privateKey: privateKey)
        let newlineSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumNewlinePersonalMessage, privateKey: privateKey)
        let tenByteSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumTenBytePersonalMessage, privateKey: privateKey)
        let hundredByteSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumHundredBytePersonalMessage, privateKey: privateKey)
        let longSignatureHex = try Ethereum.shared.signPersonalMessage(data: Vectors.ethereumLongPersonalMessage, privateKey: privateKey)
        let signature = try XCTUnwrap(WalletCrypto.hexData(String(signatureHex.dropFirst(2))))
        let emptySignature = try XCTUnwrap(WalletCrypto.hexData(String(emptySignatureHex.dropFirst(2))))
        let binarySignature = try XCTUnwrap(WalletCrypto.hexData(String(binarySignatureHex.dropFirst(2))))
        let newlineSignature = try XCTUnwrap(WalletCrypto.hexData(String(newlineSignatureHex.dropFirst(2))))
        let tenByteSignature = try XCTUnwrap(WalletCrypto.hexData(String(tenByteSignatureHex.dropFirst(2))))
        let hundredByteSignature = try XCTUnwrap(WalletCrypto.hexData(String(hundredByteSignatureHex.dropFirst(2))))
        let longSignature = try XCTUnwrap(WalletCrypto.hexData(String(longSignatureHex.dropFirst(2))))

        XCTAssertEqual(signatureHex, Vectors.ethereumPersonalMessageSignature)
        XCTAssertEqual(emptySignatureHex, Vectors.ethereumEmptyPersonalMessageSignature)
        XCTAssertEqual(binarySignatureHex, Vectors.ethereumBinaryPersonalMessageSignature)
        XCTAssertEqual(newlineSignatureHex, Vectors.ethereumNewlinePersonalMessageSignature)
        XCTAssertEqual(tenByteSignatureHex, Vectors.ethereumTenBytePersonalMessageSignature)
        XCTAssertEqual(hundredByteSignatureHex, Vectors.ethereumHundredBytePersonalMessageSignature)
        XCTAssertEqual(longSignatureHex, Vectors.ethereumLongPersonalMessageSignature)
        XCTAssertEqual(Ethereum.shared.recover(signature: signature, message: Vectors.ethereumPersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: emptySignature, message: Data()),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: binarySignature, message: Vectors.ethereumBinaryPersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: newlineSignature, message: Vectors.ethereumNewlinePersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: tenByteSignature, message: Vectors.ethereumTenBytePersonalMessage),
                       Vectors.ethereumSignerAddress)
        XCTAssertEqual(Ethereum.shared.recover(signature: hundredByteSignature, message: Vectors.ethereumHundredBytePersonalMessage),
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
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.typedDataMinifiedJSON, privateKey: privateKey),
                       Vectors.ethereumTypedDataSignature)
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.typedDataReorderedJSON, privateKey: privateKey),
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
        let solanaRawAllOnesPublicKey = Data(repeating: 1, count: 32)
        let offCurveEthereumPublicKey = Data([0x04]) + Data(repeating: 0, count: 64)

        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("not hex", coin: .ethereum), "")
        XCTAssertFalse(prefixedPublicKeyAddress.isEmpty)
        XCTAssertEqual(prefixedPublicKeyAddress,
                       WalletCrypto.addressFromPublicKeyDescription(Vectors.secpPublicKey, coin: .ethereum))
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Vectors.data(hex: Vectors.secpPublicKey), coin: .ethereum),
                       Vectors.secpEthereumAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(repeating: 1, count: 31), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(repeating: 1, count: 32), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(repeating: 1, count: 64), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(offCurveEthereumPublicKey, coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(offCurveEthereumPublicKey),
                                                                    coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Vectors.data(hex: Vectors.secpCompressedPublicKey), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.solanaAddressPublicKey, coin: .solana),
                       Vectors.solanaAddressFromPublicKey)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(Vectors.secpCompressedPublicKey, coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription("0x" + Vectors.secpCompressedPublicKey, coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(String(Vectors.secpPublicKey.dropLast(2)), coin: .ethereum), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(Data(repeating: 1, count: 31)), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(solanaRawAllOnesPublicKey),
                                                                    coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(solanaPrefixedPublicKey),
                                                                    coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(WalletCrypto.hexString(invalidSolanaPrefixedPublicKey),
                                                                    coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data([1, 2, 3]), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(Data(repeating: 1, count: 31), coin: .solana), "")
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(solanaRawAllOnesPublicKey, coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(solanaPrefixedPublicKey, coin: .solana),
                       Vectors.solanaAllOnesPublicKeyAddress)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyData(invalidSolanaPrefixedPublicKey, coin: .solana), "")
    }

}

final class ScryptROMixShimTests: XCTestCase {

    private static let rfc7914ROMixInput = Vectors.data(hex:
        "f7ce0b653d2d72a4108cf5abe912ffdd777616dbbb27a70e8204f3ae2d0f6fad" +
        "89f68f4811d1e87bcc3bd7400a9ffd29094f0184639574f39ae5a1315217bcd7" +
        "894991447213bb226c25b54da86370fbcd984380374666bb8ffcb5bf40c254b0" +
        "67d27c51ce4ad5fed829c90b505a571b7f4d1cad6a523cda770e67bceaaf7e89")

    private static let rfc7914ROMixOutput = Vectors.data(hex:
        "79ccc193629debca047f0b70604bf6b62ce3dd4a9626e355fafc6198e6ea2b46" +
        "d58413673b99b029d665c357601fb426a0b2f4bba200ee9f0a43d19b571a9c71" +
        "ef1142e65d5a266fddca832ce59faa7cac0b9cf1be2bffca300d01ee387619c4" +
        "ae12fd4438f203a0e4e1c47ec314861f4e9087cb33396a6873e8f9d2539a4b8e")

    func testROMixMatchesRFC7914Vector() {
        let inputWords = littleEndianWords(Self.rfc7914ROMixInput)
        var outputWords = [UInt32](repeating: 0, count: inputWords.count)

        let status = inputWords.withUnsafeBufferPointer { input in
            outputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocks(input.baseAddress, output.baseAddress, 16, 1, 1)
            }
        }

        XCTAssertEqual(status, 1)
        XCTAssertEqual(dataFromLittleEndianWords(outputWords), Self.rfc7914ROMixOutput)
    }

    func testSingleBlockRangeROMixMatchesRFC7914Vector() {
        let inputWords = littleEndianWords(Self.rfc7914ROMixInput)
        var outputWords = [UInt32](repeating: 0, count: inputWords.count)

        let status = inputWords.withUnsafeBufferPointer { input in
            outputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocksRange(input.baseAddress, output.baseAddress, 16, 1, 0, 1)
            }
        }

        XCTAssertEqual(status, 1)
        XCTAssertEqual(dataFromLittleEndianWords(outputWords), Self.rfc7914ROMixOutput)
    }

    func testROMixProcessesParallelBlocksIndependently() {
        var inputData = Data()
        inputData.append(Self.rfc7914ROMixInput)
        inputData.append(Self.rfc7914ROMixInput)
        var expectedOutput = Data()
        expectedOutput.append(Self.rfc7914ROMixOutput)
        expectedOutput.append(Self.rfc7914ROMixOutput)

        let inputWords = littleEndianWords(inputData)
        var outputWords = [UInt32](repeating: 0, count: inputWords.count)

        let status = inputWords.withUnsafeBufferPointer { input in
            outputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocks(input.baseAddress, output.baseAddress, 16, 1, 2)
            }
        }

        XCTAssertEqual(status, 1)
        XCTAssertEqual(dataFromLittleEndianWords(outputWords), expectedOutput)
    }

    func testSingleBlockRangesAndMultiBlockROMixMatchForEachBlock() {
        var inputData = Data()
        inputData.append(Self.rfc7914ROMixInput)
        inputData.append(Self.rfc7914ROMixOutput)

        let inputWords = littleEndianWords(inputData)
        var multiBlockOutputWords = [UInt32](repeating: 0, count: inputWords.count)
        var singleBlockRangeOutputWords = [UInt32](repeating: 0, count: inputWords.count)

        let multiBlockStatus = inputWords.withUnsafeBufferPointer { input in
            multiBlockOutputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocks(input.baseAddress, output.baseAddress, 16, 1, 2)
            }
        }
        let singleBlockStatus = inputWords.withUnsafeBufferPointer { input in
            singleBlockRangeOutputWords.withUnsafeMutableBufferPointer { output in
                let firstStatus = bwScryptROMixBlocksRange(input.baseAddress,
                                                           output.baseAddress,
                                                           16,
                                                           1,
                                                           0,
                                                           1)
                let secondStatus = bwScryptROMixBlocksRange(input.baseAddress,
                                                            output.baseAddress,
                                                            16,
                                                            1,
                                                            1,
                                                            1)
                return firstStatus == 1 && secondStatus == 1 ? 1 : 0
            }
        }

        XCTAssertEqual(multiBlockStatus, 1)
        XCTAssertEqual(singleBlockStatus, 1)
        XCTAssertEqual(singleBlockRangeOutputWords, multiBlockOutputWords)
    }

    func testROMixRangeMatchesMultiBlockOutput() {
        var inputData = Data()
        inputData.append(Self.rfc7914ROMixInput)
        inputData.append(Self.rfc7914ROMixOutput)
        inputData.append(Self.rfc7914ROMixInput)

        let inputWords = littleEndianWords(inputData)
        var multiBlockOutputWords = [UInt32](repeating: 0, count: inputWords.count)
        var rangedOutputWords = [UInt32](repeating: 0, count: inputWords.count)

        let multiBlockStatus = inputWords.withUnsafeBufferPointer { input in
            multiBlockOutputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocks(input.baseAddress, output.baseAddress, 16, 1, 3)
            }
        }
        let firstRangeStatus = inputWords.withUnsafeBufferPointer { input in
            rangedOutputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocksRange(input.baseAddress, output.baseAddress, 16, 1, 0, 1)
            }
        }
        let secondRangeStatus = inputWords.withUnsafeBufferPointer { input in
            rangedOutputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocksRange(input.baseAddress, output.baseAddress, 16, 1, 1, 2)
            }
        }

        XCTAssertEqual(multiBlockStatus, 1)
        XCTAssertEqual(firstRangeStatus, 1)
        XCTAssertEqual(secondRangeStatus, 1)
        XCTAssertEqual(rangedOutputWords, multiBlockOutputWords)
    }

    func testROMixRejectsInvalidInputs() {
        let inputWords = littleEndianWords(Self.rfc7914ROMixInput)
        var outputWords = [UInt32](repeating: 0, count: inputWords.count)

        let nilInputStatus = outputWords.withUnsafeMutableBufferPointer { output in
            bwScryptROMixBlocks(nil, output.baseAddress, 16, 1, 1)
        }
        XCTAssertEqual(nilInputStatus, 0)

        let nilOutputStatus = inputWords.withUnsafeBufferPointer { input in
            bwScryptROMixBlocks(input.baseAddress, nil, 16, 1, 1)
        }
        XCTAssertEqual(nilOutputStatus, 0)

        let nilRangeInputStatus = outputWords.withUnsafeMutableBufferPointer { output in
            bwScryptROMixBlocksRange(nil, output.baseAddress, 16, 1, 0, 1)
        }
        XCTAssertEqual(nilRangeInputStatus, 0)

        let nilRangeOutputStatus = inputWords.withUnsafeBufferPointer { input in
            bwScryptROMixBlocksRange(input.baseAddress, nil, 16, 1, 0, 1)
        }
        XCTAssertEqual(nilRangeOutputStatus, 0)

        let emptyRangeStatus = inputWords.withUnsafeBufferPointer { input in
            outputWords.withUnsafeMutableBufferPointer { output in
                bwScryptROMixBlocksRange(input.baseAddress, output.baseAddress, 16, 1, 0, 0)
            }
        }
        XCTAssertEqual(emptyRangeStatus, 0)

        let invalidMultiBlockParameterCases = [
            (n: 1, r: 1, p: 1),
            (n: 3, r: 1, p: 1),
            (n: 16, r: 0, p: 1),
            (n: 16, r: 1, p: 0),
        ]

        for invalidCase in invalidMultiBlockParameterCases {
            let status = inputWords.withUnsafeBufferPointer { input in
                outputWords.withUnsafeMutableBufferPointer { output in
                    bwScryptROMixBlocks(input.baseAddress, output.baseAddress, invalidCase.n, invalidCase.r, invalidCase.p)
                }
            }
            XCTAssertEqual(status, 0, "Expected rejection for n=\(invalidCase.n), r=\(invalidCase.r), p=\(invalidCase.p)")
        }

        let invalidRangeParameterCases = [
            (n: 1, r: 1),
            (n: 3, r: 1),
            (n: 16, r: 0),
        ]

        for invalidCase in invalidRangeParameterCases {
            let status = inputWords.withUnsafeBufferPointer { input in
                outputWords.withUnsafeMutableBufferPointer { output in
                    bwScryptROMixBlocksRange(input.baseAddress, output.baseAddress, invalidCase.n, invalidCase.r, 0, 1)
                }
            }
            XCTAssertEqual(status, 0, "Expected range rejection for n=\(invalidCase.n), r=\(invalidCase.r)")
        }
    }

}

final class WalletCoreProxyPerformanceGateTests: XCTestCase {

    private enum WalletCoreBaselineCeilingMilliseconds {
        static let scryptDefaultDerive = 1_000.0
        static let scryptWalletCoreJSONImport = 1_000.0
        static let secp256k1PublicKey = 25.0
        static let secp256k1Sign = 15.0
        static let ed25519Sign = 15.0
    }
    private enum PerformanceGateEnvironment {
        static let allowDebug = "WALLETCORE_PROXY_PERF_ALLOW_DEBUG"
        static let scryptDefaultDerive = "WALLETCORE_PROXY_PERF_SCRYPT_DERIVE_MS"
        static let scryptWalletCoreJSONImport = "WALLETCORE_PROXY_PERF_SCRYPT_WALLETCORE_JSON_IMPORT_MS"
        static let secp256k1PublicKey = "WALLETCORE_PROXY_PERF_SECP256K1_PUBLIC_KEY_MS"
        static let secp256k1Sign = "WALLETCORE_PROXY_PERF_SECP256K1_SIGN_MS"
        static let ed25519Sign = "WALLETCORE_PROXY_PERF_ED25519_SIGN_MS"
    }

    private enum PerformanceThresholdResolution: Equatable {
        case success(Double)
        case skipped(String)
        case failure(String)
    }

    func testPerformanceGateThresholdResolutionSkipsUnlessBaselineIsConfigured() {
        let thresholdEnv = "TEST_CRYPTO_PERF_MS"

        XCTAssertEqual(Self.performanceThreshold("test operation",
                                                 thresholdEnv: thresholdEnv,
                                                 baselineCeilingMilliseconds: 10,
                                                 environment: [thresholdEnv: "5"]),
                       .success(5))
        assertPerformanceThresholdSkipped(Self.performanceThreshold("test operation",
                                                                   thresholdEnv: thresholdEnv,
                                                                   baselineCeilingMilliseconds: 10,
                                                                   environment: [:]),
                                          contains: "not configured")
        XCTAssertEqual(Self.performanceThreshold("test operation",
                                                 thresholdEnv: thresholdEnv,
                                                 baselineCeilingMilliseconds: 10,
                                                 environment: [thresholdEnv: "10"]),
                       .success(10))
        XCTAssertEqual(Self.performanceThreshold("test operation",
                                                 thresholdEnv: thresholdEnv,
                                                 baselineCeilingMilliseconds: 10,
                                                 environment: [thresholdEnv: "0.25"]),
                       .success(0.25))
        assertPerformanceThresholdFailure(Self.performanceThreshold("test operation",
                                                                   thresholdEnv: thresholdEnv,
                                                                   baselineCeilingMilliseconds: 0,
                                                                   environment: [thresholdEnv: "1"]),
                                          contains: "positive")
        assertPerformanceThresholdSkipped(Self.performanceThreshold("test operation",
                                                                   thresholdEnv: thresholdEnv,
                                                                   baselineCeilingMilliseconds: 10,
                                                                   environment: [thresholdEnv: ""]),
                                          contains: "not configured")
        assertPerformanceThresholdFailure(Self.performanceThreshold("test operation",
                                                                   thresholdEnv: thresholdEnv,
                                                                   baselineCeilingMilliseconds: 10,
                                                                   environment: [thresholdEnv: "not-a-number"]),
                                          contains: "positive")
        assertPerformanceThresholdFailure(Self.performanceThreshold("test operation",
                                                                   thresholdEnv: thresholdEnv,
                                                                   baselineCeilingMilliseconds: 10,
                                                                   environment: [thresholdEnv: "11"]),
                                          contains: "sanity ceiling")
    }

    func testScryptDefaultDerivationPerformanceGate() throws {
        try Self.assertPerformanceGate("scrypt default KDF",
                                       thresholdEnv: PerformanceGateEnvironment.scryptDefaultDerive,
                                       baselineCeilingMilliseconds: WalletCoreBaselineCeilingMilliseconds.scryptDefaultDerive) {
            let derivedKey = Scrypt.deriveKey(password: Vectors.password,
                                              salt: Data(repeating: 1, count: 32),
                                              n: 1 << 14,
                                              r: 8,
                                              p: 4,
                                              dkLen: 32)
            XCTAssertEqual(derivedKey.count, 32)
            XCTAssertFalse(derivedKey.isEmpty)
            return derivedKey.count
        }
    }

    func testScryptDefaultParametersAndSequentialDerivationVectors() {
        XCTAssertTrue(Scrypt.parametersAreValid(n: 1 << 14, r: 8, p: 4, dkLen: 32))
        XCTAssertTrue(Scrypt.parametersAreValid(n: 1 << 18, r: 1, p: 8, dkLen: 32))

        XCTAssertEqual(Scrypt.deriveKey(password: Data(),
                                        salt: Data(),
                                        n: 16,
                                        r: 1,
                                        p: 1,
                                        dkLen: 64),
                       Vectors.data(hex: "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"))
        XCTAssertEqual(Scrypt.deriveKey(password: Data("password".utf8),
                                        salt: Data("NaCl".utf8),
                                        n: 16,
                                        r: 8,
                                        p: 4,
                                        dkLen: 64),
                       Vectors.data(hex: "d2143988ad24256a73275725c17155de75b463ec7bec2ada394fc56049b9bfba41d44d4da149c3e71d19c09ae8d5a98af6ca14f291a1bf032fb2f993aca706ac"))
        XCTAssertEqual(Scrypt.deriveKey(password: Vectors.password,
                                        salt: Data(repeating: 1, count: 32),
                                        n: 16,
                                        r: 1,
                                        p: 8,
                                        dkLen: 32),
                       Vectors.data(hex: "cfc5f9af09819ae06de095f0f9b2e73d12ff7d3d39d7716842d2676a82f1b93a"))
    }

    func testScryptWalletCoreJSONImportPerformanceGate() throws {
        try Self.assertPerformanceGate("scrypt WalletCore JSON import KDF",
                                       thresholdEnv: PerformanceGateEnvironment.scryptWalletCoreJSONImport,
                                       baselineCeilingMilliseconds: WalletCoreBaselineCeilingMilliseconds.scryptWalletCoreJSONImport) {
            let derivedKey = Scrypt.deriveKey(password: Vectors.walletCoreJSONPrivateKeyPassword,
                                              salt: Vectors.data(hex: "ab0c7876052600dd703518d6fc3fe8984592145b591fc8fb5c6d43190334ba19"),
                                              n: 1 << 18,
                                              r: 1,
                                              p: 8,
                                              dkLen: 32)
            return derivedKey.count
        }
    }

    func testSecp256k1PublicKeyPerformanceGate() throws {
        try Self.assertPerformanceGate("secp256k1 public key derivation",
                                       thresholdEnv: PerformanceGateEnvironment.secp256k1PublicKey,
                                       baselineCeilingMilliseconds: WalletCoreBaselineCeilingMilliseconds.secp256k1PublicKey,
                                       iterations: 5) {
            Secp256k1.publicKey(privateKey: Vectors.secpPrivateKey, compressed: false)?.count ?? 0
        }
    }

    func testSecp256k1SigningPerformanceGate() throws {
        try Self.assertPerformanceGate("secp256k1 signing",
                                       thresholdEnv: PerformanceGateEnvironment.secp256k1Sign,
                                       baselineCeilingMilliseconds: WalletCoreBaselineCeilingMilliseconds.secp256k1Sign,
                                       iterations: 5) {
            Secp256k1.sign(digest: Vectors.ethereumRawSignDigest, privateKey: Vectors.secpPrivateKey)?.count ?? 0
        }
    }

    func testEd25519SigningPerformanceGate() throws {
        try Self.assertPerformanceGate("Ed25519 signing",
                                       thresholdEnv: PerformanceGateEnvironment.ed25519Sign,
                                       baselineCeilingMilliseconds: WalletCoreBaselineCeilingMilliseconds.ed25519Sign,
                                       iterations: 5) {
            Ed25519.sign(message: Vectors.solanaMessage, seed: Vectors.solanaSigningPrivateKey)?.count ?? 0
        }
    }

    private static func assertPerformanceGate(_ name: String,
                                              thresholdEnv: String,
                                              baselineCeilingMilliseconds: Double,
                                              iterations: Int = 1,
                                              file: StaticString = #filePath,
                                              line: UInt = #line,
                                              operation: () -> Int) throws {
        let environment = ProcessInfo.processInfo.environment
#if DEBUG
        guard environment[PerformanceGateEnvironment.allowDebug] == "1" else {
            throw XCTSkip("\(PerformanceGateEnvironment.allowDebug)=1 is required to run crypto performance gates in Debug.")
        }
#endif

        guard iterations > 0 else {
            XCTFail("\(name) performance gate must run at least one iteration", file: file, line: line)
            return
        }

        let thresholdMilliseconds: Double
        switch Self.performanceThreshold(name,
                                         thresholdEnv: thresholdEnv,
                                         baselineCeilingMilliseconds: baselineCeilingMilliseconds,
                                         environment: environment) {
        case .success(let milliseconds):
            thresholdMilliseconds = milliseconds
        case .skipped(let message):
            throw XCTSkip(message)
        case .failure(let message):
            XCTFail(message, file: file, line: line)
            return
        }

        var resultSum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            resultSum += operation()
        }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - start
        let averageMilliseconds = Double(elapsedNanoseconds) / 1_000_000.0 / Double(iterations)

        XCTAssertGreaterThan(resultSum, 0, "\(name) produced no result", file: file, line: line)
        XCTAssertLessThanOrEqual(averageMilliseconds,
                                 thresholdMilliseconds,
                                 "\(name) averaged \(averageMilliseconds)ms, above WalletCore baseline \(thresholdMilliseconds)ms",
                                 file: file,
                                 line: line)
    }

    private static func performanceThreshold(_ name: String,
                                             thresholdEnv: String,
                                             baselineCeilingMilliseconds: Double,
                                             environment: [String: String]) -> PerformanceThresholdResolution {
        guard baselineCeilingMilliseconds > 0 else {
            return .failure("\(name) WalletCore baseline sanity ceiling must be a positive millisecond value")
        }

        guard let rawBaseline = environment[thresholdEnv] else {
            return .skipped("\(thresholdEnv) is not configured for \(name)")
        }
        let trimmedBaseline = rawBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseline.isEmpty else {
            return .skipped("\(thresholdEnv) is not configured for \(name)")
        }

        guard let baselineMilliseconds = Double(trimmedBaseline), baselineMilliseconds > 0 else {
            return .failure("\(thresholdEnv) must be a positive millisecond value for \(name)")
        }

        guard baselineMilliseconds <= baselineCeilingMilliseconds else {
            return .failure("\(thresholdEnv)=\(baselineMilliseconds)ms is above the WalletCore baseline " +
                            "sanity ceiling \(baselineCeilingMilliseconds)ms for \(name)")
        }

        return .success(baselineMilliseconds)
    }

    private func assertPerformanceThresholdSkipped(_ resolution: PerformanceThresholdResolution,
                                                   contains expectedSubstring: String,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) {
        guard case .skipped(let message) = resolution else {
            XCTFail("Expected performance threshold skip, got \(resolution)", file: file, line: line)
            return
        }
        XCTAssertTrue(message.contains(expectedSubstring), "\(message) does not contain \(expectedSubstring)", file: file, line: line)
    }

    private func assertPerformanceThresholdFailure(_ resolution: PerformanceThresholdResolution,
                                                   contains expectedSubstring: String,
                                                   file: StaticString = #filePath,
                                                   line: UInt = #line) {
        guard case .failure(let message) = resolution else {
            XCTFail("Expected performance threshold failure, got \(resolution)", file: file, line: line)
            return
        }
        XCTAssertTrue(message.contains(expectedSubstring), "\(message) does not contain \(expectedSubstring)", file: file, line: line)
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

    func testHDWalletDerivesPinnedAccountChangeAndSolanaDefaultPaths() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)

        assertDerivedKey(wallet: wallet,
                         coin: .ethereum,
                         path: Vectors.abandonEthereumAccountOnePath,
                         expectedPrivateKey: Vectors.abandonEthereumAccountOnePrivateKey,
                         expectedPublicKey: Vectors.abandonEthereumAccountOnePublicKey,
                         expectedAddress: Vectors.abandonEthereumAccountOneAddress)
        assertDerivedKey(wallet: wallet,
                         coin: .ethereum,
                         path: Vectors.abandonEthereumChangeOneAddressNinePath,
                         expectedPrivateKey: Vectors.abandonEthereumChangeOneAddressNinePrivateKey,
                         expectedPublicKey: Vectors.abandonEthereumChangeOneAddressNinePublicKey,
                         expectedAddress: Vectors.abandonEthereumChangeOneAddressNineAddress)
        assertDerivedKey(wallet: wallet,
                         coin: .solana,
                         path: Vectors.abandonSolanaDefaultPath,
                         expectedPrivateKey: Vectors.abandonSolanaDefaultPrivateKey,
                         expectedPublicKey: Vectors.abandonSolanaDefaultPublicKey,
                         expectedAddress: Vectors.abandonSolanaDefaultAddress)
        assertDerivedKey(wallet: wallet,
                         coin: .solana,
                         path: Vectors.abandonSolanaHDVectors[0].path,
                         expectedPrivateKey: Vectors.abandonSolanaHDVectors[0].privateKey,
                         expectedPublicKey: Vectors.abandonSolanaHDVectors[0].publicKey,
                         expectedAddress: Vectors.abandonSolanaHDVectors[0].address)
        XCTAssertNotEqual(Vectors.abandonSolanaDefaultAddress, Vectors.abandonSolanaHDVectors[0].address)
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
        XCTAssertEqual(wallet.extendedPublicKeyAccount(coin: .ethereum, derivation: .default, account: 0x80000000), "")
        XCTAssertEqual(wallet.extendedPublicKeyAccount(coin: .ethereum, derivation: .default, account: UInt32.max), "")
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
        for malformedExtended in [
            "111111111111111111111111111111111111111111111111111111111111111111111111",
            String(Vectors.abandonEthereumExtendedPublicKey.dropLast()) + "1",
        ] {
            XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: malformedExtended,
                                                                       coin: .ethereum,
                                                                       derivationPath: firstPath),
                         malformedExtended)
            XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: malformedExtended,
                                                                   coin: .ethereum,
                                                                   derivation: .custom,
                                                                   derivationPath: firstPath),
                         malformedExtended)
        }
    }

    func testExtendedPublicKeyRejectsMalformedDerivationPathsBeforeWalletCore() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let invalidPaths = [
            "not a derivation path",
            "m/44'/60'/0'/0/not-number",
            "m/44'//0",
            "m/44'/60'/0'/0/-1",
            "m/44'/60'/0'/0/2147483648",
            "m/44'/60'/2147483648'/0/0",
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

    func testInvalidHDDerivationPathsReturnInertKeys() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let invalidEthereumKey = wallet.getKey(coin: .ethereum, derivationPath: "m/44'/60'/0'/0/2147483648")
        let invalidSolanaKey = wallet.getKey(coin: .solana, derivationPath: "m/44'/501'/2147483648'")

        invalidEthereumKey.withData { XCTAssertTrue($0.isEmpty) }
        invalidSolanaKey.withData { XCTAssertTrue($0.isEmpty) }
        XCTAssertTrue(invalidEthereumKey.publicKeyData(coin: .ethereum).isEmpty)
        XCTAssertTrue(invalidSolanaKey.publicKeyData(coin: .solana).isEmpty)
        XCTAssertEqual(invalidEthereumKey.publicKeyDescription(coin: .ethereum), "")
        XCTAssertEqual(invalidSolanaKey.publicKeyDescription(coin: .solana), "")
        XCTAssertNil(invalidEthereumKey.sign(digest: Vectors.ethereumRawSignDigest, coin: .ethereum))
        XCTAssertNil(invalidSolanaKey.sign(digest: Vectors.solanaMessage, coin: .solana))
        XCTAssertEqual(WalletCrypto.previewDerivationIndex(derivationPath: "m/44'/60'/0'/0/2147483648",
                                                           coin: .ethereum),
                       0)
    }

    func testExtendedPublicKeyRejectsOffCurveCompressedPublicKeys() throws {
        let invalidCompressedPublicKey = Data([0x02]) + Data(repeating: 0xff, count: 32)
        let invalidXpub = xpub(publicKey: invalidCompressedPublicKey)
        let path = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)

        XCTAssertNil(WalletCrypto.publicKeyDescriptionFromExtended(extended: invalidXpub,
                                                                   coin: .ethereum,
                                                                   derivationPath: path))
        XCTAssertNil(WalletCrypto.accountFromExtendedPublicKey(extended: invalidXpub,
                                                               coin: .ethereum,
                                                               derivation: .custom,
                                                               derivationPath: path))
    }

    func testEthereumExtendedPublicKeyPinsWalletCorePathMismatchQuirks() throws {
        let wallet = try requireHDWallet(mnemonic: Vectors.abandonMnemonic)
        let xpub = wallet.extendedPublicKey(coin: .ethereum)
        let firstPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)
        let mismatchedAccountPath = WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 1, change: 0, address: 0)
        let mismatchedCoinPath = "m/44'/501'/0'/0'"
        let hardenedChangeAndAddressPath = "m/44'/60'/0'/0'/0'"
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
        // WalletCore derives xpub children from raw change/address values only, so hardened
        // markers in those positions are accepted even though xpub derivation cannot honor them.
        XCTAssertEqual(WalletCrypto.publicKeyDescriptionFromExtended(extended: xpub,
                                                                     coin: .ethereum,
                                                                     derivationPath: hardenedChangeAndAddressPath),
                       firstPublicKey)
        XCTAssertEqual(WalletCrypto.accountFromExtendedPublicKey(extended: xpub,
                                                                 coin: .ethereum,
                                                                 derivation: .custom,
                                                                 derivationPath: hardenedChangeAndAddressPath)?.address,
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

    private func assertDerivedKey(wallet: WalletHDWallet,
                                  coin: WalletCoin,
                                  path: String,
                                  expectedPrivateKey: Data,
                                  expectedPublicKey: String,
                                  expectedAddress: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        let privateKey = wallet.getKey(coin: coin, derivationPath: path)
        privateKey.withData {
            XCTAssertEqual($0, expectedPrivateKey, file: file, line: line)
        }
        XCTAssertEqual(privateKey.publicKeyDescription(coin: coin), expectedPublicKey, file: file, line: line)
        XCTAssertEqual(WalletCrypto.addressFromPublicKeyDescription(expectedPublicKey, coin: coin),
                       expectedAddress,
                       file: file,
                       line: line)
    }

    private func xpub(publicKey: Data) -> String {
        return BIP32.serializeExtendedPublicKey(publicKey: publicKey,
                                                chainCode: Data(repeating: 0x11, count: 32),
                                                depth: 3,
                                                parentFingerprint: 0,
                                                childNumber: 0x80000000)
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

    func testImportsWalletCoreJSONTruncatesFractionalCoinAndDerivationNumbers() throws {
        let fixtureObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Vectors.walletCoreJSONPrivateKeyFixture) as? [String: Any])
        let expectedTopLevelAccount = WalletAccount(address: Vectors.walletCoreJSONPrivateKeyAddress,
                                                    coin: .solana,
                                                    derivation: .default,
                                                    derivationPath: "m/44'/501'/0'",
                                                    publicKey: "",
                                                    extendedPublicKey: "")
        let expectedActiveAccount = WalletAccount(address: Vectors.walletCoreJSONPrivateKeyAddress,
                                                  coin: .ethereum,
                                                  derivation: .solanaSolana,
                                                  derivationPath: "m/44'/501'/0'/0/0",
                                                  publicKey: "",
                                                  extendedPublicKey: "")

        var topLevelObject = fixtureObject
        topLevelObject["coin"] = NSNumber(value: 501.9)
        let topLevelJSON = try JSONSerialization.data(withJSONObject: topLevelObject, options: [.sortedKeys])
        let topLevelKey = try XCTUnwrap(WalletStoredKey.importJSON(json: topLevelJSON))

        XCTAssertEqual(topLevelKey.accountCount, 1)
        XCTAssertEqual(topLevelKey.account(index: 0), expectedTopLevelAccount)
        XCTAssertEqual(topLevelKey.accountForCoin(coin: .solana, wallet: nil), expectedTopLevelAccount)

        var activeAccountsObject = fixtureObject
        activeAccountsObject["activeAccounts"] = [
            [
                "address": Vectors.walletCoreJSONPrivateKeyAddress,
                "coin": NSNumber(value: 60.9),
                "derivation": NSNumber(value: 6.9),
                "derivationPath": "m/44'/501'/0'/0/0",
            ],
        ]
        let activeAccountsJSON = try JSONSerialization.data(withJSONObject: activeAccountsObject, options: [.sortedKeys])
        let activeAccountsKey = try XCTUnwrap(WalletStoredKey.importJSON(json: activeAccountsJSON))

        XCTAssertEqual(activeAccountsKey.accountCount, 1)
        XCTAssertEqual(activeAccountsKey.account(index: 0), expectedActiveAccount)
        XCTAssertEqual(activeAccountsKey.accountForCoin(coin: .ethereum, wallet: nil), expectedActiveAccount)
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
        let filledStoredAccount = WalletAccount(address: Vectors.walletCoreJSONMnemonicStoredEthereumAddress,
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
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), filledStoredAccount)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), storedAccount)

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
        let key = try XCTUnwrap(WalletStoredKey(name: "empty", password: Vectors.password))
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
        try assertExportedJSON(exportedJSON, doesNotLeak: [mnemonic])

        XCTAssertEqual(reimported.name, key.name)
        XCTAssertTrue(reimported.isMnemonic)
        XCTAssertEqual(reimported.accountCount, 0)
        XCTAssertEqual(reimported.decryptMnemonic(password: Vectors.password), mnemonic)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), decryptedPayload)
        XCTAssertNotNil(reimported.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertNil(reimported.decryptMnemonic(password: Vectors.wrongPassword))
    }

    func testMnemonicPrivateKeyLookupAddsDefaultAccountWhenStoredPathIsMalformed() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let invalidPath = "m/44'/60'/0'/0/2147483648"
        let invalidAccount = WalletAccount(address: Vectors.secpEthereumAddress,
                                           coin: .ethereum,
                                           derivation: .custom,
                                           derivationPath: invalidPath,
                                           publicKey: "",
                                           extendedPublicKey: "")
        let expectedDefaultAccount = WalletAccount(address: Vectors.multiAccountEthereumAddress,
                                                   coin: .ethereum,
                                                   derivation: .default,
                                                   derivationPath: "m/44'/60'/0'/0/0",
                                                   publicKey: Vectors.multiAccountEthereumPublicKey,
                                                   extendedPublicKey: "")

        key.removeAccountForCoin(coin: .ethereum)
        key.addAccountDerivation(address: invalidAccount.address,
                                 coin: invalidAccount.coin,
                                 derivation: invalidAccount.derivation,
                                 derivationPath: invalidAccount.derivationPath,
                                 publicKey: invalidAccount.publicKey,
                                 extendedPublicKey: invalidAccount.extendedPublicKey)

        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), invalidAccount)
        let privateKey = try XCTUnwrap(key.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertEqual(privateKey.publicKeyDescription(coin: .ethereum), Vectors.multiAccountEthereumPublicKey)
        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 0), invalidAccount)
        XCTAssertEqual(key.account(index: 1), expectedDefaultAccount)

        let container = WalletContainer(id: "malformed-path", key: key)
        XCTAssertThrowsError(try container.privateKey(password: "password", account: invalidAccount))
    }

    func testMnemonicPrivateKeyLookupUsesMatchedStoredPathEvenWhenMalformed() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let expectedDefaultAccount = try XCTUnwrap(key.account(index: 0))
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let invalidPath = "m/44'/60'/0'/0/2147483648"
        let invalidAccount = WalletAccount(address: expectedDefaultAccount.address,
                                           coin: .ethereum,
                                           derivation: .default,
                                           derivationPath: invalidPath,
                                           publicKey: "",
                                           extendedPublicKey: "")

        key.removeAccountForCoin(coin: .ethereum)
        key.addAccountDerivation(address: invalidAccount.address,
                                 coin: invalidAccount.coin,
                                 derivation: invalidAccount.derivation,
                                 derivationPath: invalidAccount.derivationPath,
                                 publicKey: invalidAccount.publicKey,
                                 extendedPublicKey: invalidAccount.extendedPublicKey)

        XCTAssertEqual(key.accountForCoinDerivation(coin: .ethereum, derivation: .default, wallet: wallet),
                       invalidAccount)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), invalidAccount)
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.password))
        XCTAssertEqual(key.accountCount, 1)
    }

    func testMnemonicAccountLookupFillsMissingAddressWithoutMutatingStoredAccount() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let expectedDefaultAccount = try XCTUnwrap(key.account(index: 0))
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let missingAddressAccount = WalletAccount(address: "",
                                                  coin: .ethereum,
                                                  derivation: .default,
                                                  derivationPath: expectedDefaultAccount.derivationPath,
                                                  publicKey: expectedDefaultAccount.publicKey,
                                                  extendedPublicKey: "")

        key.removeAccountForCoin(coin: .ethereum)
        key.addAccountDerivation(address: missingAddressAccount.address,
                                 coin: missingAddressAccount.coin,
                                 derivation: missingAddressAccount.derivation,
                                 derivationPath: missingAddressAccount.derivationPath,
                                 publicKey: missingAddressAccount.publicKey,
                                 extendedPublicKey: missingAddressAccount.extendedPublicKey)

        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), missingAddressAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: wallet), expectedDefaultAccount)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertEqual(key.account(index: 0), missingAddressAccount)
    }

    func testStoredKeyAccountIndexBoundsReturnNil() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)

        XCTAssertEqual(key.accountCount, 1)
        XCTAssertNotNil(key.account(index: 0))
        XCTAssertNil(key.account(index: -1))
        XCTAssertNil(key.account(index: key.accountCount))
        XCTAssertNil(key.account(index: Int.max))
    }

    func testStoredKeysRoundTripEmptyPasswords() throws {
        let privateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: Vectors.secpPrivateKey,
                                                                        name: "empty-private-password",
                                                                        password: Data(),
                                                                        coin: .ethereum))
        let privateKeyJSON = try XCTUnwrap(privateKey.exportJSON())
        let reimportedPrivateKey = try XCTUnwrap(WalletStoredKey.importJSON(json: privateKeyJSON))

        try assertExportedJSON(privateKeyJSON, doesNotLeak: [WalletCrypto.hexString(Vectors.secpPrivateKey)])
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

        try assertExportedJSON(mnemonicJSON, doesNotLeak: [Vectors.multiAccountMnemonic])
        XCTAssertEqual(mnemonicKey.decryptMnemonic(password: Data()), Vectors.multiAccountMnemonic)
        XCTAssertNil(mnemonicKey.decryptMnemonic(password: Vectors.password))
        XCTAssertEqual(reimportedMnemonicKey.decryptMnemonic(password: Data()), Vectors.multiAccountMnemonic)
        XCTAssertNil(reimportedMnemonicKey.wallet(password: Vectors.password))
        XCTAssertEqual(solanaAccount.derivationPath, "m/44'/501'/0'")
        XCTAssertEqual(reimportedMnemonicKey.accountForCoin(coin: .solana, wallet: wallet), solanaAccount)
        XCTAssertEqual(reimportedMnemonicKey.accountCount, 1)
    }

    func testGeneratedStoredKeysUseFreshMnemonicEntropy() throws {
        let firstKey = try XCTUnwrap(WalletStoredKey(name: "generated", password: Vectors.password))
        let secondKey = try XCTUnwrap(WalletStoredKey(name: "generated", password: Vectors.password))
        let firstMnemonic = try XCTUnwrap(firstKey.decryptMnemonic(password: Vectors.password))
        let secondMnemonic = try XCTUnwrap(secondKey.decryptMnemonic(password: Vectors.password))
        let firstPayload = try XCTUnwrap(firstKey.decryptPrivateKey(password: Vectors.password))
        let secondPayload = try XCTUnwrap(secondKey.decryptPrivateKey(password: Vectors.password))
        let firstJSON = try XCTUnwrap(firstKey.exportJSON())
        let secondJSON = try XCTUnwrap(secondKey.exportJSON())
        let firstReimported = try XCTUnwrap(WalletStoredKey.importJSON(json: firstJSON))
        let secondReimported = try XCTUnwrap(WalletStoredKey.importJSON(json: secondJSON))

        try assertExportedJSON(firstJSON, doesNotLeak: [firstMnemonic])
        try assertExportedJSON(secondJSON, doesNotLeak: [secondMnemonic])
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
        let key = try XCTUnwrap(WalletStoredKey(name: "generated", password: Vectors.password))
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
        try assertExportedJSON(exportedJSON, doesNotLeak: [Vectors.multiAccountMnemonic])

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
        try assertCorruptedMnemonicJSONIsNotUsable(replacing: "\"cipher\": \"aes-128-ctr\"",
                                                   with: "\"cipher\": \"aes-192-ctr\"")
        try assertCorruptedMnemonicJSONIsNotUsable(replacing: "3f6401e478074fc9c50a69dd88ea21baca70dd8064d8590b64f64b64d493e6e50bb6ff5ffc6aabcaac18c4aad25f29c53fe1029f8d6fa4ed24fc99938f27e38bea0b0cd7f8215f38d2526c655bff0b8f1638e948d8c1b9bdaa95ab0b",
                                                   with: "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
        try assertCorruptedMnemonicJSONIsNotUsable(replacing: "67a8bf187bdeec076ac1e3647914e20b1dcbb15a5cb4643e6047fc2a07694055",
                                                   with: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    }

    func testStoredKeyImportRejectsUnsafeKDFParameters() throws {
        let scryptFixture = try XCTUnwrap(String(data: Vectors.walletCoreJSONPrivateKeyFixture, encoding: .utf8))
        let pbkdf2Fixture = try XCTUnwrap(String(data: Vectors.walletCoreJSONVariantPrivateKeyFixtures[0].json, encoding: .utf8))

        let mutations = [
            (fixture: scryptFixture, target: #""p": 8"#, replacement: #""p": 9"#),
            (fixture: scryptFixture, target: #""n": 262144"#, replacement: #""n": 262145"#),
            (fixture: pbkdf2Fixture, target: #""c": 1024"#, replacement: #""c": 0"#),
            (fixture: pbkdf2Fixture, target: #""dklen": 32"#, replacement: #""dklen": 0"#),
            (fixture: pbkdf2Fixture, target: #""prf": "hmac-sha256""#, replacement: #""prf": "hmac-sha512""#),
            (fixture: pbkdf2Fixture, target: #""cipher": "aes-128-ctr""#, replacement: #""cipher": "aes-512-ctr""#),
        ]
        for mutation in mutations {
            let json = mutation.fixture.replacingOccurrences(of: mutation.target, with: mutation.replacement)
            XCTAssertNil(WalletStoredKey.importJSON(json: Data(json.utf8)))
        }
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
        try assertStoredSolanaPrivateKeyImport(privateKeyData: Vectors.upstreamSolanaPrivateKey,
                                               expectedPublicKey: Vectors.upstreamSolanaPublicKey,
                                               expectedAddress: Vectors.upstreamSolanaAddress)
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
        XCTAssertNil(key.privateKey(coin: .solana, password: Vectors.password))
        try assertExportedJSON(exportedJSON, doesNotLeak: [WalletCrypto.hexString(Vectors.secpPrivateKey)])

        var explicitUnknownTypeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedJSON) as? [String: Any])
        explicitUnknownTypeObject["type"] = "hardware"
        let explicitUnknownTypeJSON = try JSONSerialization.data(withJSONObject: explicitUnknownTypeObject, options: [.sortedKeys])
        let explicitUnknownTypeKey = try XCTUnwrap(WalletStoredKey.importJSON(json: explicitUnknownTypeJSON))

        XCTAssertFalse(explicitUnknownTypeKey.isMnemonic)
        XCTAssertEqual(explicitUnknownTypeKey.account(index: 0), expectedAccount)
        XCTAssertNotNil(explicitUnknownTypeKey.privateKey(coin: .ethereum, password: Vectors.password))

        XCTAssertEqual(reimported.accountCount, key.accountCount)
        XCTAssertEqual(reimported.account(index: 0), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .ethereum, wallet: nil), expectedAccount)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), Vectors.secpPrivateKey)
        XCTAssertNil(reimported.privateKey(coin: .solana, password: Vectors.password))
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
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.password))
        try assertExportedJSON(exportedJSON, doesNotLeak: [WalletCrypto.hexString(Vectors.solanaAddressPrivateKey)])

        XCTAssertEqual(reimported.accountCount, key.accountCount)
        XCTAssertEqual(reimported.account(index: 0), expectedAccount)
        XCTAssertEqual(reimported.accountForCoin(coin: .solana, wallet: nil), expectedAccount)
        XCTAssertEqual(reimported.decryptPrivateKey(password: Vectors.password), Vectors.solanaAddressPrivateKey)
        XCTAssertNil(reimported.privateKey(coin: .ethereum, password: Vectors.password))
    }

    func testStoredKeyRoundTripsLongPasswordsForPrivateKeyAndMnemonicImports() throws {
        let privateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: Vectors.secpPrivateKey,
                                                                        name: "long-private",
                                                                        password: Vectors.longPassword,
                                                                        coin: .ethereum))
        let privateKeyJSON = try XCTUnwrap(privateKey.exportJSON())
        let reimportedPrivateKey = try XCTUnwrap(WalletStoredKey.importJSON(json: privateKeyJSON))

        try assertExportedJSON(privateKeyJSON, doesNotLeak: [WalletCrypto.hexString(Vectors.secpPrivateKey)])
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

        try assertExportedJSON(mnemonicJSON, doesNotLeak: [Vectors.multiAccountMnemonic])
        XCTAssertEqual(mnemonicKey.decryptMnemonic(password: Vectors.longPassword), Vectors.multiAccountMnemonic)
        XCTAssertEqual(mnemonicKey.decryptPrivateKey(password: Vectors.longPassword), Data(Vectors.multiAccountMnemonic.utf8))
        XCTAssertNil(mnemonicKey.decryptMnemonic(password: Vectors.password))
        XCTAssertEqual(reimportedMnemonicKey.decryptMnemonic(password: Vectors.longPassword), Vectors.multiAccountMnemonic)
        XCTAssertNil(reimportedMnemonicKey.wallet(password: Vectors.password))
    }

    func testReencryptedStoredKeysUseExportScryptDefaults() throws {
        let originalPrivateKey = try requireStoredPrivateKey(privateKey: Vectors.secpPrivateKey, coin: .ethereum)
        let privateKeyPayload = try XCTUnwrap(originalPrivateKey.decryptPrivateKey(password: Vectors.password))
        let reencryptedPrivateKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: privateKeyPayload,
                                                                                   name: "renamed-private",
                                                                                   password: Vectors.longPassword,
                                                                                   coin: .ethereum))
        let reencryptedPrivateKeyJSON = try XCTUnwrap(reencryptedPrivateKey.exportJSON())

        try assertExportedJSON(reencryptedPrivateKeyJSON,
                               doesNotLeak: [WalletCrypto.hexString(Vectors.secpPrivateKey)])
        XCTAssertEqual(reencryptedPrivateKey.name, "renamed-private")
        XCTAssertEqual(reencryptedPrivateKey.decryptPrivateKey(password: Vectors.longPassword), Vectors.secpPrivateKey)
        XCTAssertNil(reencryptedPrivateKey.decryptPrivateKey(password: Vectors.password))

        let originalMnemonicKey = try requireStoredMnemonicKey(coin: .ethereum)
        let mnemonic = try XCTUnwrap(originalMnemonicKey.decryptMnemonic(password: Vectors.password))
        let reencryptedMnemonicKey = try XCTUnwrap(WalletStoredKey.importHDWallet(mnemonic: mnemonic,
                                                                                  name: "renamed-mnemonic",
                                                                                  password: Vectors.longPassword,
                                                                                  coin: .ethereum))
        let reencryptedMnemonicJSON = try XCTUnwrap(reencryptedMnemonicKey.exportJSON())

        try assertExportedJSON(reencryptedMnemonicJSON, doesNotLeak: [mnemonic])
        XCTAssertEqual(reencryptedMnemonicKey.name, "renamed-mnemonic")
        XCTAssertEqual(reencryptedMnemonicKey.decryptMnemonic(password: Vectors.longPassword), mnemonic)
        XCTAssertNil(reencryptedMnemonicKey.decryptMnemonic(password: Vectors.password))
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
        try assertExportedJSON(exportedJSON, doesNotLeak: [Vectors.multiAccountMnemonic])

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
        let defaultPrivateKey = try XCTUnwrap(key.privateKey(coin: .solana, password: Vectors.password))
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
        try assertExportedJSON(exportedJSON, doesNotLeak: [Vectors.multiAccountMnemonic])

        XCTAssertEqual(defaultAccount.address, "HiipoCKL8hX2RVmJTz3vaLy34hS2zLhWWMkUWtw85TmZ")
        XCTAssertEqual(defaultAccount.derivation, .default)
        XCTAssertEqual(defaultAccount.derivationPath, "m/44'/501'/0'")
        XCTAssertEqual(solanaAccount.address, "CgWJeEWkiYqosy1ba7a3wn9HAQuHyK48xs3LM4SSDc1C")
        XCTAssertEqual(solanaAccount.derivation, .solanaSolana)
        XCTAssertEqual(solanaAccount.derivationPath, "m/44'/501'/0'/0'")
        XCTAssertEqual(defaultPrivateKey.publicKeyDescription(coin: .solana), defaultAccount.publicKey)
        XCTAssertNotEqual(defaultPrivateKey.publicKeyDescription(coin: .solana), solanaAccount.publicKey)
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

    func testLegacyMatchingAccountIsEnrichedWithoutDuplicating() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let expectedAccount = try XCTUnwrap(key.account(index: 0))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedJSON) as? [String: Any])
        var activeAccounts = try XCTUnwrap(object["activeAccounts"] as? [[String: Any]])

        activeAccounts[0].removeValue(forKey: "publicKey")
        activeAccounts[0].removeValue(forKey: "extendedPublicKey")
        object["activeAccounts"] = activeAccounts

        let legacyJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let imported = try XCTUnwrap(WalletStoredKey.importJSON(json: legacyJSON))
        let legacyAccount = try XCTUnwrap(imported.account(index: 0))
        let wallet = try XCTUnwrap(imported.wallet(password: Vectors.password))

        XCTAssertEqual(imported.accountCount, 1)
        XCTAssertEqual(legacyAccount.address, expectedAccount.address)
        XCTAssertEqual(legacyAccount.publicKey, "")
        XCTAssertEqual(imported.accountForCoin(coin: .ethereum, wallet: nil), legacyAccount)

        let enrichedAccount = try XCTUnwrap(imported.accountForCoin(coin: .ethereum, wallet: wallet))

        XCTAssertEqual(enrichedAccount, expectedAccount)
        XCTAssertEqual(imported.accountCount, 1)
        XCTAssertEqual(imported.account(index: 0), legacyAccount)
        XCTAssertEqual(imported.accountForCoinDerivation(coin: .ethereum, derivation: .default, wallet: wallet),
                       expectedAccount)
        XCTAssertEqual(imported.accountCount, 1)
        XCTAssertEqual(imported.account(index: 0), legacyAccount)
    }

    func testLegacyMatchingAccountWithConflictingPublicKeyKeepsStoredAccountByAddress() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let expectedAccount = try XCTUnwrap(key.account(index: 0))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedJSON) as? [String: Any])
        var activeAccounts = try XCTUnwrap(object["activeAccounts"] as? [[String: Any]])

        activeAccounts[0]["publicKey"] = Vectors.secpPublicKey
        activeAccounts[0].removeValue(forKey: "extendedPublicKey")
        object["activeAccounts"] = activeAccounts

        let legacyJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let imported = try XCTUnwrap(WalletStoredKey.importJSON(json: legacyJSON))
        let legacyAccount = try XCTUnwrap(imported.account(index: 0))
        let wallet = try XCTUnwrap(imported.wallet(password: Vectors.password))

        XCTAssertEqual(imported.accountCount, 1)
        XCTAssertEqual(legacyAccount.address, expectedAccount.address)
        XCTAssertEqual(legacyAccount.publicKey, Vectors.secpPublicKey)

        let matchedAccount = try XCTUnwrap(imported.accountForCoin(coin: .ethereum, wallet: wallet))

        XCTAssertEqual(matchedAccount, legacyAccount)
        XCTAssertEqual(imported.accountCount, 1)
        XCTAssertEqual(imported.account(index: 0), legacyAccount)
        XCTAssertEqual(imported.accountForCoinDerivation(coin: .ethereum, derivation: .default, wallet: wallet),
                       legacyAccount)
        XCTAssertEqual(imported.accountCount, 1)
    }

    func testLegacySolanaSolanaAccountWithMissingDerivationMatchesByAddressWithoutMutating() throws {
        let key = try requireStoredMnemonicKey(coin: .solana)
        let wallet = try XCTUnwrap(key.wallet(password: Vectors.password))
        let defaultAccount = try XCTUnwrap(key.accountForCoin(coin: .solana, wallet: wallet))
        let solanaAccount = try XCTUnwrap(key.accountForCoinDerivation(coin: .solana,
                                                                        derivation: .solanaSolana,
                                                                        wallet: wallet))
        let exportedJSON = try XCTUnwrap(key.exportJSON())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedJSON) as? [String: Any])
        var activeAccounts = try XCTUnwrap(object["activeAccounts"] as? [[String: Any]])
        activeAccounts[1].removeValue(forKey: "derivation")
        activeAccounts[1].removeValue(forKey: "publicKey")
        activeAccounts[1].removeValue(forKey: "extendedPublicKey")
        object["activeAccounts"] = activeAccounts

        let legacyJSON = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let imported = try XCTUnwrap(WalletStoredKey.importJSON(json: legacyJSON))
        let importedWallet = try XCTUnwrap(imported.wallet(password: Vectors.password))
        let storedSolanaAccount = WalletAccount(address: solanaAccount.address,
                                                coin: .solana,
                                                derivation: .default,
                                                derivationPath: solanaAccount.derivationPath,
                                                publicKey: "",
                                                extendedPublicKey: "")
        let filledSolanaAccount = WalletAccount(address: solanaAccount.address,
                                                coin: .solana,
                                                derivation: .default,
                                                derivationPath: solanaAccount.derivationPath,
                                                publicKey: solanaAccount.publicKey,
                                                extendedPublicKey: "")

        XCTAssertEqual(imported.accountCount, 2)
        XCTAssertEqual(imported.account(index: 0), defaultAccount)
        XCTAssertEqual(imported.account(index: 1), storedSolanaAccount)
        XCTAssertEqual(imported.accountForCoinDerivation(coin: .solana,
                                                         derivation: .solanaSolana,
                                                         wallet: importedWallet),
                       filledSolanaAccount)
        XCTAssertEqual(imported.accountCount, 2)
        XCTAssertEqual(imported.account(index: 1), storedSolanaAccount)
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

    func testManualCustomAccountLookupAndRemoval() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let defaultAccount = try XCTUnwrap(key.accountForCoin(coin: .ethereum, wallet: nil))
        let customAccount = WalletAccount(address: Vectors.abandonEthereumChangeOneAddressNineAddress,
                                          coin: .ethereum,
                                          derivation: .custom,
                                          derivationPath: Vectors.abandonEthereumChangeOneAddressNinePath,
                                          publicKey: Vectors.abandonEthereumChangeOneAddressNinePublicKey,
                                          extendedPublicKey: Vectors.abandonEthereumExtendedPublicKey)

        key.addAccountDerivation(address: customAccount.address,
                                 coin: customAccount.coin,
                                 derivation: customAccount.derivation,
                                 derivationPath: customAccount.derivationPath,
                                 publicKey: customAccount.publicKey,
                                 extendedPublicKey: customAccount.extendedPublicKey)

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 0), defaultAccount)
        XCTAssertEqual(key.account(index: 1), customAccount)
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), defaultAccount)
        XCTAssertNil(key.accountForCoinDerivation(coin: .ethereum, derivation: .custom, wallet: nil))

        key.removeAccountForCoinDerivationPath(coin: .ethereum, derivationPath: customAccount.derivationPath)
        XCTAssertEqual(key.accountCount, 1)
        XCTAssertNil(key.accountForCoinDerivation(coin: .ethereum, derivation: .custom, wallet: nil))
        XCTAssertEqual(key.accountForCoin(coin: .ethereum, wallet: nil), defaultAccount)
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

    func testSupportedCoinUnknownDerivationMapsToCustom() throws {
        let key = try requireStoredMnemonicKey(coin: .ethereum)
        let rawAccount = WalletRawAccountForTesting(address: Vectors.secpEthereumAddress,
                                                    coinRawValue: WalletCoin.ethereum.rawValue,
                                                    derivationRawValue: 5,
                                                    derivationPath: "m/44'/60'/0'/0/9",
                                                    publicKey: Vectors.secpPublicKey,
                                                    extendedPublicKey: "xpub-custom-ethereum")
        let expectedAccount = WalletAccount(address: rawAccount.address,
                                            coin: .ethereum,
                                            derivation: .custom,
                                            derivationPath: rawAccount.derivationPath,
                                            publicKey: rawAccount.publicKey,
                                            extendedPublicKey: rawAccount.extendedPublicKey)

        key.addUnsupportedAccountForTesting(rawAccount)

        XCTAssertEqual(key.accountCount, 2)
        XCTAssertEqual(key.account(index: 1), expectedAccount)
        XCTAssertNil(key.accountForCoinDerivation(coin: .ethereum, derivation: .custom, wallet: nil))
        XCTAssertEqual(key.rawAccountForTesting(index: 1), rawAccount)
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

    private func assertCorruptedMnemonicJSONIsNotUsable(replacing target: String,
                                                        with replacement: String,
                                                        file: StaticString = #filePath,
                                                        line: UInt = #line) throws {
        let fixture = try XCTUnwrap(String(data: Vectors.walletCoreJSONMnemonicFixture, encoding: .utf8),
                                    file: file,
                                    line: line)
        let json = Data(fixture.replacingOccurrences(of: target, with: replacement).utf8)
        guard let key = WalletStoredKey.importJSON(json: json) else { return }

        XCTAssertNil(key.decryptMnemonic(password: Vectors.walletCoreJSONMnemonicPassword), file: file, line: line)
        XCTAssertNil(key.decryptPrivateKey(password: Vectors.walletCoreJSONMnemonicPassword), file: file, line: line)
        XCTAssertNil(key.wallet(password: Vectors.walletCoreJSONMnemonicPassword), file: file, line: line)
        XCTAssertNil(key.privateKey(coin: .ethereum, password: Vectors.walletCoreJSONMnemonicPassword), file: file, line: line)
    }

    private func assertExportedJSON(_ json: Data,
                                    doesNotLeak forbiddenValues: [String],
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let jsonString = try XCTUnwrap(String(data: json, encoding: .utf8), file: file, line: line)
        let jsonObject = try JSONSerialization.jsonObject(with: json)
        let topLevel = try XCTUnwrap(jsonObject as? [String: Any], file: file, line: line)
        let crypto = try XCTUnwrap(topLevel["crypto"] as? [String: Any], file: file, line: line)
        let kdfParams = try XCTUnwrap(crypto["kdfparams"] as? [String: Any], file: file, line: line)

        XCTAssertEqual(topLevel["version"] as? Int, 3, file: file, line: line)
        XCTAssertEqual(crypto["kdf"] as? String, "scrypt", file: file, line: line)
        XCTAssertEqual(kdfParams["n"] as? Int, 1 << 14, file: file, line: line)
        XCTAssertEqual(kdfParams["r"] as? Int, 8, file: file, line: line)
        XCTAssertEqual(kdfParams["p"] as? Int, 4, file: file, line: line)
        XCTAssertEqual(kdfParams["dklen"] as? Int, 32, file: file, line: line)
        for forbiddenValue in forbiddenValues where !forbiddenValue.isEmpty {
            XCTAssertFalse(jsonString.contains(forbiddenValue),
                           "Exported JSON leaked \(forbiddenValue)",
                           file: file,
                           line: line)
        }
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
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.typedDataMinifiedJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.typedDataReorderedJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.decimalStringChainIDTypedDataJSON)),
                       Vectors.typedDataDigest)
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.hexStringChainIDTypedDataJSON)),
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
        XCTAssertNotEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.int64MinTypedDataJSON),
                          Data())
        XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.uint8OverflowTypedDataJSON),
                       Data())
        XCTAssertEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.int8UnderflowTypedDataJSON),
                       Data())
        XCTAssertNotEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.negativeZeroTypedDataJSON),
                          Data())
        XCTAssertEqual(WalletCrypto.hexString(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.shortFixedBytesTypedDataJSON)),
                       Vectors.shortFixedBytesTypedDataDigest,
                       "WalletCore accepts undersized odd-length EIP-712 bytesN values")
        XCTAssertNotEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.fixedArrayTypedDataJSON),
                          Data())
        XCTAssertNotEqual(WalletCrypto.ethereumTypedDataDigest(messageJson: Vectors.cyclicArrayTypedDataJSON),
                          Data())
    }

    func testTypedDataSigningRejectsMalformedShapesAndOutOfRangeIntegersAndAcceptsStringChainIDs() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumSignerPrivateKey)

        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.decimalStringChainIDTypedDataJSON, privateKey: privateKey),
                       Vectors.ethereumTypedDataSignature)
        XCTAssertEqual(try Ethereum.shared.sign(typedData: Vectors.hexStringChainIDTypedDataJSON, privateKey: privateKey),
                       Vectors.ethereumTypedDataSignature)
        XCTAssertNoThrow(try Ethereum.shared.sign(typedData: Vectors.negativeZeroTypedDataJSON, privateKey: privateKey))
        XCTAssertNoThrow(try Ethereum.shared.sign(typedData: Vectors.shortFixedBytesTypedDataJSON, privateKey: privateKey),
                         "WalletCore accepts undersized odd-length EIP-712 bytesN values")
        for fixture in Vectors.invalidTypedDataJSONFixtures {
            XCTAssertThrowsError(try Ethereum.shared.sign(typedData: fixture.json, privateKey: privateKey), fixture.name) {
                guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                    XCTFail("Expected failedToSign for \(fixture.name), got \($0)")
                    return
                }
            }
        }
        for fixture in [
            ("uint8 overflow", Vectors.uint8OverflowTypedDataJSON),
            ("int8 underflow", Vectors.int8UnderflowTypedDataJSON),
        ] {
            XCTAssertThrowsError(try Ethereum.shared.sign(typedData: fixture.1, privateKey: privateKey), fixture.0) {
                guard let error = $0 as? Ethereum.Error, case .failedToSign = error else {
                    XCTFail("Expected failedToSign for \(fixture.0), got \($0)")
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

        let controlStringABI = #"{"01020307":{"inputs":[{"name":"name","type":"string"}],"name":"setName"}}"#
        let controlStringCall = Vectors.data(hex: "01020307" +
                                             "0000000000000000000000000000000000000000000000000000000000000020" +
                                             "0000000000000000000000000000000000000000000000000000000000000006" +
                                             "610062080c1f" + String(repeating: "0", count: 52))
        let controlStringDecoded = #"{"function":"setName(string)","inputs":[{"name":"name","type":"string","value":"a\u0000b\b\f\u001f"}]}"#
        let decodedControlString = WalletCrypto.decodeEthereumCall(data: controlStringCall, abi: controlStringABI)
        XCTAssertEqual(decodedControlString, controlStringDecoded)
        let reparsedControlString = decodedControlString?.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0)
        }
        XCTAssertNotNil(reparsedControlString)

        let invalidUTF8StringABI = #"{"01020308":{"inputs":[{"name":"name","type":"string"}],"name":"setName"}}"#
        let invalidUTF8StringCall = Vectors.data(hex: "01020308" +
                                                 "0000000000000000000000000000000000000000000000000000000000000020" +
                                                 "0000000000000000000000000000000000000000000000000000000000000003" +
                                                 "61ff62" + String(repeating: "0", count: 58))
        let invalidUTF8StringDecoded = #"{"function":"setName(string)","inputs":[{"name":"name","type":"string","value":"a"# + "\u{fffd}" + #"b"}]}"#
        XCTAssertEqual(WalletCrypto.decodeEthereumCall(data: invalidUTF8StringCall, abi: invalidUTF8StringABI),
                       invalidUTF8StringDecoded)

        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Data(), abi: Vectors.abiJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "ffffffff"), abi: Vectors.abiJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f0027"), abi: Vectors.abiJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f002700"), abi: ",,"))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: Vectors.data(hex: "c47f002700"), abi: "{}"))

        let boolABI = #"{"01020304":{"inputs":[{"name":"flag","type":"bool"}],"name":"setFlag"}}"#
        let arrayABI = #"{"01020305":{"inputs":[{"name":"values","type":"uint256[abc]"}],"name":"badArray"}}"#
        let uint8ABI = #"{"01020306":{"inputs":[{"name":"small","type":"uint8"}],"name":"setSmall"}}"#
        let fixedBytesABI = #"{"01020309":{"inputs":[{"name":"tag","type":"bytes4"}],"name":"setTag"}}"#
        let malformedAddress = Vectors.data(hex: "a9059cbb" +
                                            "0000000000000000000000015322b34c88ed0691971bf52a7047448f0f4efc84" +
                                            "0000000000000000000000000000000000000000000000001bc16d674ec80000")
        let malformedBool = Vectors.data(hex: "01020304" + String(repeating: "0", count: 63) + "2")
        let malformedArray = Vectors.data(hex: "01020305" + String(repeating: "0", count: 64))
        let wideUint8 = Vectors.data(hex: "01020306" + String(repeating: "0", count: 60) + "0100")
        let fixedBytesWithNonZeroPadding = Vectors.data(hex: "01020309" +
                                                        "deadbeef" + String(repeating: "0", count: 54) + "01")
        let positiveInt8Overflow = Vectors.data(hex: "1234abcd" + String(repeating: "0", count: 62) + "80")
        let negativeInt8Underflow = Vectors.data(hex: "1234abcd" + String(repeating: "f", count: 62) + "7f")
        let hugeStringOffset = Vectors.data(hex: "c47f0027" +
                                            "0000000000000000000000000000000000000000000000007fffffffffffffff")

        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: malformedAddress, abi: Vectors.abiERC20TransferJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: malformedBool, abi: boolABI))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: malformedArray, abi: arrayABI))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: wideUint8, abi: uint8ABI))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: fixedBytesWithNonZeroPadding, abi: fixedBytesABI))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: positiveInt8Overflow, abi: Vectors.abiSignedIntegerJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: negativeInt8Underflow, abi: Vectors.abiSignedIntegerJSON))
        XCTAssertNil(WalletCrypto.decodeEthereumCall(data: hugeStringOffset, abi: Vectors.abiJSON))
    }

    func testSignLegacyERC20TransactionMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "09c7652400"),
            gasLimit: Vectors.data(hex: "0130b9"),
            toAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
            privateKey: privateKey,
            amount: Data(),
            data: Vectors.data(hex: "a9059cbb0000000000000000000000005322b34c88ed0691971bf52a7047448f0f4efc840000000000000000000000000000000000000000000000001bc16d674ec80000")
        ))
        let emptySendTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "01"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "0x0000000000000000000000000000000000000001",
            privateKey: privateKey,
            amount: Data(),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedERC20Transaction)
        XCTAssertEqual(WalletCrypto.hexString(emptySendTransaction), Vectors.signedEmptySendTransaction)
        for invalidAddress in [
            "0x",
            "0xdeadbeef",
            "deadbeef",
            "0x000000000000000000000000000000000000000g",
            "0x00000000000000000000000000000000000000001",
        ] {
            XCTAssertNil(WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                              nonce: Data(),
                                                              gasPrice: Vectors.data(hex: "01"),
                                                              gasLimit: Vectors.data(hex: "5208"),
                                                              toAddress: invalidAddress,
                                                              privateKey: privateKey,
                                                              amount: Data(),
                                                              data: Data()),
                         invalidAddress)
        }
    }

    func testSignLegacyTransactionPinsDataAndAlternateChainIDVectors() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let dataOnlyTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "09c7652400"),
            gasLimit: Vectors.data(hex: "0130b9"),
            toAddress: "0x6b175474e89094c44da98b954eedeac495271d0f",
            privateKey: privateKey,
            amount: Data(),
            data: Vectors.data(hex: "deadbeef")
        ))
        let mixedCaseDataOnlyTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "09c7652400"),
            gasLimit: Vectors.data(hex: "0130b9"),
            toAddress: "0x6B175474E89094C44Da98b954EedeAC495271d0F",
            privateKey: privateKey,
            amount: Data(),
            data: Vectors.data(hex: "deadbeef")
        ))
        let alternateChainIDTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "03"),
            nonce: Vectors.data(hex: "06"),
            gasPrice: Vectors.data(hex: "04a817c800"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "0x3535353535353535353535353535353535353535",
            privateKey: privateKey,
            amount: Vectors.data(hex: "01"),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(dataOnlyTransaction), Vectors.signedDataOnlyTransaction)
        XCTAssertEqual(WalletCrypto.hexString(mixedCaseDataOnlyTransaction), Vectors.signedDataOnlyTransaction)
        XCTAssertEqual(WalletCrypto.hexString(alternateChainIDTransaction), Vectors.signedChainThreeOneWeiTransaction)
    }

    func testSignLegacyContractCreationTransactionMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "01"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "",
            privateKey: privateKey,
            amount: Data(),
            data: Vectors.data(hex: "6001600055")
        ))

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedContractCreationTransaction)
    }

    func testSignLegacyTransactionPinsMultiByteChainIDVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "2105"),
            nonce: Vectors.data(hex: "06"),
            gasPrice: Vectors.data(hex: "04a817c800"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "0x3535353535353535353535353535353535353535",
            privateKey: privateKey,
            amount: Vectors.data(hex: "01"),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedBaseChainOneWeiTransaction)
    }

    func testSignLegacyTransactionNormalizesLeadingZeroQuantityFields() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let leadingZeroEmptySend = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "0001"),
            nonce: Vectors.data(hex: "00"),
            gasPrice: Vectors.data(hex: "0001"),
            gasLimit: Vectors.data(hex: "005208"),
            toAddress: "0x0000000000000000000000000000000000000001",
            privateKey: privateKey,
            amount: Vectors.data(hex: "0000"),
            data: Data()
        ))
        let leadingZeroOneWei = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "0001"),
            nonce: Vectors.data(hex: "00"),
            gasPrice: Vectors.data(hex: "0001"),
            gasLimit: Vectors.data(hex: "005208"),
            toAddress: "0x0000000000000000000000000000000000000001",
            privateKey: privateKey,
            amount: Vectors.data(hex: "0001"),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(leadingZeroEmptySend), Vectors.signedEmptySendTransaction)
        XCTAssertEqual(WalletCrypto.hexString(leadingZeroOneWei), Vectors.signedOneWeiTransaction)
    }

    func testSignLegacyTransactionPinsEmptyChainIDWalletCoreBehavior() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)
        let signedTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Data(),
            nonce: Data(),
            gasPrice: Vectors.data(hex: "01"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "0x0000000000000000000000000000000000000001",
            privateKey: privateKey,
            amount: Data(),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedEmptyChainIDTransaction)
    }

    func testSignLegacyNativeTransferMatchesWalletCoreVector() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumNativeTransferPrivateKey)
        let signedTransaction = try XCTUnwrap(WalletCrypto.signEthereumTransaction(
            chainID: Vectors.data(hex: "01"),
            nonce: Vectors.data(hex: "09"),
            gasPrice: Vectors.data(hex: "04a817c800"),
            gasLimit: Vectors.data(hex: "5208"),
            toAddress: "0x3535353535353535353535353535353535353535",
            privateKey: privateKey,
            amount: Vectors.data(hex: "0de0b6b3a7640000"),
            data: Data()
        ))

        XCTAssertEqual(WalletCrypto.hexString(signedTransaction), Vectors.signedNativeTransferTransaction)
    }

    func testSignLegacyTransactionAmountBoundaryCases() throws {
        let privateKey = try requirePrivateKey(Vectors.ethereumTransactionPrivateKey)

        func signAmount(_ amount: Data) throws -> Data {
            return try XCTUnwrap(WalletCrypto.signEthereumTransaction(chainID: Vectors.data(hex: "01"),
                                                                     nonce: Data(),
                                                                     gasPrice: Vectors.data(hex: "01"),
                                                                     gasLimit: Vectors.data(hex: "5208"),
                                                                     toAddress: "0x0000000000000000000000000000000000000001",
                                                                     privateKey: privateKey,
                                                                     amount: amount,
                                                                     data: Data()))
        }

        let emptyAmountTransaction = try signAmount(Data())
        let zeroAmountTransaction = try signAmount(Vectors.data(hex: "00"))
        let oneWeiTransaction = try signAmount(Vectors.data(hex: "01"))
        let leadingZeroOneWeiTransaction = try signAmount(Vectors.data(hex: "0001"))
        let maxAmountTransaction = try signAmount(Data(repeating: 0xff, count: 32))

        XCTAssertEqual(WalletCrypto.hexString(emptyAmountTransaction), Vectors.signedEmptySendTransaction)
        XCTAssertEqual(zeroAmountTransaction, emptyAmountTransaction)
        XCTAssertEqual(WalletCrypto.hexString(oneWeiTransaction), Vectors.signedOneWeiTransaction)
        XCTAssertEqual(leadingZeroOneWeiTransaction, oneWeiTransaction)
        XCTAssertEqual(WalletCrypto.hexString(maxAmountTransaction), Vectors.signedMaxAmountTransaction)
    }

    func testLegacyTransactionSignatureVRejectsUnsupportedRecoveryIDs() {
        XCTAssertEqual(EthereumTransactionSigner.legacySignatureV(chainID: Data(), recovery: 0), Data([27]))
        XCTAssertEqual(EthereumTransactionSigner.legacySignatureV(chainID: Data(), recovery: 1), Data([28]))
        XCTAssertEqual(EthereumTransactionSigner.legacySignatureV(chainID: Vectors.data(hex: "01"), recovery: 0), Data([37]))
        XCTAssertEqual(EthereumTransactionSigner.legacySignatureV(chainID: Vectors.data(hex: "0001"), recovery: 1), Data([38]))
        XCTAssertNil(EthereumTransactionSigner.legacySignatureV(chainID: Vectors.data(hex: "01"), recovery: 2))
        XCTAssertNil(EthereumTransactionSigner.legacySignatureV(chainID: Vectors.data(hex: "01"), recovery: 3))
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

    func testSolanaMessageSigningWrappersProduceValidSignaturesAndPreserveDecodeBehavior() throws {
        let privateKey = try requirePrivateKey(Vectors.solanaSigningPrivateKey)
        let upstreamPrivateKey = try requirePrivateKey(Vectors.upstreamSolanaPrivateKey)
        let binaryBase58 = WalletCrypto.base58Encode(data: Vectors.solanaBinaryMessage)
        let binaryHex = WalletCrypto.hexString(data: Vectors.solanaBinaryMessage)
        let longBase58 = WalletCrypto.base58Encode(data: Vectors.solanaLongMessage)
        let longHex = WalletCrypto.hexString(data: Vectors.solanaLongMessage)

        XCTAssertEqual(Solana.shared.decodeMessage(binaryBase58, asHex: false), Vectors.solanaBinaryMessage)
        XCTAssertEqual(Solana.shared.decodeTransactionMessage(binaryBase58), Vectors.solanaBinaryMessage)
        XCTAssertEqual(Solana.shared.decodeMessage(binaryHex, asHex: true), Vectors.solanaBinaryMessage)
        try assertValidSolanaSignature(Solana.shared.sign(messageData: Vectors.solanaBinaryMessage, privateKey: privateKey),
                                       message: Vectors.solanaBinaryMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: binaryBase58, asHex: false, privateKey: privateKey),
                                       message: Vectors.solanaBinaryMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: binaryHex, asHex: true, privateKey: privateKey),
                                       message: Vectors.solanaBinaryMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(messageData: Vectors.solanaLongMessage, privateKey: privateKey),
                                       message: Vectors.solanaLongMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: longBase58, asHex: false, privateKey: privateKey),
                                       message: Vectors.solanaLongMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: longHex, asHex: true, privateKey: privateKey),
                                       message: Vectors.solanaLongMessage,
                                       publicKeyHex: Vectors.solanaSigningPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: Vectors.solanaMessageBase58,
                                                          asHex: false,
                                                          privateKey: upstreamPrivateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.upstreamSolanaPublicKey)
        try assertValidSolanaSignature(Solana.shared.sign(message: Vectors.solanaMessageHex,
                                                          asHex: true,
                                                          privateKey: upstreamPrivateKey),
                                       message: Vectors.solanaMessage,
                                       publicKeyHex: Vectors.upstreamSolanaPublicKey)
        XCTAssertEqual(Solana.shared.decodeMessage("1", asHex: false), Data([0]))
        XCTAssertEqual(Solana.shared.decodeMessage("111", asHex: false), Data(repeating: 0, count: 3))
        XCTAssertEqual(Solana.shared.decodeMessage("0x00", asHex: true), Data([0]))
        XCTAssertEqual(Solana.shared.decodeMessage("ABCDEF", asHex: true), Vectors.data(hex: "abcdef"))
        XCTAssertEqual(Solana.shared.sign(message: WalletCrypto.base58Encode(data: Data()), asHex: false, privateKey: privateKey),
                       nil)
        try assertValidSolanaSignature(Solana.shared.sign(message: "", asHex: true, privateKey: privateKey),
                                       message: Data(),
                                       publicKeyHex: Vectors.solanaSigningPublicKey)

        XCTAssertEqual(Solana.shared.decodeMessage("", asHex: true), Data())
        XCTAssertNil(Solana.shared.decodeMessage("", asHex: false))
        XCTAssertNil(Solana.shared.decodeMessage("0OIl", asHex: false))
        XCTAssertNil(Solana.shared.decodeMessage("abc", asHex: true))
        XCTAssertNil(Solana.shared.decodeMessage("0X00", asHex: true))
        XCTAssertNil(Solana.shared.decodeMessage("00\n", asHex: true))
        XCTAssertNil(Solana.shared.sign(message: "0OIl", asHex: false, privateKey: privateKey))
        XCTAssertNil(Solana.shared.sign(message: "abc", asHex: true, privateKey: privateKey))
    }

    func testSolanaTransactionMessageDecodeRejectsOverlongBase58Payload() {
        let message = String(repeating: "z", count: Solana.maxBase58EncodedWirePayloadLength + 1)

        XCTAssertNil(Solana.shared.decodeTransactionMessage(message))
        XCTAssertEqual(Solana.shared.validationErrorForSigningTransaction(message: message,
                                                                          publicKey: Vectors.solanaAllOnesPublicKeyAddress),
                       .invalidMessage)
    }

    func testSolanaTransactionMessageDecodeRejectsOverlongDecodedPayload() {
        let message = String(repeating: "1", count: Solana.maxWirePayloadLength + 1)
        XCTAssertLessThanOrEqual(message.utf8.count, Solana.maxBase58EncodedWirePayloadLength)

        XCTAssertNil(Solana.shared.decodeTransactionMessage(message))
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
