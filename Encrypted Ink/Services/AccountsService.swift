// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift

struct AccountsService {
    
    static func validateAccountKey(_ key: String) -> Bool {
        let address = try? EthPrivateKey(hex: key).address().value()
        return address != nil
    }
    
    static func addAccount(privateKey: String) -> Account? {
        guard
            let addressBytes = try? EthPrivateKey(hex: privateKey).address().value()
        else {
            return nil
        }
        // TODO: checksum address
        let address = addressBytes.toPrefixedHexString()
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
