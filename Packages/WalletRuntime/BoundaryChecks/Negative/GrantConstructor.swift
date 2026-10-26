import Foundation
import WalletAuthority

func forbidden(challenge: WalletAuthenticationChallenge) {
    _ = WalletAuthenticationGrant(challenge: challenge, identifier: UUID(), credentialIsCurrent: { true })
}
