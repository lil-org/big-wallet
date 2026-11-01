import Foundation
import WalletDomain
import XCTest
@testable import WalletAuthority

@MainActor
final class RuntimeCompositionTests: XCTestCase {
    func testTransportMaterializesApprovalWithoutWalletOrVaultStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = NativeTransportRuntime(composition: fixture.composition,
            solanaEndpoints: AuthorityTestSolanaEndpoints())
        let origin = "https://runtime.example"
        guard case .snapshot(let authority) = await runtime.requests.configurationSnapshot(
            configurationKey: origin, profileIdentifier: nil) else { return XCTFail("Expected authority") }
        let raw: [String: Any] = [
            "id": 1, "name": "requestAccounts", "provider": "ethereum", "body": ["address": ""],
            "host": "runtime.example", "configurationKey": origin,
            "enqueueAttempt": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "admissionDeadline": Int(Date().addingTimeInterval(150).timeIntervalSince1970 * 1_000),
            "workflowVersion": ExtensionBridge.workflowVersion, "authority": authority.version.json,
        ]
        let request = try XCTUnwrap(SafariRequest(json: raw))
        guard case .accepted(let ingress) = ExtensionBridge.dappIngressResult(
            request: request, rawObject: raw, responseOwner: testDocumentResponseOwner),
              case .accepted(let handle, _, _, _, _) = await runtime.requests.enqueue(ingress: ingress, profileIdentifier: nil)
        else { return XCTFail("Expected admission") }
        let result = await runtime.admission.materialize(handle: handle)
        XCTAssertEqual(result, .approvalRequired)
        guard case .found(let snapshot) = await runtime.requests.load(handle: handle) else {
            return XCTFail("Expected retained approval")
        }
        XCTAssertEqual(snapshot.phase, .queued)
    }

    func testPopupConstructsOneVaultAndMetadataReaderWithoutManagement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spy = ConstructionSpy(preferences: fixture.preferences)
        var dependencies = PopupAuthorityRuntime.Dependencies()
        dependencies.makeVault = { _, _ in spy.makeVault() }
        dependencies.makeMetadata = spy.makeMetadata
        let runtime = PopupAuthorityRuntime(composition: fixture.composition,
            solanaEndpoints: AuthorityTestSolanaEndpoints(), broadcaster: RejectingBroadcastForTesting(),
            preparation: .init(prepare: { _, _, _ in AsyncThrowingStream { $0.finish() } },
                preflight: { transaction, _ in .unavailable(transaction, .init(info: nil, nextBaseFee: nil)) }),
            dependencies: dependencies)
        let first = runtime.makePopupApprovalAuthority(approvalSubjectTitle: { _ in "Approve" }, loadTransactionContext: { _ in nil })
        let second = runtime.makePopupApprovalAuthority(approvalSubjectTitle: { _ in "Approve" }, loadTransactionContext: { _ in nil })
        XCTAssertFalse(first === second)
        XCTAssertEqual(spy.constructed, ["metadata", "vault"])
    }

    func testApplicationConstructsOnlyItsPlatformManagementServices() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let spy = ConstructionSpy(preferences: fixture.preferences)
        var dependencies = WalletManagementServices.Dependencies()
        dependencies.makeKeychain = spy.makeKeychain
        dependencies.makeMetadata = spy.makeMetadata
        dependencies.notifications = .init(postLocalChange: {}, postMutation: {}, startObserving: { _, _ in },
            stopObserving: { _ in }, isExternalChange: { _ in false })
#if os(macOS)
        let runtime = AuthorityRuntime(composition: fixture.composition, management: dependencies,
            solanaEndpoints: AuthorityTestSolanaEndpoints(), broadcaster: RejectingBroadcastForTesting())
        XCTAssertEqual(spy.constructed, ["keychain", "metadata"])
#else
        dependencies.makeVault = { _, _ in spy.makeVault() }
        dependencies.makeIntegrityKeyStore = spy.makeIntegrityKeyStore
        dependencies.vaultHostDefaults = fixture.preferences
        let runtime = AuthorityRuntime(composition: fixture.composition, management: dependencies)
        XCTAssertEqual(spy.constructed, ["keychain", "metadata", "vault", "integrity"])
#endif
        XCTAssertEqual(runtime.wallets.loadState, .idle)
    }

    @MainActor
    private struct Fixture {
        let suite: String
        let root: URL
        let preferences: UserDefaultsPreferenceStorage
        let composition: AuthorityComposition

        init() throws {
            suite = "RuntimeComposition.\(UUID().uuidString)"
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            preferences = try XCTUnwrap(UserDefaultsPreferenceStorage(suiteName: suite))
            var dependencies = AuthorityComposition.Dependencies()
            dependencies.customSnapshot = { .empty }
            dependencies.freshCustomSnapshot = { .loaded(.empty) }
            dependencies.definitionResult = { _ in .unavailable }
            dependencies.insertNetwork = { _ in .unavailable }
            dependencies.invalidateCache = {}
            composition = AuthorityComposition(configuration: .init(catalog: nil, catalogOwnedChainIds: [],
                storage: .init(containerURL: root), messages: .testingEnglish), dependencies: dependencies)
        }

        func remove() {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class ConstructionSpy {
        let preferences: UserDefaultsPreferenceStorage
        var constructed = [String]()

        init(preferences: UserDefaultsPreferenceStorage) { self.preferences = preferences }

        func makeKeychain() -> Keychain {
            constructed.append("keychain")
            return Keychain(copyMatching: { _, _ in XCTFail("Construction read wallet credentials"); return -25300 })
        }

        func makeMetadata() -> WalletsMetadataService {
            constructed.append("metadata")
            return WalletsMetadataService(storage: preferences)
        }

        func makeVault() -> SafariApprovalVault {
            constructed.append("vault")
            return SafariApprovalVault(fileURL: nil)
        }

        func makeIntegrityKeyStore() -> any SafariApprovalIntegrityKeyStoring {
            constructed.append("integrity")
            return UnusedIntegrityStore()
        }
    }

    private final class UnusedIntegrityStore: SafariApprovalIntegrityKeyStoring {
        func loadOrCreate() throws -> SecretBytes {
            XCTFail("Construction read vault integrity keys")
            throw CocoaError(.fileReadUnknown)
        }
    }
}
