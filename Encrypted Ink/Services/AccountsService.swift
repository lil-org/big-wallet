// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import WalletCore

struct AccountsService {
    
    private init() {}
    private let keychain = Keychain.shared
    
    static let shared = AccountsService()
    
    enum InputValidationResult {
        case valid, invalid, requiresPassword
    }
    
    func validateAccountInput(_ input: String) -> InputValidationResult {
        if Mnemonic.isValid(mnemonic: input) {
            return .valid
        } else if let data = Data(hexString: input) {
            return PrivateKey.isValid(data: data, curve: CoinType.ethereum.curve) ? .valid : .invalid
        } else {
            return input.maybeJSON ? .requiresPassword : .invalid
        }
    }
    
    func createAccount() {
        guard let password = keychain.password?.data(using: .utf8) else { return }
        let key = StoredKey(name: "", password: password)
        guard let privateKey = key.wallet(password: password)?.getKeyForCoin(coin: .ethereum) else { return }
        _ = saveAccount(privateKey: privateKey)
    }
    
    func addAccount(input: String, password: String?) -> LegacyAccountWithKey? {
        let key: PrivateKey
        if Mnemonic.isValid(mnemonic: input) {
            key = HDWallet(mnemonic: input, passphrase: "").getKeyForCoin(coin: .ethereum)
        } else if let data = Data(hexString: input), let privateKey = PrivateKey(data: data) {
            key = privateKey
        } else if input.maybeJSON,
                  let password = password,
                  let json = input.data(using: .utf8),
                  let jsonKey = StoredKey.importJSON(json: json),
                  let data = jsonKey.decryptPrivateKey(password: Data(password.utf8)),
                  let privateKey = PrivateKey(data: data) {
            key = privateKey
        } else {
            return nil
        }
        
        let account = saveAccount(privateKey: key)
        return account
    }
    
    private func saveAccount(privateKey: PrivateKey) -> LegacyAccountWithKey? {
        let address = CoinType.ethereum.deriveAddress(privateKey: privateKey).lowercased()
        // TODO: use checksum address
        let account = LegacyAccountWithKey(privateKey: privateKey.data.hexString, address: address)
        var accounts = getAccounts()
        guard !accounts.contains(where: { $0.address == address }) else { return nil }
        accounts.append(account)
        try? keychain.save(accounts: accounts)
        return account
    }
    
    func removeAccount(_ account: LegacyAccountWithKey) {
        var accounts = getAccounts()
        accounts.removeAll(where: {$0.address == account.address })
        try? keychain.save(accounts: accounts)
    }
    
    func getAccounts() -> [LegacyAccountWithKey] {
        return keychain.accounts
    }
    
    func getAccountForAddress(_ address: String) -> LegacyAccountWithKey? {
        let allAccounts = getAccounts()
        return allAccounts.first(where: { $0.address == address.lowercased() })
    }
    
}

private extension String {
    
    var maybeJSON: Bool {
        return hasPrefix("{") && hasSuffix("}") && count > 3
    }
    
}
