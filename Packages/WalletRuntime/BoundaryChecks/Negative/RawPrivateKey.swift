import Foundation
import WalletAuthority

func forbidden(bytes: Data) {
    _ = WalletPrivateKey(data: bytes)
}
