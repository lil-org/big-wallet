import Foundation
import XCTest
@testable import WalletDomain

final class WalletDomainTests: XCTestCase {
    func testAuthorityIdentityRequiresCanonicalToken() {
        let value = UUID()
        XCTAssertNotNil(RequestToken(rawValue: value.uuidString.lowercased()))
        XCTAssertNil(RequestToken(rawValue: value.uuidString.uppercased()))
        XCTAssertNil(RequestToken(rawValue: "invalid"))
    }
}
