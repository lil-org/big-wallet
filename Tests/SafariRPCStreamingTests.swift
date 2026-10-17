import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class SafariRPCStreamingTests: XCTestCase {
    func testAcceptsExactByteLimitAndProjectsResponseBeforeReleasingBudget() async throws {
        let data = Data(#"{"id":1,"result":{"value":"ok"},"privateUpstreamField":true}"#.utf8)
        let session = makeSession { _ in .init(headers: ["Content-Length": String(data.count)], chunks: [data]) }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let budget = SafariRPCResponseBudget(maximumBytes: data.count)
        let execution = execution(maximumResponseBytes: data.count, budget: budget)
        let result = try await SafariRPCClient(urlSession: session).send(
            endpoint: endpoint(), request: request(), execution: execution
        )
        XCTAssertEqual((result.json["result"] as? [String: Any])?["value"] as? String, "ok")
        XCTAssertNil(result.json["privateUpstreamField"])
        XCTAssertTrue(execution.dispatched)
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testDeclaredOversizedResponseCancelsBeforeWaitingForBody() async throws {
        let stopped = expectation(description: "Oversized declared response cancelled")
        let headers = ["Content-Length": "4096", "Content-Type": "application/json"]
        let response = try XCTUnwrap(HTTPURLResponse(
            url: endpoint().url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers
        ))
        XCTAssertEqual(response.expectedContentLength, 4096)
        XCTAssertEqual(response.mimeType, "application/json")
        let session = makeSession { _ in
            .init(headers: headers, chunks: [], finishes: false, stopped: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let budget = SafariRPCResponseBudget(maximumBytes: 128)
        await assertFailure(.responseTooLarge) {
            try await SafariRPCClient(urlSession: session).send(
                endpoint: self.endpoint(), request: self.request(),
                execution: self.execution(maximumResponseBytes: 128, budget: budget)
            )
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testActualStreamLimitAppliesWithoutOrWithShortContentLength() async throws {
        let data = Data(#"{"id":1,"result":"oversized response"}"#.utf8)
        for headers: [String: String] in [[:], ["Content-Length": "1"]] {
            let session = makeSession { _ in
                .init(headers: headers, chunks: [Data(data.prefix(12)), Data(data.dropFirst(12))])
            }
            defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
            let budget = SafariRPCResponseBudget(maximumBytes: 64)
            await assertFailure(.responseTooLarge) {
                try await SafariRPCClient(urlSession: session).send(
                    endpoint: self.endpoint(), request: self.request(),
                    execution: self.execution(maximumResponseBytes: data.count - 1, budget: budget)
                )
            }
            XCTAssertEqual(budget.bufferedBytes, 0)
        }
    }

    func testAggregateResponseBudgetRejectsWithoutLeakingReservation() async throws {
        let data = Data(#"{"result":"ok"}"#.utf8)
        let session = makeSession { _ in .init(chunks: [data]) }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let budget = SafariRPCResponseBudget(maximumBytes: data.count)
        let occupied = budget.acquire()
        try occupied.reserve(data.count - 1)
        await assertFailure(.busy) {
            try await SafariRPCClient(urlSession: session).send(
                endpoint: self.endpoint(), request: self.request(),
                execution: self.execution(maximumResponseBytes: 128, budget: budget)
            )
        }
        XCTAssertEqual(budget.bufferedBytes, data.count - 1)
        occupied.release()
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testMalformedResponseReleasesItsBuffer() async throws {
        let session = makeSession { _ in .init(chunks: [Data("not-json".utf8)]) }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let budget = SafariRPCResponseBudget(maximumBytes: 128)
        await assertFailure(.transport) {
            try await SafariRPCClient(urlSession: session).send(
                endpoint: self.endpoint(), request: self.request(),
                execution: self.execution(maximumResponseBytes: 128, budget: budget)
            )
        }
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testCancellationStopsIncompleteNetworkResponseAndReleasesBudget() async throws {
        let started = expectation(description: "Incomplete response started")
        let stopped = expectation(description: "Incomplete response cancelled")
        let session = makeSession { _ in
            .init(chunks: [Data(#"{"result":""#.utf8)], finishes: false,
                  started: { started.fulfill() }, stopped: { stopped.fulfill() })
        }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let client = SafariRPCClient(urlSession: session)
        let budget = SafariRPCResponseBudget(maximumBytes: 128)
        let execution = execution(maximumResponseBytes: 128, budget: budget)
        let endpoint = endpoint()
        let request = try request()
        let task = Task { try await client.send(endpoint: endpoint, request: request, execution: execution) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled RPC returned a response")
        } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testBothUnauthorizedAttemptsRemainSubjectToResponseLimits() async throws {
        for oversizedAttempt in [0, 1] {
            let budget = SafariRPCResponseBudget(maximumBytes: 64)
            let authorization = RPCStreamingAuthorization {
                XCTAssertEqual(budget.bufferedBytes, 0, "First attempt buffer survived into authorization recovery")
            }
            let session = makeSession { index in
                let data = index == oversizedAttempt ? Data(repeating: 65, count: 65) : Data(#"{"error":"unauthorized"}"#.utf8)
                return .init(status: 401, chunks: [data])
            }
            defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
            await assertFailure(.responseTooLarge) {
                try await SafariRPCClient(urlSession: session, authorizationProvider: authorization).send(
                    endpoint: self.alchemyEndpoint(), request: self.request(),
                    execution: self.execution(maximumResponseBytes: 64, budget: budget)
                )
            }
            XCTAssertEqual(authorization.replacementCount, oversizedAttempt)
            XCTAssertEqual(authorization.invalidatedTokens, [oversizedAttempt == 0 ? "initial" : "replacement"])
            XCTAssertEqual(RPCStreamingURLProtocol.requestCount, oversizedAttempt + 1)
            XCTAssertEqual(budget.bufferedBytes, 0)
        }
    }

    func testRawSubmissionResponseLimitFailuresInvalidateWithoutReplay() async throws {
        let chunk = Data(repeating: 65, count: 32)
        let cases: [(headers: [String: String], chunks: [Data], occupiedBytes: Int, failure: SafariRPCFailure)] = [
            (["Content-Length": "65"], [], 0, .responseTooLarge),
            ([:], [chunk, chunk + Data([65])], 0, .responseTooLarge),
            ([:], [chunk, chunk], 1, .busy)
        ]
        for status in [401, 500] {
            for testCase in cases {
                let authorization = RPCStreamingAuthorization()
                let session = makeSession { _ in
                    .init(status: status, headers: testCase.headers, chunks: testCase.chunks)
                }
                defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
                let budget = SafariRPCResponseBudget(maximumBytes: 64)
                let occupied = budget.acquire()
                try occupied.reserve(testCase.occupiedBytes)
                await assertFailure(testCase.failure) {
                    try await SafariRPCClient(urlSession: session, authorizationProvider: authorization).send(
                        endpoint: self.alchemyEndpoint(), request: self.request(method: "eth_sendRawTransaction"),
                        execution: self.execution(maximumResponseBytes: 64, budget: budget)
                    )
                }
                XCTAssertEqual(authorization.invalidatedTokens, status == 401 ? ["initial"] : [])
                XCTAssertEqual(authorization.replacementCount, 0)
                XCTAssertEqual(RPCStreamingURLProtocol.requestCount, 1)
                XCTAssertEqual(budget.bufferedBytes, testCase.occupiedBytes)
                occupied.release()
                XCTAssertEqual(budget.bufferedBytes, 0)
            }
        }
    }

    func testSecondUnauthorizedResponseInvalidatesWithoutAThirdAttempt() async throws {
        let authorization = RPCStreamingAuthorization()
        let session = makeSession { _ in .init(status: 401, chunks: [Data(#"{"error":"unauthorized"}"#.utf8)]) }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let budget = SafariRPCResponseBudget(maximumBytes: 64)
        let response = try await SafariRPCClient(urlSession: session, authorizationProvider: authorization).send(
            endpoint: alchemyEndpoint(), request: request(),
            execution: execution(maximumResponseBytes: 64, budget: budget)
        )
        XCTAssertEqual(response.json["error"] as? String, "unauthorized")
        XCTAssertEqual(authorization.replacementCount, 1)
        XCTAssertEqual(authorization.invalidationCount, 1)
        XCTAssertEqual(RPCStreamingURLProtocol.requestCount, 2)
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testDeadlineExpiredDuringAuthorizationPreventsDispatch() async throws {
        let clock = TestClock()
        let authorization = RPCStreamingAuthorization(onAuthorization: { clock.advance(by: 2_000_000_000) })
        let session = makeSession { _ in .init(chunks: [Data(#"{"result":"unexpected"}"#.utf8)]) }
        defer { session.invalidateAndCancel(); RPCStreamingURLProtocol.reset() }
        let execution = SafariRPCExecution(
            deadline: clock.instant.advanced(by: .seconds(1)), now: { clock.instant },
            responseBudget: SafariRPCResponseBudget(maximumBytes: 128)
        )
        await assertFailure(.timeout) {
            try await SafariRPCClient(urlSession: session, authorizationProvider: authorization).send(
                endpoint: self.alchemyEndpoint(), request: self.request(), execution: execution
            )
        }
        XCTAssertFalse(execution.dispatched)
        XCTAssertEqual(RPCStreamingURLProtocol.requestCount, 0)
    }

    private func endpoint() -> EthereumRPCEndpoint {
        .unauthenticated(URL(string: "https://rpc.example/test")!)
    }

    private func alchemyEndpoint() -> EthereumRPCEndpoint {
        .catalog(URL(string: "https://eth-mainnet.g.alchemy.com/v2")!, alchemyNetwork: "eth-mainnet")
    }

    private func request(method: String = "eth_blockNumber") throws -> ValidatedRPCRequest {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method])
        return try ValidatedRPCRequest(body: String(decoding: data, as: UTF8.self), id: 1)
    }

    private func execution(maximumResponseBytes: Int, budget: SafariRPCResponseBudget) -> SafariRPCExecution {
        SafariRPCExecution(deadline: .now.advanced(by: .seconds(30)),
                           limits: .init(maximumResponseBytes: maximumResponseBytes), responseBudget: budget)
    }

    private func makeSession(_ handler: @escaping RPCStreamingURLProtocol.Handler) -> URLSession {
        RPCStreamingURLProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RPCStreamingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func assertFailure(
        _ expected: SafariRPCFailure,
        file: StaticString = #filePath, line: UInt = #line,
        operation: () async throws -> RPCResponseToExtension
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch { XCTAssertEqual(error as? SafariRPCFailure, expected, file: file, line: line) }
    }
}

private final class RPCStreamingAuthorization: AlchemyAuthorizationProviding {
    private let replacements = Mutex(0)
    private let invalidations = Mutex([String]())
    private let onReplacement: @Sendable () -> Void
    private let onAuthorization: @Sendable () -> Void

    init(onAuthorization: @escaping @Sendable () -> Void = {}, onReplacement: @escaping @Sendable () -> Void = {}) {
        self.onAuthorization = onAuthorization
        self.onReplacement = onReplacement
    }

    var replacementCount: Int { replacements.withLock { $0 } }
    var invalidationCount: Int { invalidations.withLock { $0.count } }
    var invalidatedTokens: [String] { invalidations.withLock { $0 } }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        onAuthorization()
        return .init(token: "initial")
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        replacements.withLock { $0 += 1 }
        onReplacement()
        return .init(token: "replacement")
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        invalidations.withLock { $0.append(rejected.token) }
    }
}

private final class RPCStreamingURLProtocol: URLProtocol {
    struct Plan: Sendable {
        var status = 200
        var headers = [String: String]()
        var chunks: [Data]
        var finishes = true
        var started: @Sendable () -> Void = {}
        var stopped: @Sendable () -> Void = {}
    }

    typealias Handler = @Sendable (Int) -> Plan
    private struct Registry {
        var handler: Handler?
        var count = 0
    }
    private struct State {
        var finished = false
        var stopped: (@Sendable () -> Void)?
    }
    private static let registry = Mutex(Registry())
    private let state = Mutex(State())

    static var requestCount: Int { registry.withLock { $0.count } }
    static func configure(_ handler: @escaping Handler) { registry.withLock { $0 = Registry(handler: handler) } }
    static func reset() { registry.withLock { $0 = Registry() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let registration = Self.registry.withLock { registry -> (Handler?, Int) in
            defer { registry.count += 1 }
            return (registry.handler, registry.count)
        }
        guard let plan = registration.0?(registration.1), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        state.withLock { $0.stopped = plan.stopped }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks {
            guard !state.withLock({ $0.finished }) else { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        plan.started()
        if plan.finishes {
            let finish = state.withLock { state in
                guard !state.finished else { return false }
                state.finished = true
                return true
            }
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        let stopped = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.finished else { return nil }
            state.finished = true
            return state.stopped
        }
        stopped?()
    }
}
