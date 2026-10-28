import WalletDomain
import WalletAuthority
import WalletNetworking
import Foundation

protocol AccountPreviewSession: Sendable {
    func previewAccounts(page: Int) async throws -> [WalletAccount]
    func invalidate()
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
        case status
    }

    enum Status: Equatable {
        case idle, loadingInitial, ready, loadingMore, recovering
        case failed(page: Int)
    }

    enum RefreshOutcome: Equatable {
        case keepEditing, close
    }

    private(set) var wallet: WalletSnapshot
    private(set) var accounts = [WalletAccount]()
    private(set) var status = Status.idle
    private var selectedKeys: Set<WalletPreviewAccountKey>
    private let makeSession: @Sendable (WalletSnapshot) async throws -> any AccountPreviewSession
    private let timing: Timing
    private let didChange: (Change) -> Void
    private var session: (any AccountPreviewSession)?
    private var preparingSession: (generation: UInt64, session: any AccountPreviewSession)?
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isPagingEnabled = false
    private var nextPage = 0
    private var lastCompletedPageAt: ContinuousClock.Instant?
    private var hasLoadedAllPages = false
    private var recoveryTargetPage = 0

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
        session?.invalidate()
        preparingSession?.session.invalidate()
    }

    var hasChanges: Bool {
        selectedKeys != Set(wallet.accounts.map(\.previewAccountKey))
    }

    var hasEnabledAccounts: Bool {
        !selectedKeys.isEmpty
    }

    var canEdit: Bool {
        session != nil && (status == .ready || status == .loadingMore)
    }

    var canRetry: Bool {
        if case .failed = status { return true }
        return false
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
        guard canEdit, accounts.indices.contains(index) else { return }
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
        status = .loadingInitial
        startFreshSession(through: 0, change: .reload)
    }

    @discardableResult
    func retry() -> Bool {
        guard case .failed(let page) = status else { return false }
        cancelWork()
        status = .recovering
        startFreshSession(through: page, change: .status)
        return true
    }

    func suspendForStore() {
        guard status != .idle else { return }
        let page: Int
        if case .failed(let failedPage) = status { page = failedPage }
        else if status == .recovering { page = recoveryTargetPage }
        else { page = status == .loadingMore ? nextPage : max(nextPage - 1, 0) }
        cancelWork()
        status = .failed(page: page)
        didChange(.status)
    }

    private func startFreshSession(through lastPage: Int, change: Change) {
        recoveryTargetPage = lastPage
        let wallet = wallet
        let makeSession = makeSession
        let generation = generation
        didChange(change)
        guard self.generation == generation else { return }
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let session = try await makeSession(wallet)
                var adopted = false
                defer {
                    if !adopted {
                        session.invalidate()
                        if self?.preparingSession?.generation == generation {
                            self?.preparingSession = nil
                        }
                    }
                }
                try Task.checkCancellation()
                guard self?.generation == generation else { return }
                self?.preparingSession = (generation, session)
                var accounts = [WalletAccount]()
                var completedPages = 0
                var reachedEnd = false
                for page in 0...lastPage {
                    let pageAccounts = try await session.previewAccounts(page: page)
                    try Task.checkCancellation()
                    guard self?.generation == generation else { return }
                    completedPages = page + 1
                    accounts.append(contentsOf: pageAccounts)
                    if pageAccounts.isEmpty {
                        reachedEnd = true
                        break
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                loadTask = nil
                self.session = session
                preparingSession = nil
                adopted = true
                self.accounts = accounts
                nextPage = completedPages
                hasLoadedAllPages = reachedEnd
                lastCompletedPageAt = timing.now()
                status = .ready
                didChange(.initialPage(generation))
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                loadTask = nil
                status = .failed(page: lastPage)
                didChange(.status)
            }
        }
    }

    func activatePaging(for generation: UInt64) -> Bool {
        guard self.generation == generation, session != nil, loadTask == nil, status == .ready else { return false }
        isPagingEnabled = true
        return true
    }

    func loadMore() {
        guard isPagingEnabled, let session, loadTask == nil, !hasLoadedAllPages, status == .ready else { return }
        let generation = generation
        let page = nextPage
        let deadline = lastCompletedPageAt.map { $0 + Self.minimumPreviewInterval }
        let timing = timing
        status = .loadingMore
        didChange(.status)
        guard self.generation == generation else { return }
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
                status = .ready
                guard !accounts.isEmpty else { didChange(.status); return }
                let previousCount = self.accounts.count
                self.accounts.append(contentsOf: accounts)
                didChange(.append(previousCount..<self.accounts.count))
            } catch {
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                loadTask = nil
                self.session?.invalidate()
                self.session = nil
                isPagingEnabled = false
                status = .failed(page: page)
                didChange(.status)
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
        if session != nil || canRetry || status == .recovering {
            didChange(.reload)
        } else {
            restartInitialPreview()
        }
        return .keepEditing
    }

    func invalidate() {
        cancelWork()
        status = .idle
        nextPage = 0
        lastCompletedPageAt = nil
        hasLoadedAllPages = false
    }

    private func cancelWork() {
        generation &+= 1
        let task = loadTask
        let currentSession = session
        let initialSession = preparingSession?.session
        loadTask = nil
        session = nil
        preparingSession = nil
        isPagingEnabled = false
        currentSession?.invalidate()
        initialSession?.invalidate()
        task?.cancel()
    }
}
