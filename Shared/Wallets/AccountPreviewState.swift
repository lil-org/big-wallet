import Foundation

protocol AccountPreviewSession: Sendable {
    func previewAccounts(page: Int) async throws -> [WalletAccount]
}

extension WalletPreviewSession: AccountPreviewSession {}

@MainActor
final class AccountPreviewState {
    struct Timing: Sendable {
        var now: @Sendable () -> ContinuousClock.Instant
        var sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

        static let live = Timing(
            now: { .now },
            sleepUntil: { try await ContinuousClock().sleep(until: $0) }
        )
    }

    private static let minimumPreviewInterval = Duration.milliseconds(230)

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
    private let makeSession: @Sendable (WalletSnapshot) async throws -> any AccountPreviewSession
    private let timing: Timing
    private let didChange: (Change) -> Void
    private var session: (any AccountPreviewSession)?
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isPagingEnabled = false
    private var nextPage = 0
    private var lastCompletedPageAt: ContinuousClock.Instant?
    private var hasLoadedAllPages = false

    init(
        wallet: WalletSnapshot,
        makeSession: @escaping @Sendable (WalletSnapshot) async throws -> any AccountPreviewSession,
        timing: Timing = .live,
        didChange: @escaping (Change) -> Void
    ) {
        self.wallet = wallet
        selectedKeys = Set(wallet.accounts.map(\.previewAccountKey))
        self.makeSession = makeSession
        self.timing = timing
        self.didChange = didChange
    }

    isolated deinit {
        loadTask?.cancel()
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
        guard session != nil, accounts.indices.contains(index) else { return }
        let key = accounts[index].previewAccountKey
        if !selectedKeys.insert(key).inserted {
            selectedKeys.remove(key)
        }
        didChange(.selection)
    }

    func reset() {
        selectedKeys = Set(wallet.accounts.map(\.previewAccountKey))
        restartInitialPreview()
    }

    private func restartInitialPreview() {
        invalidate()
        accounts.removeAll()
        let wallet = wallet
        let makeSession = makeSession
        let generation = generation
        didChange(.reload)
        guard self.generation == generation else { return }
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let session = try await makeSession(wallet)
                try Task.checkCancellation()
                let accounts = try await session.previewAccounts(page: 0)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                loadTask = nil
                self.session = session
                self.accounts = accounts
                nextPage = 1
                lastCompletedPageAt = timing.now()
                didChange(.initialPage(generation))
            } catch {
                guard let self, self.generation == generation else { return }
                loadTask = nil
            }
        }
    }

    func activatePaging(for generation: UInt64) -> Bool {
        guard self.generation == generation, session != nil, loadTask == nil else { return false }
        isPagingEnabled = true
        return true
    }

    func loadMore() {
        guard isPagingEnabled, let session, loadTask == nil, !hasLoadedAllPages else { return }
        let generation = generation
        let page = nextPage
        let deadline = lastCompletedPageAt.map { $0 + Self.minimumPreviewInterval }
        let timing = timing
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                if let deadline, timing.now() < deadline { try await timing.sleepUntil(deadline) }
                try Task.checkCancellation()
                let accounts = try await session.previewAccounts(page: page)
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                loadTask = nil
                nextPage = page + 1
                lastCompletedPageAt = timing.now()
                hasLoadedAllPages = accounts.isEmpty
                guard !accounts.isEmpty else { return }
                let previousCount = self.accounts.count
                self.accounts.append(contentsOf: accounts)
                didChange(.append(previousCount..<self.accounts.count))
            } catch {
                guard let self, self.generation == generation else { return }
                loadTask = nil
            }
        }
    }

    func refresh(wallet: WalletSnapshot?) -> RefreshOutcome {
        guard let wallet, wallet.id == self.wallet.id else {
            invalidate()
            return .close
        }
        let previousKeys = Set(self.wallet.accounts.map(\.previewAccountKey))
        let currentKeys = Set(wallet.accounts.map(\.previewAccountKey))
        let addedKeys = selectedKeys.subtracting(previousKeys)
        let removedKeys = previousKeys.subtracting(selectedKeys)
        selectedKeys = currentKeys.subtracting(removedKeys).union(addedKeys)
        self.wallet = wallet
        if session != nil {
            didChange(.reload)
        } else {
            restartInitialPreview()
        }
        return .keepEditing
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        session = nil
        isPagingEnabled = false
        nextPage = 0
        lastCompletedPageAt = nil
        hasLoadedAllPages = false
    }
}
