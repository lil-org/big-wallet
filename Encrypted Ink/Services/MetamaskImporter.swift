// Copyright © 2021 Encrypted Ink. All rights reserved.

import SwiftStore
import CryptoSwift
import WalletCore

class MetamaskImporter {
    
    static func importFromPath(_ metamaskDir: String, passphrase: String) -> (privateKeys: [String], mnemonics: [String])? {
        guard
            let store = SwiftStore(dirPath: metamaskDir),
            let storageString = store.findKeys(key: "").first,
            let storageData = storageString.data(using: .utf8),
            let storage = try? JSONDecoder().decode(MetamaskStorage.self, from: storageData),
            let decryptedStorage = decrypt(data: storage.keyringController.vault.data,
                                           iv: storage.keyringController.vault.iv,
                                           salt: storage.keyringController.vault.salt,
                                           password: passphrase),
            let parsedDecryptedStorage = (try? JSONSerialization.jsonObject(with: decryptedStorage, options: []) as? [[String: Any]])
        else {
            return nil
        }
        
        var exportedPrivateKeys = [String]()
        var exportedMnemonics = [String]()
        for account in parsedDecryptedStorage {
            guard let type = account["type"] as? String else { continue }
            if type == "Simple Key Pair" {
                guard let privateKeys = account["data"] as? [String] else { continue }
                exportedPrivateKeys.append(contentsOf: privateKeys)
            } else if type == "HD Key Tree" {
                guard
                    let data = account["data"] as? [String: Any],
                    let mnemonic = data["mnemonic"] as? String,
                    let numberOfAccounts = data["numberOfAccounts"] as? Int,
                    let hdPath = data["hdPath"] as? String
                else {
                    continue
                }
                exportedMnemonics.append(mnemonic)
                let wallet = HDWallet(mnemonic: mnemonic, passphrase: "")
                let firstKey = wallet.getKeyForCoin(coin: .ethereum).data.hexString
                
                for accountIndex in 0..<numberOfAccounts {
                    let privateKey = wallet.getKey(coin: .ethereum, derivationPath: hdPath + "/\(accountIndex)").data.hexString
                    if privateKey != firstKey {
                        exportedPrivateKeys.append(privateKey)
                    }
                }
            }
        }
        return (exportedPrivateKeys, exportedMnemonics)
    }
    
    private struct MetamaskStorage: Decodable {
        let keyringController: KeyringController
        
        enum CodingKeys: String, CodingKey {
            case keyringController = "KeyringController"
        }
        
        struct KeyringController: Decodable {
            let vault: Vault
            
            struct Vault: Decodable {
                let data: String
                let iv: String
                let salt: String
            }
            
            enum CodingKeys: String, CodingKey {
                case vault
            }
            
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let vaultString = try container.decode(String.self, forKey: .vault)
                guard let vaultData = vaultString.data(using: .utf8) else {
                    throw NSError()
                }
                vault = try JSONDecoder().decode(Vault.self, from: vaultData)
            }
        }
    }

    private static func keyFromPassword(password: String, salt: String) -> [UInt8]? {
        guard
            let passwordData = password.data(using: .utf8),
            let saltData = Data(base64Encoded: salt),
            let key = try? PKCS5.PBKDF2(password: passwordData.bytes,
                                        salt: saltData.bytes,
                                        iterations: 10000,  // See https://github.com/MetaMask/browser-passworder/blob/main/src/index.ts#L121
                                        variant: .sha256).calculate()
        else {
            return nil
        }
        return key
    }
    
    private static func decrypt(data: String, iv: String, salt: String, password: String) -> Data? {
        guard
            let key = keyFromPassword(password: password, salt: salt),
            let encryptedData = Data(base64Encoded: data),
            let ivData = Data(base64Encoded: iv),
            let aes = try? AES(key: key,
                               blockMode: GCM(iv: ivData.bytes, mode: .combined),
                               padding: .noPadding),
            let decryptedData = try? aes.decrypt(encryptedData.bytes)
        else {
            return nil
        }
        return Data(decryptedData)
    }
    
}
