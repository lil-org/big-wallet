import Foundation
import WalletAuthority

func forbidden() {
    _ = WalletAuthenticationChallenge(authorityID: UUID(), purpose: .walletAccess(UUID()), deadline: Date())
}
