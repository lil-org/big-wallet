import WalletAuthority

func forbidden() {
    _ = ExtensionBridge.BroadcastDispatchPermit.self
}
