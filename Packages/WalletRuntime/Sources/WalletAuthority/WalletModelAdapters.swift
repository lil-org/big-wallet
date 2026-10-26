import Foundation
import WalletDomain

extension WalletAccountCatalog {
    init(wallets: [WalletContainer]) {
        self.init(accounts: wallets.flatMap { wallet in
            wallet.accounts.map { WalletAccountDescriptor(walletID: wallet.id, account: $0) }
        })
    }
}

extension Notification.Name {
    static let walletsChanged = Notification.Name("walletsChanged")
    static let walletStoreChanged = Notification.Name("walletStoreChanged")
}

extension ResponseToExtension {
    public static func failure(for request: SafariRequest, error: ProviderResponseError) -> ResponseToExtension {
        ResponseToExtension(for: request, payload: .error(error))
    }
}
