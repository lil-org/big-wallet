// ∅ 2026 lil org

import Foundation

struct WalletSnapshot: Hashable, Sendable {
    let id: String
    let isMnemonic: Bool
    let accounts: [WalletAccount]

    init(id: String, isMnemonic: Bool, accounts: [WalletAccount]) {
        self.id = id
        self.isMnemonic = isMnemonic
        self.accounts = accounts
    }

    init(_ wallet: WalletContainer) {
        self.init(id: wallet.id, isMnemonic: wallet.isMnemonic, accounts: wallet.accounts)
    }

    func hasAccountMatching(_ account: WalletAccount) -> Bool {
        let normalizedAddress = account.coin.normalizedAddress(account.address)
        return accounts.contains {
            $0.coin == account.coin &&
                $0.derivationPath == account.derivationPath &&
                account.coin.normalizedAddress($0.address) == normalizedAddress
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

final class WalletContainer: Hashable, Equatable {

    let id: String
    var key: WalletStoredKey
    
    var isMnemonic: Bool {
        return key.isMnemonic
    }

    var accounts: [WalletAccount] {
        return (0..<key.accountCount).compactMap({ key.account(index: $0) })
    }
    
    init(id: String, key: WalletStoredKey) {
        self.id = id
        self.key = key
    }
    
    func getAccount(password: String, coin: WalletCoin) throws -> WalletAccount {
        let wallet = key.wallet(password: Data(password.utf8))
        guard let account = key.accountForCoin(coin: coin, wallet: wallet) else { throw WalletKeyStoreError.invalidPassword }
        return account
    }

    func privateKey(password: String, account: WalletAccount) throws -> WalletPrivateKey {
        return try privateKey(passwordData: Data(password.utf8), account: account)
    }

    func privateKey(passwordData: Data, account: WalletAccount) throws -> WalletPrivateKey {
        if isMnemonic {
            let wallet = key.wallet(password: passwordData)
            guard let privateKey = wallet?.privateKey(coin: account.coin, derivationPath: account.derivationPath) else { throw WalletKeyStoreError.invalidPassword }
            return privateKey
        } else {
            guard let privateKey = key.privateKey(coin: account.coin, password: passwordData) else { throw WalletKeyStoreError.invalidPassword }
            return privateKey
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WalletContainer, rhs: WalletContainer) -> Bool {
        return lhs.id == rhs.id
    }
    
}
