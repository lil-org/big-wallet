import Dispatch
import Foundation
import Synchronization
import WalletDomain
@testable import WalletNetworking
import WalletRuntimeTestSupport
import XCTest

@MainActor
final class SafariRPCClientAuthorizationTests: XCTestCase {
    func testSafariRPCClientRoutesReversedConcurrentResponsesToTheirOwnCompletions() async throws {
        let requestCount = 32
        let malformedIndex = 11
        let allRequestsStarted = expectation(description: "All RPC requests started")
        allRequestsStarted.expectedFulfillmentCount = requestCount
        let allRequestsCompleted = expectation(description: "All RPC requests completed")
        allRequestsCompleted.expectedFulfillmentCount = requestCount
        SafariRPCClientURLProtocol.reset {
            allRequestsStarted.fulfill()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariRPCClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            SafariRPCClientURLProtocol.reset()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())
        var failures = [String]()

        for index in 0..<requestCount {
            let url = try XCTUnwrap(URL(string: "https://rpc.example/request-\(index)"))
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": index, "method": "eth_blockNumber"])
            Task { @MainActor in
                let response =
                    (try? await client.send(endpoint: .unauthenticated(url), request: Self.rpcRequest(body, id: index), execution: Self.rpcExecution()))?
                    .json
                defer {
                    allRequestsCompleted.fulfill()
                }

                if index == malformedIndex {
                    if response != nil {
                        failures.append("Malformed response \(index) unexpectedly parsed")
                    }
                    return
                }

                guard let responseIndex = (response?["result"] as? NSNumber)?.intValue else {
                    failures.append("Request \(index) received no parsed response")
                    return
                }
                if responseIndex != index {
                    failures.append("Request \(index) received response \(responseIndex)")
                }
            }
        }

        await fulfillment(of: [allRequestsStarted], timeout: 5)

        let requests = SafariRPCClientURLProtocol.pendingRequests
        XCTAssertEqual(requests.count, requestCount)
        XCTAssertEqual(
            Set(requests.compactMap(\.url?.absoluteString)),
            Set((0..<requestCount).map { "https://rpc.example/request-\($0)" })
        )
        XCTAssertTrue(requests.allSatisfy { request in
            return request.httpMethod == "POST"
                && request.value(forHTTPHeaderField: "Accept") == "application/json"
                && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
                && (request.httpBody != nil || request.httpBodyStream != nil)
        })

        SafariRPCClientURLProtocol.completePendingRequestsInReverse { request in
            guard let pathComponent = request.url?.lastPathComponent else { return nil }
            guard pathComponent == "request-\(malformedIndex)" else {
                guard pathComponent.hasPrefix("request-"),
                      let index = Int(pathComponent.dropFirst("request-".count)) else {
                    return nil
                }
                return try? JSONSerialization.data(withJSONObject: ["id": index, "result": index])
            }
            return Data("not-json".utf8)
        }

        await fulfillment(of: [allRequestsCompleted], timeout: 5)
        let recordedFailures = failures
        XCTAssertTrue(recordedFailures.isEmpty, recordedFailures.joined(separator: "\n"))
    }

    func testSafariRPCClientAttachesDynamicAlchemyAuthorization() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let session = makeSafariAuthorizationSession { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token"
            )
            return (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(token: "current-token")
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Authorized Safari RPC completed")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), request: Self.rpcRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#.utf8), id: 1), execution: Self.rpcExecution()
                ))?.json
            XCTAssertEqual(response?["result"] as? String, "ok")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testSafariRPCClientRetriesOnceWithReplacementAuthorizationAfter401() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            if attempt == 1 {
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer rejected-token"
                )
                return (401, Data(#"{"error":"unauthorized"}"#.utf8))
            }

            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer replacement-token"
            )
            return (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Safari RPC recovered from 401")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), request: Self.rpcRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#.utf8), id: 1), execution: Self.rpcExecution()
                ))?.json
            XCTAssertEqual(response?["result"] as? String, "ok")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCClientNeverReplaysRawTransactionAfter401() async throws {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), try Self.rpcRequest(body, id: 1).body)
            return (
                401,
                Data(
                    #"[{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"FeeTooLow","data":{"reason":"EffectivePriorityFeePerGas too low"}}}]"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "raw transaction rejection returned without replay"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()))?
                .json
            XCTAssertEqual(response?["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(response?["id"] as? Int, 1)
            let error = response?["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? Int, -32_000)
            XCTAssertEqual(error?["message"] as? String, "FeeTooLow")
            let data = error?["data"] as? [String: Any]
            XCTAssertEqual(
                data?["reason"] as? String,
                "EffectivePriorityFeePerGas too low"
            )
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
    }

    func testSafariRPCClientReturnsUniqueMatchingDictionaryFromArrayResponse()
        async throws
    {
        let url = try XCTUnwrap(URL(string: "https://rpc.example"))
        let session = makeSafariAuthorizationSession { _ in
            return (
                200,
                Data(
                    #"[{"jsonrpc":"2.0","id":3,"result":"wrong"},null,{"jsonrpc":"2.0","id":2,"result":"matched"}]"#.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())
        let completion = expectation(
            description: "Safari RPC returned the matching array dictionary"
        )

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: .unauthenticated(url),
                    request: Self.rpcRequest(Data(#"{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}"#.utf8), id: 2), execution: Self.rpcExecution()))?.json
            XCTAssertEqual(response?["id"] as? Int, 2)
            XCTAssertEqual(response?["result"] as? String, "matched")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
    }

    func testSafariRPCClientRejectsMismatchedAndAmbiguousResponseIDs()
        async throws
    {
        let fixtures: [(path: String, response: String)] = [
            (
                "wrong-top-level",
                #"{"jsonrpc":"2.0","id":3,"result":"wrong"}"#
            ),
            (
                "no-array-match",
                #"[{"jsonrpc":"2.0","id":3,"result":"wrong"}]"#
            ),
            (
                "duplicate-array-match",
                #"[{"jsonrpc":"2.0","id":1,"result":"first"},{"jsonrpc":"2.0","id":1,"result":"second"}]"#
            ),
            (
                "boolean-top-level",
                #"{"jsonrpc":"2.0","id":true,"result":"wrong"}"#
            ),
            (
                "string-mismatch",
                #"{"jsonrpc":"2.0","id":"3","result":"wrong"}"#
            ),
            (
                "non-numeric-string",
                #"{"jsonrpc":"2.0","id":"abc","result":"wrong"}"#
            ),
            (
                "duplicate-mixed-type-match",
                #"[{"jsonrpc":"2.0","id":1,"result":"first"},{"jsonrpc":"2.0","id":"1","result":"second"}]"#
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC rejected \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        request: Self.rpcRequest(Data(
                            #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#.utf8
                        ), id: 1), execution: Self.rpcExecution()))?.json
                XCTAssertNil(response, fixture.path)
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientAcceptsMissingAndNullTopLevelResponseIDs()
        async throws
    {
        let fixtures: [(path: String, response: String)] = [
            ("missing", #"{"jsonrpc":"2.0","result":"ok"}"#),
            (
                "null",
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC accepted \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        request: Self.rpcRequest(Data(
                            #"{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}"#.utf8
                        ), id: 2), execution: Self.rpcExecution()))?.json
                XCTAssertNotNil(response, fixture.path)
                XCTAssertEqual(
                    response?["id"] as? Int,
                    2,
                    fixture.path
                )
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientAcceptsStringResponseIDs() async throws {
        let fixtures: [(path: String, response: String, result: String)] = [
            (
                "string-single",
                #"{"jsonrpc":"2.0","id":"2","result":"ok"}"#,
                "ok"
            ),
            (
                "string-batch",
                #"[{"jsonrpc":"2.0","id":"3","result":"wrong"},{"jsonrpc":"2.0","id":"2","result":"matched"}]"#,
                "matched"
            ),
        ]
        let session = makeSafariAuthorizationSession { request in
            let path = request.url?.lastPathComponent
            let fixture = fixtures.first { $0.path == path }
            return (
                200,
                Data((fixture?.response ?? "not-json").utf8)
            )
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())

        for fixture in fixtures {
            let url = try XCTUnwrap(
                URL(string: "https://rpc.example/\(fixture.path)")
            )
            let completion = expectation(
                description: "Safari RPC accepted \(fixture.path)"
            )
            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url),
                        request: Self.rpcRequest(Data(
                            #"{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}"#.utf8
                        ), id: 2), execution: Self.rpcExecution()))?.json
                XCTAssertNotNil(response, fixture.path)
                XCTAssertEqual(
                    response?["id"] as? Int,
                    2,
                    fixture.path
                )
                XCTAssertEqual(
                    response?["result"] as? String,
                    fixture.result,
                    fixture.path
                )
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }
    }

    func testSafariRPCClientRejectsRedirectResponseBody() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://rpc.example/source"))
        let redirectURL = try XCTUnwrap(URL(string: "https://rpc.example/redirect"))
        SafariRedirectURLProtocol.configure(
            sourceURL: sourceURL,
            redirectURL: redirectURL,
            statusCode: 307,
            responseData: Data(
                #"{"jsonrpc":"2.0","id":1,"result":"source"}"#.utf8
            )
        )
        defer {
            SafariRedirectURLProtocol.reset()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariRedirectURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
        }
        let client = SafariRPCClient(urlSession: session, authorizationProvider: RejectingRPCAuth())
        let completion = expectation(
            description: "Replay-safe redirect rejected"
        )

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: .unauthenticated(sourceURL),
                    request: Self.rpcRequest(Data(
                        #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}"#.utf8
                    ), id: 1), execution: Self.rpcExecution()))?.json
            XCTAssertNil(response)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(SafariRedirectURLProtocol.requestCount, 1)
        XCTAssertEqual(
            SafariRedirectURLProtocol.requestedURLs,
            [sourceURL]
        )
    }

    func testSafariRPCClientDoesNotReplayRawTransactionWhenReplacementIsUnavailable()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), try Self.rpcRequest(body, id: 1).body)
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "Unavailable replacement authorization returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()))?
                .json
            XCTAssertEqual(response?["error"] as? String, "unauthorized")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
    }

    func testSafariRPCClientReplaysSupportedReadOnlyMethodsAfter401() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let methods = ["eth_blobBaseFee", "eth_estimateUserOperationGas", "eth_supportedEntryPoints", "txpool_contentFrom"]
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            let firstAttempt = requestCount.increment().isMultiple(of: 2) == false
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           firstAttempt ? "Bearer rejected-token" : "Bearer replacement-token")
            return firstAttempt
                ? (401, Data(#"{"error":"unauthorized"}"#.utf8))
                : (200, Data(#"{"result":"ok"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(token: "rejected-token", replacementToken: "replacement-token")
        let client = SafariRPCClient(urlSession: session, authorizationProvider: authorizationProvider)
        for method in methods {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": []])
            let response = try await client.send(
                endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()
            )
            XCTAssertEqual(response.json["result"] as? String, "ok", method)
        }
        XCTAssertEqual(requestCount.value, methods.count * 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, methods.count)
        XCTAssertEqual(authorizationProvider.replacementCallCount, methods.count)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCClientNeverReplaysUnknownOrMutatingMethodsAfter401()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "unused-replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let bodies = [
            Data(
                #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransactionSync","params":["0x01"]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":2,"method":"vendor_unknownMutation","params":[]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":3,"method":"eth_sendRawTransaction","params":["0x02"]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":4,"method":"eth_sendUserOperation","params":[]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":5,"method":"eth_getVendorMutation","params":[]}"#.utf8
            ),
            Data(
                #"{"jsonrpc":"2.0","id":6,"method":"alchemy_getUnknown","params":[]}"#.utf8
            ),
        ]

        for (index, body) in bodies.enumerated() {
            let completion = expectation(
                description: "non-replayable Safari RPC \(index) completed"
            )
            completion.assertForOverFulfill = true
            Task { @MainActor in
                let response =
                    (try? await client.send(endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: index + 1), execution: Self.rpcExecution()))?
                    .json
                XCTAssertEqual(response?["error"] as? String, "unauthorized")
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
        }

        XCTAssertEqual(requestCount.value, bodies.count)
        XCTAssertEqual(
            authorizationProvider.authorizationCallCount,
            bodies.count
        )
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(
            authorizationProvider.invalidationCallCount,
            bodies.count
        )
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            [String](repeating: "rejected-token", count: bodies.count)
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs,
            [URL](repeating: url, count: bodies.count)
        )
    }

    func testSafariRPCClientInvalidatesRejectedRawTransactionAuthorizationWithoutReplay()
        async throws
    {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let requestCount = LockedNetworkCatalogCounter()
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let session = makeSafariAuthorizationSession { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            XCTAssertEqual(try Self.bodyData(from: request), try Self.rpcRequest(body, id: 1).body)
            return (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "persistent Safari authorization failure returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response = (try? await client.send(endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()))?
                .json
            XCTAssertEqual(response?["error"] as? String, "unauthorized")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
        XCTAssertEqual(authorizationProvider.invalidationURLs, [url])
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationAfter403() async throws {
        let url = try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2"))
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token"
            )
            return (403, Data(#"{"error":"forbidden"}"#.utf8))
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(description: "Safari RPC returned forbidden response")
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let response =
                (try? await client.send(
                    endpoint: alchemyEndpoint(url), request: Self.rpcRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#.utf8), id: 1), execution: Self.rpcExecution()
                ))?.json
            XCTAssertEqual(response?["error"] as? String, "forbidden")
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testSafariRPCCancellationSurvivesUncooperativeAuthorizationSteps() async throws {
        let cases: [(SafariAuthorizationProviderStub.Checkpoint, String?)] = [
            (.authorization, "replacement"),
            (.replacement, "replacement"),
            (.replacement, nil),
            (.invalidation, "replacement")
        ]
        for (checkpoint, replacement) in cases {
            let gate = TestGate<Void>()
            let reachedCheckpoint = expectation(description: "Reached \(checkpoint)")
            let requestCount = LockedNetworkCatalogCounter()
            let provider = SafariAuthorizationProviderStub(
                token: "rejected", replacementToken: replacement,
                pause: { point in
                    guard point == checkpoint else { return }
                    reachedCheckpoint.fulfill()
                    await gate.wait()
                }
            )
            let session = makeSafariAuthorizationSession { _ in
                requestCount.increment()
                return (401, Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"rejected"}}"#.utf8))
            }
            defer {
                gate.resolve(())
                session.invalidateAndCancel()
                SafariAuthorizationURLProtocol.removeRequestHandler()
            }
            let client = SafariRPCClient(urlSession: session, authorizationProvider: provider)
            let endpoint = alchemyEndpoint(try XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2")))
            let method = checkpoint == .invalidation ? "eth_sendRawTransaction" : "eth_blockNumber"
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method])
            let task = Task { try await client.send(endpoint: endpoint, request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()) }
            await fulfillment(of: [reachedCheckpoint], timeout: 2)
            task.cancel()
            gate.resolve(())
            switch await task.result {
            case .success:
                XCTFail("Canceled request accepted a response after \(checkpoint)")
            case .failure(let error):
                XCTAssertTrue(error is CancellationError, "Unexpected cancellation result: \(error)")
            }
            XCTAssertEqual(requestCount.value, checkpoint == .authorization ? 0 : 1)
            XCTAssertEqual(provider.replacementCallCount, checkpoint == .replacement ? 1 : 0)
            XCTAssertEqual(provider.invalidationCallCount, checkpoint == .invalidation ? 1 : 0)
        }
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationAfterNetworkFailure()
        async throws
    {
        try await assertSafariRawSendDoesNotRecoverAuthorization(
            response: { _ in
                throw URLError(.networkConnectionLost)
            },
            validate: { response in
                XCTAssertNil(response)
            }
        )
    }

    func testSafariRPCClientDoesNotRefreshAuthorizationForHTTP200RPCError()
        async throws
    {
        try await assertSafariRawSendDoesNotRecoverAuthorization(
            response: { _ in
                return (
                    200,
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"already processed"}}"#.utf8
                    )
                )
            },
            validate: { response in
                let error = response?["error"] as? [String: Any]
                XCTAssertEqual(error?["code"] as? Int, -32_002)
                XCTAssertEqual(error?["message"] as? String, "already processed")
            }
        )
    }

    func testSafariRPCClientNeverAttachesAuthorizationToCustomOrKeyedURLs() async throws {
        let keylessCustomURL = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2")
        )
        let urls = try [
            XCTUnwrap(URL(string: "https://rpc.example/custom")),
            keylessCustomURL,
            XCTUnwrap(URL(string: "https://eth-mainnet.g.alchemy.com/v2/embedded-key")),
        ]
        let authorizationProvider = SafariAuthorizationProviderStub(token: "alchemy-only-token")
        for url in urls {
            let session = makeSafariAuthorizationSession { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data(#"{"result":"ok"}"#.utf8))
            }
            let client = SafariRPCClient(
                urlSession: session,
                authorizationProvider: authorizationProvider
            )
            let completion = expectation(description: "Unauthenticated RPC completed for \(url)")

            Task { @MainActor in
                let response =
                    (try? await client.send(
                        endpoint: .unauthenticated(url), request: Self.rpcRequest(Data(#"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}"#.utf8), id: 1), execution: Self.rpcExecution()))?.json
                XCTAssertEqual(response?["result"] as? String, "ok")
                completion.fulfill()
            }

            await fulfillment(of: [completion], timeout: 2)
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }

        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    private nonisolated static func rpcRequest(_ body: Data, id: Int) throws -> ValidatedRPCRequest {
        try ValidatedRPCRequest(body: String(decoding: body, as: UTF8.self), id: id)
    }

    private nonisolated static func rpcExecution() -> SafariRPCExecution {
        SafariRPCExecution(
            deadline: .now.advanced(by: .seconds(30)),
            responseBudget: SafariRPCResponseBudget(maximumBytes: SafariRPCLimits.live.maximumBufferedResponseBytes)
        )
    }

    private func alchemyEndpoint(_ url: URL) -> EthereumRPCEndpoint {
        return .catalog(url, alchemyNetwork: "eth-mainnet")
    }

    private func makeSafariAuthorizationSession(
        requestHandler: @escaping SafariAuthorizationURLProtocol.RequestHandler
    ) -> URLSession {
        SafariAuthorizationURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafariAuthorizationURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func assertSafariRawSendDoesNotRecoverAuthorization(
        response: @escaping SafariAuthorizationURLProtocol.RequestHandler,
        validate: @escaping ([String: Any]?) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let url = try XCTUnwrap(
            URL(string: "https://eth-mainnet.g.alchemy.com/v2"),
            file: file,
            line: line
        )
        let body = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x01"]}"#.utf8
        )
        let requestCount = LockedNetworkCatalogCounter()
        let session = makeSafariAuthorizationSession { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token",
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Self.bodyData(from: request),
                try Self.rpcRequest(body, id: 1).body,
                file: file,
                line: line
            )
            return try response(request)
        }
        defer {
            session.invalidateAndCancel()
            SafariAuthorizationURLProtocol.removeRequestHandler()
        }
        let authorizationProvider = SafariAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-replacement-token"
        )
        let client = SafariRPCClient(
            urlSession: session,
            authorizationProvider: authorizationProvider
        )
        let completion = expectation(
            description: "Non-401 Safari raw-send failure returned"
        )
        completion.assertForOverFulfill = true

        Task { @MainActor in
            let result = (try? await client.send(endpoint: alchemyEndpoint(url), request: Self.rpcRequest(body, id: 1), execution: Self.rpcExecution()))?
                .json
            validate(result)
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(requestCount.value, 1, file: file, line: line)
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

    nonisolated private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? URLError(.cannotDecodeRawData)
            }
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }

}

private final class SafariAuthorizationProviderStub: AlchemyAuthorizationProviding {
    enum Checkpoint: Equatable, Sendable { case authorization, replacement, invalidation }
    private struct State: Sendable {
        var authorizationCallCount = 0
        var replacementCallCount = 0
        var invalidatedTokens = [String]()
        var invalidationURLs = [URL]()
    }
    private let state = Mutex(State())
    private let token: String?
    private let replacementToken: String?
    private let pause: @Sendable (Checkpoint) async -> Void

    init(
        token: String? = nil,
        replacementToken: String? = nil,
        pause: @escaping @Sendable (Checkpoint) async -> Void = { _ in }
    ) {
        self.token = token
        self.replacementToken = replacementToken
        self.pause = pause
    }

    var authorizationCallCount: Int { state.withLock { $0.authorizationCallCount } }
    var replacementCallCount: Int { state.withLock { $0.replacementCallCount } }
    var invalidationCallCount: Int { state.withLock { $0.invalidatedTokens.count } }
    var invalidatedTokens: [String] { state.withLock { $0.invalidatedTokens } }
    var invalidationURLs: [URL] { state.withLock { $0.invalidationURLs } }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.authorizationCallCount += 1 }
        await pause(.authorization)
        return AlchemyJWTProvider.isAlchemyRPCURL(url) ? token.map { AlchemyAuthorization(token: $0) } : nil
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.replacementCallCount += 1 }
        await pause(.replacement)
        return AlchemyJWTProvider.isAlchemyRPCURL(url) ? replacementToken.map { AlchemyAuthorization(token: $0) } : nil
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        state.withLock { state in
            state.invalidatedTokens.append(rejected.token)
            state.invalidationURLs.append(url)
        }
        await pause(.invalidation)
    }
}


private final class LockedNetworkCatalogCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    @discardableResult
    func increment() -> Int {
        count.withLock {
            $0 += 1; return $0
        }
    }
}

private final class SafariAuthorizationURLProtocol: URLProtocol {

    typealias RequestHandler = @Sendable (URLRequest) throws -> (statusCode: Int, data: Data)

    private static let requestHandler = Mutex<RequestHandler?>(nil)
    static func setRequestHandler(_ handler: @escaping RequestHandler) { requestHandler.withLock { $0 = handler } }
    static func removeRequestHandler() { requestHandler.withLock { $0 = nil } }
    private static func currentRequestHandler() -> RequestHandler? { requestHandler.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let requestHandler = Self.currentRequestHandler(),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let result = try requestHandler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: result.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

}

private final class SafariRedirectURLProtocol: URLProtocol {

    private struct Configuration: Sendable {
        var sourceURL: URL?
        var redirectURL: URL?
        var statusCode = 307
        var responseData = Data()
        var recordedURLs = [URL]()
    }
    private static let configuration = Mutex(Configuration())
    static var requestCount: Int { configuration.withLock { $0.recordedURLs.count } }
    static var requestedURLs: [URL] { configuration.withLock { $0.recordedURLs } }

    static func configure(sourceURL: URL, redirectURL: URL, statusCode: Int, responseData: Data) {
        configuration.withLock { $0 = Configuration(sourceURL: sourceURL, redirectURL: redirectURL, statusCode: statusCode, responseData: responseData) }
    }
    static func reset() { configuration.withLock { $0 = Configuration() } }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        let (sourceURL, redirectURL, statusCode, responseData) = Self.configuration.withLock { configuration in
            configuration.recordedURLs.append(url)
            return (configuration.sourceURL, configuration.redirectURL, configuration.statusCode, configuration.responseData)
        }

        guard url == sourceURL,
              let redirectURL,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectURL.absoluteString]
              ) else {
            respondWithSuccess(for: url)
            return
        }

        var redirectRequest = request
        redirectRequest.url = redirectURL
        client?.urlProtocol(
            self,
            wasRedirectedTo: redirectRequest,
            redirectResponse: response
        )
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func respondWithSuccess(for url: URL) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"jsonrpc":"2.0","id":1,"result":"redirected"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

}

private final class SafariRPCClientURLProtocol: URLProtocol {
    // Only terminal delivery crosses the Foundation boundary; each loader gates completion and cancellation.
    private final class ResponseEndpoint: @unchecked Sendable {
        private weak var owner: SafariRPCClientURLProtocol?
        let identifier: ObjectIdentifier
        let request: URLRequest

        init(_ owner: SafariRPCClientURLProtocol) {
            self.owner = owner
            identifier = ObjectIdentifier(owner)
            request = owner.request
        }

        func complete(data: Data?) { owner?.completeResponse(data: data) }
    }

    private struct State: Sendable {
        var pending = [ResponseEndpoint]()
        var requestStarted: (@Sendable () -> Void)?
    }
    private static let state = Mutex(State())
    private let responseFinished = Mutex(false)

    static var pendingRequests: [URLRequest] {
        state.withLock { $0.pending.map(\.request) }
    }

    static func reset(requestStarted: (@Sendable () -> Void)? = nil) {
        state.withLock { $0 = State(requestStarted: requestStarted) }
    }

    static func completePendingRequestsInReverse(responseData: (URLRequest) -> Data?) {
        let endpoints = state.withLock { state in
            let endpoints = Array(state.pending.reversed())
            state.pending.removeAll()
            state.requestStarted = nil
            return endpoints
        }
        for endpoint in endpoints { endpoint.complete(data: responseData(endpoint.request)) }
    }

    private func completeResponse(data: Data?) {
        let canFinish = responseFinished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard canFinish else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]),
              let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let endpoint = ResponseEndpoint(self)
        let started = Self.state.withLock { state in
            state.pending.append(endpoint)
            return state.requestStarted
        }
        started?()
    }

    override func stopLoading() {
        responseFinished.withLock { $0 = true }
        let identifier = ObjectIdentifier(self)
        Self.state.withLock { $0.pending.removeAll { $0.identifier == identifier } }
    }
}
