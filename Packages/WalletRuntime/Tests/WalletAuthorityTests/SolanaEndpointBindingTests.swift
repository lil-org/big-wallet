import Foundation
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
import XCTest
@testable import WalletAuthority

@MainActor
final class SolanaEndpointBindingTests: XCTestCase {
    func testReviewFreezesEndpointBeforeResolverChangesAndBroadcastCheckpoint() async throws {
        let (fixture, snapshot, catalog, account) = try requestFixture()
        let original = SolanaRPCEndpoint(url: URL(string: "https://original.example/devnet")!, allowsAlchemyAuthorization: false)
        let replacement = SolanaRPCEndpoint(url: URL(string: "https://replacement.example/devnet")!, allowsAlchemyAuthorization: true)
        let resolver = MutableEndpoints([.devnet: original])
        guard case .approval(let intent) = await requestProcessorForTesting(solanaEndpoints: resolver).prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected a broadcast review") }
        resolver.replace([.devnet: replacement])
        let consent = try XCTUnwrap(ApprovalReview(intent: intent).acceptMessage(cluster: .devnet, approvedAt: fixture.now))
        let approval = try consent.resolve(context: .init(accounts: catalog.orderedAccounts)).get()
        guard case .signing(_, .solanaLegacyBroadcast(_, _, .devnet, let endpoint)) = approval.kind else {
            return XCTFail("Expected a frozen Solana endpoint")
        }
        XCTAssertEqual(endpoint, original)
        guard case .claimed(let claim) = fixture.store.claim(handle: snapshot.handle),
              claim.adoptForExecution(),
              case .authorized(let permit) = fixture.store.authorize(claim: claim, approval: approval),
              permit.consumeExecution() else { return XCTFail("Expected execution authority") }
        let signing = makeWalletSigningPreparationForTesting(
            scope: WalletSigningScope(handle: claim.handle, approvedAccount: account, signingDeadline: claim.executionDeadline),
            commit: .native, clock: { fixture.now }
        )
        let session = try XCTUnwrap(signing.consume(permit: permit))
        defer { session.invalidate() }
        guard case .broadcast(let broadcast) = try await session.sign().get(),
              case .prepared(let dispatch) = fixture.store.prepareBroadcast(permit: permit, broadcast: broadcast) else {
            return XCTFail("Expected a committed broadcast")
        }
        let sender = RecordingBroadcast()
        _ = await broadcast.dispatch(using: dispatch, broadcaster: sender)
        XCTAssertEqual(sender.endpoints, [original])
        XCTAssertEqual(resolver.reads, Solana.Cluster.allCases.count)
    }

    func testUnavailableSelectedEndpointCannotProduceSigningAuthority() async throws {
        let (fixture, snapshot, catalog, _) = try requestFixture()
        let resolver = MutableEndpoints([.devnet: .init(url: URL(string: "https://devnet.example")!, allowsAlchemyAuthorization: false)])
        guard case .approval(let intent) = await requestProcessorForTesting(solanaEndpoints: resolver).prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("Expected a review with one available cluster") }
        let consent = try XCTUnwrap(ApprovalReview(intent: intent).acceptMessage(cluster: .testnet, approvedAt: fixture.now))
        guard case .failure(.invalidDecision) = consent.resolve(context: .init(accounts: catalog.orderedAccounts)) else {
            return XCTFail("An unavailable cluster must not create a signing payload")
        }
        let nativeReview = NativeApprovalReview(intent: intent)
        XCTAssertNil(nativeReview.makeMessageAuthenticationChallenge(solanaCluster: .testnet))

        resolver.replace([:])
        guard case .unavailable = await requestProcessorForTesting(solanaEndpoints: resolver).prepare(
            try XCTUnwrap(snapshot.requestBinding), catalog: catalog
        ) else { return XCTFail("No endpoint must stop broadcast review preparation") }
    }

    private func requestFixture() throws -> (ApprovedExecutionTestFixture, ExtensionBridge.Snapshot, WalletReviewCatalog, WalletAccountDescriptor) {
        let fixture = try ApprovedExecutionTestFixture()
        let key = try XCTUnwrap(WalletPrivateKey(data: Data(repeating: 1, count: 32)))
        let publicKey = key.publicKeyData(coin: .solana)
        let account = WalletAccountDescriptor(walletID: "wallet", coin: .solana,
            normalizedAddress: WalletEncoding.base58Encode(data: publicKey), derivationPath: "m/44'/501'/0'/0'")
        try fixture.establishGrant(account)
        let message = SolanaMessageFixture.wireMessage(accountKeys: [publicKey], bodyAfterBlockhash: Data([0]))
        let snapshot = try fixture.enqueue(id: 42, name: "signAndSendTransaction", provider: .solana,
            body: ["publicKey": account.normalizedAddress, "object": ["params": [
                "message": WalletEncoding.base58Encode(data: message), "options": ["cluster": "devnet"],
            ]]])
        let catalog = WalletReviewCatalog(identity: .init(generation: nil, catalogData: Data()), orderedAccounts: [account.specificAccount])
        return (fixture, snapshot, catalog, account)
    }

    private final class MutableEndpoints: SolanaEndpointResolving {
        private struct State {
            var endpoints: [Solana.Cluster: SolanaRPCEndpoint]
            var reads = 0
        }
        private let state: Mutex<State>

        init(_ endpoints: [Solana.Cluster: SolanaRPCEndpoint]) { state = Mutex(State(endpoints: endpoints)) }
        var reads: Int { state.withLock { $0.reads } }
        func replace(_ endpoints: [Solana.Cluster: SolanaRPCEndpoint]) { state.withLock { $0.endpoints = endpoints } }
        func endpoint(for cluster: Solana.Cluster) -> SolanaRPCEndpoint? {
            state.withLock { state in
                state.reads += 1
                return state.endpoints[cluster]
            }
        }
    }

    private final class RecordingBroadcast: SignedTransactionBroadcasting {
        var endpoints = [SolanaRPCEndpoint]()
        func broadcast(_ request: BroadcastRequest) async -> BroadcastResult {
            guard case .solana(_, let signature, _, let endpoint, _) = request else {
                XCTFail("Expected a Solana broadcast")
                return .notSubmitted(.solana(.notSubmitted))
            }
            endpoints.append(endpoint)
            return .accepted(signature)
        }
    }
}
