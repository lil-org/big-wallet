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

    func testBroadcastOutcomePreservesChainFailure() {
        let failure = Solana.SendTransactionError.confirmationTimedOut(signature: "signature")
        let outcome = BroadcastResult.confirmationFailed(transactionID: "signature", failure: .solana(failure))
        XCTAssertNil(outcome.ethereumResult)
        guard case .failure(let recovered)? = outcome.solanaResult else {
            return XCTFail("Missing Solana result")
        }
        XCTAssertEqual(recovered, failure)
    }
}
