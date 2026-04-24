// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class TransactionInspectorTests: XCTestCase {

    func testMint() {
        let a = TransactionInspector.shared.decode(data: "0x94bf804d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0021fb3f", nameHex: "94bf804d", signature: "mint(uint256,address)")
        XCTAssert(a?.lowercased() == "mint(uint256,address)\n\n1\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe")
    }
    
    func testClaim() {
        let b = TransactionInspector.shared.decode(data: "0x84bb1e42000000000000000000000000e26067c76fdbe877f48b0a8400cf5db8b47af0fe0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000080ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000009184e72a000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021fb3f", nameHex: "84bb1e42", signature: "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)")
        XCTAssert(b?.lowercased() == "claim(address,uint256,address,uint256,(bytes32[],uint256,uint256,address),bytes)\n\n0xe26067c76fdbe877f48b0a8400cf5db8b47af0fe\n\n1\n\n0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n\n10000000000000\n\n(115792089237316195423570985008687907853269984665640564039457584007913129639935, 10000000000000, 0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee)\n\n0x")
    }
    
    func testMintPublic() {
        let c = TransactionInspector.shared.decode(data: "0x161ac21f0000000000000000000000003539ac68bc96fc1f470d7739a49bbbf3d321fd5d0000000000000000000000000000a26b00c1f0df003000390027140000faa719000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010021fb3f", nameHex: "161ac21f", signature: "mintPublic(address,address,address,uint256)")
        XCTAssert(c?.lowercased() == "mintpublic(address,address,address,uint256)\n\n0x3539ac68bc96fc1f470d7739a49bbbf3d321fd5d\n\n0x0000a26b00c1f0df003000390027140000faa719\n\n0x0000000000000000000000000000000000000000\n\n1")
        
    }
    
    func testEmptyData() {
        let d = TransactionInspector.shared.decode(data: "0x", nameHex: "", signature: "mint(uint256,address)")
        XCTAssert(d == nil)
    }

    func testSolanaParserAcceptsVersionZeroMessages() {
        var message = Data([0x80, 1, 0, 0, 1])
        message.append(Data(repeating: 7, count: 32))
        message.append(Data(repeating: 9, count: 32))

        guard let parsedMessage = SolanaWireMessageParser.parse(message) else {
            XCTFail("Expected Solana v0 message to parse")
            return
        }

        XCTAssertEqual(parsedMessage.requiredSignaturesCount, 1)
        XCTAssertEqual(parsedMessage.accountKeys.count, 1)
        XCTAssertEqual(parsedMessage.blockhashRange.lowerBound, 37)
        XCTAssertEqual(parsedMessage.blockhashRange.upperBound, 69)
    }

    func testSolanaParserRejectsUnsupportedVersionedMessages() {
        var message = Data([0x81, 1, 0, 0, 1])
        message.append(Data(repeating: 7, count: 32))
        message.append(Data(repeating: 9, count: 32))

        XCTAssertNil(SolanaWireMessageParser.parse(message))
    }

}
