import Foundation
import Synchronization
@testable import WalletNetworking

func makeMetadataSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MetadataURLProtocol.self]
    return URLSession(configuration: configuration)
}

final class MetadataURLProtocol: URLProtocol {
    private final class ResponseEndpoint: @unchecked Sendable {
        private weak var owner: MetadataURLProtocol?
        init(_ owner: MetadataURLProtocol) { self.owner = owner }
        func complete(data: Data, status: Int, error: URLError?) {
            owner?.completeResponse(data: data, status: status, error: error)
        }
    }

    private struct State: Sendable {
        var activeRequests = [ObjectIdentifier: ResponseEndpoint]()
        var onStart: (@Sendable () -> Void)?
        var onStop: (@Sendable () -> Void)?
        var requestCount = 0
        var stopLoadingCount = 0
    }

    private static let state = Mutex(State())
    private let responseFinished = Mutex(false)

    static var requestCount: Int { state.withLock { $0.requestCount } }
    static var stopLoadingCount: Int { state.withLock { $0.stopLoadingCount } }

    static func configure(onStart: @escaping @Sendable () -> Void, onStop: @escaping @Sendable () -> Void = {}) {
        state.withLock { $0 = State(onStart: onStart, onStop: onStop) }
    }

    static func complete(data: Data = Data(), status: Int = 200, error: URLError? = nil) {
        let requests = state.withLock { value in
            let requests = Array(value.activeRequests.values)
            value.activeRequests.removeAll()
            return requests
        }
        for endpoint in requests { endpoint.complete(data: data, status: status, error: error) }
    }

    static func reset() { state.withLock { $0 = State() } }

    private func completeResponse(data: Data, status: Int, error: URLError?) {
        let canFinish = responseFinished.withLock { finished in
            guard !finished else { return false }
            finished = true
            return true
        }
        guard canFinish, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let identifier = ObjectIdentifier(self)
        let endpoint = ResponseEndpoint(self)
        let onStart = Self.state.withLock { state in
            state.activeRequests[identifier] = endpoint
            state.requestCount += 1
            return state.onStart
        }
        onStart?()
    }

    override func stopLoading() {
        responseFinished.withLock { $0 = true }
        let identifier = ObjectIdentifier(self)
        let onStop = Self.state.withLock { state in
            guard state.activeRequests.removeValue(forKey: identifier) != nil else {
                return Optional<@Sendable () -> Void>.none
            }
            state.stopLoadingCount += 1
            return state.onStop
        }
        onStop?()
    }
}

final class MetadataTestClock: Sendable {
    private struct Sleeper: Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State: Sendable {
        var now = ContinuousClock.now
        var sleepers = [Sleeper]()
        var deadlines = [ContinuousClock.Instant]()
    }

    private let state = Mutex(State())
    private let onSleep: @Sendable () -> Void

    init(onSleep: @escaping @Sendable () -> Void = {}) { self.onSleep = onSleep }

    var timing: HTTPResponseTiming {
        HTTPResponseTiming(now: { self.state.withLock { $0.now } }, sleepUntil: { try await self.sleep(until: $0) })
    }

    var deadlines: [ContinuousClock.Instant] { state.withLock { $0.deadlines } }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now += duration
            let ready = state.sleepers.filter { $0.deadline <= state.now }
            state.sleepers.removeAll { $0.deadline <= state.now }
            return ready
        }
        ready.forEach { $0.continuation.resume() }
    }

    private func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let immediate: Result<Void, Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.deadlines.append(deadline)
                    if deadline <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
                onSleep()
            }
        } onCancel: {
            let sleeper = self.state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return Optional<Sleeper>.none }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
