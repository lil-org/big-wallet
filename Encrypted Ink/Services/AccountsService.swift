// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletCore

struct AccountsService {
    
    static func validateAccountKey(_ key: String) -> Bool {
        if let data = Data(hexString: key) {
            return PrivateKey.isValid(data: data, curve: CoinType.ethereum.curve)
        } else {
            return false
        }
    }
    
    static func addAccount(privateKey: String) -> Account? {
        guard let data = Data(hexString: privateKey),
              let key = PrivateKey(data: data) else { return nil }
        let address = CoinType.ethereum.deriveAddress(privateKey: key).lowercased()
        // TODO: use checksum address
        let account = Account(privateKey: privateKey, address: address)
        var accounts = getAccounts()
        guard !accounts.contains(where: { $0.address == address }) else { return nil }
        accounts.append(account)
        Keychain.save(accounts: accounts)
        return account
    }
    
    static func removeAccount(_ account: Account) {
        var accounts = getAccounts()
        accounts.removeAll(where: {$0.address == account.address })
        Keychain.save(accounts: accounts)
    }
    
    static func getAccounts() -> [Account] {
        return Keychain.accounts
    }
    
    static func getAccountForAddress(_ address: String) -> Account? {
        let allAccounts = getAccounts()
        return allAccounts.first(where: { $0.address == address.lowercased() })
    }
    
}
