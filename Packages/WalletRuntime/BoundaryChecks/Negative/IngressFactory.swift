import WalletDomain
import WalletAuthority

func forbidden(request: SafariRequest, wire: WireProtocol.ValidatedObject) {
    _ = ExtensionBridge.dappIngressResult(request: request, wire: wire)
}
