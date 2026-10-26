import Foundation
import XCTest
import WalletDomain
import WalletNetworking

enum NetworkTestVectors {
    static let solanaMessages = SolanaRPCClient.Messages(
        failedToSend: "Failed to send",
        blockhashNotFound: "Solana blockhash not found. Check the selected network and try again."
    )
    static let abiStaticAndDynamicBytesCall = WalletEncoding.hexData(
        "12345678" +
        "0000000000000000000000000000000000000000000000000000000000000001" +
        "deadbeef00000000000000000000000000000000000000000000000000000000" +
        "1111111111111111111111111111111111111111111111111111111111111111" +
        "0000000000000000000000000000000000000000000000000000000000000080" +
        "0000000000000000000000000000000000000000000000000000000000000004" +
        "000102ff00000000000000000000000000000000000000000000000000000000"
    )!
    static let abiArrayCall = WalletEncoding.hexData(
        "abcdef01" +
        "0000000000000000000000000000000000000000000000000000000000000060" +
        "0000000000000000000000001111111111111111111111111111111111111111" +
        "0000000000000000000000002222222222222222222222222222222222222222" +
        "0000000000000000000000000000000000000000000000000000000000000003" +
        "0000000000000000000000000000000000000000000000000000000000000001" +
        "0000000000000000000000000000000000000000000000000000000000000002" +
        "00000000000000000000000000000000000000000000000000000000000003e8"
    )!
    static let signedEthereumType2Transaction = "0x02f8e5822105068459682f008509502f9000830186a09435353535353535353535353535353535353535350184deadbeeff872f859940000000000000000000000000000000000000101f842a00000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000060a7d6941111111111111111111111111111111111111111c080a014dd6d80870ac4a49e57ae811431fb78be23f11b96846631f823204cf892f6c9a026e1a1ce4bf3cc048eb39089271fc8e1bab0eb75e16630737e8f3fc827f4b1dd"
    static let signedEthereumLegacyTransaction = "0xf864068504a817c80082520894353535353535353535353535353535353535353501802aa0e059a80a438240f955e8fd75dc852f1e87a20c0c22f842a4a251e69527ba0d7da075ef56fc4a39b1201f3058471a054dd02f209926a2aadf67815761991b627f45"
    static let signedSolanaTransaction: String = {
        var data = WalletEncoding.base58Decode("4smDpCXsnHgmoapt2q3Hx3gdVHty7Vta81VAZYPSmzNSHXjtvyfJu4qz1WMHCx2MVXACDb6QY6B1V7CD2u9bgVEGWjqi5gjLcz2PDvti8vYQs7gAZu1DEPmutwqpvUo8T7GjTBKsBLD8fb8Q3N5WKf6K3vj5o3wiZHHv4BkgaXkQ4aoq1PnyxoRpajUXPL3kif4xbSGP9uwSci17SHyEhs5spxyD5sXztX")!
        data.replaceSubrange(1..<65, with: Data((1...64).map(UInt8.init)))
        return data.base64EncodedString()
    }()
}

struct RejectingRPCAuth: AlchemyAuthorizationProviding {
    private enum Failure: Error { case unexpectedAuthorization }

    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        XCTFail("Unexpected RPC authorization for \(url)")
        throw Failure.unexpectedAuthorization
    }

    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        XCTFail("Unexpected RPC authorization replacement for \(url)")
        throw Failure.unexpectedAuthorization
    }

    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {
        XCTFail("Unexpected RPC authorization invalidation for \(url)")
    }
}
