// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

private typealias Vectors = WalletCoreProxyTestVectors

final class SolanaOptionsTests: XCTestCase {

    func testSolanaSendOptionsAcceptClusterHintAliases() {
        let aliases: [(String, Solana.Cluster)] = [
            ("mainnet", .mainnetBeta),
            ("mainnet-beta", .mainnetBeta),
            ("mainnetBeta", .mainnetBeta),
            ("solana:mainnet", .mainnetBeta),
            ("devnet", .devnet),
            ("solana:devnet", .devnet),
            ("testnet", .testnet),
            ("solana:testnet", .testnet),
        ]

        for (alias, expectedCluster) in aliases {
            switch Solana.preparedSendOptions(from: ["cluster": alias]) {
            case .success(let options):
                XCTAssertEqual(options.clusterHint, expectedCluster)
            case .failure(let error):
                XCTFail("Expected \(alias) to parse, got \(error)")
            }
        }
    }

    func testSolanaSendOptionsRejectInvalidAndConflictingClusterHints() {
        switch Solana.preparedSendOptions(from: ["cluster": "localnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected invalid cluster hint to fail")
        }

        switch Solana.preparedSendOptions(from: ["cluster": "mainnet", "bigWalletCluster": "devnet"]) {
        case .failure(.invalidSendOptions):
            break
        default:
            XCTFail("Expected conflicting cluster hints to fail")
        }
    }

    func testSolanaSendOptionsSanitizeRPCOptions() {
        switch Solana.preparedSendOptions(from: [
            "cluster": "devnet",
            "bigWalletCluster": "solana:devnet",
            "encoding": "base58",
            "skipPreflight": false,
            "commitment": "finalized",
            "preflightCommitment": "confirmed",
            "mode": "serial",
            "maxRetries": 2,
            "minContextSlot": 123,
            "rpcURL": "https://example.com",
        ]) {
        case .success(let options):
            XCTAssertEqual(options.clusterHint, .devnet)
            XCTAssertEqual(options.confirmationCommitment, .finalized)
            XCTAssertEqual(options.rpcOptions["encoding"] as? String, "base64")
            XCTAssertEqual(options.rpcOptions["skipPreflight"] as? Bool, false)
            XCTAssertEqual(options.rpcOptions["preflightCommitment"] as? String, "confirmed")
            XCTAssertEqual(options.rpcOptions["maxRetries"] as? Int, 2)
            XCTAssertEqual(options.rpcOptions["minContextSlot"] as? Int, 123)
            XCTAssertNil(options.rpcOptions["commitment"])
            XCTAssertNil(options.rpcOptions["mode"])
            XCTAssertNil(options.rpcOptions["rpcURL"])
            XCTAssertNil(options.rpcOptions["cluster"])
            XCTAssertNil(options.rpcOptions["bigWalletCluster"])
        case .failure(let error):
            XCTFail("Expected sanitized options, got \(error)")
        }
    }

    func testSolanaSendOptionsRejectUnsafeValues() {
        let invalidOptions: [[String: Any]] = [
            ["skipPreflight": true],
            ["preflightCommitment": "unsafe"],
            ["commitment": "unsafe"],
            ["mode": "parallel"],
            ["mode": "unsafe"],
            ["maxRetries": -1],
            ["minContextSlot": 1.5],
        ]

        for options in invalidOptions {
            switch Solana.preparedSendOptions(from: options) {
            case .failure(.invalidSendOptions):
                break
            default:
                XCTFail("Expected invalid options to fail: \(options)")
            }
        }
    }

    func testSolanaRPCConfigurationUsesAndCachesAlchemyForSupportedClusters() throws {
        var builtNetworks: [String] = []
        let configuration = Solana.RPCConfiguration(
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
        let configuration = Solana.RPCConfiguration()

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
        let configuration = Solana.RPCConfiguration { network in
            urlBuilderCallCount += 1
            return URL(string: "https://\(network).g.alchemy.com/v2")
        }

        let testnetEndpoint = try XCTUnwrap(configuration.endpoint(for: .testnet))
        XCTAssertEqual(testnetEndpoint.url.absoluteString, "https://api.testnet.solana.com")
        XCTAssertFalse(testnetEndpoint.allowsAlchemyAuthorization)
        XCTAssertEqual(urlBuilderCallCount, 2)
    }

    func testSolanaRPCSourcesUseAccurateDisplayNames() {
        XCTAssertEqual(Solana.Cluster.mainnetBeta.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.devnet.rpcSource, .alchemy)
        XCTAssertEqual(Solana.Cluster.testnet.rpcSource, .publicFallback)
        XCTAssertEqual(Solana.RPCSource.alchemy.displayName, Strings.alchemyRPC)
        XCTAssertEqual(Solana.RPCSource.publicFallback.displayName, Strings.publicRPC)
    }

    func testSolanaDevnetSubmissionAndConfirmationReuseResolvedEndpoint() throws {
        let sentinelURL = try XCTUnwrap(URL(string: "https://sentinel.example/devnet"))
        let configuration = Solana.RPCConfiguration { network in
            if network == "solana-devnet" {
                return sentinelURL
            }
            return URL(string: "https://unused.example/mainnet")
        }
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(description: "Solana transaction confirmed")

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .devnet,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .devnet,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.map(\.method), ["sendTransaction", "getSignatureStatuses"])
        XCTAssertEqual(requests.map(\.url), [sentinelURL, sentinelURL])
        XCTAssertEqual(requests.map(\.authorization), [String?](repeating: nil, count: 2))
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaInjectedKeylessAlchemyEndpointNeverInvokesAuthorizationProvider() throws {
        let keylessCustomURL = try XCTUnwrap(
            URL(string: "https://solana-devnet.g.alchemy.com/v2")
        )
        let configuration = Solana.RPCConfiguration { network in
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(description: "Custom keyless endpoint completed")

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .devnet,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .devnet,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(recorder.snapshot().map(\.url), [keylessCustomURL])
        XCTAssertEqual(
            recorder.snapshot().map(\.authorization),
            [String?](repeating: nil, count: 1)
        )
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaMainnetReplaysSubmissionOnceWithReplacementAuthorizationAfter401()
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(
            description: "Submission recovered with replacement authorization"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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

    func testSolanaPersistentSubmission401IsTerminalAfterOneReplacement()
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Persistent submission authorization failure returned"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(
                result,
                .failure(.rpcError(message: "unauthorized", code: 401))
            )
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Replacement authorization failure returned"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(
                result,
                .failure(.rpcError(message: "unauthorized", code: 401))
            )
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaPersistentConfirmation401ContinuesPollingWithFreshAuthorization()
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Confirmation recovered on a later poll"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Persistent confirmation authorization failed"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
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
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Authorization acquisition failure was bounded"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .failure(
                .confirmationFailed(let signature, _, let code)
            ) = result else {
                XCTFail("Expected a shaped confirmation failure, got \(result)")
                completion.fulfill()
                return
            }
            XCTAssertEqual(signature, "test-signature")
            XCTAssertNil(code)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(recorder.snapshot().count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 3)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaConfirmationRetriesPollingWhenReplacementAuthorizationFails()
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Confirmation polling recovered without resubmission"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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
        throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Forbidden confirmation response stayed retryable"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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

    func testSolanaDoesNotRefreshAuthorizationAfter403() throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(description: "Forbidden response returned")
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .failure(.rpcError(message: "forbidden", code: 403)))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(recorder.snapshot().map(\.authorization), ["Bearer current-token"])
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaSubmissionDoesNotRefreshAuthorizationAfterNetworkFailure()
        throws {
        try assertSolanaSubmissionDoesNotRecoverAuthorization(
            expectedResult: .failure(.unknown)
        ) { _ in
            throw URLError(.networkConnectionLost)
        }
    }

    func testSolanaSubmissionDoesNotRefreshAuthorizationForHTTP200RPCError()
        throws {
        try assertSolanaSubmissionDoesNotRecoverAuthorization(
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

    func testSolanaPublicTestnetNeverReceivesAlchemyAuthorization() throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey))
        let completion = expectation(description: "Public testnet transaction sent")

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .testnet,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .testnet,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
        XCTAssertEqual(recorder.snapshot().map(\.authorization), [String?](repeating: nil, count: 1))
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSolanaPublicTestnet401PreservesConfirmationPolling() throws {
        let configuration = Solana.RPCConfiguration.bundled
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: configuration,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(using: solana)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey)
        )
        let completion = expectation(
            description: "Public testnet confirmation recovered"
        )

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .testnet,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .testnet,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: .finalized
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result, .success("test-signature"))
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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
    ) throws {
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
        let solana = Solana(
            urlSession: session,
            rpcConfiguration: .bundled,
            authorizationProvider: authorizationProvider
        )
        let prepared = try preparedTransaction(
            using: solana,
            file: file,
            line: line
        )
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(data: Vectors.solanaPreparedSignerPrivateKey),
            file: file,
            line: line
        )
        let completion = expectation(
            description: "Non-401 submission failure returned"
        )
        completion.assertForOverFulfill = true

        solana.signAndSendTransaction(
            preparedSerializedTransaction: prepared,
            cluster: .mainnetBeta,
            sendOptions: Solana.PreparedSendOptions(
                clusterHint: .mainnetBeta,
                rpcOptions: [
                    "encoding": "base64",
                    "skipPreflight": false,
                ],
                confirmationCommitment: nil
            ),
            privateKey: privateKey
        ) { result in
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            XCTAssertEqual(result, expectedResult, file: file, line: line)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 5)
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

    private func preparedTransaction(using solana: Solana,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) throws -> Solana.PreparedSerializedTransaction {
        switch solana.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: Vectors.solanaPreparedSerializedTransaction,
            publicKey: Vectors.solanaPreparedSignerPublicKey
        ) {
        case .success(let prepared):
            return prepared
        case .failure(let error):
            XCTFail("Expected valid prepared transaction, got \(error)", file: file, line: line)
            throw SolanaRPCStubError.invalidFixture
        }
    }

    private func makeRPCSession(
        requestHandler: @escaping SolanaOptionsURLProtocol.RequestHandler
    ) -> URLSession {
        SolanaOptionsURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SolanaOptionsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func httpResponse(
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

private final class SolanaRPCRequestRecorder {

    struct RecordedRequest: Equatable {
        let method: String
        let url: URL
        let authorization: String?
        let body: Data
    }

    private let lock = NSLock()
    private var requests = [RecordedRequest]()

    func record(_ request: URLRequest) throws -> String {
        guard let url = request.url,
              let body = try Self.bodyData(from: request),
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            throw SolanaRPCStubError.invalidRequest
        }

        lock.lock()
        requests.append(RecordedRequest(
            method: method,
            url: url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: body
        ))
        lock.unlock()
        return method
    }

    func snapshot() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
    case invalidFixture
    case invalidRequest
    case unexpectedMethod
    case unexpectedRequest
}

private enum SolanaAuthorizationStubError: Error {
    case unavailable
}

private final class SolanaAuthorizationProviderStub:
    Big_Wallet.AlchemyAuthorizationProviding,
    @unchecked Sendable {

    private let lock = NSLock()
    private var currentToken: String?
    private let replacementToken: String?
    private let replacementError: Error?
    private let tokenAfterInvalidation: String?
    private let authorizationErrorStartingAtCall: Int?
    private let authorizedHosts = Set([
        "solana-mainnet.g.alchemy.com",
        "solana-devnet.g.alchemy.com",
    ])
    private var storedAuthorizationCallCount = 0
    private var storedReplacementCallCount = 0
    private var storedInvalidatedTokens = [String]()
    private var storedInvalidationURLs = [URL]()

    init(
        token: String? = nil,
        replacementToken: String? = nil,
        replacementError: Error? = nil,
        tokenAfterInvalidation: String? = nil,
        authorizationErrorStartingAtCall: Int? = nil
    ) {
        self.currentToken = token
        self.replacementToken = replacementToken
        self.replacementError = replacementError
        self.tokenAfterInvalidation = tokenAfterInvalidation
        self.authorizationErrorStartingAtCall =
            authorizationErrorStartingAtCall
    }

    var authorizationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAuthorizationCallCount
    }

    var replacementCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReplacementCallCount
    }

    var invalidationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens.count
    }

    var invalidatedTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens
    }

    var invalidationURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidationURLs
    }

    func authorization(for url: URL) async throws -> Big_Wallet.AlchemyAuthorization? {
        let (token, shouldFail) = recordAuthorizationCall(for: url)
        if shouldFail {
            throw SolanaAuthorizationStubError.unavailable
        }
        return token.map { Big_Wallet.AlchemyAuthorization(token: $0) }
    }

    func replacementAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async throws -> Big_Wallet.AlchemyAuthorization? {
        let replacementToken = recordReplacementCall(for: url)
        if let replacementError {
            throw replacementError
        }
        return replacementToken.map { Big_Wallet.AlchemyAuthorization(token: $0) }
    }

    func invalidateAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async {
        recordInvalidation(token: rejected.token, url: url)
    }

    private func recordAuthorizationCall(
        for url: URL
    ) -> (token: String?, shouldFail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storedAuthorizationCallCount += 1
        let shouldFail = authorizationErrorStartingAtCall.map {
            storedAuthorizationCallCount >= $0
        } ?? false
        let token = authorizedHosts.contains(url.host ?? "")
            ? currentToken
            : nil
        return (token, shouldFail)
    }

    private func recordReplacementCall(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        storedReplacementCallCount += 1
        guard authorizedHosts.contains(url.host ?? "") else { return nil }
        currentToken = replacementToken
        return replacementToken
    }

    private func recordInvalidation(token: String, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storedInvalidatedTokens.append(token)
        storedInvalidationURLs.append(url)
        if let tokenAfterInvalidation {
            currentToken = tokenAfterInvalidation
        }
    }

}

private final class LockedSolanaCounter {

    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedValue += 1
        return storedValue
    }

}

private final class SolanaOptionsURLProtocol: URLProtocol {

    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let requestHandlerLock = NSLock()
    private static var requestHandler: RequestHandler?

    static func setRequestHandler(_ handler: @escaping RequestHandler) {
        requestHandlerLock.lock()
        requestHandler = handler
        requestHandlerLock.unlock()
    }

    static func removeRequestHandler() {
        requestHandlerLock.lock()
        requestHandler = nil
        requestHandlerLock.unlock()
    }

    private static func currentRequestHandler() -> RequestHandler? {
        requestHandlerLock.lock()
        defer { requestHandlerLock.unlock() }
        return requestHandler
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
