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
                for: request(), policy: .init(maximumResponseBytes: data.count)
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
            for: request(), policy: .init(maximumResponseBytes: 64)
        )
        XCTAssertNil(response.data)
        XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(response.error as? HTTPResponsePolicyError, .responseTooLarge)
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
                for: request(), policy: .init(maximumResponseBytes: limit)
            )
            XCTAssertNil(response.data, "A complete JSON prefix must not survive overflow")
            XCTAssertEqual(response.error as? HTTPResponsePolicyError, .responseTooLarge)
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
        let timerStarted = expectation(description: "Deadline timer started")
        let timerStopped = expectation(description: "Deadline timer cancelled")
        let clock = TransportTestClock(onStart: { timerStarted.fulfill() }, onStop: { timerStopped.fulfill() })
        let session = makeSession(.init(
            chunks: [Data("{".utf8)], finishes: false,
            started: { started.fulfill() }, stopped: { stopped.fulfill() }
        ))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task {
            try await session.responsePreservingTransportError(
                for: request, policy: .init(maximumResponseBytes: 64, totalTimeout: .seconds(5)), timing: clock.timing
            )
        }
        await fulfillment(of: [started, timerStarted], timeout: 2)
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
        await fulfillment(of: [stopped, timerStopped], timeout: 2)
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
            try await session.responsePreservingTransportError(for: request, policy: .init(maximumResponseBytes: 8))
        }
        await fulfillment(of: [started], timeout: 2)
        let tasks = await sessionTasks(session)
        let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
        let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
        delegate.urlSession?(session, dataTask: task, didReceive: Data(repeating: 65, count: 9))
        let response = try await pending.value
        XCTAssertNil(response.data)
        XCTAssertEqual(response.error as? HTTPResponsePolicyError, .responseTooLarge)
        await fulfillment(of: [stopped], timeout: 2)
        delegate.urlSession?(session, dataTask: task, didReceive: Data("{}".utf8))
        delegate.urlSession?(session, task: task, didCompleteWithError: nil)
        delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
    }

    func testAlreadyCancelledCallerDoesNotDispatch() async throws {
        let gate = TestGate<Void>()
        let clock = TransportTestClock()
        let session = makeSession(.init(chunks: [Data("{}".utf8)]))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task {
            await gate.wait()
            return try await session.responsePreservingTransportError(
                for: request, policy: .init(maximumResponseBytes: 64, totalTimeout: .seconds(5)), timing: clock.timing
            )
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
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

    func testTotalDeadlineStopsStalledResponsesBeforeAndAfterHeaders() async throws {
        for receivesHeaders in [false, true] {
            let started = expectation(description: "Stalled response started")
            let stopped = expectation(description: "Stalled response stopped")
            let timerStarted = expectation(description: "Deadline timer started")
            let timerStopped = expectation(description: "Deadline timer finished")
            let clock = TransportTestClock(onStart: { timerStarted.fulfill() }, onStop: { timerStopped.fulfill() })
            let session = makeSession(.init(
                chunks: [], finishes: false, receivesHeaders: false,
                started: { started.fulfill() }, stopped: { stopped.fulfill() }
            ))
            defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
            let request = request()
            let pending = Task {
                try await session.responsePreservingTransportError(
                    for: request, policy: .init(maximumResponseBytes: 64, totalTimeout: .seconds(5)), timing: clock.timing
                )
            }
            await fulfillment(of: [started, timerStarted], timeout: 2)
            let tasks = await sessionTasks(session)
            let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
            let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
            if receivesHeaders {
                try await deliverHeaders(to: delegate, session: session, task: task, status: 401)
                delegate.urlSession?(session, dataTask: task, didReceive: Data("{".utf8))
            }
            clock.advance(by: .seconds(5))
            let response = try await pending.value
            XCTAssertNil(response.data)
            XCTAssertEqual((response.response as? HTTPURLResponse)?.statusCode, receivesHeaders ? 401 : nil)
            XCTAssertEqual(response.error as? HTTPResponsePolicyError, .deadlineExceeded)
            await fulfillment(of: [stopped, timerStopped], timeout: 2)
            delegate.urlSession?(session, dataTask: task, didReceive: Data("}".utf8))
            delegate.urlSession?(session, task: task, didCompleteWithError: nil)
            delegate.urlSession?(session, task: task, didCompleteWithError: URLError(.cancelled))
            XCTAssertEqual(NativeTransportURLProtocol.requestCount, 1)
        }
    }

    func testStreamingChunksDoNotExtendTheOriginalDeadline() async throws {
        let started = expectation(description: "Streaming response started")
        let stopped = expectation(description: "Expired stream stopped")
        let timerStarted = expectation(description: "Deadline timer started")
        let timerStopped = expectation(description: "Deadline timer cancelled")
        let clock = TransportTestClock(onStart: { timerStarted.fulfill() }, onStop: { timerStopped.fulfill() })
        let initialInstant = clock.now
        let session = makeSession(.init(
            chunks: [], finishes: false, receivesHeaders: false,
            started: { started.fulfill() }, stopped: { stopped.fulfill() }
        ))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let request = request()
        let pending = Task {
            try await session.responsePreservingTransportError(
                for: request, policy: .init(maximumResponseBytes: 64, totalTimeout: .seconds(5)), timing: clock.timing
            )
        }
        await fulfillment(of: [started, timerStarted], timeout: 2)
        let tasks = await sessionTasks(session)
        let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
        let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
        try await deliverHeaders(to: delegate, session: session, task: task)
        for _ in 0..<2 {
            clock.advance(by: .seconds(2), wakingTimer: false)
            delegate.urlSession?(session, dataTask: task, didReceive: Data(" ".utf8))
        }
        XCTAssertEqual(clock.deadlines, [initialInstant.advanced(by: .seconds(5))])
        clock.advance(by: .seconds(1), wakingTimer: false)
        delegate.urlSession?(session, dataTask: task, didReceive: Data("{}".utf8))
        let response = try await pending.value
        XCTAssertNil(response.data)
        XCTAssertEqual(response.error as? HTTPResponsePolicyError, .deadlineExceeded)
        await fulfillment(of: [stopped, timerStopped], timeout: 2)
    }

    func testExpiredHeadersAndCompletionRejectBeforeDelayedTimerRuns() async throws {
        for completes in [false, true] {
            let started = expectation(description: "Response started")
            let timerStarted = expectation(description: "Deadline timer started")
            let timerStopped = expectation(description: "Deadline timer cancelled")
            let clock = TransportTestClock(onStart: { timerStarted.fulfill() }, onStop: { timerStopped.fulfill() })
            let session = makeSession(.init(
                chunks: [], finishes: false, receivesHeaders: false, started: { started.fulfill() }
            ))
            defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
            let request = request()
            let pending = Task {
                try await session.responsePreservingTransportError(
                    for: request, policy: .init(maximumResponseBytes: 64, totalTimeout: .seconds(5)), timing: clock.timing
                )
            }
            await fulfillment(of: [started, timerStarted], timeout: 2)
            let tasks = await sessionTasks(session)
            let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
            let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
            if completes {
                try await deliverHeaders(to: delegate, session: session, task: task)
                delegate.urlSession?(session, dataTask: task, didReceive: Data("{}".utf8))
            }
            clock.advance(by: .seconds(5), wakingTimer: false)
            if completes {
                delegate.urlSession?(session, task: task, didCompleteWithError: nil)
            } else {
                let headers = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
                let rejected = expectation(description: "Expired headers rejected")
                delegate.urlSession?(session, dataTask: task, didReceive: headers) { disposition in
                    XCTAssertEqual(disposition, .cancel)
                    rejected.fulfill()
                }
                await fulfillment(of: [rejected], timeout: 2)
            }
            let response = try await pending.value
            XCTAssertNil(response.data)
            XCTAssertEqual(response.error as? HTTPResponsePolicyError, .deadlineExceeded)
            await fulfillment(of: [timerStopped], timeout: 2)
        }
    }

    func testExpiredDeadlineDoesNotDispatch() async throws {
        let clock = TransportTestClock()
        let session = makeSession(.init(chunks: [Data("{}".utf8)]))
        defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
        let response = try await session.responsePreservingTransportError(
            for: request(), policy: .init(maximumResponseBytes: 64, totalTimeout: .zero), timing: clock.timing
        )
        XCTAssertNil(response.data)
        XCTAssertNil(response.response)
        XCTAssertEqual(response.error as? HTTPResponsePolicyError, .deadlineExceeded)
        XCTAssertEqual(NativeTransportURLProtocol.requestCount, 0)
        XCTAssertTrue(clock.deadlines.isEmpty)
    }

    func testSuccessAndPolicyRejectionsCancelTheDeadlineTimer() async throws {
        for outcome in ["success", "overflow", "redirect"] {
            let started = expectation(description: "Response started")
            let timerStarted = expectation(description: "Deadline timer started")
            let timerStopped = expectation(description: "Deadline timer cancelled")
            let clock = TransportTestClock(onStart: { timerStarted.fulfill() }, onStop: { timerStopped.fulfill() })
            let session = makeSession(.init(chunks: [], finishes: false, receivesHeaders: false, started: { started.fulfill() }))
            defer { session.invalidateAndCancel(); NativeTransportURLProtocol.reset() }
            let request = request()
            let pending = Task {
                try await session.responsePreservingTransportError(
                    for: request, policy: .init(maximumResponseBytes: 2, totalTimeout: .seconds(5)), timing: clock.timing
                )
            }
            await fulfillment(of: [started, timerStarted], timeout: 2)
            let tasks = await sessionTasks(session)
            let task = try XCTUnwrap(tasks.first as? URLSessionDataTask)
            let delegate = try XCTUnwrap(task.delegate as? any URLSessionDataDelegate)
            try await deliverHeaders(to: delegate, session: session, task: task)
            delegate.urlSession?(session, dataTask: task, didReceive: Data("{}".utf8))
            if outcome == "success" {
                delegate.urlSession?(session, task: task, didCompleteWithError: nil)
            } else if outcome == "overflow" {
                delegate.urlSession?(session, dataTask: task, didReceive: Data(" ".utf8))
            } else {
                let redirect = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil))
                let rejected = expectation(description: "Redirect rejected")
                delegate.urlSession?(session, task: task, willPerformHTTPRedirection: redirect,
                                     newRequest: URLRequest(url: URL(string: "https://redirect.example/metadata")!)) { request in
                    XCTAssertNil(request)
                    rejected.fulfill()
                }
                await fulfillment(of: [rejected], timeout: 2)
            }
            let response = try await pending.value
            XCTAssertEqual(response.data, outcome == "success" ? Data("{}".utf8) : nil)
            XCTAssertEqual(response.error as? HTTPResponsePolicyError,
                           outcome == "success" ? nil : outcome == "overflow" ? .responseTooLarge : .redirectRejected)
            await fulfillment(of: [timerStopped], timeout: 2)
            clock.advance(by: .seconds(10))
            delegate.urlSession?(session, task: task, didCompleteWithError: nil)
            XCTAssertEqual(NativeTransportURLProtocol.requestCount, 1)
        }
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://native-rpc.example/test")!)
    }

    private func deliverHeaders(
        to delegate: any URLSessionDataDelegate,
        session: URLSession,
        task: URLSessionDataTask,
        status: Int = 200
    ) async throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request().url!, statusCode: status, httpVersion: nil, headerFields: nil
        ))
        let accepted = expectation(description: "Headers accepted")
        delegate.urlSession?(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
            accepted.fulfill()
        }
        await fulfillment(of: [accepted], timeout: 2)
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

private final class TransportTestClock: Sendable {
    private struct State {
        var now = ContinuousClock.now
        var deadlines = [ContinuousClock.Instant]()
    }

    private let state = Mutex(State())
    private let sleeper = TestDeferred<Void>()
    private let onStart: @Sendable () -> Void
    private let onStop: @Sendable () -> Void

    init(onStart: @escaping @Sendable () -> Void = {}, onStop: @escaping @Sendable () -> Void = {}) {
        self.onStart = onStart
        self.onStop = onStop
    }

    var now: ContinuousClock.Instant { state.withLock { $0.now } }
    var deadlines: [ContinuousClock.Instant] { state.withLock { $0.deadlines } }
    var timing: HTTPResponseTiming {
        .init(now: { self.now }, sleepUntil: { deadline in
            self.state.withLock { $0.deadlines.append(deadline) }
            self.onStart()
            defer { self.onStop() }
            try await self.sleeper.value()
        })
    }

    func advance(by duration: Duration, wakingTimer: Bool = true) {
        let due = state.withLock { state in
            state.now += duration
            return state.deadlines.contains { $0 <= state.now }
        }
        if wakingTimer && due { sleeper.resolve(.success(())) }
    }
}

private final class NativeTransportURLProtocol: URLProtocol {
    struct Plan: Sendable {
        var status = 200
        var headers = [String: String]()
        var chunks: [Data]
        var finishes = true
        var receivesHeaders = true
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
        if plan.receivesHeaders {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
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
