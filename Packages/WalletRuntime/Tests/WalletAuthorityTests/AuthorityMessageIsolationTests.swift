import Foundation
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class AuthorityMessageIsolationTests: XCTestCase {
    func testConcurrentSystemsRetainTheirCatalogThroughLateDetachedCleanup() async throws {
        let first = try system(label: "first")
        let second = try system(label: "second")
        defer {
            UserDefaults.standard.removePersistentDomain(forName: first.suite)
            UserDefaults.standard.removePersistentDomain(forName: second.suite)
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        let entered = [TestGate<Void>(), TestGate<Void>()]
        let releases = [TestGate<Void>(), TestGate<Void>()]
        let discarded = [TestGate<(String, String)>(), TestGate<(String, String)>()]
        let operations = [first.system, second.system].enumerated().map { index, system in
            Task {
                await AuthorityMessageContext.$current.withValue(system.messages) {
                    await ApprovalResolution<ProviderResponseError>().value(
                        timeoutValue: system.error(.approvalInterrupted), callerCancellation: .resolveTimeout,
                        onDiscardedValue: { error in
                            discarded[index].resolve((error.message, AuthorityStrings.somethingWentWrong))
                        },
                        operation: {
                            entered[index].resolve(())
                            await releases[index].wait()
                            return .internalError
                        }
                    )
                }
            }
        }
        await entered[0].wait()
        await entered[1].wait()
        operations[0].cancel()
        operations[1].cancel()
        let firstResult = await operations[0].value
        let secondResult = await operations[1].value
        XCTAssertEqual(firstResult.message, "first.approvalInterrupted")
        XCTAssertEqual(secondResult.message, "second.approvalInterrupted")
        releases[1].resolve(())
        releases[0].resolve(())
        let firstDiscard = await discarded[0].wait()
        let secondDiscard = await discarded[1].wait()
        XCTAssertEqual(firstDiscard.0, "first.somethingWentWrong")
        XCTAssertEqual(firstDiscard.1, "first.somethingWentWrong")
        XCTAssertEqual(secondDiscard.0, "second.somethingWentWrong")
        XCTAssertEqual(secondDiscard.1, "second.somethingWentWrong")
        XCTAssertEqual(first.system.error(.internalError).message, "first.somethingWentWrong")
        XCTAssertEqual(second.system.error(.internalError).message, "second.somethingWentWrong")
    }

    func testRuntimeSharesNativeReviewAuthorityOnlyWithinItsExactRoute() throws {
        let fixture = try system(label: "native-route-cache")
        defer {
            UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let handle = RequestHandle(id: 7, token: .init(value: UUID()), profileIdentifier: UUID())
        let nonce = NativeDeliveryNonce(value: UUID())
        let first = fixture.system.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nonce)
        let repeated = fixture.system.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: nonce)
        XCTAssertTrue(first === repeated)
        let otherNonce = fixture.system.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: .init(value: UUID()))
        XCTAssertFalse(first === otherNonce)
        let otherProfile = RequestHandle(id: handle.id, token: handle.token, profileIdentifier: UUID())
        let separate = fixture.system.makeNativeApprovalAuthority(handle: otherProfile, nativeDeliveryNonce: nonce)
        XCTAssertFalse(first === separate)
        weak var released: NativeApprovalAuthority?
        do {
            let transient = fixture.system.makeNativeApprovalAuthority(handle: handle, nativeDeliveryNonce: .init(value: UUID()))
            released = transient
        }
        XCTAssertNil(released)
    }

    func testPopupCatalogDurabilityReadKeepsMainActorResponsive() async throws {
        try await assertCatalogReadKeepsMainActorResponsive(admission: false)
    }

#if os(iOS) || os(visionOS)
    func testAdmissionCatalogDurabilityReadKeepsMainActorResponsive() async throws {
        try await assertCatalogReadKeepsMainActorResponsive(admission: true)
    }
#endif

    private func assertCatalogReadKeepsMainActorResponsive(admission: Bool) async throws {
        let started = expectation(description: "Durable catalog read started")
        let finished = LockedTestValue(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var fileIO = SafariApprovalVault.FileIO.live
        fileIO.readDurableSnapshot = { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            finished.value = true
            return .unavailable
        }
        let vault = SafariApprovalVault(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-vault-\(UUID().uuidString)"), fileIO: fileIO)
        let fixture = try system(label: "background-catalog", vault: vault)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let origin = "https://wallet.example"
        guard case .snapshot(let authority) = await fixture.system.requests.configurationSnapshot(
            configurationKey: origin, profileIdentifier: nil
        ) else { return XCTFail("Expected initial authority") }
        let raw: [String: Any] = [
            "id": 1, "name": "requestAccounts", "provider": "ethereum", "body": ["address": ""],
            "host": "wallet.example", "configurationKey": origin,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(Date().addingTimeInterval(150).timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion, "authority": authority.version.json,
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request, rawObject: raw, responseOwner: testDocumentResponseOwner
        ), case .accepted(let handle, _, _, _, _) = await fixture.system.requests.enqueue(
            ingress: ingress, profileIdentifier: nil
        ) else { return XCTFail("Expected admitted request") }
        let popup = fixture.system.makePopupApprovalAuthority(
            approvalSubjectTitle: { _ in "Approve" }, loadTransactionContext: { _ in nil }
        )
        let commandJSON: [String: Any] = [
            "id": handle.id, "subject": "getApprovalState", "requestToken": handle.requestToken,
            "workflowVersion": ExtensionBridge.workflowVersion,
        ]
        let command = try InternalSafariRequest(wire: XCTUnwrap(WireProtocol.object(.nativeCommand, value: commandJSON)))
        let operation = Task {
            if admission { _ = await fixture.system.admission.materialize(handle: handle) }
            else { _ = await popup.dispatch(request: command, profileIdentifier: nil) }
        }
        defer { operation.cancel() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(finished.value)
        release.signal()
        await operation.value
        XCTAssertTrue(finished.value)
    }

    private func system(label: String, vault: SafariApprovalVault? = nil) throws -> (system: AuthorityRuntime, suite: String, root: URL) {
        let suite = "AuthorityMessageIsolation.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaultsPreferenceStorage(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let messages = AuthorityMessages(values: Dictionary(uniqueKeysWithValues:
            AuthorityMessages.Key.allCases.map { ($0, "\(label).\($0.rawValue)") }))
        let preparation = TransactionApprovalOperations(
            prepare: { _, _, _ in AsyncThrowingStream { $0.finish() } },
            preflight: { transaction, _ in .unavailable(transaction, .init(info: nil, nextBaseFee: nil)) }
        )
        let system = AuthorityRuntime.testing(
            catalog: nil, catalogOwnedChainIds: [], solanaEndpoints: AuthorityTestSolanaEndpoints(),
            broadcaster: RejectingBroadcastForTesting(), preparation: preparation,
            storage: .init(containerURL: root), messages: messages,
            keychain: Keychain(copyMatching: { _, _ in XCTFail("Unexpected credential read"); return -25300 }),
            metadata: WalletsMetadataService(storage: preferences),
            vault: vault ?? SafariApprovalVault(fileURL: nil), integrityKeyStore: UnusedIntegrityStore(),
            vaultHostDefaults: preferences,
            customSnapshot: { .empty }, freshCustomSnapshot: { .loaded(.empty) },
            definitionResult: { _ in .unavailable }, insertNetwork: { _ in .unavailable },
            notifications: .init(postLocalChange: {}, postMutation: {}, startObserving: { _, _ in },
                stopObserving: { _ in }, isExternalChange: { _ in false })
        )
        return (system, suite, root)
    }

    private final class UnusedIntegrityStore: SafariApprovalIntegrityKeyStoring, Sendable {
        func loadOrCreate() throws -> SecretBytes {
            XCTFail("Message isolation must not read integrity keys")
            throw CocoaError(.fileReadUnknown)
        }
    }
}
