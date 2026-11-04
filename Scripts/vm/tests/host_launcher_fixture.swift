private extension Host {
    func watchdogResult() -> [String: Bool] {
        [
            "ownerExists": kill(options.ownerPID, 0) == 0,
            "parentMatches": getppid() == options.ownerPID,
            "stopRequested": stopRequestReason() != nil,
        ]
    }

    func installationResult() -> [String: Bool] {
        if installationIsProtected {
            beginShutdown(reason: "owner-exited")
            precondition(applicationShouldTerminate(.shared) == .terminateCancel)
            beginShutdown(reason: "owner-exited")
            precondition(deferredShutdownReason == "upgrade-quit-requested")
            precondition(stopReason == deferredShutdownReason)
            forceStop()
        }
        return ["protected": installationIsProtected, "deferred": deferredShutdownReason != nil,
                "shutdownStarted": shutdownStarted != nil, "forceStopRequested": forceStopRequested,
                "windowRequested": upgradeWindowRequested]
    }
}

@main
@MainActor
private struct HostFixture {
    static func main() throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst(2)))
        if CommandLine.arguments[1] == "orphan" {
            let deadline = ContinuousClock.now + .seconds(5)
            while getppid() == options.ownerPID, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            precondition(getppid() != options.ownerPID)
        }
        let host = Host(options: options)
        let result = CommandLine.arguments[1] == "protection" ? host.installationResult() : host.watchdogResult()
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
