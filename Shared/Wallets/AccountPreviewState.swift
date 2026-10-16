import Foundation

@MainActor
protocol AccountPreviewPaging: AnyObject {
    func reset() async -> [WalletAccount]?
    func previewMoreIfNeeded() async -> [WalletAccount]?
    func invalidate()
}

extension WalletsManager.PreviewAccountsPager: AccountPreviewPaging {}

@MainActor
final class AccountPreviewState {
    enum Change: Equatable {
        case reload
        case initialPage(UInt64)
        case append(Range<Int>)
        case selection
    }

    enum RefreshOutcome: Equatable {
        case keepEditing, close
    }

    private(set) var wallet: WalletSnapshot
    private(set) var accounts = [WalletAccount]()
    private var selectedKeys: Set<WalletPreviewAccountKey>
    private let makePager: (WalletSnapshot) -> any AccountPreviewPaging
    private let didChange: (Change) -> Void
    private var pager: (any AccountPreviewPaging)?
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isPagingEnabled = false

    init(
        wallet: WalletSnapshot,
        makePager: @escaping (WalletSnapshot) -> any AccountPreviewPaging,
        didChange: @escaping (Change) -> Void
    ) {
        self.wallet = wallet
        selectedKeys = Set(wallet.accounts.map(\.previewAccountKey))
        self.makePager = makePager
        self.didChange = didChange
    }

    isolated deinit {
        loadTask?.cancel()
        pager?.invalidate()
    }

    var hasChanges: Bool {
        selectedKeys != Set(wallet.accounts.map(\.previewAccountKey))
    }

    var hasEnabledAccounts: Bool {
        !selectedKeys.isEmpty
    }

    var enabledAccounts: [WalletAccount] {
        let loadedKeys = Set(accounts.map(\.previewAccountKey))
        return accounts.filter(isEnabled) + wallet.accounts.filter {
            isEnabled($0) && !loadedKeys.contains($0.previewAccountKey)
        }
    }

    func isEnabled(_ account: WalletAccount) -> Bool {
        selectedKeys.contains(account.previewAccountKey)
    }

    func toggle(at index: Int) {
        guard pager != nil, accounts.indices.contains(index) else { return }
        let key = accounts[index].previewAccountKey
        if !selectedKeys.insert(key).inserted {
            selectedKeys.remove(key)
        }
        didChange(.selection)
    }

    func reset() {
        invalidate()
        accounts.removeAll()
        selectedKeys = Set(wallet.accounts.map(\.previewAccountKey))
        let pager = makePager(wallet)
        self.pager = pager
        let generation = generation
        didChange(.reload)
        guard self.generation == generation else { return }
        loadTask = Task { [weak self, pager] in
            let accounts = await pager.reset()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            loadTask = nil
            guard let accounts else { return }
            self.accounts = accounts
            didChange(.initialPage(generation))
        }
    }

    func activatePaging(for generation: UInt64) -> Bool {
        guard self.generation == generation, pager != nil, loadTask == nil else { return false }
        isPagingEnabled = true
        return true
    }

    func loadMore() {
        guard isPagingEnabled, let pager, loadTask == nil else { return }
        let generation = generation
        loadTask = Task { [weak self, pager] in
            let accounts = await pager.previewMoreIfNeeded()
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            loadTask = nil
            guard let accounts, !accounts.isEmpty else { return }
            let previousCount = self.accounts.count
            self.accounts.append(contentsOf: accounts)
            didChange(.append(previousCount..<self.accounts.count))
        }
    }

    func refresh(wallet: WalletSnapshot?) -> RefreshOutcome {
        guard let wallet, wallet.id == self.wallet.id else {
            invalidate()
            return .close
        }
        let previousKeys = Set(self.wallet.accounts.map(\.previewAccountKey))
        let currentKeys = Set(wallet.accounts.map(\.previewAccountKey))
        if previousKeys == currentKeys {
            self.wallet = wallet
            didChange(.reload)
        } else if hasChanges {
            invalidate()
            return .close
        } else {
            self.wallet = wallet
            reset()
        }
        return .keepEditing
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        pager?.invalidate()
        pager = nil
        isPagingEnabled = false
    }
}
