import Foundation

actor SafariRPCService {
    struct Scope: Hashable, Sendable {
        let profileIdentifier: UUID?
        let origin: String
    }

    struct Clock: Sendable {
        var now: @Sendable () -> ContinuousClock.Instant
        var sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

        static let live = Clock(
            now: { .now },
            sleepUntil: { try await ContinuousClock().sleep(until: $0) }
        )
    }

    struct Statistics: Equatable, Sendable {
        let activeRequests: Int
        let outstandingRequests: Int
        let retainedRequestBytes: Int
        let scopeCount: Int
    }

    typealias Operation = @Sendable (ValidatedRPCRequest, SafariRPCExecution) async throws -> RPCResponseToExtension
    typealias Serializer = @Sendable (ValidatedRPCRequest.Prepared) async throws -> ValidatedRPCRequest

    private final class Job {
        let token: UUID
        let id: Int
        let scope: Scope
        let body: String
        var retainedBodyBytes: Int
        let queueDeadline: ContinuousClock.Instant
        let execution: SafariRPCExecution
        let operation: Operation
        var continuation: CheckedContinuation<RPCResponseToExtension, Never>?
        var operationTask: Task<Void, Never>?
        var queueTimer: Task<Void, Never>?
        var lifetimeTimer: Task<Void, Never>?
        var isActive = false

        init(
            token: UUID, id: Int, scope: Scope, body: String, byteCount: Int,
            queueDeadline: ContinuousClock.Instant, execution: SafariRPCExecution,
            operation: @escaping Operation,
            continuation: CheckedContinuation<RPCResponseToExtension, Never>
        ) {
            self.token = token
            self.id = id
            self.scope = scope
            self.body = body
            self.retainedBodyBytes = byteCount
            self.queueDeadline = queueDeadline
            self.execution = execution
            self.operation = operation
            self.continuation = continuation
        }
    }

    private let limits: SafariRPCLimits
    private let clock: Clock
    private let responseBudget: SafariRPCResponseBudget
    private let serializeRequest: Serializer
    private var jobs = [UUID: Job]()
    private var queues = [Scope: [UUID]]()
    private var readyScopes = [Scope]()
    private var activeByScope = [Scope: Int]()
    private var outstandingByScope = [Scope: Int]()
    private var activeRequests = 0
    private var retainedRequestBytes = 0

    init(
        limits: SafariRPCLimits = .live, clock: Clock = .live,
        serializeRequest: @escaping Serializer = { try $0.serialize() }
    ) {
        self.limits = limits
        self.clock = clock
        self.serializeRequest = serializeRequest
        responseBudget = SafariRPCResponseBudget(maximumBytes: limits.maximumBufferedResponseBytes)
    }

    var statistics: Statistics {
        Statistics(
            activeRequests: activeRequests,
            outstandingRequests: jobs.count,
            retainedRequestBytes: retainedRequestBytes,
            scopeCount: outstandingByScope.count
        )
    }

    func perform(
        id: Int, body: String, scope: Scope,
        operation: @escaping Operation
    ) async -> RPCResponseToExtension {
        guard !Task.isCancelled else {
            return SafariRPCFailure.cancelled.response(id: id, dispatched: false)
        }
        let byteCount = body.utf8.prefix(limits.maximumRequestBytes + 1).count
        guard byteCount <= limits.maximumRequestBytes else {
            return SafariRPCFailure.requestTooLarge.response(id: id, dispatched: false)
        }
        let token = UUID()
        let admittedAt = clock.now()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: SafariRPCFailure.cancelled.response(id: id, dispatched: false))
                    return
                }
                guard jobs.count < limits.maximumOutstandingRequests,
                      outstandingByScope[scope, default: 0] < limits.maximumOutstandingPerOrigin,
                      byteCount <= limits.maximumRetainedRequestBytes - retainedRequestBytes else {
                    continuation.resume(returning: SafariRPCFailure.busy.response(id: id, dispatched: false))
                    return
                }
                let execution = SafariRPCExecution(
                    deadline: admittedAt.advanced(by: limits.maximumLifetime),
                    now: clock.now,
                    limits: limits,
                    responseBudget: responseBudget
                )
                let job = Job(
                    token: token, id: id, scope: scope, body: body, byteCount: byteCount,
                    queueDeadline: admittedAt.advanced(by: limits.maximumQueueWait),
                    execution: execution, operation: operation, continuation: continuation
                )
                jobs[token] = job
                outstandingByScope[scope, default: 0] += 1
                retainedRequestBytes += byteCount
                if queues[scope] == nil { readyScopes.append(scope) }
                queues[scope, default: []].append(token)
                job.queueTimer = timer(token: token, deadline: job.queueDeadline, failure: .queueTimeout)
                job.lifetimeTimer = timer(token: token, deadline: execution.deadline, failure: .timeout)
                drain()
            }
        } onCancel: {
            Task { await self.cancel(token: token, failure: .cancelled) }
        }
    }

    private func timer(
        token: UUID, deadline: ContinuousClock.Instant, failure: SafariRPCFailure
    ) -> Task<Void, Never> {
        let clock = clock
        return Task.detached { [weak self] in
            do {
                while clock.now() < deadline {
                    try await clock.sleepUntil(deadline)
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
            } catch { return }
            await self?.expire(token: token, failure: failure)
        }
    }

    private func drain() {
        while activeRequests < limits.maximumActiveRequests {
            var selected: Job?
            for _ in 0..<readyScopes.count {
                let scope = readyScopes.removeFirst()
                guard var queue = queues[scope], !queue.isEmpty else {
                    queues.removeValue(forKey: scope)
                    continue
                }
                guard activeByScope[scope, default: 0] < limits.maximumActivePerOrigin else {
                    readyScopes.append(scope)
                    continue
                }
                let token = queue.removeFirst()
                if queue.isEmpty {
                    queues.removeValue(forKey: scope)
                } else {
                    queues[scope] = queue
                    readyScopes.append(scope)
                }
                selected = jobs[token]
                if selected != nil { break }
            }
            guard let job = selected else { return }
            if clock.now() >= job.execution.deadline {
                finishQueued(job, failure: .timeout)
            } else if clock.now() >= job.queueDeadline {
                finishQueued(job, failure: .queueTimeout)
            } else {
                start(job)
            }
        }
    }

    private func start(_ job: Job) {
        job.isActive = true
        activeRequests += 1
        activeByScope[job.scope, default: 0] += 1
        job.queueTimer?.cancel()
        job.queueTimer = nil
        let token = job.token
        let id = job.id
        let body = job.body
        let execution = job.execution
        let operation = job.operation
        job.operationTask = Task.detached {
            let result: Result<RPCResponseToExtension, SafariRPCFailure>
            do {
                try execution.checkCancellationAndDeadline()
                let request = try await self.validateRequest(token: token, id: id, body: body, execution: execution)
                try execution.checkCancellationAndDeadline()
                let response = try await operation(request, execution)
                guard response.id == id else { throw SafariRPCFailure.transport }
                try execution.checkCancellationAndDeadline()
                result = .success(response)
            } catch let failure as SafariRPCFailure {
                result = .failure(failure)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch {
                result = .failure(.transport)
            }
            await self.complete(token: token, result: result)
        }
    }

    @concurrent
    private nonisolated func validateRequest(
        token: UUID, id: Int, body: String, execution: SafariRPCExecution
    ) async throws -> ValidatedRPCRequest {
        let prepared = try ValidatedRPCRequest.prepare(body: body, id: id, limits: execution.limits) {
            try execution.checkCancellationAndDeadline()
        }
        try await reserveCanonicalBody(token: token, byteCount: prepared.canonicalByteCount)
        try execution.checkCancellationAndDeadline()
        let request = try await serializeRequest(prepared)
        guard request.id == id, request.body.count == prepared.canonicalByteCount else {
            throw SafariRPCFailure.transport
        }
        try execution.checkCancellationAndDeadline()
        return request
    }

    private func reserveCanonicalBody(token: UUID, byteCount: Int) throws {
        guard let job = jobs[token], job.isActive else { throw CancellationError() }
        try job.execution.checkCancellationAndDeadline()
        guard byteCount <= limits.maximumRetainedRequestBytes - retainedRequestBytes else {
            throw SafariRPCFailure.busy
        }
        job.retainedBodyBytes += byteCount
        retainedRequestBytes += byteCount
    }

    private func expire(token: UUID, failure: SafariRPCFailure) {
        guard let job = jobs[token] else { return }
        if failure == .queueTimeout, job.isActive { return }
        cancel(token: token, failure: clock.now() >= job.execution.deadline ? .timeout : failure)
    }

    private func cancel(token: UUID, failure: SafariRPCFailure) {
        guard let job = jobs[token] else { return }
        if job.isActive {
            job.execution.cancel()
            job.operationTask?.cancel()
            job.lifetimeTimer?.cancel()
            job.lifetimeTimer = nil
            resolve(job, result: .failure(failure))
        } else {
            removeQueued(job)
            finishQueued(job, failure: failure)
            drain()
        }
    }

    private func complete(token: UUID, result: Result<RPCResponseToExtension, SafariRPCFailure>) {
        guard let job = jobs[token] else { return }
        resolve(job, result: clock.now() >= job.execution.deadline ? .failure(.timeout) : result)
        remove(job)
        drain()
    }

    private func finishQueued(_ job: Job, failure: SafariRPCFailure) {
        resolve(job, result: .failure(failure))
        remove(job)
    }

    private func resolve(_ job: Job, result: Result<RPCResponseToExtension, SafariRPCFailure>) {
        let continuation = job.continuation
        job.continuation = nil
        guard let continuation else { return }
        switch result {
        case .success(let response): continuation.resume(returning: response)
        case .failure(let failure):
            continuation.resume(returning: failure.response(id: job.id, dispatched: job.execution.dispatched))
        }
    }

    private func removeQueued(_ job: Job) {
        queues[job.scope]?.removeAll { $0 == job.token }
        if queues[job.scope]?.isEmpty == true {
            queues.removeValue(forKey: job.scope)
            readyScopes.removeAll { $0 == job.scope }
        }
    }

    private func remove(_ job: Job) {
        jobs.removeValue(forKey: job.token)
        job.queueTimer?.cancel()
        job.lifetimeTimer?.cancel()
        retainedRequestBytes -= job.retainedBodyBytes
        if job.isActive {
            activeRequests -= 1
            decrement(&activeByScope, scope: job.scope)
        }
        decrement(&outstandingByScope, scope: job.scope)
    }

    private func decrement(_ counts: inout [Scope: Int], scope: Scope) {
        guard let count = counts[scope] else { return }
        if count == 1 { counts.removeValue(forKey: scope) }
        else { counts[scope] = count - 1 }
    }
}
