import WalletAuthority
import WalletDomain
// ∅ 2026 lil org

import Foundation

@MainActor
public final class NativeAgentLauncher {
    public enum HelperTarget: Equatable, Sendable {
        case running(
            url: URL,
            processIdentifier: Int32,
            runtimeInstanceIdentifier: UUID
        )
        case launch(url: URL)

        public var url: URL {
            switch self {
            case .running(let url, _, _), .launch(let url):
                return url
            }
        }
    }

    public typealias Launch = @MainActor @Sendable (HelperTarget, URL) async -> Bool
    public struct RuntimeHelper: Sendable {
        public let processIdentifier: Int32
        public let bundleURL: URL?
        public let processStartDate: Date?
        public let isRunning: @MainActor @Sendable () -> Bool
        public let requestQuit: @MainActor @Sendable () -> Bool

        public init(
            processIdentifier: Int32,
            bundleURL: URL?,
            processStartDate: Date? = nil,
            isRunning: @escaping @MainActor @Sendable () -> Bool = { false },
            requestQuit: @escaping @MainActor @Sendable () -> Bool = { false }
        ) {
            self.processIdentifier = processIdentifier
            self.bundleURL = bundleURL
            self.processStartDate = processStartDate
            self.isRunning = isRunning
            self.requestQuit = requestQuit
        }
    }

    public struct ExpectedRuntime: Sendable {
        public let url: URL
        public let version: AmbientRuntimeIdentity.Version

        public init(url: URL, version: AmbientRuntimeIdentity.Version) {
            self.url = url.standardizedFileURL
            self.version = version
        }

        public init?(url: URL) {
            let url = url.standardizedFileURL
            guard let version = AmbientRuntimeIdentity.bundleVersion(
                at: url
            ) else { return nil }
            self.init(url: url, version: version)
        }

        public func isCompatible(
            _ identity: AmbientRuntimeIdentity,
            runtimeURL: URL?
        ) -> Bool {
            runtimeURL?.standardizedFileURL == url && identity.isCompatible(
                withWorkflowVersion: ExtensionBridge.workflowVersion,
                expectedVersion: version
            )
        }

        public var installedVersionMatches: Bool {
            AmbientRuntimeIdentity.bundleVersion(at: url) == version
        }
    }

    private enum RuntimeSubject {
        case candidate(RuntimeHelper)
        case receiptOwner(NativeDeliveryOwner)
    }

    public struct IdentifiedRuntime: Sendable {
        public let helper: RuntimeHelper
        public let identity: AmbientRuntimeIdentity

        public var target: HelperTarget {
            .running(
                url: URL(fileURLWithPath: identity.bundlePath).standardizedFileURL,
                processIdentifier: helper.processIdentifier,
                runtimeInstanceIdentifier: identity.instanceIdentifier
            )
        }

        public init(
            helper: RuntimeHelper,
            identity: AmbientRuntimeIdentity
        ) {
            self.helper = helper
            self.identity = identity
        }
    }

    public enum RuntimeAssessment: Sendable {
        case absent
        case unidentified(RuntimeHelper?)
        case compatible(IdentifiedRuntime)
        case incompatible(IdentifiedRuntime)
    }

    public enum OwnerRetirementResult: Sendable {
        case exited, reassess, unavailable
    }

    private struct RuntimeProcessKey: Hashable {
        let processIdentifier: Int32
        let processStartDate: Date?

        init(_ helper: RuntimeHelper) {
            processIdentifier = helper.processIdentifier
            processStartDate = helper.processStartDate
        }
    }

    public struct Dependencies: Sendable {
        public let helperURL: @MainActor () -> URL?
        public let validate: @MainActor (URL) async -> Bool
        public let helpers: @MainActor () -> [RuntimeHelper]
        public let helper: @MainActor (Int32) -> RuntimeHelper?
        public let identity: @MainActor (Int32) -> AmbientRuntimeIdentity?
        public let launch: Launch
        public let uptime: @Sendable () -> UInt64
        public let sleepUntil: @MainActor (UInt64) async -> Void

        public func deadline(after interval: UInt64) -> UInt64 {
            let result = uptime().addingReportingOverflow(interval)
            return result.overflow ? UInt64.max : result.partialValue
        }

        @MainActor
        public func wait(_ interval: UInt64) async {
            await sleepUntil(deadline(after: interval))
        }

        public init(
            helperURL: @escaping @MainActor () -> URL?,
            validate: @escaping @MainActor (URL) async -> Bool,
            helpers: @escaping @MainActor () -> [RuntimeHelper],
            helper: @escaping @MainActor (Int32) -> RuntimeHelper?,
            identity: @escaping @MainActor (Int32) -> AmbientRuntimeIdentity?,
            launch: @escaping Launch,
            uptime: @escaping @Sendable () -> UInt64,
            sleepUntil: @escaping @MainActor (UInt64) async -> Void
        ) {
            self.helperURL = helperURL
            self.validate = validate
            self.helpers = helpers
            self.helper = helper
            self.identity = identity
            self.launch = launch
            self.uptime = uptime
            self.sleepUntil = sleepUntil
        }
    }

    private let dependencies: Dependencies

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func expectedRuntime(at url: URL? = nil) -> ExpectedRuntime? {
        guard let url = url ?? dependencies.helperURL() else { return nil }
        return ExpectedRuntime(url: url)
    }

    public func observe(
        owner: NativeDeliveryOwner,
        expected: ExpectedRuntime? = nil
    ) -> RuntimeAssessment {
        guard let expected = expected ?? expectedRuntime() else { return .unidentified(nil) }
        let assessment = assessRuntime(.receiptOwner(owner), expected: expected)
        if case .compatible(let runtime) = assessment {
            guard runtimeIsCurrent(runtime, expected: expected) else {
                return .unidentified(runtime.helper)
            }
        }
        return assessment
    }

    public func verifiedExpectedRuntime(for runtime: IdentifiedRuntime) async -> ExpectedRuntime? {
        guard let expected = expectedRuntime(),
              await verify(runtime, expected: expected) else { return nil }
        return expected
    }

    public func retireVerifiedOwner(
        owner: NativeDeliveryOwner,
        observedRuntime: IdentifiedRuntime,
        expected: ExpectedRuntime,
        deadline: UInt64
    ) async -> OwnerRetirementResult {
        guard !Task.isCancelled, dependencies.uptime() < deadline,
              expected.installedVersionMatches else { return .unavailable }
        switch observe(owner: owner, expected: expected) {
        case .absent:
            return .exited
        case .compatible:
            return .reassess
        case .incompatible(let current) where current.identity == observedRuntime.identity:
            guard requestQuit(current.helper, expected: expected, deadline: deadline),
                  await waitForExit(current, deadline: deadline) else {
                return .unavailable
            }
            return .exited
        case .incompatible, .unidentified:
            return .unavailable
        }
    }

    private func requestQuit(
        _ helper: RuntimeHelper,
        expected: ExpectedRuntime,
        deadline: UInt64
    ) -> Bool {
        guard !Task.isCancelled, dependencies.uptime() < deadline,
              expected.installedVersionMatches else { return false }
        return helper.requestQuit()
    }

    private func waitForExit(_ runtime: IdentifiedRuntime, deadline: UInt64) async -> Bool {
        while runtime.helper.isRunning(), !Task.isCancelled,
              dependencies.uptime() < deadline {
            await dependencies.wait(NativeApprovalTiming.launchPollIntervalNanoseconds)
        }
        return !Task.isCancelled && dependencies.uptime() < deadline
    }

    public func isConfirmed(
        _ expected: ExpectedRuntime,
        deadline: UInt64
    ) -> Bool {
        guard !Task.isCancelled, dependencies.uptime() < deadline else { return false }
        for helper in dependencies.helpers() {
            guard !Task.isCancelled, dependencies.uptime() < deadline else { return false }
            if case .compatible(let runtime) = assessRuntime(.candidate(helper), expected: expected),
               runtimeIsCurrent(runtime, expected: expected) {
                return !Task.isCancelled && dependencies.uptime() < deadline
            }
        }
        return false
    }

    public func send(
        _ route: NativeAgentRoute,
        to selectedTarget: HelperTarget,
        deadline: UInt64
    ) async -> Bool {
        let dependencies = dependencies
        let isPending = { !Task.isCancelled && dependencies.uptime() < deadline }
        guard !Task.isCancelled, isPending(),
              await dependencies.validate(selectedTarget.url),
              !Task.isCancelled, isPending() else {
            return false
        }
        let launch = dependencies.launch
        let uptime = dependencies.uptime
        return await ApprovalResolution<Bool>().value(
            timeoutValue: false,
            callerCancellation: .resolveTimeout,
            operation: { @MainActor in
                guard !Task.isCancelled, uptime() < deadline else { return false }
                let succeeded = await launch(selectedTarget, route.url)
                return succeeded && !Task.isCancelled && uptime() < deadline
            }
        )
    }

    private func assessRuntime(
        _ subject: RuntimeSubject,
        expected: ExpectedRuntime
    ) -> RuntimeAssessment {
        let runtime: RuntimeHelper
        let owner: NativeDeliveryOwner?
        switch subject {
        case .candidate(let candidate):
            runtime = candidate
            owner = nil
        case .receiptOwner(let receiptOwner):
            guard receiptOwner.isValid else { return .unidentified(nil) }
            guard let candidate = dependencies.helper(receiptOwner.processIdentifier) else { return .absent }
            guard candidate.processIdentifier == receiptOwner.processIdentifier else {
                return .unidentified(candidate)
            }
            runtime = candidate
            owner = receiptOwner
        }
        guard runtime.isRunning() else { return .absent }
        if let owner {
            guard let started = runtime.processStartDate else { return .unidentified(runtime) }
            guard AmbientRuntimeIdentity.matchesProcessStart(owner.processStartDate, started) else {
                return .absent
            }
        }
        guard let url = runtime.bundleURL?.standardizedFileURL,
              let observed = verifiedRuntimeIdentity(
                  processIdentifier: runtime.processIdentifier,
                  bundleURL: url, processStartDate: runtime.processStartDate,
                  identity: dependencies.identity
              ), owner.map({ observed.matches($0) }) ?? true else {
            return .unidentified(runtime)
        }
        let identified = IdentifiedRuntime(helper: runtime, identity: observed)
        return expected.isCompatible(observed, runtimeURL: url)
            ? .compatible(identified) : .incompatible(identified)
    }

    private func verifiedRuntimeIdentity(
        processIdentifier: Int32,
        bundleURL: URL,
        processStartDate: Date?,
        identity: @MainActor (Int32) -> AmbientRuntimeIdentity?
    ) -> AmbientRuntimeIdentity? {
        guard let runtimeIdentity = identity(processIdentifier),
              runtimeIdentity.matches(
                  processIdentifier: processIdentifier,
                  bundleURL: bundleURL,
                  processStartDate: processStartDate
              ) else { return nil }
        return runtimeIdentity
    }

    public func resolveTarget(
        expected: ExpectedRuntime,
        deadline: UInt64
    ) async -> HelperTarget? {
        let dependencies = dependencies
        let canContinue = { !Task.isCancelled && dependencies.uptime() < deadline }
        guard canContinue() else { return nil }
        var unknownFirstObservedAt = [RuntimeProcessKey: UInt64]()
        var requestedQuit = Set<RuntimeProcessKey>()
        while canContinue() {
            let now = dependencies.uptime()
            guard canContinue(), now < deadline else { return nil }
            let candidates = dependencies.helpers().filter {
                $0.bundleURL?.standardizedFileURL == expected.url
            }
            var target: HelperTarget?
            var mustWait = false
            var verifiedCurrentBundle = false
            for candidate in candidates {
                guard canContinue() else { return nil }
                let key = RuntimeProcessKey(candidate)
                switch assessRuntime(.candidate(candidate), expected: expected) {
                case .absent:
                    continue
                case .compatible(let runtime):
                    if target == nil { target = runtime.target }
                    continue
                case .unidentified:
                    let firstObserved = unknownFirstObservedAt[key] ?? now
                    unknownFirstObservedAt[key] = firstObserved
                    if now < firstObserved ||
                        now - firstObserved < NativeApprovalTiming.runtimeIdentityGracePeriodNanoseconds {
                        mustWait = true
                        continue
                    }
                case .incompatible:
                    break
                }
                if requestedQuit.contains(key) {
                    mustWait = true
                    continue
                }
                if !verifiedCurrentBundle {
                    guard await dependencies.validate(expected.url) else { return nil }
                    verifiedCurrentBundle = true
                }
                guard canContinue(), expected.installedVersionMatches else { return nil }
                switch assessRuntime(.candidate(candidate), expected: expected) {
                case .absent:
                    mustWait = true
                    continue
                case .compatible(let runtime):
                    if target == nil { target = runtime.target }
                case .incompatible, .unidentified:
                    mustWait = true
                    requestedQuit.insert(key)
                    guard requestQuit(candidate, expected: expected, deadline: deadline) else { return nil }
                }
            }
            guard canContinue() else { return nil }
            if mustWait {
                let now = dependencies.uptime()
                guard now < deadline else { return nil }
                await dependencies.wait(min(NativeApprovalTiming.launchPollIntervalNanoseconds, deadline - now))
                continue
            }
            return target ?? .launch(url: expected.url)
        }
        return nil
    }

    private func verify(
        _ runtime: IdentifiedRuntime,
        expected: ExpectedRuntime
    ) async -> Bool {
        let runtimeURL = runtime.target.url
        guard await dependencies.validate(expected.url) else { return false }
        if runtimeURL != expected.url {
            guard await dependencies.validate(runtimeURL) else { return false }
        }
        return runtimeIsCurrent(runtime, expected: expected)
    }

    private func runtimeIsCurrent(
        _ runtime: IdentifiedRuntime,
        expected: ExpectedRuntime
    ) -> Bool {
        expected.installedVersionMatches && runtime.helper.isRunning() &&
            verifiedRuntimeIdentity(
                processIdentifier: runtime.helper.processIdentifier,
                bundleURL: runtime.target.url,
                processStartDate: runtime.helper.processStartDate,
                identity: dependencies.identity
            ) == runtime.identity
    }
}
