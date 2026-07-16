// ∅ 2026 lil org

@testable import Big_Wallet
import Foundation
import XCTest

final class Tests_macOS: XCTestCase {

#if os(macOS) && DEBUG
    func testAmbientPseudoLocalizationLaunchModeParsesEnvironmentValues() {
        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode(environmentValue: "long"), .long)
        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode(environmentValue: " rtl "), .rtl)
        XCTAssertNil(AmbientPseudoLocalizationLaunchMode(environmentValue: nil))
        XCTAssertNil(AmbientPseudoLocalizationLaunchMode(environmentValue: ""))
        XCTAssertNil(AmbientPseudoLocalizationLaunchMode(environmentValue: "regular"))
    }

    func testAmbientPseudoLocalizationLaunchModeMapsLaunchArguments() {
        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode.long.launchArguments,
                       ["-NSDoubleLocalizedStrings", "YES"])
        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode.rtl.launchArguments,
                       ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"])
    }

    func testAmbientPseudoLocalizationLaunchModeReturnsStoredArgumentsForLiveOwner() {
        let suiteName = "org.lil.wallet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerProcessId = pid_t(12345)
        let date = Date()
        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment(environment: [
            AmbientPseudoLocalizationLaunchMode.environmentKey: "long"
        ], ownerProcessId: ownerProcessId, date: date, defaults: defaults)

        let arguments = AmbientPseudoLocalizationLaunchMode.ambientLaunchArguments(date: date.addingTimeInterval(1),
                                                                                  defaults: defaults) { processId in
            processId == ownerProcessId
        }

        XCTAssertEqual(arguments, AmbientPseudoLocalizationLaunchMode.long.launchArguments)
    }

    func testAmbientPseudoLocalizationLaunchModeClearsInvalidOrStaleMarkers() {
        let suiteName = "org.lil.wallet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownerProcessId = pid_t(12345)
        let date = Date()
        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment(environment: [
            AmbientPseudoLocalizationLaunchMode.environmentKey: "rtl"
        ], ownerProcessId: ownerProcessId, date: date, defaults: defaults)

        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode.ambientLaunchArguments(date: date,
                                                                                  defaults: defaults) { _ in false },
                       [])

        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment(environment: [
            AmbientPseudoLocalizationLaunchMode.environmentKey: "rtl"
        ], ownerProcessId: ownerProcessId, date: date, defaults: defaults)

        XCTAssertEqual(AmbientPseudoLocalizationLaunchMode.ambientLaunchArguments(date: date.addingTimeInterval(25 * 60 * 60),
                                                                                  defaults: defaults) { _ in true },
                       [])
    }
#endif
    
}
