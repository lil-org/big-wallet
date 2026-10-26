import Foundation
import WalletAuthority

func forbidden(challenge: WalletAuthenticationChallenge) {
    _ = challenge.issueGrant(for: UUID(), credentialIsCurrent: { true })
}
