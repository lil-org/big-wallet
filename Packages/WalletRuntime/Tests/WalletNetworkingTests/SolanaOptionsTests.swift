// ∅ 2026 lil org

import XCTest
import Synchronization
import WalletDomain
import WalletRuntimeTestSupport
@testable import WalletNetworking


@MainActor
final class SolanaOptionsTests: XCTestCase {

    func testCancellationDuringAuthorizationInvalidationDoesNotStartConfirmation() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let entered = TestGate<Void>()
        let released = TestGate<Void>()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let provider = SuspendedSolanaInvalidation(entered: entered, released: released)
        let solana = SolanaRPCClient(urlSession: session, authorizationProvider: provider, messages: NetworkTestVectors.solanaMessages)
        let signed = try signedTransactionFixture()
        let operation = Task {
            try await solana.sendSignedTransaction(signed, endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)), sendOptions: .init(confirmationCommitment: .finalized))
        }
        await entered.wait()
        operation.cancel()
        released.resolve(())
        do {
            _ = try await operation.value
            XCTFail("Cancellation must be checked after authorization invalidation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.snapshot().map(\.method), ["sendTransaction"])
    }

    func testCancelledSubmissionDoesNotAuthorizeOrSend() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            throw SolanaRPCStubError.unexpectedRequest
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let authorization = SolanaAuthorizationProviderStub(token: "initial-token")
        let solana = SolanaRPCClient(urlSession: session, authorizationProvider: authorization, messages: NetworkTestVectors.solanaMessages)
        let signed = try signedTransactionFixture()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await solana.sendSignedTransaction(signed, endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)), sendOptions: .init())
        }
        do {
            _ = try await operation.value
            XCTFail("A cancelled submission must not start")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(recorder.snapshot().isEmpty)
        XCTAssertEqual(authorization.authorizationCallCount, 0)
    }

    func testCancellationDuringConfirmationSleepDoesNotResubmit() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let sleeping = TestGate<Void>()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let body: String
            switch method {
            case "sendTransaction": body = #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#
            case "getSignatureStatuses": body = #"{"jsonrpc":"2.0","id":1,"result":{"value":[null]}}"#
            default: throw SolanaRPCStubError.unexpectedMethod
            }
            return (try Self.httpResponse(for: request), Data(body.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: RejectingRPCAuth(), timing: .init(now: { Date() }, sleep: { _ in
                sleeping.resolve(())
                try await TestDeferred<Void>().value()
            }), messages: NetworkTestVectors.solanaMessages
        )
        let signed = try signedTransactionFixture()
        let operation = Task {
            try await solana.sendSignedTransaction(signed, endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .testnet)), sendOptions: .init(confirmationCommitment: .finalized))
        }
        await sleeping.wait()
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancellation must stop confirmation polling")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.snapshot().map(\.method), ["sendTransaction", "getSignatureStatuses"])
    }









    func testSolanaRPCConfigurationUsesAndCachesAlchemyForSupportedClusters() throws {
        var builtNetworks: [String] = []
        let configuration = SolanaRPCClient.RPCConfiguration(
            trustsAlchemyURLBuilderOutput: true
        ) { network in
            builtNetworks.append(network)
            return URL(string: "https://\(network).g.alchemy.com/v2")
        }

        XCTAssertEqual(builtNetworks, ["solana-mainnet", "solana-devnet"])

        let mainnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .mainnetBeta))
        XCTAssertEqual(mainnetEndpoint.url.scheme, "https")
        XCTAssertEqual(mainnetEndpoint.url.host, "solana-mainnet.g.alchemy.com")
        XCTAssertEqual(mainnetEndpoint.url.path, "/v2")
        XCTAssertTrue(mainnetEndpoint.allowsAlchemyAuthorization)

        let devnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .devnet))
        XCTAssertEqual(devnetEndpoint.url.scheme, "https")
        XCTAssertEqual(devnetEndpoint.url.host, "solana-devnet.g.alchemy.com")
        XCTAssertEqual(devnetEndpoint.url.path, "/v2")
        XCTAssertTrue(devnetEndpoint.allowsAlchemyAuthorization)

        _ = configuration.endpoint(for: .mainnetBeta)
        _ = configuration.endpoint(for: .devnet)
        XCTAssertEqual(builtNetworks, ["solana-mainnet", "solana-devnet"])
    }

    func testSolanaRPCConfigurationUsesKeylessAlchemyEndpointsByDefault() throws {
        let configuration = SolanaRPCClient.RPCConfiguration()

        XCTAssertEqual(
            configuration.endpoint(for: .mainnetBeta)?.url.absoluteString,
            "https://solana-mainnet.g.alchemy.com/v2"
        )
        XCTAssertEqual(
            configuration.endpoint(for: .devnet)?.url.absoluteString,
            "https://solana-devnet.g.alchemy.com/v2"
        )
        XCTAssertFalse(
            try XCTUnwrap(configuration.endpoint(for: .mainnetBeta))
                .allowsAlchemyAuthorization
        )
        XCTAssertFalse(
            try XCTUnwrap(configuration.endpoint(for: .devnet))
                .allowsAlchemyAuthorization
        )
        let testnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .testnet))
        XCTAssertEqual(testnetEndpoint.url.absoluteString, "https://api.testnet.solana.com")
        XCTAssertFalse(testnetEndpoint.allowsAlchemyAuthorization)
    }

    func testSolanaTestnetAlwaysUsesPublicEndpoint() throws {
        var urlBuilderCallCount = 0
        let configuration = SolanaRPCClient.RPCConfiguration { network in
            urlBuilderCallCount += 1
            return URL(string: "https://\(network).g.alchemy.com/v2")
        }

        let testnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .testnet))
        XCTAssertEqual(testnetEndpoint.url.absoluteString, "https://api.testnet.solana.com")
        XCTAssertFalse(testnetEndpoint.allowsAlchemyAuthorization)
        XCTAssertEqual(urlBuilderCallCount, 2)
    }



    func testSolanaMissingEndpointDoesNotAuthorizeOrSubmit() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            throw SolanaRPCStubError.unexpectedRequest
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let configuration = SolanaRPCClient.RPCConfiguration { _ in nil }
        XCTAssertNil(configuration.endpoint(for: .mainnetBeta))
        XCTAssertNil(configuration.endpoint(for: .devnet))
        XCTAssertTrue(recorder.snapshot().isEmpty)
    }

    func testSolanaDevnetSubmissionAndConfirmationReuseResolvedEndpoint() async throws {
        let sentinelURL = try XCTUnwrap(URL(string: "https://sentinel.example/devnet"))
        var configuration = SolanaRPCClient.RPCConfiguration { network in
            if network == "solana-devnet" {
                return sentinelURL
            }
            return URL(string: "https://unused.example/mainnet")
        }
        let approvedEndpoint = try XCTUnwrap(configuration.endpoint(for: .devnet))
        configuration = SolanaRPCClient.RPCConfiguration(endpoints: [
            .devnet: .init(url: URL(string: "https://changed.example/devnet")!, allowsAlchemyAuthorization: false),
        ])
        XCTAssertNotEqual(configuration.endpoint(for: .devnet), approvedEndpoint)
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let responseBody: String
            switch method {
            case "sendTransaction":
                responseBody = #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#
            case "getSignatureStatuses":
                responseBody = #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"slot":1,"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#
            default:
                throw SolanaRPCStubError.unexpectedMethod
            }
            return (try Self.httpResponse(for: request), Data(responseBody.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub()
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: approvedEndpoint,
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .devnet,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .success("test-signature"))

        let requests = recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), ["sendTransaction", "getSignatureStatuses"])
        XCTAssertEqual(requests.map(\.url), [sentinelURL, sentinelURL])
        XCTAssertEqual(requests.map(\.authorization), [String?](repeating: nil, count: 2))
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaInjectedKeylessAlchemyEndpointNeverInvokesAuthorizationProvider() async throws {
        let keylessCustomURL = try XCTUnwrap(
            URL(string: "https://solana-devnet.g.alchemy.com/v2")
        )
        let configuration = SolanaRPCClient.RPCConfiguration { network in
            return network == "solana-devnet"
                ? keylessCustomURL
                : URL(string: "https://solana-mainnet.g.alchemy.com/v2")
        }
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return (
                try Self.httpResponse(for: request),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(token: "must-not-be-used")
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .devnet)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .devnet,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(recorder.snapshot().map(\.url), [keylessCustomURL])
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [String?](repeating: nil, count: 1)
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaDoesNotSubmitWhenAuthorizationAcquisitionFails() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return (
                try Self.httpResponse(for: request),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"unexpected-signature"}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "unused-token",
            authorizationErrorStartingAtCall: 1
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .failure(.notSubmitted))

        XCTAssertTrue(recorder.snapshot().isEmpty)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaSubmissionHonorsResultFrom401WithoutReplay() async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            _ = requestCount.increment()
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "accepted-then-rejected-token",
            replacementToken: "unused-replacement-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["accepted-then-rejected-token"]
        )
    }

    func testSolanaSubmissionRejectsInvalidEnvelopesWithoutReplay() async throws {
        let bodies = [
            "",
            #"{"id":1,"result":"test-signature"}"#,
            #"{"jsonrpc":"1.0","id":1,"result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","id":2,"result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","id":"1","result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","id":true,"result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","id":1.0000000000000001,"result":"test-signature"}"#,
            #"{"jsonrpc":"2.0","id":1.0000000000000001,"error":{"code":401,"message":"unauthorized"}}"#,
            #"{"jsonrpc":"2.0","id":1,"error":{"code":401.00000000000001,"message":"unauthorized"}}"#,
            #"{"jsonrpc":"2.0","id":1,"error":{"code":40100000000000001e-14,"message":"unauthorized"}}"#,
            #"{"jsonrpc":"2.0","id":null,"error":{"code":401,"message":"unauthorized"}}"#,
            #"{"jsonrpc":"2.0","id":1,"result":"test-signature","error":null}"#,
            #"{"jsonrpc":"2.0","id":1,"result":null}"#,
            #"{"jsonrpc":"2.0","id":1,"error":{"code":401}}"#,
        ]
        let signedTransaction = try signedTransactionFixture()
        let endpoint = try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta))
        for statusCode in [200, 401] {
            for body in bodies {
                let recorder = SolanaRPCRequestRecorder()
                let session = makeRPCSession { request in
                    _ = try recorder.record(request)
                    return (try Self.httpResponse(for: request, statusCode: statusCode), Data(body.utf8))
                }
                defer {
                    session.invalidateAndCancel()
                    SolanaOptionsURLProtocol.removeRequestHandler()
                }
                let authorization = SolanaAuthorizationProviderStub(
                    token: "current-token", replacementToken: "unused-token"
                )
                let solana = SolanaRPCClient(
                    urlSession: session, authorizationProvider: authorization,
                    messages: NetworkTestVectors.solanaMessages
                )

                do {
                    let signature = try await solana.sendSignedTransaction(
                        signedTransaction, endpoint: endpoint, sendOptions: .init()
                    )
                    XCTFail("Accepted invalid HTTP \(statusCode) reply: \(body), signature: \(signature)")
                } catch {
                    XCTAssertEqual(error as? Solana.SendTransactionError, .unknown, body)
                }
                XCTAssertEqual(recorder.snapshot().map(\.method), ["sendTransaction"], body)
                XCTAssertEqual(authorization.authorizationCallCount, 1, body)
                XCTAssertEqual(authorization.replacementCallCount, 0, body)
                XCTAssertEqual(authorization.invalidatedTokens, statusCode == 401 ? ["current-token"] : [], body)
            }
        }
    }

    func testSolanaConfirmationPollsPastMalformedAndPendingReplies() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            let body: String
            switch requestCount.increment() {
            case 1:
                body = #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#
            case 2:
                body = #"{"jsonrpc":"2.0","id":2,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#
            case 3:
                body = #"{"jsonrpc":"2.0","id":1,"result":{"value":[null]}}"#
            case 4:
                body = #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
            return (try Self.httpResponse(for: request), Data(body.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let clock = TestClock()
        let solana = SolanaRPCClient(
            urlSession: session, authorizationProvider: RejectingRPCAuth(),
            timing: .init(now: { clock.date }, sleep: { interval in
                try Task.checkCancellation()
                clock.advance(by: UInt64(interval * 1_000_000_000))
            }), messages: NetworkTestVectors.solanaMessages
        )

        let signature = try await solana.sendSignedTransaction(
            signedTransactionFixture(),
            endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .testnet)),
            sendOptions: .init(confirmationCommitment: .finalized)
        )

        XCTAssertEqual(signature, "test-signature")
        XCTAssertEqual(recorder.snapshot().map(\.method), [
            "sendTransaction", "getSignatureStatuses", "getSignatureStatuses", "getSignatureStatuses",
        ])
    }

    func testSolanaConfirmationRecoversAuthorizationAfterMalformed401() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            let attempt = requestCount.increment()
            let body: String
            switch attempt {
            case 1:
                body = #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#
            case 2:
                body = #"{"error":"unauthorized"}"#
            case 3:
                body = #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
            return (try Self.httpResponse(for: request, statusCode: attempt == 2 ? 401 : 200), Data(body.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let authorization = SolanaAuthorizationProviderStub(token: "initial-token", replacementToken: "replacement-token")
        let solana = SolanaRPCClient(
            urlSession: session, authorizationProvider: authorization, messages: NetworkTestVectors.solanaMessages
        )

        let signature = try await solana.sendSignedTransaction(
            signedTransactionFixture(),
            endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)),
            sendOptions: .init(confirmationCommitment: .finalized)
        )

        XCTAssertEqual(signature, "test-signature")
        XCTAssertEqual(recorder.snapshot().map(\.method), ["sendTransaction", "getSignatureStatuses", "getSignatureStatuses"])
        XCTAssertEqual(recorder.snapshot().map(\.authorization), ["Bearer initial-token", "Bearer initial-token", "Bearer replacement-token"])
        XCTAssertEqual(authorization.authorizationCallCount, 2)
        XCTAssertEqual(authorization.replacementCallCount, 1)
        XCTAssertEqual(authorization.invalidationCallCount, 0)
    }

    func testSolanaMainnetReplaysSubmissionOnceWithReplacementAuthorizationAfter401()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let attempt = requestCount.increment()
            XCTAssertEqual(method, "sendTransaction")
            XCTAssertLessThanOrEqual(attempt, 2)
            if attempt == 2 {
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 2)
        let requests = recorder.snapshot()
        XCTAssertEqual(
            requests.map(\.authorization),
            ["Bearer rejected-token", "Bearer replacement-token"]
        )
        XCTAssertEqual(requests.first?.body, requests.last?.body)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSubmissionAndConfirmationHaveIndependentRecoveryBudgets() async throws {
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            switch requestCount.increment() {
            case 1, 3, 4:
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8)
                )
            case 2:
                return (
                    try Self.httpResponse(for: request),
                    Data(#"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8)
                )
            case 5:
                return (
                    try Self.httpResponse(for: request),
                    Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8)
                )
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }
        let provider = SolanaAuthorizationProviderStub(
            token: "initial",
            replacementTokens: ["submission-replacement", "confirmation-replacement"],
            tokenAfterInvalidation: "fresh"
        )
        let clock = TestClock()
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: provider,
            timing: .init(now: { clock.date }, sleep: { interval in
                try Task.checkCancellation()
                clock.advance(by: UInt64(interval * 1_000_000_000))
            }), messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let signature = try await solana.sendSignedTransaction(
            signedTransaction,
            endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)),
            sendOptions: .init(confirmationCommitment: .finalized)
        )

        XCTAssertEqual(signature, "test-signature")
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), [
            "sendTransaction", "sendTransaction",
            "getSignatureStatuses", "getSignatureStatuses", "getSignatureStatuses",
        ])
        XCTAssertEqual(requests.map(\.authorization), [
            "Bearer initial", "Bearer submission-replacement", "Bearer submission-replacement",
            "Bearer confirmation-replacement", "Bearer fresh",
        ])
        XCTAssertEqual(provider.authorizationCallCount, 3)
        XCTAssertEqual(provider.replacementCallCount, 2)
        XCTAssertEqual(provider.invalidatedTokens, ["confirmation-replacement"])
        XCTAssertEqual(Set(requests.filter { $0.method == "sendTransaction" }.map(\.body)).count, 1)
        XCTAssertEqual(Set(requests.filter { $0.method == "getSignatureStatuses" }.map(\.body)).count, 1)
    }

    func testSolanaPersistentSubmission401IsTerminalAfterOneReplacement()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let attempt = requestCount.increment()
            XCTAssertEqual(method, "sendTransaction")
            XCTAssertLessThanOrEqual(attempt, 2)
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(
            result,
            .failure(.rpcError(message: "unauthorized", code: 401))
        )

        XCTAssertEqual(requestCount.value, 2)
        let requests = recorder.snapshot()
        XCTAssertEqual(
            requests.map(\.authorization),
            ["Bearer rejected-token", "Bearer replacement-token"]
        )
        XCTAssertEqual(requests.first?.body, requests.last?.body)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["replacement-token"]
        )
    }

    func testSolanaSubmissionDoesNotReplayWhenReplacementAuthorizationFails()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "unused-replacement-token",
            replacementError: SolanaAuthorizationStubError.unavailable
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(
            result,
            .failure(.rpcError(message: "unauthorized", code: 401))
        )

        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaPersistentConfirmation401ContinuesPollingWithFreshAuthorization()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let attempt = requestCount.increment()
            switch attempt {
            case 1:
                XCTAssertEqual(method, "sendTransaction")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            case 2, 3:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                    )
                )
            case 4:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8
                    )
                )
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token",
            tokenAfterInvalidation: "fresh-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 4)
        let requests = recorder.snapshot()
        XCTAssertEqual(
            requests.map(\.method),
            [
                "sendTransaction",
                "getSignatureStatuses",
                "getSignatureStatuses",
                "getSignatureStatuses",
            ]
        )
        XCTAssertEqual(
            requests.map(\.authorization),
            [
                "Bearer rejected-token",
                "Bearer rejected-token",
                "Bearer replacement-token",
                "Bearer fresh-token",
            ]
        )
        XCTAssertEqual(requests.filter { $0.method == "sendTransaction" }.count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["replacement-token"]
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs.map(\.absoluteString),
            ["https://solana-mainnet.g.alchemy.com/v2"]
        )
    }

    func testSolanaPersistentConfirmation401StopsAfterOneFreshPoll()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            switch requestCount.increment() {
            case 1:
                XCTAssertEqual(method, "sendTransaction")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            case 2, 3, 4:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                    )
                )
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token",
            tokenAfterInvalidation: "fresh-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(
            result,
            .failure(
                .confirmationFailed(
                    signature: "test-signature",
                    message: "unauthorized",
                    code: 401
                )
            )
        )

        XCTAssertEqual(requestCount.value, 4)
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [
                "Bearer rejected-token",
                "Bearer rejected-token",
                "Bearer replacement-token",
                "Bearer fresh-token",
            ]
        )
        XCTAssertEqual(
            recorder.snapshot().filter {
                $0.method == "sendTransaction"
            }.count,
            1
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 2)
    }

    func testSolanaPersistentConfirmationAuthorizationAcquisitionFailureIsBounded()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            XCTAssertEqual(method, "sendTransaction")
            return (
                try Self.httpResponse(for: request),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "submission-token",
            authorizationErrorStartingAtCall: 2
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        guard case .failure(
            .confirmationFailed(let signature, _, let code)
        ) = result else {
            XCTFail("Expected a shaped confirmation failure, got \(result)")

            return
        }
        XCTAssertEqual(signature, "test-signature")
        XCTAssertNil(code)

        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaConfirmationRetriesPollingWhenReplacementAuthorizationFails()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            switch requestCount.increment() {
            case 1:
                XCTAssertEqual(method, "sendTransaction")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            case 2:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                    )
                )
            case 3:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8
                    )
                )
            default:
                XCTFail("Transaction submission or confirmation was replayed")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[]}}"#.utf8
                    )
                )
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "fresh-token",
            replacementError: SolanaAuthorizationStubError.unavailable
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 3)
        XCTAssertEqual(
            recorder.snapshot().map(\.method),
            [
                "sendTransaction",
                "getSignatureStatuses",
                "getSignatureStatuses",
            ]
        )
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [
                "Bearer rejected-token",
                "Bearer rejected-token",
                "Bearer fresh-token",
            ]
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaConfirmation403PreservesPollingWithoutAuthorizationRefresh()
        async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            let attempt = requestCount.increment()
            switch attempt {
            case 1:
                XCTAssertEqual(method, "sendTransaction")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            case 2:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request, statusCode: 403),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":403,"message":"forbidden"}}"#.utf8
                    )
                )
            case 3:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8
                    )
                )
            default:
                XCTFail("Unexpected confirmation poll after success")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8
                    )
                )
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 3)
        XCTAssertEqual(
            recorder.snapshot().map(\.method),
            [
                "sendTransaction",
                "getSignatureStatuses",
                "getSignatureStatuses",
            ]
        )
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [
                "Bearer current-token",
                "Bearer current-token",
                "Bearer current-token",
            ]
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaDoesNotRefreshAuthorizationAfter403() async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            _ = requestCount.increment()
            return (
                try Self.httpResponse(for: request, statusCode: 403),
                Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":403,"message":"forbidden"}}"#.utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .failure(.rpcError(message: "forbidden", code: 403)))

        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(recorder.snapshot().map(\.authorization), ["Bearer current-token"])
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaSubmissionDoesNotRefreshAuthorizationAfterNetworkFailure()
        async throws {
        try await assertSolanaSubmissionDoesNotRecoverAuthorization(
            expectedResult: .failure(.unknown)
        ) { _ in
            throw URLError(.networkConnectionLost)
        }
    }

    func testSolanaSubmissionDoesNotRefreshAuthorizationForHTTP200RPCError()
        async throws {
        try await assertSolanaSubmissionDoesNotRecoverAuthorization(
            expectedResult: .failure(
                .rpcError(message: "already processed", code: -32_002)
            )
        ) { request in
            return (
                try Self.httpResponse(for: request),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"already processed"}}"#.utf8
                )
            )
        }
    }

    func testSolanaPublicTestnetNeverReceivesAlchemyAuthorization() async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return (
                try Self.httpResponse(for: request),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(token: "alchemy-only-token")
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .testnet)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .testnet,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(recorder.snapshot().map(\.authorization), [String?](repeating: nil, count: 1))
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaPublicTestnet401PreservesConfirmationPolling() async throws {
        let configuration = SolanaRPCClient.RPCConfiguration.bundled
        let recorder = SolanaRPCRequestRecorder()
        let requestCount = LockedSolanaCounter()
        let session = makeRPCSession { request in
            let method = try recorder.record(request)
            switch requestCount.increment() {
            case 1:
                XCTAssertEqual(method, "sendTransaction")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"test-signature"}"#.utf8
                    )
                )
            case 2:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8
                    )
                )
            case 3:
                XCTAssertEqual(method, "getSignatureStatuses")
                return (
                    try Self.httpResponse(for: request),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmations":null,"err":null,"confirmationStatus":"finalized"}]}}"#.utf8
                    )
                )
            default:
                throw SolanaRPCStubError.unexpectedRequest
            }
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "alchemy-only-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture()

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(configuration.endpoint(for: .testnet)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .testnet,
                    confirmationCommitment: .finalized
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(result, .success("test-signature"))

        XCTAssertEqual(requestCount.value, 3)
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [String?](repeating: nil, count: 3)
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    private func assertSolanaSubmissionDoesNotRecoverAuthorization(
        expectedResult: Result<String, Solana.SendTransactionError>,
        response: @escaping SolanaOptionsURLProtocol.RequestHandler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let recorder = SolanaRPCRequestRecorder()
        let session = makeRPCSession { request in
            _ = try recorder.record(request)
            return try response(request)
        }
        defer {
            session.invalidateAndCancel()
            SolanaOptionsURLProtocol.removeRequestHandler()
        }

        let authorizationProvider = SolanaAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-replacement-token"
        )
        let solana = SolanaRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider, messages: NetworkTestVectors.solanaMessages
        )
        let signedTransaction = try signedTransactionFixture(
            file: file,
            line: line
        )

        let result: Result<String, Solana.SendTransactionError>
        do {
            result = .success(try await solana.sendSignedTransaction(
                signedTransaction,
                endpoint: try XCTUnwrap(SolanaRPCClient.RPCConfiguration.bundled.endpoint(for: .mainnetBeta)),
                sendOptions: Solana.PreparedSendOptions(
                    clusterHint: .mainnetBeta,
                    confirmationCommitment: nil
                )
            ))
        } catch {
            result = .failure(error as? Solana.SendTransactionError ?? .unknown)
        }
        XCTAssertTrue(Thread.isMainThread, file: file, line: line)
        XCTAssertEqual(result, expectedResult, file: file, line: line)

        XCTAssertEqual(recorder.snapshot().count, 1, file: file, line: line)
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            ["Bearer current-token"],
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.authorizationCallCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.replacementCallCount,
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.invalidationCallCount,
            0,
            file: file,
            line: line
        )
    }

    private func signedTransactionFixture(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        NetworkTestVectors.signedSolanaTransaction
    }

    private func makeRPCSession(
        requestHandler: @escaping SolanaOptionsURLProtocol.RequestHandler
    ) -> URLSession {
        SolanaOptionsURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SolanaOptionsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func httpResponse(
        for request: URLRequest,
        statusCode: Int = 200
    ) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            throw SolanaRPCStubError.invalidRequest
        }
        return response
    }

}

private struct SuspendedSolanaInvalidation: WalletNetworking.AlchemyAuthorizationProviding {
    let entered: TestGate<Void>
    let released: TestGate<Void>

    func authorization(for url: URL) async throws -> WalletNetworking.AlchemyAuthorization? {
        WalletNetworking.AlchemyAuthorization(token: "initial-token")
    }

    func replacementAuthorization(afterUnauthorized rejected: WalletNetworking.AlchemyAuthorization, for url: URL) async throws -> WalletNetworking.AlchemyAuthorization? {
        nil
    }

    func invalidateAuthorization(afterUnauthorized rejected: WalletNetworking.AlchemyAuthorization, for url: URL) async {
        entered.resolve(())
        await released.wait()
    }
}



private final class SolanaRPCRequestRecorder: Sendable {

    struct RecordedRequest: Equatable, Sendable {
        let method: String
        let url: URL
        let authorization: String?
        let body: Data
    }

    private let requests = Mutex([RecordedRequest]())

    func record(_ request: URLRequest) throws -> String {
        guard let url = request.url,
              let body = try Self.bodyData(from: request),
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            throw SolanaRPCStubError.invalidRequest
        }

        requests.withLock { requests in requests.append(RecordedRequest(
            method: method,
            url: url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        )) }
        return method
    }

    func snapshot() -> [RecordedRequest] {
        requests.withLock { $0 }
    }

    private static func bodyData(from request: URLRequest) throws -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? SolanaRPCStubError.invalidRequest
            }
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private enum SolanaRPCStubError: Error {
    case invalidRequest
    case unexpectedMethod
    case unexpectedRequest
}

private enum SolanaAuthorizationStubError: Error {
    case unavailable
}

private final class SolanaAuthorizationProviderStub: WalletNetworking.AlchemyAuthorizationProviding, Sendable {
    private struct State {
        var currentToken: String?
        var authorizationCalls = 0
        var replacementCalls = 0
        var invalidatedTokens = [String]()
        var invalidationURLs = [URL]()
    }
    private let state: Mutex<State>
    private let replacementToken: String?
    private let replacementTokens: [String]?
    private let replacementError: Error?
    private let tokenAfterInvalidation: String?
    private let authorizationErrorStartingAtCall: Int?
    private let authorizedHosts = Set(["solana-mainnet.g.alchemy.com", "solana-devnet.g.alchemy.com"])

    init(token: String? = nil, replacementToken: String? = nil, replacementTokens: [String]? = nil,
         replacementError: Error? = nil, tokenAfterInvalidation: String? = nil,
         authorizationErrorStartingAtCall: Int? = nil) {
        self.state = Mutex(State(currentToken: token))
        self.replacementToken = replacementToken
        self.replacementTokens = replacementTokens
        self.replacementError = replacementError
        self.tokenAfterInvalidation = tokenAfterInvalidation
        self.authorizationErrorStartingAtCall = authorizationErrorStartingAtCall
    }

    var authorizationCallCount: Int { state.withLock { $0.authorizationCalls } }
    var replacementCallCount: Int { state.withLock { $0.replacementCalls } }
    var invalidationCallCount: Int { state.withLock { $0.invalidatedTokens.count } }
    var invalidatedTokens: [String] { state.withLock { $0.invalidatedTokens } }
    var invalidationURLs: [URL] { state.withLock { $0.invalidationURLs } }

    func authorization(for url: URL) async throws -> WalletNetworking.AlchemyAuthorization? {
        try state.withLock { state in
            state.authorizationCalls += 1
            if let threshold = authorizationErrorStartingAtCall, state.authorizationCalls >= threshold {
                throw SolanaAuthorizationStubError.unavailable
            }
            guard authorizedHosts.contains(url.host ?? "") else { return nil }
            return state.currentToken.map { WalletNetworking.AlchemyAuthorization(token: $0) }
        }
    }

    func replacementAuthorization(
        afterUnauthorized rejected: WalletNetworking.AlchemyAuthorization, for url: URL
    ) async throws -> WalletNetworking.AlchemyAuthorization? {
        let token = state.withLock { state -> String? in
            state.replacementCalls += 1
            guard authorizedHosts.contains(url.host ?? "") else { return nil }
            let index = state.replacementCalls - 1
            let replacement = replacementTokens.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? replacementToken
            state.currentToken = replacement
            return replacement
        }
        if let replacementError { throw replacementError }
        return token.map { WalletNetworking.AlchemyAuthorization(token: $0) }
    }

    func invalidateAuthorization(
        afterUnauthorized rejected: WalletNetworking.AlchemyAuthorization, for url: URL
    ) async {
        state.withLock { state in
            state.invalidatedTokens.append(rejected.token)
            state.invalidationURLs.append(url)
            if let tokenAfterInvalidation { state.currentToken = tokenAfterInvalidation }
        }
    }
}

private final class LockedSolanaCounter: Sendable {
    private let storage = Mutex(0)
    var value: Int { storage.withLock { $0 } }
    @discardableResult
    func increment() -> Int {
        storage.withLock { $0 += 1; return $0 }
    }
}

private final class SolanaOptionsURLProtocol: URLProtocol {

    typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let requestHandler = Mutex<RequestHandler?>(nil)

    static func setRequestHandler(_ handler: @escaping RequestHandler) {
        requestHandler.withLock { $0 = handler }
    }

    static func removeRequestHandler() {
        requestHandler.withLock { $0 = nil }
    }

    private static func currentRequestHandler() -> RequestHandler? {
        requestHandler.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.currentRequestHandler() else {
            client?.urlProtocol(self, didFailWithError: SolanaRPCStubError.unexpectedRequest)
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
