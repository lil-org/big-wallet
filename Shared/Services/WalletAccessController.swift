import Foundation
import WalletAuthority
#if os(macOS)
import AppKit
#endif

@MainActor
protocol WalletAccessObserver: AnyObject {
    func walletAccessDidLock()
    func walletAccessDidUnlock()
}

extension WalletAccessObserver {
    func walletAccessDidLock() {}
    func walletAccessDidUnlock() {}
}

@MainActor
protocol WalletAccessExpirationScheduling: AnyObject {
    // Registration and cancellation never invoke the action or access callbacks synchronously.
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
private final class WalletAccessExpirationScheduler: WalletAccessExpirationScheduling {
    @MainActor
    private final class Action: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
        @objc func fire(_ timer: Timer) { run() }
    }

    private var timer: Timer?

    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) {
        cancel()
        let components = delay.components
        let interval = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let timer = Timer(timeInterval: interval, target: Action(action), selector: #selector(Action.fire(_:)), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
#if os(macOS)
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .eventTracking)
#endif
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit { timer?.invalidate() }
}

@MainActor
final class WalletAccessController {
    enum LockReason: Equatable {
        case idle, background, protectedDataUnavailable, systemSleep, sessionInactive
    }

    private struct Observer {
        weak var value: (any WalletAccessObserver)?
    }

    @MainActor
    final class AuthenticationAttempt {
        private enum State {
            case active, completed, cancelled
        }

        @MainActor
        final class Operation {
            private weak var attempt: AuthenticationAttempt?
            private var challenge: WalletAuthenticationChallenge?
            private var task: Task<Void, Never>?
            private var isRetired = false

            fileprivate init(attempt: AuthenticationAttempt, challenge: WalletAuthenticationChallenge?) {
                self.attempt = attempt
                self.challenge = challenge
            }

            isolated deinit {
                challenge?.invalidate()
                task?.cancel()
            }

            var isCurrent: Bool {
                !isRetired && attempt?.isCurrent == true && attempt?.operation === self
            }

            @discardableResult
            func attachChallenge(_ challenge: WalletAuthenticationChallenge) -> Bool {
                guard isCurrent else {
                    challenge.invalidate()
                    return false
                }
                if self.challenge !== challenge {
                    let previous = self.challenge
                    self.challenge = challenge
                    previous?.invalidate()
                }
                return isCurrent
            }

            @discardableResult
            func complete(_ grant: WalletAuthenticationGrant) -> Bool {
                defer { grant.invalidate() }
                guard isCurrent, let owner = attempt?.owner,
                      let session = owner.credentials.accessSession(authorization: grant) else { return false }
                return complete(session)
            }

            @discardableResult
            func complete(_ session: WalletAccessSession) -> Bool {
                guard isCurrent, let attempt else {
                    session.invalidate()
                    return false
                }
                return attempt.complete(session)
            }

            fileprivate func start(_ run: @escaping @MainActor (Operation) async -> Void) {
                guard isCurrent else { return }
                task = Task { [self] in
                    defer { retire(cancellingTask: false) }
                    guard isCurrent, !Task.isCancelled else { return }
                    await run(self)
                }
            }

            fileprivate func retire(cancellingTask: Bool) {
                guard !isRetired else { return }
                isRetired = true
                let previousChallenge = challenge
                let previousTask = task
                challenge = nil
                task = nil
                if attempt?.operation === self { attempt?.operation = nil }
                previousChallenge?.invalidate()
                if cancellingTask { previousTask?.cancel() }
            }
        }

        private weak var owner: WalletAccessController?
        private var state = State.active
        private var operation: Operation?
        private var onCancelled: (@MainActor (AuthenticationAttempt) -> Void)?

        fileprivate init(owner: WalletAccessController, onCancelled: @escaping @MainActor (AuthenticationAttempt) -> Void) {
            self.owner = owner
            self.onCancelled = onCancelled
        }

        isolated deinit { operation?.retire(cancellingTask: true) }

        var isCurrent: Bool {
            state == .active && owner?.authentication === self && owner?.isLockTransitioning == false
        }

        @discardableResult
        func replaceOperation(
            challenge: WalletAuthenticationChallenge? = nil,
            run: (@MainActor (Operation) async -> Void)? = nil
        ) -> Operation {
            let next = Operation(attempt: self, challenge: challenge)
            guard isCurrent else {
                next.retire(cancellingTask: true)
                return next
            }
            let previous = operation
            operation = next
            previous?.retire(cancellingTask: true)
            if let run { next.start(run) }
            return next
        }

        func cancelOperation() {
            let previous = operation
            operation = nil
            previous?.retire(cancellingTask: true)
        }

        @discardableResult
        func complete(_ session: WalletAccessSession) -> Bool {
            guard let owner else {
                session.invalidate()
                retire(cancelled: true)
                return false
            }
            return owner.completeAuthentication(session, attempt: self)
        }

        func cancel() {
            if let owner { owner.cancelAuthentication(self) }
            else { retire(cancelled: true) }
        }

        fileprivate func retire(cancelled: Bool) {
            guard state == .active else { return }
            state = cancelled ? .cancelled : .completed
            let previous = operation
            let callback = onCancelled
            operation = nil
            onCancelled = nil
            previous?.retire(cancellingTask: cancelled)
            if cancelled { callback?(self) }
        }
    }

    private(set) var session: WalletAccessSession?
    private(set) var generation: UInt64 = 0
    private(set) var isLocked = true
    private(set) var hasLocked = false
    private(set) var lockReason: LockReason?
    var isProtectedDataAvailable: @MainActor () -> Bool = { true }

    private let credentials: WalletCredentials
    private let expirationScheduler: any WalletAccessExpirationScheduling
    private let activityClock: @MainActor () -> ContinuousClock.Instant
    private var observers = [ObjectIdentifier: Observer]()
    private var authentication: AuthenticationAttempt?
    private var timerGeneration: UInt64 = 0
    private var isLockTransitioning = false
    private var lastContinuousInteraction: ContinuousClock.Instant?

    init(
        credentials: WalletCredentials,
        expirationScheduler: any WalletAccessExpirationScheduling = WalletAccessExpirationScheduler(),
        activityClock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.credentials = credentials
        self.expirationScheduler = expirationScheduler
        self.activityClock = activityClock
    }

    isolated deinit {
        session?.invalidate()
        expirationScheduler.cancel()
        authentication?.retire(cancelled: true)
    }

    func addObserver(_ observer: any WalletAccessObserver) {
        observers = observers.filter { $0.value.value != nil }
        observers[ObjectIdentifier(observer)] = Observer(value: observer)
    }

    func removeObserver(_ observer: any WalletAccessObserver) {
        observers.removeValue(forKey: ObjectIdentifier(observer))
    }

    @discardableResult
    func beginAuthentication(onCancelled: @escaping @MainActor (AuthenticationAttempt) -> Void) -> AuthenticationAttempt {
        let attempt = AuthenticationAttempt(owner: self, onCancelled: onCancelled)
        guard !isLockTransitioning else {
            attempt.retire(cancelled: true)
            return attempt
        }
        if !isLocked { lock(reason: .idle) }
        let previous = authentication
        generation &+= 1
        authentication = attempt
        previous?.retire(cancelled: true)
        return attempt
    }

    @discardableResult
    private func completeAuthentication(_ session: WalletAccessSession, attempt: AuthenticationAttempt) -> Bool {
        guard attempt.isCurrent, authentication === attempt,
              credentials.validateAccess(session), attempt.isCurrent else {
            session.invalidate()
            return false
        }
        guard isProtectedDataAvailable() else {
            session.invalidate()
            lock(reason: .protectedDataUnavailable)
            return false
        }
        guard attempt.isCurrent else { session.invalidate(); return false }
        let generation = generation
        authentication = nil
        attempt.retire(cancelled: false)
        self.session?.invalidate()
        self.session = session
        isLocked = false
        lockReason = nil
        guard let remaining = remainingLifetime() else { return false }
        scheduleTimer(after: remaining)
        guard self.generation == generation, self.session === session, validateCurrentAccess() else { return false }
        let currentObservers = liveObservers()
        for observer in currentObservers {
            guard self.generation == generation, !isLocked else { break }
            observer.walletAccessDidUnlock()
        }
        return self.generation == generation && !isLocked
    }

    private func cancelAuthentication(_ attempt: AuthenticationAttempt) {
        if authentication === attempt {
            authentication = nil
            generation &+= 1
        }
        attempt.retire(cancelled: true)
    }

    func matchesPresentation(_ generation: UInt64) -> Bool {
        self.generation == generation && !isLocked
    }

    @discardableResult
    func validateCurrentAccess(expectedGeneration: UInt64? = nil) -> Bool {
        if let expectedGeneration, !matchesPresentation(expectedGeneration) { return false }
        return remainingLifetime() != nil
    }

    private func remainingLifetime() -> Duration? {
        guard !isLocked, let session else { return nil }
        guard isProtectedDataAvailable() else {
            lock(reason: .protectedDataUnavailable)
            return nil
        }
        guard let remaining = credentials.remainingAccessLifetime(session) else {
            lock(reason: .idle)
            return nil
        }
        return remaining
    }

    func requireCurrentAccess(expectedGeneration: UInt64? = nil) throws -> WalletAccessSession {
        guard validateCurrentAccess(expectedGeneration: expectedGeneration), let session else { throw WalletCredentialError.authorizationUnavailable }
        let current = generation
        guard credentials.validateAccess(session) else {
            validateCurrentAccess()
            throw WalletCredentialError.authorizationUnavailable
        }
        guard generation == current, self.session === session, validateCurrentAccess() else {
            throw WalletCredentialError.authorizationUnavailable
        }
        return session
    }

    @discardableResult
    func recordInteraction(expectedGeneration: UInt64? = nil) -> Bool {
        guard validateCurrentAccess(expectedGeneration: expectedGeneration), let session else { return false }
        let current = generation
        guard let remaining = credentials.recordInteraction(session) else {
            validateCurrentAccess()
            return false
        }
        scheduleTimer(after: remaining)
        return generation == current && self.session === session && !isLocked
    }

    func recordContinuousInteraction() {
        let now = activityClock()
        guard lastContinuousInteraction.map({ now - $0 < .seconds(1) }) != true else { return }
        if recordInteraction() { lastContinuousInteraction = now }
    }

    func lock(reason: LockReason) {
        guard !isLockTransitioning else { return }
        isLockTransitioning = true
        defer { isLockTransitioning = false }
        generation &+= 1
        let current = generation
        let previousSession = session
        let previousAuthentication = authentication
        session = nil
        authentication = nil
        isLocked = true
        hasLocked = true
        lockReason = reason
        lastContinuousInteraction = nil
        cancelScheduledTimer()
        previousSession?.invalidate()
        previousAuthentication?.retire(cancelled: true)
        let currentObservers = liveObservers()
        for observer in currentObservers {
            guard generation == current, isLocked else { break }
            observer.walletAccessDidLock()
        }
    }

    private func liveObservers() -> [any WalletAccessObserver] {
        observers = observers.filter { $0.value.value != nil }
        return observers.values.compactMap(\.value)
    }

    private func cancelScheduledTimer() {
        timerGeneration &+= 1
        expirationScheduler.cancel()
    }

    private func scheduleTimer(after remaining: Duration) {
        let accessGeneration = generation
        let currentSession = session
        cancelScheduledTimer()
        guard !isLocked, let currentSession, session === currentSession,
              generation == accessGeneration else { return }
        let scheduledGeneration = timerGeneration
        expirationScheduler.schedule(after: remaining) { [weak self] in
            guard let self, timerGeneration == scheduledGeneration,
                  generation == accessGeneration, let remaining = remainingLifetime() else { return }
            scheduleTimer(after: remaining)
        }
    }
}
