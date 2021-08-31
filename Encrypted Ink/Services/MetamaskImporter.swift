// Copyright © 2021 Encrypted Ink. All rights reserved.

import SwiftStore
import CryptoSwift

class MetamaskImporter {
    
    enum MetamaskError: Error {
        case userClickedCancel
        case unknownError
    }
    
    static func selectMetamaskDirectory() throws -> String {
        guard var libraryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw MetamaskError.unknownError }
        while !libraryURL.path.hasSuffix("Library") {
            libraryURL.deleteLastPathComponent()
        }
        
        let metamaskDirectoryName = "nkbihfbeogaeaoehlefnkodbefgpgknn"
        let dirPath = "Application Support/Google/Chrome/Default/Local Extension Settings/\(metamaskDirectoryName)"
        guard let dirURL = URL(string: libraryURL.appendingPathComponent(dirPath).absoluteString) else {
            throw MetamaskError.unknownError
        }
        
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = dirURL
        openPanel.message = "Press Enter to import"
        openPanel.prompt = "Import"
        openPanel.allowedFileTypes = ["none"]
        openPanel.allowsOtherFileTypes = false
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        let response = openPanel.runModal()
        if response == .cancel {
            throw MetamaskError.userClickedCancel
        }
        guard
            response == .OK,
            let accessDirectory = openPanel.urls.first,
            let inside = try? FileManager.default.contentsOfDirectory(at: accessDirectory, includingPropertiesForKeys: nil, options: []),
            inside.contains(where: { $0.absoluteString.contains(metamaskDirectoryName) }),
            let metamaskPath = libraryURL.appendingPathComponent(dirPath).path.removingPercentEncoding
        else {
            throw MetamaskError.unknownError
        }
        return metamaskPath
    }
    
    static func importFromPath(_ metamaskDir: String, passphrase: String) throws -> [InkWallet] {
        guard let store = SwiftStore(dirPath: metamaskDir) else {
            throw MetamaskError.unknownError
        }
        defer {
            store.close()
        }
        guard
            let storageString = store.findKeys(key: "").first,
            let storageData = storageString.data(using: .utf8),
            let storage = try? JSONDecoder().decode(MetamaskStorage.self, from: storageData),
            let decryptedStorage = decrypt(data: storage.keyringController.vault.data,
                                           iv: storage.keyringController.vault.iv,
                                           salt: storage.keyringController.vault.salt,
                                           password: passphrase),
            let parsedDecryptedStorage = (try? JSONSerialization.jsonObject(with: decryptedStorage, options: []) as? [[String: Any]])
        else {
            throw MetamaskError.unknownError
        }
        
        var addedWallets = [InkWallet]()
        for account in parsedDecryptedStorage {
            guard let type = account["type"] as? String else { continue }
            if type == "Simple Key Pair" {
                guard let privateKeys = account["data"] as? [String] else { continue }
                for privateKey in privateKeys {
                    if let inkWallet = try? WalletsManager.shared.addWallet(input: privateKey, inputPassword: nil) {
                        addedWallets.append(inkWallet)
                    }
                }
            } else if type == "HD Key Tree" {
                guard
                    let data = account["data"] as? [String: Any],
                    let mnemonic = data["mnemonic"] as? String,
                    let numberOfAccounts = data["numberOfAccounts"] as? Int,
                    let hdPath = data["hdPath"] as? String,
                    let hdWallets = try? WalletsManager.shared.addHDWallets(mnemonic: mnemonic, numberOfAccounts: numberOfAccounts, hdPath: hdPath)
                else {
                    continue
                }
                addedWallets.append(contentsOf: hdWallets)
            }
        }
        return addedWallets
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
