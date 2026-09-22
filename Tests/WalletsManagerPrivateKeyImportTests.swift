// ∅ 2026 lil org

import CryptoKit
import Foundation
import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class WalletsManagerPrivateKeyImportTests: XCTestCase {

    private enum TestError: Error {
        case invalidPrivateKey
    }

    private let privateKeyData = Data(1...32)

    func testSolanaPrivateKeyExportUsesPhantomSecretKeyFormat() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .solana)
        guard let decoded = WalletCrypto.base58Decode(string: exported) else {
            XCTFail("Expected Solana private key export to be base58")
            return
        }

        XCTAssertEqual(decoded.count, 64)
        XCTAssertEqual(Data(decoded.prefix(32)), privateKeyData)
        XCTAssertEqual(Data(decoded.suffix(32)), privateKey.publicKeyData(coin: .solana))
        XCTAssertEqual(exported, Vectors.solanaSequentialSecretKeyBase58)
        XCTAssertNotEqual(exported, WalletCrypto.hexString(data: privateKeyData))
    }

    func testSolanaPrivateKeyImportAcceptsPhantomSecretKeyFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSecretKeyBase58)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsBase58SeedFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSeedBase58)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsByteArraySecretKeyFormat() {
        let imported = WalletsManager.privateKeyImport(from: Vectors.solanaSequentialSecretKeyByteArray)

        XCTAssertEqual(imported?.coin, .solana)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportAcceptsByteArraySeedAndWhitespaceSecretKeyFormats() {
        let seedByteArray = "[ " + privateKeyData.map(String.init).joined(separator: " , ") + " ]"
        let secretKeyWithWhitespace = Vectors.solanaSequentialSecretKeyByteArray
            .replacingOccurrences(of: ",", with: ", ")

        let importedSeed = WalletsManager.privateKeyImport(from: seedByteArray)
        let importedSecretKey = WalletsManager.privateKeyImport(from: secretKeyWithWhitespace)

        XCTAssertEqual(importedSeed?.coin, .solana)
        XCTAssertEqual(importedSecretKey?.coin, .solana)
        assertPrivateKey(importedSeed?.privateKey, equals: privateKeyData)
        assertPrivateKey(importedSecretKey?.privateKey, equals: privateKeyData)
    }

    func testSolanaPrivateKeyImportRejectsByteArraySecretKeyWithInvalidLength() {
        let secretKey = Data(1...33)
        let byteArrayString = "[" + secretKey.map(String.init).joined(separator: ",") + "]"

        XCTAssertNil(WalletsManager.privateKeyImport(from: byteArrayString))
    }

    func testSolanaPrivateKeyImportRejectsInvalidByteArrayValues() {
        let thirtyOneOnes = Array(repeating: "1", count: 31)
        let invalidInputs = [
            byteArrayString(["true"] + thirtyOneOnes),
            byteArrayString(["1.5"] + thirtyOneOnes),
            byteArrayString(["-1"] + thirtyOneOnes),
            byteArrayString(["256"] + thirtyOneOnes),
            byteArrayString(["\"1\""] + thirtyOneOnes),
            byteArrayString(["1"]),
            byteArrayString(Array(repeating: "1", count: 65)),
            byteArrayString(Array(repeating: "1", count: 31) + ["[]"]),
            "{}",
            "[[]]",
            "[1,]",
            "[1,2",
        ]

        for input in invalidInputs {
            XCTAssertNil(WalletsManager.privateKeyImport(from: input), "Expected invalid byte array to be rejected: \(input)")
        }
    }

    func testSolanaPrivateKeyImportRejectsMismatchedPublicKey() throws {
        let privateKey = try testPrivateKey()

        let exported = privateKey.withData { privateKeyData in
            var secretKey = privateKeyData
            defer { secretKey.resetBytes(in: 0..<secretKey.count) }
            secretKey.append(Data(repeating: 9, count: 32))
            return WalletCrypto.base58Encode(data: secretKey)
        }

        XCTAssertNil(WalletsManager.privateKeyImport(from: exported))
    }

    func testSolanaPrivateKeyImportRejectsByteArraySecretKeyWithMismatchedPublicKey() {
        var mismatchedSecretKey = privateKeyData
        mismatchedSecretKey.append(Data(repeating: 7, count: 32))
        let byteArrayString = "[" + mismatchedSecretKey.map(String.init).joined(separator: ",") + "]"

        XCTAssertNil(WalletsManager.privateKeyImport(from: byteArrayString))
    }

    func testSolanaPrivateKeyImportRejectsBadBase58Seeds() {
        let invalidAlphabetSeed = String(repeating: "1", count: 31) + "0"

        XCTAssertNil(WalletsManager.privateKeyImport(from: "11111111111111111111111111111111"))
        XCTAssertEqual(invalidAlphabetSeed.count, 32)
        XCTAssertNil(WalletCrypto.base58Decode(string: invalidAlphabetSeed))
        XCTAssertNil(WalletsManager.privateKeyImport(from: invalidAlphabetSeed))
    }

    func testEthereumPrivateKeyExportStaysHex() throws {
        let privateKey = try testPrivateKey()

        let exported = WalletsManager.privateKeyExportString(privateKey: privateKey, coin: .ethereum)

        XCTAssertEqual(exported, WalletCrypto.hexString(data: privateKeyData))
    }

    func testEthereumPrivateKeyImportStaysHex() {
        let privateKeyData = Data(1...32)
        let imported = WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: privateKeyData))

        XCTAssertEqual(imported?.coin, .ethereum)
        assertPrivateKey(imported?.privateKey, equals: privateKeyData)
    }

    func testEthereumPrivateKeyImportRejectsInvalidHexKeys() {
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.zeroPrivateKey)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Data(repeating: 1, count: 31))))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Data(repeating: 1, count: 33))))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.secp256k1PrivateKeyAtCurveOrder)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: WalletCrypto.hexString(data: Vectors.secp256k1PrivateKeyAboveCurveOrder)))
        XCTAssertNil(WalletsManager.privateKeyImport(from: "0X" + WalletCrypto.hexString(data: privateKeyData)))
    }

    func testEthereumPrivateKeyImportAcceptsBase58DecodableHexThatIsInvalidForSolana() throws {
        let input = Vectors.ethereumHexThatDecodesAsInvalidSolanaSecretBase58
        let decodedAsBase58 = try XCTUnwrap(WalletCrypto.base58Decode(string: input))
        let imported = WalletsManager.privateKeyImport(from: input)

        XCTAssertEqual(decodedAsBase58.count, 64)
        XCTAssertEqual(Data(decodedAsBase58.prefix(32)), Vectors.zeroPrivateKey)
        XCTAssertEqual(imported?.coin, .ethereum)
        assertPrivateKey(imported?.privateKey, equals: Vectors.data(hex: input))
    }

    private func testPrivateKey(file: StaticString = #filePath, line: UInt = #line) throws -> WalletPrivateKey {
        guard let privateKey = WalletPrivateKey(data: privateKeyData) else {
            XCTFail("Expected valid private key", file: file, line: line)
            throw TestError.invalidPrivateKey
        }
        return privateKey
    }

    private func assertPrivateKey(_ privateKey: WalletPrivateKey?,
                                  equals expectedData: Data,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let privateKey else {
            XCTFail("Expected valid private key", file: file, line: line)
            return
        }

        privateKey.withData {
            XCTAssertEqual($0, expectedData, file: file, line: line)
        }
    }

    private func byteArrayString(_ values: [String]) -> String {
        return "[" + values.joined(separator: ",") + "]"
    }

}

@MainActor
final class WalletSigningScopeTests: XCTestCase {

    private let walletID = "approved-wallet"

    func testAccessRejectsOtherIdentitiesWithoutConsumingBinding() async throws {
        let approved = descriptor()
        let backing = SigningSpy()
        let access = requestAccess(approved: approved, backing: backing)
        let alternatives = [
            WalletAccountDescriptor(walletID: "other-wallet", account: approved.account),
            descriptor(address: Vectors.oneEthereumAddress),
            descriptor(path: "m/44'/60'/0'/0/1"),
            WalletAccountDescriptor(walletID: walletID, account: solanaAccount()),
        ]
        for alternative in alternatives {
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: alternative)
            XCTAssertNil(access.bind(operation: operation))
            XCTAssertTrue(backing.operations.isEmpty)
        }

        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: approved)
        let signer = try XCTUnwrap(access.bind(operation: operation))
        let result = await signer.sign()
        guard case .success(.ethereumSignature("test-signature")) = result else {
            return XCTFail("Expected the approved operation to sign")
        }
        XCTAssertEqual(backing.operations.map(\.approvedAccount), [approved])
        XCTAssertEqual(backing.operations.first?.handle, operation.handle)
        XCTAssertEqual(backing.operations.first?.deadline, operation.deadline)
        XCTAssertEqual(backing.operations.first?.configurationKey, operation.configurationKey)
    }

    func testAccountIdentityNormalizesEthereumCaseAndIgnoresPublicMetadata() throws {
        let approved = descriptor()
        let reconstructed = WalletAccount(
            address: approved.account.address.uppercased(),
            coin: .ethereum,
            derivation: .default,
            derivationPath: approved.derivationPath,
            publicKey: "different-public-metadata",
            extendedPublicKey: "different-extended-metadata"
        )
        let access = requestAccess(approved: approved, backing: SigningSpy())
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: reconstructed)
        )
        XCTAssertNotNil(access.bind(operation: operation))
    }

    func testBindingPreservesSolanaAddressCase() throws {
        let account = solanaAccount()
        let approved = WalletAccountDescriptor(walletID: walletID, account: account)
        let access = requestAccess(approved: approved, backing: SigningSpy())
        let changed = WalletAccountDescriptor(
            walletID: walletID,
            coin: .solana,
            normalizedAddress: account.address.replacingOccurrences(of: "C", with: "c"),
            derivationPath: account.derivationPath
        )
        XCTAssertTrue(changed.isValid)
        XCTAssertNil(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: changed)))
        XCTAssertNotNil(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: approved)))
    }

    func testAccessAndSignerAreSingleUseAfterSuccessAndFailure() async throws {
        for succeeds in [false, true] {
            let backing = SigningSpy()
            backing.result = succeeds ? .success(.ethereumSignature("test-signature")) : .failure(.failedToSign)
            let access = requestAccess(approved: descriptor(), backing: backing)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
            let signer = try XCTUnwrap(access.bind(operation: operation))
            XCTAssertNil(access.bind(operation: operation))
            _ = await signer.sign()
            assertUnavailable(await signer.sign())
            XCTAssertNil(access.bind(operation: operation))
            XCTAssertEqual(backing.operations.count, 1)
            XCTAssertEqual(backing.invalidations, 1)
        }
    }

    func testOwnerInvalidationBeforeSigningReleasesAuthorization() async throws {
        for invalidateAccess in [false, true] {
            let backing = SigningSpy()
            let access = requestAccess(approved: descriptor(), backing: backing)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
            let signer = try XCTUnwrap(access.bind(operation: operation))
            if invalidateAccess {
                access.invalidate()
            } else {
                signer.invalidate()
            }
            XCTAssertEqual(backing.invalidations, 1)
            assertUnavailable(await signer.sign())
            assertUnavailable(await signer.sign())
            XCTAssertTrue(backing.operations.isEmpty)
            XCTAssertNil(access.bind(operation: operation))
            XCTAssertEqual(backing.invalidations, 1)
        }
    }

    func testConcurrentSigningConsumesAuthorizationBeforeSuspension() async throws {
        let backing = SigningSpy()
        let started = expectation(description: "Signing started")
        var continuation: CheckedContinuation<Void, Never>?
        backing.beforeReturn = {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = try XCTUnwrap(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())))
        let first = Task { await signer.sign() }
        await fulfillment(of: [started], timeout: 1)
        assertUnavailable(await signer.sign())
        XCTAssertEqual(backing.operations.count, 1)
        try XCTUnwrap(continuation).resume()
        _ = await first.value
    }

    func testExpiryBeforeSigningNeverReachesBacking() async throws {
        let start = Date()
        var now = start
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing, clock: { now })
        let signer = try XCTUnwrap(access.bind(operation: try approvedWalletSigningOperationForTesting(
            approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
        )))
        now = start.addingTimeInterval(1)
        assertUnavailable(await signer.sign())
        now = start
        assertUnavailable(await signer.sign())
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testCancellationBeforeSigningConsumesAuthorizationWithoutBackingAccess() async throws {
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = try XCTUnwrap(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())))
        let task = Task { await signer.sign() }
        task.cancel()
        assertUnavailable(await task.value)
        assertUnavailable(await signer.sign())
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testInvalidationExpiryAndCancellationDiscardInFlightResults() async throws {
        for interruption in 0..<4 {
            let start = Date()
            var now = start
            var current = true
            let backing = SigningSpy()
            let started = expectation(description: "Signing started")
            var continuation: CheckedContinuation<Void, Never>?
            backing.beforeReturn = {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            let access = requestAccess(
                approved: descriptor(), backing: backing,
                isCurrent: { current }, clock: { now }
            )
            let signer = try XCTUnwrap(access.bind(operation: try approvedWalletSigningOperationForTesting(
                approvedAccount: descriptor(), deadline: start.addingTimeInterval(1)
            )))
            let signing = Task { await signer.sign() }
            await fulfillment(of: [started], timeout: 1)
            switch interruption {
            case 0: access.invalidate()
            case 1: now = start.addingTimeInterval(1)
            case 2: signing.cancel()
            default: current = false
            }
            if interruption == 0 || interruption == 2 {
                XCTAssertEqual(backing.invalidations, 1)
            }
            try XCTUnwrap(continuation).resume()
            assertUnavailable(await signing.value)
            assertUnavailable(await signer.sign())
            XCTAssertEqual(backing.operations.count, 1)
        }
    }

    func testSigningConsumptionDoesNotConsumeExecutionLease() async throws {
        let backing = SigningSpy()
        let access = requestAccess(approved: descriptor(), backing: backing)
        let signer = try XCTUnwrap(access.bind(operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())))
        _ = await signer.sign()
        let firstLease = await access.takeExecutionLease()
        XCTAssertNotNil(firstLease)
        firstLease?.release()
        let secondLease = await access.takeExecutionLease()
        XCTAssertNil(secondLease)
        assertUnavailable(await signer.sign())
    }

    func testStaleAndInvalidScopesCannotBind() throws {
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor())
        for approved in [
            WalletAccountDescriptor(walletID: "", account: descriptor().account),
            descriptor(address: "0x1234"),
            descriptor(path: ""),
        ] {
            let backing = SigningSpy()
            let access = requestAccess(approved: approved, backing: backing)
            XCTAssertNil(access.bind(operation: operation))
            XCTAssertTrue(backing.operations.isEmpty)
        }
        let backing = SigningSpy()
        let stale = requestAccess(approved: descriptor(), backing: backing, isCurrent: { false })
        XCTAssertNil(stale.bind(operation: operation))
        XCTAssertTrue(backing.operations.isEmpty)
    }

    func testSourceSignerSignsOnceAndReturnsVerifiableSignature() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.attributes = [reader.walletAttributes(id: walletID)]
        reader.walletData = [walletID: Vectors.walletCoreJSONPrivateKeyFixture]
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        XCTAssertTrue(manager.reloadFromStore())
        let account = try XCTUnwrap(manager.wallets.first?.accounts.first)
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: WalletAccountDescriptor(walletID: walletID, account: account)
        )
        let signer = SourceWalletSigner(operation: operation, walletsManager: manager)
        try assertWalletSigningSuccessForTesting(await signer.sign(), account: account)
        assertUnavailable(await signer.sign())
        XCTAssertEqual(reader.passwordReadCount, 1)
    }

    func testSourceSignerRejectsMissingAccountAndExpiredOperation() async throws {
        let reader = KeychainCopyMatchingStub()
        reader.passwordData = Vectors.walletCoreJSONPrivateKeyPassword
        let manager = WalletsManager(keychain: Keychain(copyMatching: reader.copyMatching))
        let start = Date()
        let operation = try approvedWalletSigningOperationForTesting(approvedAccount: descriptor(), deadline: start)
        let expired = SourceWalletSigner(operation: operation, walletsManager: manager, clock: { start })
        assertUnavailable(await expired.sign())
        let missing = SourceWalletSigner(
            operation: try approvedWalletSigningOperationForTesting(approvedAccount: descriptor()), walletsManager: manager
        )
        assertUnavailable(await missing.sign())
        XCTAssertEqual(reader.passwordReadCount, 0)
    }

    func testEthereumSigningModesUseTheCapturedPayload() async throws {
        let cases: [(SignMessageAction.Payload, String)] = [
            (.ethereumMessage(Vectors.ethereumRawSignDigest), Vectors.ethereumRawSignature),
            (.ethereumPersonalMessage(Vectors.ethereumPersonalMessage), Vectors.ethereumPersonalMessageSignature),
            (.ethereumTypedData(Vectors.typedDataJSON), Vectors.ethereumTypedDataSignature),
        ]
        for (payload, expectedSignature) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = BoundWalletSigner(operation: operation, access: access, isCurrent: { true })
            guard case .success(.ethereumSignature(let signature)) = await signer.sign() else {
                return XCTFail("Expected the approved Ethereum signing mode")
            }
            XCTAssertEqual(signature, expectedSignature)
            assertUnavailable(await signer.sign())
        }
    }

    func testCryptographicFailureConsumesTheBoundSigner() async throws {
        let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
        let operation = try approvedWalletSigningOperationForTesting(
            approvedAccount: account, payload: .ethereumTypedData(Vectors.malformedTypedDataJSON)
        )
        let signer = BoundWalletSigner(operation: operation, access: access, isCurrent: { true })
        guard case .failure(.failedToSign) = await signer.sign() else {
            return XCTFail("Expected malformed typed data to fail")
        }
        assertUnavailable(await signer.sign())
    }

    func testEthereumTransactionCapturesFinalNonceFeesAndDestination() async throws {
        let cases: [(PreparedTransactionFee, PreparedTransactionFee)] = [
            (.legacy(gasPrice: 10), .legacy(gasPrice: 20)),
            (.eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 10),
             .eip1559(maxPriorityFeePerGas: 3, maxFeePerGas: 20)),
        ]
        for (initialFee, finalFee) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .ethereum, key: Vectors.ethereumSignerPrivateKey)
            let network = ResolvedEthereumNetwork(network: EthereumNetwork(
                chainId: 10, name: "Approved network", symbol: "ETH",
                rpcEndpoint: .unauthenticated(URL(string: "https://approved.example/rpc")!),
                isTestnet: true, mightShowPrice: false, explorer: nil
            ), source: .custom)
            let original = Transaction(
                id: UUID(), from: account.normalizedAddress,
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0", gas: "0x5208", value: "0x1", data: "0x",
                feeIntent: initialFee.intent, preparedFee: initialFee
            )
            var final = original
            final.nonce = "0x7"
            final.preparedFee = finalFee
            let request = try XCTUnwrap(SafariRequest(json: [
                "id": 1, "name": "signTransaction", "provider": "ethereum",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["address": account.normalizedAddress, "chainId": "0xa"],
            ]))
            let operation = try XCTUnwrap(ApprovedWalletSigningOperation(
                request: request,
                approval: .transaction(SendTransactionAction(
                    transaction: original, resolvedNetwork: network, walletId: account.walletID, account: account.account
                ), final),
                handle: .init(id: 1, token: .init(value: UUID()), profileIdentifier: nil),
                deadline: Date().addingTimeInterval(60)
            ))
            let expected = try Ethereum.signedTransaction(
                transaction: final, privateKey: XCTUnwrap(WalletPrivateKey(data: Vectors.ethereumSignerPrivateKey)),
                network: network.network
            ).get()
            final.nonce = "0x8"
            let signer = BoundWalletSigner(operation: operation, access: access, isCurrent: { true })
            guard case .success(.ethereumTransaction(let signed, let hash, let destination)) = await signer.sign() else {
                return XCTFail("Expected signed Ethereum transaction")
            }
            XCTAssertEqual(signed, expected)
            XCTAssertEqual(hash, Ethereum.transactionHash(signedTransaction: expected))
            XCTAssertEqual(destination, network)
            assertUnavailable(await signer.sign())
            if finalFee.isEIP1559 { XCTAssertTrue(signed.hasPrefix("0x02")) }
        }
    }

    func testSolanaMessageTransactionAndBatchSignaturesPreserveOrder() async throws {
        let publicKeyData = try XCTUnwrap(WalletCrypto.base58Decode(string: Vectors.solanaPreparedSignerPublicKey))
        let messages = [UInt8(9), UInt8(10)].map { seed in
            SolanaMessageFixture.wireMessage(accountKeys: [publicKeyData], blockhashSeed: seed,
                                            bodyAfterBlockhash: Data.encodeLength(0))
        }
        let prepared = try messages.map {
            try Solana.shared.preparedTransactionMessageForSigning(
                message: WalletCrypto.base58Encode(data: $0), publicKey: Vectors.solanaPreparedSignerPublicKey
            ).get()
        }
        let cases: [(SignMessageAction.Payload, [Data])] = [
            (.solanaMessage(walletSigningTestMessage), [walletSigningTestMessage]),
            (.solanaTransaction(prepared[0]), [messages[0]]),
            (.solanaTransactions(prepared), messages),
        ]
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        for (payload, expectedMessages) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = BoundWalletSigner(operation: operation, access: access, isCurrent: { true })
            let signatures: [String]
            switch try await signer.sign().get() {
            case .solanaSignature(let value): signatures = [value]
            case .solanaSignatures(let values): signatures = values
            default: return XCTFail("Expected Solana signatures")
            }
            XCTAssertEqual(signatures.count, expectedMessages.count)
            for (signature, message) in zip(signatures, expectedMessages) {
                let bytes = try XCTUnwrap(WalletCrypto.base58Decode(string: signature))
                XCTAssertTrue(publicKey.isValidSignature(bytes, for: message))
            }
            assertUnavailable(await signer.sign())
        }
    }

    func testMalformedSolanaBatchCannotProducePartialApproval() throws {
        let account = WalletAccountDescriptor(walletID: walletID, account: solanaAccount())
        let publicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: account.normalizedAddress))
        let message = WalletCrypto.base58Encode(data: SolanaMessageFixture.wireMessage(
            accountKeys: [publicKey], bodyAfterBlockhash: Data.encodeLength(0)
        ))
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: try WalletAccountCatalog(accounts: [account]).canonicalData()),
            orderedAccounts: [account.specificAccount]
        )
        for messages in [[message, "0"], ["0", message]] {
            let request = try XCTUnwrap(SafariRequest(json: [
                "id": 2, "name": "signAllTransactions", "provider": "solana",
                "host": "wallet.example", "configurationKey": "https://wallet.example",
                "enqueueAttempt": String(repeating: "a", count: 32),
                "admissionDeadline": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000),
                "workflowVersion": ExtensionBridge.workflowVersion,
                "body": ["publicKey": account.normalizedAddress, "object": ["params": ["messages": messages]]],
            ]))
            guard case .response(let response) = DappRequestProcessor().prepare(request, catalog: catalog) else {
                return XCTFail("A malformed batch must not issue a partial signing approval")
            }
            XCTAssertNotNil(response.json["error"])
            XCTAssertNil(response.json["result"])
        }
    }

    func testSolanaBroadcastPreservesCosignersPlacementClusterAndOptions() async throws {
        let signerPublicKey = try XCTUnwrap(WalletCrypto.base58Decode(string: Vectors.solanaPreparedSignerPublicKey))
        let cosigner = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 5, count: 32))
        let singleMessage = SolanaMessageFixture.wireMessage(accountKeys: [signerPublicKey], bodyAfterBlockhash: Data.encodeLength(0))
        let multiMessage = SolanaMessageFixture.wireMessage(
            requiredSignatures: 2, accountKeys: [cosigner.publicKey.rawRepresentation, signerPublicKey],
            bodyAfterBlockhash: Data.encodeLength(0)
        )
        let cosignerSignature = try cosigner.signature(for: multiMessage)
        let serialized = Data([2]) + cosignerSignature + Data(repeating: 0, count: 64) + multiMessage
        let legacy = try Solana.shared.preparedLegacySignAndSendTransaction(
            message: WalletCrypto.base58Encode(data: singleMessage), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let prepared = try Solana.shared.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletCrypto.base58Encode(data: serialized), publicKey: Vectors.solanaPreparedSignerPublicKey
        ).get()
        let options = try Solana.preparedSendOptions(from: [
            "maxRetries": 4, "minContextSlot": 42, "preflightCommitment": "confirmed"
        ]).get()
        let cases: [(SignMessageAction.Payload, Data, Int)] = [
            (.solanaLegacyBroadcast(legacy, options), singleMessage, 0),
            (.solanaSerializedBroadcast(prepared, options), multiMessage, 1),
        ]
        for (payload, message, signerIndex) in cases {
            let (account, access) = try unlockedSigningAccess(coin: .solana, key: Vectors.solanaPreparedSignerPrivateKey)
            let operation = try approvedWalletSigningOperationForTesting(approvedAccount: account, payload: payload)
            let signer = BoundWalletSigner(operation: operation, access: access, isCurrent: { true })
            guard case .success(.solanaTransaction(let signed, let signature, let cluster, let capturedOptions)) = await signer.sign() else {
                return XCTFail("Expected signed Solana transaction")
            }
            let bytes = try XCTUnwrap(Data(base64Encoded: signed))
            let signatureOffset = 1 + signerIndex * 64
            let signerSignature = bytes.subdata(in: signatureOffset..<(signatureOffset + 64))
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signerPublicKey)
            XCTAssertTrue(publicKey.isValidSignature(signerSignature, for: message))
            XCTAssertEqual(bytes.suffix(message.count), message)
            if signerIndex == 1 {
                XCTAssertEqual(bytes.subdata(in: 1..<65), cosignerSignature)
                XCTAssertEqual(signature, WalletCrypto.base58Encode(data: cosignerSignature))
            } else {
                XCTAssertEqual(signature, WalletCrypto.base58Encode(data: signerSignature))
            }
            XCTAssertEqual(cluster, .devnet)
            XCTAssertEqual(capturedOptions.maxRetries, 4)
            XCTAssertEqual(capturedOptions.minContextSlot, 42)
            XCTAssertEqual(capturedOptions.preflightCommitment, .confirmed)
            assertUnavailable(await signer.sign())
        }
    }

    private func unlockedSigningAccess(coin: WalletCoin, key: Data) throws -> (WalletAccountDescriptor, UnlockedWalletSigner) {
        let password = Data("signing-tests".utf8)
        let storedKey = try XCTUnwrap(WalletStoredKey.importPrivateKey(privateKey: key, name: "Signer", password: password, coin: coin))
        let wallet = WalletContainer(id: walletID, key: storedKey)
        let account = try XCTUnwrap(wallet.accounts.first)
        let access = try XCTUnwrap(UnlockedWalletSigner(password: password, wallets: [wallet]))
        return (WalletAccountDescriptor(walletID: walletID, account: account), access)
    }

    private func descriptor(
        address: String = Vectors.sequentialEthereumAddress,
        path: String = "m/44'/60'/0'/0/0"
    ) -> WalletAccountDescriptor {
        WalletAccountDescriptor(walletID: walletID, coin: .ethereum, normalizedAddress: address.lowercased(), derivationPath: path)
    }

    private func solanaAccount() -> WalletAccount {
        WalletAccount(address: Vectors.sequentialSolanaAddress, coin: .solana, derivation: .solanaSolana,
                      derivationPath: "m/44'/501'/0'/0'", publicKey: Vectors.sequentialSolanaPublicKey, extendedPublicKey: "")
    }

    private func requestAccess(
        approved: WalletAccountDescriptor,
        backing: SigningSpy,
        isCurrent: @escaping () -> Bool = { true },
        clock: @escaping () -> Date = Date.init
    ) -> RequestScopedWalletAccess {
        RequestScopedWalletAccess(backing, approvedAccount: approved, isCurrent: isCurrent,
                                  acquireExecutionLease: { WalletExecutionLease {} }, clock: clock)
    }

    private func assertUnavailable(
        _ result: Result<WalletSigningOutput, WalletSigningFailure>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(.authorizationUnavailable) = result else {
            return XCTFail("Expected unavailable signing authorization", file: file, line: line)
        }
    }

    private final class SigningSpy: OwnedWalletSigningAccess {
        private let lock = NSLock()
        var operations = [ApprovedWalletSigningOperation]()
        private var invalidationCount = 0
        var invalidations: Int { lock.withLock { invalidationCount } }
        var result: Result<WalletSigningOutput, WalletSigningFailure> = .success(.ethereumSignature("test-signature"))
        var beforeReturn: (() async -> Void)?

        @MainActor
        func sign(_ operation: ApprovedWalletSigningOperation) async -> Result<WalletSigningOutput, WalletSigningFailure> {
            operations.append(operation)
            await beforeReturn?()
            return result
        }

        func invalidate() { lock.withLock { invalidationCount += 1 } }
    }
}
