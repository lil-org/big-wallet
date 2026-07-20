// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class SafariPrewarmBridgeTests: XCTestCase {

    func testDecodesSolanaPrewarmRequest() throws {
        let request = try decode(
            """
            {
              "id": 17,
              "subject": "prewarmAlchemy",
              "provider": "solana"
            }
            """
        )

        XCTAssertEqual(request.id, 17)
        XCTAssertEqual(request.subject, .prewarmAlchemy)
        XCTAssertEqual(request.provider, .solana)
        XCTAssertNil(request.chainId)
        XCTAssertNil(request.body)
    }

    func testDecodesEthereumPrewarmRequestWithChainID() throws {
        let request = try decode(
            """
            {
              "id": 18,
              "subject": "prewarmAlchemy",
              "provider": "ethereum",
              "chainId": "0x1"
            }
            """
        )

        XCTAssertEqual(request.id, 18)
        XCTAssertEqual(request.subject, .prewarmAlchemy)
        XCTAssertEqual(request.provider, .ethereum)
        XCTAssertEqual(request.chainId, "0x1")
    }

    func testUnknownProviderDecodesSafely() throws {
        let request = try decode(
            """
            {
              "id": 19,
              "subject": "prewarmAlchemy",
              "provider": "future-provider"
            }
            """
        )

        XCTAssertEqual(request.provider, .unknown)
    }

    func testRejectsMalformedBridgeRequests() {
        let malformedRequests = [
            """
            {"subject":"prewarmAlchemy","provider":"solana"}
            """,
            """
            {"id":"17","subject":"prewarmAlchemy","provider":"solana"}
            """,
            """
            {"id":17,"subject":"future-subject","provider":"solana"}
            """,
        ]

        for json in malformedRequests {
            XCTAssertThrowsError(try decode(json), json)
        }
    }

    func testPrewarmPolicyAllowsOnlyConfiguredAlchemyRPCs() {
        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .solana,
                chainId: nil
            )
        )
        XCTAssertTrue(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .ethereum,
                chainId: "0x1"
            )
        )
        XCTAssertTrue(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: nil,
                chainId: "0x1"
            )
        )

        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .ethereum,
                chainId: nil
            )
        )
        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .ethereum,
                chainId: "not-hex"
            )
        )
        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .ethereum,
                chainId: "0x7fffffff"
            )
        )
        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .unknown,
                chainId: "0x1"
            )
        )
        XCTAssertFalse(
            SafariAlchemyPrewarmPolicy.allowsPrewarm(
                provider: .multiple,
                chainId: "0x1"
            )
        )
    }

    private func decode(_ json: String) throws -> InternalSafariRequest {
        return try JSONDecoder().decode(
            InternalSafariRequest.self,
            from: Data(json.utf8)
        )
    }

}
