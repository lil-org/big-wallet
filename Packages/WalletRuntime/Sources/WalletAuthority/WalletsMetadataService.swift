import WalletDomain
import WalletStorageSupport
// ∅ 2026 lil org

import Synchronization

public final class WalletsMetadataService: Sendable {
    private let storage: any SharedPreferenceStorage
    private let names: Mutex<[String: String]>
    private let postChange: @Sendable () -> Void

    init(storage: any SharedPreferenceStorage, postChange: @escaping @Sendable () -> Void = {}) {
        self.storage = storage
        self.postChange = postChange
        storage.synchronize()
        names = Mutex(storage.object(forKey: Self.namesKey) as? [String: String] ?? [:])
    }

    static func live() -> WalletsMetadataService {
        WalletsMetadataService(storage: Defaults.metadataStorage) {
            WalletStoreSync.postLocalAndExternalChange(defaultsAlreadySynchronized: true)
        }
    }

    var mutations: WalletRepository.MetadataMutations {
        .init(
            removeWallet: { self.removeMetadataForWallet($0, postChange: false) },
            removeAccounts: { self.removeMetadataForAccounts(walletId: $0, accounts: $1, postChange: false) }
        )
    }

    private static let namesKey = "walletsAndAccountsNames"

    public func reload() {
        names.withLock { $0 = currentNames() }
    }

    public func getWalletName(wallet: WalletSnapshot) -> String? {
        names.withLock { $0[itemKey(walletId: wallet.id, account: nil)] }
    }

    public func saveWalletName(_ name: String?, wallet: WalletSnapshot) {
        saveItemName(name, wallet: wallet, account: nil)
    }

    public func getAccountName(walletId: String, account: WalletAccount) -> String? {
        names.withLock { $0[itemKey(walletId: walletId, account: account)] }
    }

    public func saveAccountName(_ name: String?, wallet: WalletSnapshot, account: WalletAccount) {
        saveItemName(name, wallet: wallet, account: account)
    }

    func removeMetadataForWallet(_ wallet: WalletSnapshot, postChange: Bool = true) {
        updateNames(postChange: postChange) { names in
            for key in names.keys.filter({ isMetadataKey($0, forWalletId: wallet.id) }) {
                names.removeValue(forKey: key)
            }
        }
    }

    func removeMetadataForAccounts(walletId: String, accounts: [WalletAccount], postChange: Bool = true) {
        updateNames(postChange: postChange) { names in
            for account in accounts {
                names.removeValue(forKey: itemKey(walletId: walletId, account: account))
            }
        }
    }

    private func saveItemName(_ name: String?, wallet: WalletSnapshot, account: WalletAccount?) {
        updateNames { names in
            let key = itemKey(walletId: wallet.id, account: account)
            if let name, !name.isEmpty {
                names[key] = name
            } else {
                names.removeValue(forKey: key)
            }
        }
    }

    private func updateNames(postChange: Bool = true, _ update: (inout [String: String]) -> Void) {
        names.withLock { names in
            names = currentNames()
            update(&names)
            storage.set(names, forKey: Self.namesKey)
            storage.synchronize()
        }
        if postChange {
            self.postChange()
        }
    }

    private func itemKey(walletId: String, account: WalletAccount?) -> String {
        guard let account else { return walletId }
        return "\(walletId)-\(account.coin.rawValue)-\(account.derivationPath)"
    }

    private func isMetadataKey(_ key: String, forWalletId walletId: String) -> Bool {
        key == walletId || key.hasPrefix("\(walletId)-")
    }

    private func currentNames() -> [String: String] {
        storage.synchronize()
        return storage.object(forKey: Self.namesKey) as? [String: String] ?? [:]
    }
}

