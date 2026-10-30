import Foundation
import Synchronization
import XCTest
import WalletRuntimeTestSupport
@testable import WalletNetworking

@MainActor
final class NativeRPCTransportTests: XCTestCase {
    func testAcceptsExactByteLimitAcrossChunksAndPreservesHTTPResponse() async throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":"accepted"}"#.utf8)
        for headers in [[:], ["Content-Length": String(data.count)]] {
            let session = makeSession(.init(
                status: 401, headers: headers, chunks: [Data(data.prefix(12)), Data(data.dropFirst(12))]
            ))
            defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
            let response = try await session.responsePreservingTransportError(
                for: request(), limits: .init(maximumResponseBytes: data.count)
            )
            XCTAssertEqual(response.data, data)
            XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, 401)
            XCTAssertNil(response.error)
            XCTAssertEqual(NativeTransportURLProtocol.requestCount, 1)
        }
    }

    func testDeclaredOversizeCancelsWithoutWaitingForBody() async throws {
        let stopped = expectation(description: "Oversized header stopped transfer")
        let session = makeSession(.init(
            status: 401, headers: ["Content-Length": "65"], chunks: [], finishes: false,
            stopped: { stopped.fulfill() }
        ))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let response = try await session.responsePreservingTransportError(
            for: request(), limits: .init(maximumResponseBytes: 64)
        )
        XCTAssertNil(response.data)
        XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(response.error as? NativeRPCResponsePolicyError, .responseTooLarge)
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testActualByteLimitRejectsMissingAndMisleadingContentLengths() async throws {
        let prefix = Data(#"{"jsonrpc":"2.0","id":1,"result":"accepted"}"#.utf8)
        let limit = prefix.count + 8
        for headers in [[:], ["Content-Length": "1"]] {
            let stopped = expectation(description: "Overflow stopped transfer")
            let session = makeSession(.init(
                headers: headers, chunks: [prefix, Data(repeating: 32, count: 9)], finishes: false,
                stopped: { stopped.fulfill() }
            ))
            defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
            let response = try await session.responsePreservingTransportError(
                for: request(), limits: .init(maximumResponseBytes: limit)
            )
            XCTAssertNil(response.data, "A complete JSON prefix must not survive overflow")
            XCTAssertEqual(response.error as? NativeRPCResponsePolicyError, .responseTooLarge)
            await fulfillment(of: [stopped], timeout: 2)
        }
    }

    func testDiscardsBodyButPreservesHTTPStatusWithTransportFailure() async throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":401,"message":"unauthorized"}}"#.utf8)
        let started = expectation(description: "Response started")
        let session = makeSession(.init(status: 401, chunks: [], finishes: false, started: { started.fulfill() }))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task { try await session.responsePreservingTransportError(for: request) }
        await fulfillment(of: [started], timeout: 2)
        let tasks = await sessionTasks(session)
        let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
        let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
        let headers = try XCTUnwrap(HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        ))
        let accepted = expectation(description: "Headers delivered")
        delegate.urlSession?(session, dataTask: task, didReceive: headers) { disposition in
            XCTAssertEqual(disposition, .allow)
            accepted.fulfill()
        }
        await fulfillment(of: [accepted], timeout: 2)
        delegate.urlSession?(session, dataTask: task, didReceive: data)
        delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        let response = try await pending.value
        XCTAssertNil(response.data)
        XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual((response.error as? URLError)?.code, .networkConnectionLost)
    }

    func testCancellationStopsUnfinishedResponseAndIgnoresLateCallbacks() async throws {
        let started = expectation(description: "Incomplete response started")
        let stopped = expectation(description: "Incomplete response cancelled")
        let session = makeSession(.init(
            chunks: [Data("{".utf8)], finishes: false,
            started: { started.fulfill() }, stopped: { stopped.fulfill() }
        ))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task { try await session.responsePreservingTransportError(for: request) }
        await fulfillment(of: [started], timeout: 2)
        let tasks = await sessionTasks(session)
        let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
        let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancelled transfer returned a response")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        delegate.urlSession?(session, dataTask: task, didReceive: Data(repeating: 65, count: 128))
        delegate.urlSession?(session, task: task, didCompleteWithError: nil)
        delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    func testLimitFailureIgnoresLateSuccessAndFailureCallbacks() async throws {
        let started = expectation(description: "Incomplete response started")
        let stopped = expectation(description: "Overflow cancelled transfer")
        let session = makeSession(.init(
            chunks: [Data("{".utf8)], finishes: false,
            started: { started.fulfill() }, stopped: { stopped.fulfill() }
        ))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task {
            try await session.responsePreservingTransportError(for: request, limits: .init(maximumResponseBytes: 8))
        }
        await fulfillment(of: [started], timeout: 2)
        let tasks = await sessionTasks(session)
        let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
        let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
        delegate.urlSession?(session, dataTask: task, didReceive: Data(repeating: 65, count: 9))
        let response = try await pending.value
        XCTAssertNil(response.data)
        XCTAssertEqual(response.error as? NativeRPCResponsePolicyError, .responseTooLarge)
        await fulfillment(of: [stopped], timeout: 2)
        delegate.urlSession?(session, dataTask: task, didReceive: Data("{}".utf8))
        delegate.urlSession?(session, task: task, didCompleteWithError: nil)
        delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
    }

    func testAlreadyCancelledCallerDoesNotDispatch() async throws {
        let gate = TestGate<Void>()
        let session = makeSession(.init(chunks: [Data("{}".utf8)]))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task {
            await gate.wait()
            return try await session.responsePreservingTransportError(for: request)
        }
        pending.cancel()
        gate.resolve(())
        do {
            _ = try await pending.value
            XCTFail("Already cancelled caller dispatched")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(NativeTransportURLProtocol.requestCount, 0)
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://native-rpc.example/test")!)
    }

    private func makeSession(_ plan: NativeTransportURLProtocol.Plan) -> URLSession {
        NativeTransportURLProtocol.configure(plan)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeTransportURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }

    private func sessionTasks(_ session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }
}

private final class NativeTransportURLProtocol: URLProtocol {
    struct Plan: Sendable {
        var status = 200
        var headers = [String: String]()
        var chunks: [Data]
        var finishes = true
        var started: @Sendable () -> Void = {}
        var stopped: @Sendable () -> Void = {}
    }

    private struct Registry {
        var plan: Plan?
        var requestCount = 0
    }

    private struct State {
        var finished = false
        var stopped: (@Sendable () -> Void)?
    }

    private static let registry = Mutex(Registry())
    private let state = Mutex(State())

    static var requestCount: Int { registry.withLock { $0.requestCount } }
    static func configure(_ plan: Plan) { registry.withLock { $0 = Registry(plan: plan) } }
    static func reset() { registry.withLock { $0 = Registry() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let plan = Self.registry.withLock { registry in
            registry.requestCount += 1
            return registry.plan
        }
        guard let plan, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var headers = plan.headers
        headers["Content-Type"] = "application/json"
        guard
              let response = HTTPURLResponse(
                url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers
              ) else {
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
        guard plan.finishes else { return }
        let finished = state.withLock { state in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        guard finished else { return }
        client?.urlProtocolDidFinishLoading(self)
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
