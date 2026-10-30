import Foundation
import Synchronization
import WalletDomain
@testable import WalletNetworking
import XCTest

@MainActor
final class NativeRPCClientPolicyTests: XCTestCase {
    func testEthereumReadPolicyFailuresDoNotRetryOrReplaceAuthorization() async throws {
        for policy in ResponsePolicyCase.allCases {
            for status in [200, 401] {
                let authorization = NativeClientAuthorization()
                let retries = NativeClientCounter()
                let session = makeSession { _, _ in policy.plan(status: status) }
                defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                let client = EthereumRPC(urlSession: session, authorizationProvider: authorization, waitForRetry: {
                    retries.increment()
                })
                do {
                    _ = try await client.fetchChainID(endpoint: ethereumEndpoint)
                    XCTFail("Expected terminal \(policy) rejection for HTTP \(status)")
                } catch {}
                let requests = NativeClientURLProtocol.requests
                XCTAssertEqual(requests.count, 1, "\(policy), HTTP \(status)")
                XCTAssertEqual(requests.first?.rpcMethod, "eth_chainId")
                XCTAssertEqual(requests.first?.url, ethereumEndpoint.url)
                XCTAssertEqual(requests.first?.method, "POST")
                XCTAssertEqual(authorization.authorizationCount, 1)
                XCTAssertEqual(authorization.replacementCount, 0)
                XCTAssertEqual(authorization.invalidatedTokens, status == 401 ? ["initial-token"] : [])
                XCTAssertEqual(retries.value, 0)
            }
        }
    }

    func testBroadcastPolicyFailuresRemainUnknownWithoutResubmission() async throws {
        for chain in NativeChain.allCases {
            for policy in ResponsePolicyCase.allCases {
                for status in [200, 401] {
                    let authorization = NativeClientAuthorization()
                    let session = makeSession { _, _ in policy.plan(status: status) }
                    defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                    let result = await broadcaster(session, authorization: authorization).broadcast(broadcastRequest(chain))
                    guard case .submissionUnknown = result else {
                        XCTFail("Expected uncertain \(chain) submission for \(policy), HTTP \(status); got \(result)")
                        continue
                    }
                    let requests = NativeClientURLProtocol.requests
                    XCTAssertEqual(requests.count, 1, "\(chain), \(policy), HTTP \(status)")
                    XCTAssertEqual(requests.first?.rpcMethod, chain.sendMethod)
                    XCTAssertEqual(requests.first?.method, "POST")
                    XCTAssertEqual(requests.first?.url, endpointURL(chain))
                    XCTAssertEqual(authorization.authorizationCount, 1)
                    XCTAssertEqual(authorization.replacementCount, 0)
                    XCTAssertEqual(authorization.invalidatedTokens, status == 401 ? ["initial-token"] : [])
                }
            }
        }
    }

    func testFailedTransfersDiscardValidJSONPrefixesWithoutResubmitting() async throws {
        for chain in NativeChain.allCases {
            for status in [200, 401] {
                for (kind, body) in [("success", Self.success(chain.transactionID)), ("error", Self.unauthorized)] {
                    let context = "\(chain), HTTP \(status), \(kind) prefix"
                    let started = expectation(description: "Started \(context)")
                    let authorization = NativeClientAuthorization()
                    let session = makeSession { _, index in
                        if index == 0 {
                            return .init(status: status, chunks: [], finishes: false, started: { started.fulfill() })
                        }
                        return .init(chunks: [Self.success(chain.transactionID)])
                    }
                    defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                    let client = broadcaster(session, authorization: authorization)
                    let request = broadcastRequest(chain)
                    let pending = Task { await client.broadcast(request) }
                    await fulfillment(of: [started], timeout: 2)
                    let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
                        session.getAllTasks { continuation.resume(returning: $0) }
                    }
                    let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
                    let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
                    let response = try XCTUnwrap(HTTPURLResponse(
                        url: endpointURL(chain), statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json", "Content-Length": String(body.count + 1)]
                    ))
                    let headers = expectation(description: "Delivered headers for \(context)")
                    delegate.urlSession?(session, dataTask: task, didReceive: response) { disposition in
                        XCTAssertEqual(disposition, .allow)
                        headers.fulfill()
                    }
                    await fulfillment(of: [headers], timeout: 2)
                    delegate.urlSession?(session, dataTask: task, didReceive: body)
                    delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
                    let result = await pending.value
                    switch result {
                    case .submissionUnknown: break
                    default: XCTFail("Expected uncertain submission for \(context); got \(result)")
                    }
                    XCTAssertEqual(NativeClientURLProtocol.requests.count, 1, context)
                    XCTAssertEqual(NativeClientURLProtocol.requests.map(\.rpcMethod), [chain.sendMethod], context)
                    XCTAssertEqual(authorization.authorizationCount, 1, context)
                    XCTAssertEqual(authorization.replacementCount, 0, context)
                    XCTAssertEqual(authorization.invalidatedTokens, status == 401 ? ["initial-token"] : [], context)
                }
            }
        }
    }

    func testSolanaConfirmationPolicyFailuresPreserveSubmittedSignature() async throws {
        for policy in ResponsePolicyCase.allCases {
            for status in [200, 401] {
                let authorization = NativeClientAuthorization()
                let session = makeSession { request, _ in
                    if request.rpcMethod == "sendTransaction" {
                        return .init(chunks: [Self.success("known-signature")])
                    }
                    return policy.plan(status: status)
                }
                defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                let result = await broadcaster(session, authorization: authorization).broadcast(
                    broadcastRequest(.solana, confirmation: .confirmed)
                )
                guard case .confirmationFailed(let transactionID, .solana(let failure)) = result,
                      case .confirmationFailed(let signature, _, _) = failure else {
                    XCTFail("Expected confirmation failure for \(policy), HTTP \(status); got \(result)")
                    continue
                }
                XCTAssertEqual(transactionID, "known-signature")
                XCTAssertEqual(signature, "known-signature")
                XCTAssertEqual(NativeClientURLProtocol.requests.map(\.rpcMethod), ["sendTransaction", "getSignatureStatuses"])
                XCTAssertTrue(NativeClientURLProtocol.requests.allSatisfy { $0.url == solanaEndpoint.url && $0.method == "POST" })
                XCTAssertEqual(authorization.authorizationCount, 2)
                XCTAssertEqual(authorization.replacementCount, 0)
                XCTAssertEqual(authorization.invalidatedTokens, status == 401 ? ["initial-token"] : [])
            }
        }
    }

    func testEthereumReadStillRecoversFromValidUnauthorizedResponseOnce() async throws {
        let authorization = NativeClientAuthorization()
        let session = makeSession { _, index in
            index == 0 ? .init(status: 401, chunks: [Self.unauthorized]) : .init(chunks: [Self.success("0x1")])
        }
        defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
        let client = EthereumRPC(urlSession: session, authorizationProvider: authorization, waitForRetry: {})
        let result = try await client.fetchChainID(endpoint: ethereumEndpoint)
        XCTAssertEqual(result, "0x1")
        assertAuthorizedReplay(method: "eth_chainId", url: ethereumEndpoint.url, authorization: authorization)
    }

    func testSolanaSendStillRecoversFromValidUnauthorizedResponseOnce() async throws {
        let authorization = NativeClientAuthorization()
        let session = makeSession { _, index in
            index == 0 ? .init(status: 401, chunks: [Self.unauthorized]) : .init(chunks: [Self.success("known-signature")])
        }
        defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
        let result = await broadcaster(session, authorization: authorization).broadcast(broadcastRequest(.solana))
        XCTAssertEqual(result, .accepted("known-signature"))
        assertAuthorizedReplay(method: "sendTransaction", url: solanaEndpoint.url, authorization: authorization)
    }

    func testEthereumSubmissionStillDoesNotReplayValidUnauthorizedResponse() async throws {
        let authorization = NativeClientAuthorization()
        let session = makeSession { _, _ in .init(status: 401, chunks: [Self.unauthorized]) }
        defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
        let result = await broadcaster(session, authorization: authorization).broadcast(broadcastRequest(.ethereum))
        guard case .rejected(.ethereum(.rpc(.serverError(let code, _, _)))) = result else {
            XCTFail("Expected the original RPC rejection; got \(result)")
            return
        }
        XCTAssertEqual(code, 401)
        XCTAssertEqual(NativeClientURLProtocol.requests.map(\.rpcMethod), ["eth_sendRawTransaction"])
        XCTAssertEqual(authorization.authorizationCount, 1)
        XCTAssertEqual(authorization.replacementCount, 0)
        XCTAssertEqual(authorization.invalidatedTokens, ["initial-token"])
    }

    func testEthereumReadRejectsEveryRedirectWithoutRetrying() async throws {
        for status in Self.redirectStatuses {
            for sameOrigin in [true, false] {
                let source = ethereumEndpoint.url
                let target = redirectTarget(source, sameOrigin: sameOrigin)
                let authorization = NativeClientAuthorization()
                let retries = NativeClientCounter()
                let session = makeSession { request, _ in
                    .init(status: request.url == source ? status : 200,
                          chunks: [Self.success("0x1")], redirect: request.url == source ? target : nil)
                }
                defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                let client = EthereumRPC(urlSession: session, authorizationProvider: authorization, waitForRetry: {
                    retries.increment()
                })
                do {
                    _ = try await client.fetchChainID(endpoint: ethereumEndpoint)
                    XCTFail("Expected HTTP \(status) redirect rejection")
                } catch {}
                assertNoRedirectDispatch(source: source, target: target, method: "eth_chainId", authorization: authorization)
                XCTAssertEqual(retries.value, 0)
            }
        }
    }

    func testBroadcastRejectsEveryRedirectWithoutTargetDispatchOrResubmission() async throws {
        for chain in NativeChain.allCases {
            for status in Self.redirectStatuses {
                for sameOrigin in [true, false] {
                    let source = endpointURL(chain)
                    let target = redirectTarget(source, sameOrigin: sameOrigin)
                    let authorization = NativeClientAuthorization()
                    let session = makeSession { request, _ in
                        .init(status: request.url == source ? status : 200,
                              chunks: [Self.success(chain.transactionID)], redirect: request.url == source ? target : nil)
                    }
                    defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                    let result = await broadcaster(session, authorization: authorization).broadcast(broadcastRequest(chain))
                    guard case .submissionUnknown = result else {
                        XCTFail("Expected uncertain \(chain) submission for HTTP \(status); got \(result)")
                        continue
                    }
                    assertNoRedirectDispatch(source: source, target: target, method: chain.sendMethod, authorization: authorization)
                }
            }
        }
    }

    func testSolanaConfirmationRedirectsPreserveSignatureWithoutAnotherPoll() async throws {
        for status in Self.redirectStatuses {
            for sameOrigin in [true, false] {
                let source = solanaEndpoint.url
                let target = redirectTarget(source, sameOrigin: sameOrigin)
                let authorization = NativeClientAuthorization()
                let session = makeSession { request, _ in
                    if request.rpcMethod == "sendTransaction" {
                        return .init(chunks: [Self.success("known-signature")])
                    }
                    return .init(status: request.url == source ? status : 200,
                                 chunks: [Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmationStatus":"finalized","err":null}]}}"#.utf8)],
                                 redirect: request.url == source ? target : nil)
                }
                defer { session.invalidateAndCancel(); NativeClientURLProtocol.reset() }
                let result = await broadcaster(session, authorization: authorization).broadcast(
                    broadcastRequest(.solana, confirmation: .confirmed)
                )
                guard case .confirmationFailed(let transactionID, .solana(let failure)) = result,
                      case .confirmationFailed(let signature, _, _) = failure else {
                    XCTFail("Expected confirmation failure for HTTP \(status); got \(result)")
                    continue
                }
                XCTAssertEqual(transactionID, "known-signature")
                XCTAssertEqual(signature, "known-signature")
                XCTAssertEqual(NativeClientURLProtocol.requests.map(\.rpcMethod), ["sendTransaction", "getSignatureStatuses"])
                XCTAssertEqual(NativeClientURLProtocol.requests.map(\.url), [source, source])
                XCTAssertEqual(authorization.authorizationCount, 2)
                XCTAssertEqual(authorization.replacementCount, 0)
            }
        }
    }

    private static let redirectStatuses = [301, 302, 303, 307, 308]
    private nonisolated static let unauthorized = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8)

    private nonisolated static func success(_ result: String) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"\(result)\"}".utf8)
    }

    private var ethereumEndpoint: EthereumRPCEndpoint {
        .catalog(URL(string: "https://eth-mainnet.g.alchemy.com/v2")!, alchemyNetwork: "eth-mainnet")
    }

    private var solanaEndpoint: SolanaRPCEndpoint {
        .init(url: URL(string: "https://solana-mainnet.g.alchemy.com/v2")!, allowsAlchemyAuthorization: true)
    }

    private func endpointURL(_ chain: NativeChain) -> URL {
        chain == .ethereum ? ethereumEndpoint.url : solanaEndpoint.url
    }

    private func redirectTarget(_ source: URL, sameOrigin: Bool) -> URL {
        sameOrigin ? source.appendingPathComponent("redirected") : URL(string: "https://untrusted.example/rpc")!
    }

    private func broadcastRequest(_ chain: NativeChain, confirmation: Solana.Commitment? = nil) -> BroadcastRequest {
        switch chain {
        case .ethereum:
            .ethereum(signedTransaction: "0x0102", expectedHash: chain.transactionID,
                      network: .init(network: .init(chainId: 1, name: "Ethereum", symbol: "ETH", rpcEndpoint: ethereumEndpoint,
                                                   isTestnet: false, mightShowPrice: true, explorer: nil), source: .alchemy))
        case .solana:
            .solana(signedTransaction: "AQID", expectedSignature: chain.transactionID, cluster: .mainnetBeta,
                    endpoint: solanaEndpoint, options: .init(confirmationCommitment: confirmation))
        }
    }

    private func broadcaster(_ session: URLSession, authorization: NativeClientAuthorization) -> SignedBroadcastClient {
        SignedBroadcastClient(
            ethereum: EthereumBroadcastClient(rpc: EthereumRPC(urlSession: session, authorizationProvider: authorization, waitForRetry: {})),
            solana: SolanaRPCClient(urlSession: session, authorizationProvider: authorization,
                                   timing: .init(now: { Date() }, sleep: { _ in throw UnexpectedNativeClientPoll() }),
                                   messages: .init(failedToSend: "Failed to send", blockhashNotFound: "Blockhash not found"))
        )
    }

    private func makeSession(_ handler: @escaping NativeClientURLProtocol.Handler) -> URLSession {
        NativeClientURLProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeClientURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }

    private func assertAuthorizedReplay(method: String, url: URL, authorization: NativeClientAuthorization,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let requests = NativeClientURLProtocol.requests
        XCTAssertEqual(requests.count, 2, file: file, line: line)
        XCTAssertEqual(requests.map(\.rpcMethod), [method, method], file: file, line: line)
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"], file: file, line: line)
        XCTAssertEqual(requests.map(\.url), [url, url], file: file, line: line)
        XCTAssertEqual(requests.map(\.authorization), ["Bearer initial-token", "Bearer replacement-token"], file: file, line: line)
        if requests.count == 2 { XCTAssertEqual(requests[0].body, requests[1].body, file: file, line: line) }
        XCTAssertEqual(authorization.authorizationCount, 1, file: file, line: line)
        XCTAssertEqual(authorization.replacementCount, 1, file: file, line: line)
    }

    private func assertNoRedirectDispatch(source: URL, target: URL, method: String, authorization: NativeClientAuthorization,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let requests = NativeClientURLProtocol.requests
        XCTAssertEqual(requests.map(\.url), [source], file: file, line: line)
        XCTAssertFalse(requests.contains { $0.url == target }, file: file, line: line)
        XCTAssertEqual(requests.map(\.rpcMethod), [method], file: file, line: line)
        XCTAssertEqual(requests.map(\.method), ["POST"], file: file, line: line)
        XCTAssertEqual(authorization.authorizationCount, 1, file: file, line: line)
        XCTAssertEqual(authorization.replacementCount, 0, file: file, line: line)
    }
}

private struct UnexpectedNativeClientPoll: Error {}

private final class NativeClientCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

private enum NativeChain: CaseIterable, Sendable {
    case ethereum, solana

    var sendMethod: String { self == .ethereum ? "eth_sendRawTransaction" : "sendTransaction" }
    var transactionID: String { self == .ethereum ? "0xknownhash" : "known-signature" }
}

private enum ResponsePolicyCase: CaseIterable, Sendable {
    case declaredBytes, streamedBytes, depth, tokens

    func plan(status: Int) -> NativeClientURLProtocol.Plan {
        let limits = NativeRPCResponseLimits.live
        switch self {
        case .declaredBytes:
            return .init(status: status, headers: ["Content-Length": String(limits.maximumResponseBytes + 1)], chunks: [], finishes: false)
        case .streamedBytes:
            let prefix = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":""#.utf8)
            let body = Data(repeating: 0x61, count: limits.maximumResponseBytes)
            return .init(status: status, chunks: [prefix, body, Data(#""}}"#.utf8)])
        case .depth:
            let nested = String(repeating: "[", count: limits.maximumJSONDepth) + "0" + String(repeating: "]", count: limits.maximumJSONDepth)
            return .init(status: status, chunks: [Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":401,\"message\":\"unauthorized\",\"data\":\(nested)}}".utf8)])
        case .tokens:
            let array = "[" + String(repeating: "0,", count: limits.maximumJSONTokens) + "0]"
            return .init(status: status, chunks: [Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":401,\"message\":\"unauthorized\",\"data\":\(array)}}".utf8)])
        }
    }
}

private final class NativeClientAuthorization: AlchemyAuthorizationProviding {
    private struct State {
        var authorizations = 0
        var replacements = 0
        var invalidatedTokens = [String]()
    }
    private let state = Mutex(State())
    var authorizationCount: Int { state.withLock { $0.authorizations } }
    var replacementCount: Int { state.withLock { $0.replacements } }
    var invalidatedTokens: [String] { state.withLock { $0.invalidatedTokens } }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.authorizations += 1 }
        return .init(token: "initial-token")
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        state.withLock { $0.replacements += 1 }
        return .init(token: "replacement-token")
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        state.withLock { $0.invalidatedTokens.append(rejected.token) }
    }
}

private final class NativeClientURLProtocol: URLProtocol {
    struct Request: Sendable {
        let url: URL
        let method: String?
        let rpcMethod: String?
        let body: Data
        let authorization: String?

        init(_ request: URLRequest) throws {
            guard let url = request.url else { throw URLError(.badURL) }
            self.url = url
            method = request.httpMethod
            authorization = request.value(forHTTPHeaderField: "Authorization")
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
                body = data
            } else { body = Data() }
            rpcMethod = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String
        }
    }

    struct Plan: Sendable {
        var status = 200
        var headers = [String: String]()
        var chunks: [Data]
        var finishes = true
        var redirect: URL?
        var started: @Sendable () -> Void = {}
    }

    typealias Handler = @Sendable (Request, Int) -> Plan
    private struct Registry {
        var handler: Handler?
        var requests = [Request]()
    }
    private static let registry = Mutex(Registry())
    private let stopped = Mutex(false)

    static var requests: [Request] { registry.withLock { $0.requests } }
    static func configure(_ handler: @escaping Handler) { registry.withLock { $0 = Registry(handler: handler) } }
    static func reset() { registry.withLock { $0 = Registry() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let recorded = try Request(request)
            let (handler, index) = Self.registry.withLock { registry in
                let index = registry.requests.count
                registry.requests.append(recorded)
                return (registry.handler, index)
            }
            guard let plan = handler?(recorded, index) else { throw URLError(.badServerResponse) }
            var headers = plan.headers
            headers["Content-Type"] = "application/json"
            if let redirect = plan.redirect { headers["Location"] = redirect.absoluteString }
            guard let response = HTTPURLResponse(url: recorded.url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw URLError(.badServerResponse)
            }
            if let redirect = plan.redirect {
                var redirectedRequest = request
                redirectedRequest.url = redirect
                client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in plan.chunks {
                guard !stopped.withLock({ $0 }) else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            plan.started()
            if plan.finishes { client?.urlProtocolDidFinishLoading(self) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}
