import Foundation
import XCTest

final class CustomNetworkPackagingTests: XCTestCase {
#if os(macOS)
    func testCustomRPCPlistsAllowHTTPAndDescribeLocalNetworkAccess() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let extensionPlists = [
            "Safari macOS/Info.plist",
            "Safari iOS/Info.plist",
            "Safari visionOS/Info.plist",
        ]
        let appPlists = [
            "App macOS/Info.plist",
            "App iOS/Info.plist",
            "App visionOS/Info.plist",
            "Big Wallet Ambient/Info.plist",
        ]

        for relativePath in extensionPlists {
            let plist = try propertyList(at: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist["NSAppTransportSecurity"] as? [String: Bool],
                ["NSAllowsArbitraryLoads": true],
                relativePath
            )
        }
        for relativePath in appPlists {
            let plist = try propertyList(at: repositoryRoot.appendingPathComponent(relativePath))
            XCTAssertEqual(
                plist["NSLocalNetworkUsageDescription"] as? String,
                "Big Wallet connects to custom blockchain RPC endpoints you choose on your local network.",
                relativePath
            )
        }
    }
#endif
#if os(macOS)
    private func propertyList(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
#endif
}
