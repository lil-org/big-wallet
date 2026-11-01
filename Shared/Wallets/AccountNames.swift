import WalletDomain

extension WalletAccount {
    @MainActor
    func nameOrCroppedAddress(walletId: String) -> String {
        return ApplicationServices.shared.metadata.getAccountName(walletId: walletId, account: self) ?? croppedAddress
    }

    @MainActor
    func name(walletId: String) -> String? {
        return ApplicationServices.shared.metadata.getAccountName(walletId: walletId, account: self)
    }

}
