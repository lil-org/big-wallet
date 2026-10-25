import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class RPCRequestAuthorizationTests: XCTestCase {
    private let url = URL(string: "https://eth-mainnet.g.alchemy.com/v2")!

    func testDisabledAuthorizationNeverInvokesProvider() async throws {
        let provider = RPCRequestAuthorizationProviderStub()
        let authorization = RPCRequestAuthorization(
            url: url, allowsAlchemyAuthorization: false, provider: provider
        )
        let rejected = AlchemyAuthorization(token: "rejected")

        let initial = try await authorization.acquire()
        let replacement = try await authorization.replacement(afterUnauthorized: rejected)
        await authorization.invalidate(afterUnauthorized: rejected)

        XCTAssertNil(initial)
        XCTAssertNil(replacement)
        XCTAssertFalse(authorization.reserveUnauthorizedRecovery())
        XCTAssertEqual(provider.calls, .init())
    }

    func testAcquisitionRemainsFreshWithoutResettingRecovery() async throws {
        let provider = RPCRequestAuthorizationProviderStub(authorizations: [
            .success(AlchemyAuthorization(token: "first")),
            .success(AlchemyAuthorization(token: "second")),
        ])
        let authorization = makeAuthorization(provider: provider)
        let first = try await authorization.acquire()
        XCTAssertTrue(authorization.reserveUnauthorizedRecovery())
        let second = try await authorization.acquire()

        XCTAssertEqual(first?.token, "first")
        XCTAssertEqual(second?.token, "second")
        XCTAssertFalse(authorization.reserveUnauthorizedRecovery())
        XCTAssertEqual(provider.calls.acquisitions, [url, url])
        XCTAssertTrue(provider.calls.replacements.isEmpty)
    }

    func testAcquisitionFailureAndNilDoNotConsumeRecovery() async throws {
        let provider = RPCRequestAuthorizationProviderStub(authorizations: [
            .failure(.unavailable), .success(nil),
        ])
        let authorization = makeAuthorization(provider: provider)
        do {
            _ = try await authorization.acquire()
            XCTFail("Expected the acquisition failure")
        } catch {
            XCTAssertEqual(error as? RPCRequestAuthorizationProviderStub.Failure, .unavailable)
        }
        let missing = try await authorization.acquire()

        XCTAssertNil(missing)
        XCTAssertTrue(authorization.reserveUnauthorizedRecovery())
        XCTAssertEqual(provider.calls.acquisitions, [url, url])
    }

    func testCopiedAuthorizationSharesOneConcurrentReservation() async {
        let provider = RPCRequestAuthorizationProviderStub()
        let authorization = makeAuthorization(provider: provider)
        let copy = authorization
        let reservations = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<32 {
                let contender = index.isMultiple(of: 2) ? authorization : copy
                group.addTask { contender.reserveUnauthorizedRecovery() }
            }
            var winners = 0
            for await reserved in group {
                if reserved { winners += 1 }
            }
            return winners
        }

        XCTAssertEqual(reservations, 1)
        XCTAssertFalse(authorization.reserveUnauthorizedRecovery())
        XCTAssertFalse(copy.reserveUnauthorizedRecovery())
        XCTAssertTrue(makeAuthorization(provider: provider).reserveUnauthorizedRecovery())
        XCTAssertEqual(provider.calls, .init())
    }

    func testReplacementOutcomeDoesNotResetReservedRecovery() async throws {
        let outcomes: [Result<AlchemyAuthorization?, RPCRequestAuthorizationProviderStub.Failure>] = [
            .success(AlchemyAuthorization(token: "replacement")),
            .success(nil),
            .failure(.unavailable),
        ]
        for outcome in outcomes {
            let provider = RPCRequestAuthorizationProviderStub(replacement: outcome)
            let authorization = makeAuthorization(provider: provider)
            let copy = authorization
            let rejected = AlchemyAuthorization(token: "rejected")
            XCTAssertTrue(authorization.reserveUnauthorizedRecovery())

            do {
                let replacement = try await copy.replacement(afterUnauthorized: rejected)
                switch outcome {
                case .success(let expected): XCTAssertEqual(replacement, expected)
                case .failure: XCTFail("Expected the replacement failure")
                }
            } catch {
                guard case .failure(let expected) = outcome else {
                    XCTFail("Unexpected replacement error: \(error)")
                    continue
                }
                XCTAssertEqual(error as? RPCRequestAuthorizationProviderStub.Failure, expected)
            }
            _ = try await authorization.acquire()

            XCTAssertFalse(authorization.reserveUnauthorizedRecovery())
            XCTAssertFalse(copy.reserveUnauthorizedRecovery())
            XCTAssertEqual(provider.calls.replacements, [.init(url: url, token: rejected.token)])
            XCTAssertTrue(provider.calls.invalidations.isEmpty)
        }
    }

    func testInvalidationPreservesRejectedIdentityWithoutConsumingRecovery() async {
        let provider = RPCRequestAuthorizationProviderStub()
        let authorization = makeAuthorization(provider: provider)
        let rejected = AlchemyAuthorization(token: "rejected")

        await authorization.invalidate(afterUnauthorized: rejected)

        XCTAssertEqual(provider.calls.invalidations, [.init(url: url, token: rejected.token)])
        XCTAssertTrue(provider.calls.acquisitions.isEmpty)
        XCTAssertTrue(provider.calls.replacements.isEmpty)
        XCTAssertTrue(authorization.reserveUnauthorizedRecovery())
    }

    private func makeAuthorization(provider: RPCRequestAuthorizationProviderStub) -> RPCRequestAuthorization {
        RPCRequestAuthorization(url: url, allowsAlchemyAuthorization: true, provider: provider)
    }
}

private final class RPCRequestAuthorizationProviderStub: AlchemyAuthorizationProviding {
    enum Failure: Error, Equatable {
        case unavailable
    }

    struct Rejection: Equatable, Sendable {
        let url: URL
        let token: String
    }

    struct Calls: Equatable, Sendable {
        var acquisitions = [URL]()
        var replacements = [Rejection]()
        var invalidations = [Rejection]()
    }

    private let authorizations: [Result<AlchemyAuthorization?, Failure>]
    private let replacement: Result<AlchemyAuthorization?, Failure>
    private let state = Mutex(Calls())

    init(
        authorizations: [Result<AlchemyAuthorization?, Failure>] = [.success(AlchemyAuthorization(token: "initial"))],
        replacement: Result<AlchemyAuthorization?, Failure> = .success(AlchemyAuthorization(token: "replacement"))
    ) {
        self.authorizations = authorizations
        self.replacement = replacement
    }

    var calls: Calls { state.withLock { $0 } }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        let index = state.withLock { calls in
            calls.acquisitions.append(url)
            return calls.acquisitions.count - 1
        }
        guard authorizations.indices.contains(index) else { return nil }
        return try authorizations[index].get()
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.replacements.append(.init(url: url, token: rejected.token)) }
        return try replacement.get()
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        state.withLock { $0.invalidations.append(.init(url: url, token: rejected.token)) }
    }
}
