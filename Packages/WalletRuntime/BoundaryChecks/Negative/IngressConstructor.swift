import Foundation
import WalletDomain
import WalletAuthority

func forbidden(request: SafariRequest, authority: RequestAuthorityVersion) {
    _ = ExtensionBridge.Ingress(request: request, canonicalData: Data(), fingerprint: Data(), authority: authority, replayOnly: false, responseOwner: .worker)
}
