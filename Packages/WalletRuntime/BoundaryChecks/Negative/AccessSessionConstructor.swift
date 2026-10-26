import Foundation
import WalletAuthority

func forbidden() {
    _ = WalletAccessSession(authorityID: UUID(), credentialIsCurrent: { true })
}
