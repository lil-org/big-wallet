// ∅ 2026 lil org

import AppKit
import Darwin

struct LegacyAmbientHelperProcess {

    let processIdentifier: pid_t
    private let terminate: () -> Bool

    init(processIdentifier: pid_t, terminate: @escaping () -> Bool) {
        self.processIdentifier = processIdentifier
        self.terminate = terminate
    }

    func forceTerminate() -> Bool {
        return terminate()
    }

}

struct LegacyAmbientHelperCleanup {

    typealias RunningApplications = (String) -> [LegacyAmbientHelperProcess]
    typealias Kill = (pid_t, Int32) -> Bool
    private static let bundleIdentifier = "org.lil.wallet.ambient"

    static let live = LegacyAmbientHelperCleanup(
        runningApplications: { bundleIdentifier in
            return NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).map { application in
                return LegacyAmbientHelperProcess(
                    processIdentifier: application.processIdentifier,
                    terminate: {
                        return application.forceTerminate()
                    }
                )
            }
        },
        kill: { processIdentifier, signal in
            let result = Darwin.kill(processIdentifier, signal)
            return result == 0 || errno == ESRCH
        }
    )

    private let runningApplications: RunningApplications
    private let kill: Kill

    init(
        runningApplications: @escaping RunningApplications,
        kill: @escaping Kill
    ) {
        self.runningApplications = runningApplications
        self.kill = kill
    }

    @discardableResult
    func run() -> Bool {
        var succeeded = true
        for application in runningApplications(Self.bundleIdentifier) {
            let signalAccepted = kill(application.processIdentifier, SIGKILL)
            let terminationAccepted = application.forceTerminate()
            succeeded = succeeded && (signalAccepted || terminationAccepted)
        }
        return succeeded
    }

}

final class LegacyAmbientHelperCleanupGate {

    static let live = LegacyAmbientHelperCleanupGate(
        cleanup: LegacyAmbientHelperCleanup.live
    )

    private let lock = NSLock()
    private let cleanup: LegacyAmbientHelperCleanup
    private var didRun = false

    init(cleanup: LegacyAmbientHelperCleanup) {
        self.cleanup = cleanup
    }

    func runBestEffort() {
        lock.lock()
        defer { lock.unlock() }

        guard !didRun else { return }
        didRun = true
        cleanup.run()
    }

}
