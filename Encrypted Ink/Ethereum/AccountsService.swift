// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift

struct AccountsService {
    
    private static let keychainKey = "EncryptedInkStorage"
    
    static func addAccount(privateKey: String) -> Account? {
        guard
            let addressBytes = try? EthPrivateKey(hex: privateKey).address().value()
        else {
            return nil
        }
        let address = addressBytes.toPrefixedHexString()
        let account = Account(privateKey: privateKey, address: address)
        var accounts = getAccounts()
        guard !accounts.contains(where: { $0.address == address }) else { return nil }
        accounts.append(account)
        saveInKeychain(accounts: accounts)
        return account
    }
    
    static func removeAccount(_ account: Account) {
        var accounts = getAccounts()
        accounts.removeAll(where: {$0.address == account.address })
        
        saveInKeychain(accounts: accounts)
    }
    
    static func getAccounts() -> [Account] {
        return loadAccountsFromKeychain() ?? []
    }
    
    private static func saveInKeychain(accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        let query = [kSecClass as String: kSecClassGenericPassword as String,
                     kSecAttrAccount as String: keychainKey,
                     kSecValueData as String: data] as [String: Any]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private static func loadAccountsFromKeychain() -> [Account]? {
        guard let returnDataQueryValue = kCFBooleanTrue else { return nil }
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccount as String: keychainKey,
                     kSecReturnData as String: returnDataQueryValue,
                     kSecMatchLimit as String: kSecMatchLimitOne] as [String: Any]

        var dataTypeRef: AnyObject?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == noErr, let data = dataTypeRef as? Data {
            let accounts = try? JSONDecoder().decode([Account].self, from: data)
            return accounts
        } else {
            return nil
        }
    }
}
