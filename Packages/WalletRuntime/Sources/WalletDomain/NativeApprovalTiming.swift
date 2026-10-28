import Foundation

public enum NativeApprovalTiming: Sendable {
    public static let recoveryTimeout: TimeInterval = 10
    public static let recoveryRetryInterval: TimeInterval = 1
    public static let recoveryRetryNanoseconds = UInt64(recoveryRetryInterval * 1_000_000_000)
    public static let observationInitialDelayNanoseconds: UInt64 = 1_000_000_000
    public static let observationMaximumDelayNanoseconds: UInt64 = 5_000_000_000
    public static let launchTimeoutNanoseconds: UInt64 = 5_000_000_000
    public static let launchPollIntervalNanoseconds: UInt64 = 50_000_000
    public static let runtimeIdentityGracePeriodNanoseconds: UInt64 = 1_000_000_000
    public static let receiptWaitTimeoutNanoseconds: UInt64 = 250_000_000
}

