// ∅ 2026 lil org

import Foundation

final class ExtensionRequestFileStore {
    typealias AtomicWrite = (Data, URL) throws -> Void
    typealias ReadData = (URL) throws -> Data
    typealias ReadFileSize = (URL) throws -> Int?
    typealias RemoveItem = (URL) throws -> Void
    typealias ParseRequest = (Data) -> SafariRequest?

    struct Dependencies {
        let clock: () -> Date
        let token: () -> UUID
        let crossProcessLock: CrossProcessFileLock?
        let crossProcessLockTimeoutNanoseconds: UInt64
        let crossProcessLockPollNanoseconds: UInt64
        let atomicWrite: AtomicWrite
        let readData: ReadData
        let readFileSize: ReadFileSize
        let removeItem: RemoveItem
        let parseRequest: ParseRequest

        init(
            clock: @escaping () -> Date = Date.init,
            token: @escaping () -> UUID = UUID.init,
            crossProcessLock: CrossProcessFileLock? = nil,
            crossProcessLockTimeoutNanoseconds: UInt64 = 1_000_000_000,
            crossProcessLockPollNanoseconds: UInt64 = 10_000_000,
            atomicWrite: @escaping AtomicWrite = ExtensionRequestFileStore.defaultAtomicWrite,
            readData: @escaping ReadData = ExtensionRequestFileStore.defaultReadData,
            readFileSize: @escaping ReadFileSize = ExtensionRequestFileStore.defaultReadFileSize,
            removeItem: @escaping RemoveItem = ExtensionRequestFileStore.defaultRemoveItem,
            parseRequest: @escaping ParseRequest = { SafariRequest(data: $0) }
        ) {
            self.clock = clock
            self.token = token
            self.crossProcessLock = crossProcessLock
            self.crossProcessLockTimeoutNanoseconds = crossProcessLockTimeoutNanoseconds
            self.crossProcessLockPollNanoseconds = crossProcessLockPollNanoseconds
            self.atomicWrite = atomicWrite
            self.readData = readData
            self.readFileSize = readFileSize
            self.removeItem = removeItem
            self.parseRequest = parseRequest
        }
    }

    private struct ProfileState: Codable {
        let schemaVersion: Int
        let workflowVersion: Int
        let profileIdentifier: UUID?
        var records: [Record]
    }

    private struct Record: Codable {
        enum State: Codable {
            case pending(request: Data)
            case claimed(claimID: UUID, request: Data)
            case broadcastPrepared(claimID: UUID, request: Data, recoveryResponse: Data)
            case completed(since: Date, response: Data)

            var requestData: Data? {
                switch self {
                case .pending(let request), .claimed(_, let request),
                     .broadcastPrepared(_, let request, _):
                    return request
                case .completed:
                    return nil
                }
            }

            var responseData: Data? {
                switch self {
                case .broadcastPrepared(_, _, let response), .completed(_, let response):
                    return response
                case .pending, .claimed:
                    return nil
                }
            }

            var isActive: Bool {
                switch self {
                case .pending, .claimed, .broadcastPrepared:
                    return true
                case .completed:
                    return false
                }
            }
        }

        let id: Int
        let profileIdentifier: UUID?
        let enqueueAttempt: String
        let requestToken: UUID
        let host: String
        let configurationKey: String
        let requestFingerprint: Data
        let revisions: ExtensionBridge.ProviderRevisions
        let admissionCreatedAt: Date
        var createdAt: Date
        var state: State

        var handle: ExtensionBridge.Handle {
            ExtensionBridge.Handle(
                id: id,
                token: .init(value: requestToken),
                profileIdentifier: profileIdentifier
            )
        }
    }

    private enum ProfileRead {
        case state(ProfileState)
        case unavailable
    }

    private enum PendingDeadlineTransition {
        case active(SafariRequest), expired, unavailable
    }

    private enum OperationLockStatus {
        case held, unlocked, unavailable
    }

    private enum RegularFileStatus {
        case missing, regular, unsafe, unavailable
    }

    private struct ProfileFileIdentity {
        let identifier: UUID?
    }

    private struct ProfileFileCandidate {
        let url: URL
        let identity: ProfileFileIdentity
    }

    private static let profileSchemaVersion = 5
    private static let profileDirectoryName = "profiles-v5"
    private static let profileSweepCursorName = "sweep.cursor"
    private static let operationLockDirectoryName = "operation-locks-v5"
    static let profileSweepBatchSize = 2
    private static let maximumProfileBytes =
        ExtensionBridge.maximumRetainedRequests * ExtensionBridge.maximumStoredRecordBytes + 64 * 1024
    private static let futureSkew = ExtensionBridge.admissionDeadlineFutureSkew

    private let rootURL: URL?
    private let clock: () -> Date
    private let token: () -> UUID
    private let storeLock: CrossProcessFileLock?
    private let lockTimeout: UInt64
    private let lockPoll: UInt64
    private let atomicWrite: AtomicWrite
    private let readData: ReadData
    private let readFileSize: ReadFileSize
    private let removeItem: RemoveItem
    private let parseRequest: ParseRequest
    private let fileManager = FileManager.default

    static func defaultAtomicWrite(_ data: Data, _ url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func defaultReadData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func defaultReadFileSize(_ url: URL) throws -> Int? {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize
    }

    static func defaultRemoveItem(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    init(
        rootURL: URL?,
        dependencies: Dependencies = .init()
    ) {
        self.rootURL = rootURL
        clock = dependencies.clock
        token = dependencies.token
        lockTimeout = dependencies.crossProcessLockTimeoutNanoseconds
        lockPoll = dependencies.crossProcessLockPollNanoseconds
        atomicWrite = dependencies.atomicWrite
        readData = dependencies.readData
        readFileSize = dependencies.readFileSize
        removeItem = dependencies.removeItem
        parseRequest = dependencies.parseRequest
        storeLock = dependencies.crossProcessLock ?? rootURL.map {
            CrossProcessFileLock(fileURL: $0.appendingPathComponent("bridge-v5.lock"))
        }
    }

    func enqueue(
        ingress: ExtensionBridge.Ingress,
        profileIdentifier: UUID?
    ) -> ExtensionBridge.EnqueueResult {
        withLock(or: .unavailable) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }

            if let existing = profile.records.first(where: {
                $0.enqueueAttempt == ingress.request.enqueueAttempt
            }) {
                guard existing.id == ingress.request.id,
                      existing.host == ingress.request.host,
                      existing.configurationKey == ingress.request.configurationKey,
                      existing.requestFingerprint == ingress.fingerprint else {
                    return .rejected
                }
                let approvalRequired: Bool
                if case .completed = existing.state {
                    approvalRequired = false
                } else {
                    approvalRequired = true
                }
                return .accepted(
                    handle: existing.handle,
                    approvalRequired: approvalRequired,
                    revisions: existing.revisions
                )
            }

            switch ExtensionBridge.admissionDeadlineDisposition(
                ingress.request.admissionDeadline,
                now: now
            ) {
            case .admissible:
                break
            case .expired:
                return .expired
            case .invalid:
                return .rejected
            }

            let active = profile.records.filter(\.state.isActive)
            guard active.count < ExtensionBridge.maximumRequests,
                  active.filter({
                      $0.configurationKey == ingress.request.configurationKey
                  }).count <
                    ExtensionBridge.maximumRequestsPerHost,
                  let requestToken = uniqueToken(in: profile.records) else {
                return .rejected
            }

            var retiredHandles = [ExtensionBridge.Handle]()
            while profile.records.filter({
                $0.configurationKey == ingress.request.configurationKey
            }).count >= ExtensionBridge.maximumRetainedRequestsPerOrigin {
                guard let index = oldestEvictableCompletedRecordIndex(
                    in: profile.records,
                    now: now,
                    configurationKey: ingress.request.configurationKey
                ) else {
                    return .rejected
                }
                retiredHandles.append(profile.records[index].handle)
                profile.records.remove(at: index)
            }
            if profile.records.count >= ExtensionBridge.maximumRetainedRequests {
                guard let index = oldestEvictableCompletedRecordIndex(
                    in: profile.records,
                    now: now
                ) else {
                    return .rejected
                }
                retiredHandles.append(profile.records[index].handle)
                profile.records.remove(at: index)
            }

            let record = Record(
                id: ingress.request.id,
                profileIdentifier: profileIdentifier,
                enqueueAttempt: ingress.request.enqueueAttempt,
                requestToken: requestToken,
                host: ingress.request.host,
                configurationKey: ingress.request.configurationKey,
                requestFingerprint: ingress.fingerprint,
                revisions: ingress.revisions,
                admissionCreatedAt: now,
                createdAt: now,
                state: .pending(request: ingress.canonicalData)
            )
            profile.records.append(record)
            guard writeProfileLocked(profile) else { return .unavailable }
            for handle in retiredHandles {
                removeOperationLockLocked(handle: handle)
            }
            return .accepted(
                handle: record.handle,
                approvalRequired: true,
                revisions: record.revisions
            )
        }
    }

    func list(profileIdentifier: UUID?) -> ExtensionBridge.SnapshotsResult {
        let maintenanceCandidates = discoverProfileCandidates(
            excluding: profileIdentifier
        )
        return withLock(or: .unavailable) {
            let now = clock()
            guard prepareDirectoriesLocked() else { return .unavailable }
            sweepProfilesLocked(
                candidates: maintenanceCandidates,
                now: now
            )
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: profileIdentifier,
                now: now,
                recover: true
            ) else { return .unavailable }
            let snapshots = profile.records.enumerated().reduce(
                into: [ExtensionBridge.Handle: ExtensionBridge.Snapshot]()
            ) { result, item in
                result[item.element.handle] = snapshot(
                    item.element,
                    sequence: item.offset
                )
            }
            return .available(snapshots)
        }
    }

    func load(handle: ExtensionBridge.Handle) -> ExtensionBridge.SnapshotResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == handle
            }) else {
                return .missing
            }
            return .found(snapshot(profile.records[index], sequence: index))
        }
    }

    func claim(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.ApprovalClaimResult {
        withLock(or: .unavailable) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let index = profile.records.firstIndex(where: { $0.handle == handle }) else {
                return .missing
            }
            switch profile.records[index].state {
            case .pending(let request):
                guard let lease = acquireOperationLeaseLocked(handle: handle),
                      let claimID = nextID(excluding: handle.token.value) else {
                    return .unavailable
                }
                profile.records[index].state = .claimed(
                    claimID: claimID,
                    request: request
                )
                guard writeProfileLocked(profile) else {
                    lease.release()
                    return .unavailable
                }
                return .claimed(.init(
                    handle: handle,
                    value: claimID,
                    lease: lease
                ))
            case .claimed, .broadcastPrepared:
                return .executing
            case .completed:
                return .responded
            }
        }
    }

    func release(
        claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier,
                now: now,
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, let requestData) = profile.records[index].state,
                  claim.matches(handle: claim.handle, value: claimID) else {
                return .ownershipLost
            }
            profile.records[index].state = .pending(request: requestData)
            let result: ExtensionBridge.StoreMutationResult
            switch transitionExpiredPending(
                &profile.records[index],
                now: now
            ) {
            case .active:
                result = .persisted
            case .expired:
                result = .ownershipLost
            case .unavailable:
                return .retryablePersistenceFailure
            }
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
            claim.releaseLease()
            removeOperationLockLocked(handle: claim.handle)
            return result
        }
    }

    func complete(
        handle: ExtensionBridge.Handle,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        finish(handle: handle, response: response)
    }

    func reject(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: { $0.handle == handle }),
                  let requestData = profile.records[index].state.requestData,
                  let request = parseRequest(requestData),
                  case .pending = profile.records[index].state else {
                return .ownershipLost
            }
            let response = ResponseToExtension(
                for: request,
                payload: .error(.userRejected)
            )
            guard let data = boundedResponseData(response, request: request) else {
                return .retryablePersistenceFailure
            }
            profile.records[index].state = .completed(
                since: max(profile.records[index].createdAt, clock()),
                response: data
            )
            return writeProfileLocked(profile)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    func begin(
        claim: ExtensionBridge.ApprovalClaim
    ) -> ExtensionBridge.BeginExecutionResult {
        withLock(or: .retryablePersistenceFailure) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: claim.handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let record = profile.records.first(where: {
                $0.handle == claim.handle
            }), case .claimed(let claimID, _) = record.state,
                  claim.matches(handle: claim.handle, value: claimID),
                  let lease = claim.lease,
                  lease.consume() else { return .ownershipLost }
            return .began(.init(
                handle: claim.handle,
                value: claimID,
                lease: lease
            ))
        }
    }

    func prepareBroadcast(
        permit: ExtensionBridge.ExecutionPermit,
        recoveryResponse: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            guard recoveryResponse.id == permit.handle.id,
                  let responseData = exactResponseData(recoveryResponse) else {
                return .ownershipLost
            }
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            switch profile.records[index].state {
            case .claimed(let claimID, let request):
                guard permit.matches(handle: permit.handle, value: claimID),
                      permit.lease != nil else { return .ownershipLost }
                profile.records[index].state = .broadcastPrepared(
                    claimID: claimID,
                    request: request,
                    recoveryResponse: responseData
                )
                return writeProfileLocked(profile)
                    ? .persisted
                    : .retryablePersistenceFailure
            case .broadcastPrepared(let claimID, _, let existing):
                guard permit.matches(handle: permit.handle, value: claimID) else {
                    return .ownershipLost
                }
                return existing == responseData ? .persisted : .ownershipLost
            case .pending, .completed:
                return .ownershipLost
            }
        }
    }

    func complete(
        permit: ExtensionBridge.ExecutionPermit,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            guard response.id == permit.handle.id else { return .ownershipLost }
            guard case .state(var profile) = readProfileLocked(
                profileIdentifier: permit.handle.profileIdentifier,
                now: clock(),
                recover: false
            ) else { return .retryablePersistenceFailure }
            guard let index = profile.records.firstIndex(where: {
                $0.handle == permit.handle
            }) else { return .ownershipLost }
            let requestData: Data
            let claimID: UUID
            let recoveryResponseData: Data?
            switch profile.records[index].state {
            case .claimed(let value, let request):
                claimID = value
                requestData = request
                recoveryResponseData = nil
            case .broadcastPrepared(let value, let request, let recoveryResponse):
                claimID = value
                requestData = request
                recoveryResponseData = recoveryResponse
            case .completed:
                permit.releaseLease()
                return .persisted
            case .pending:
                return .ownershipLost
            }
            guard permit.matches(handle: permit.handle, value: claimID),
                  let request = parseRequest(requestData),
                  let responseData = boundedResponseData(
                      response,
                      request: request,
                      recoveryResponseData: recoveryResponseData
                  ) else {
                return .ownershipLost
            }
            profile.records[index].state = .completed(
                since: max(profile.records[index].createdAt, clock()),
                response: responseData
            )
            guard writeProfileLocked(profile) else {
                return .retryablePersistenceFailure
            }
            permit.releaseLease()
            removeOperationLockLocked(handle: permit.handle)
            return .persisted
        }
    }

    func readResponse(
        handle: ExtensionBridge.Handle,
        configurationKey: String
    ) -> ExtensionBridge.ResponseReadResult {
        withLock(or: .unavailable) {
            guard case .state(let profile) = readProfileLocked(
                profileIdentifier: handle.profileIdentifier,
                now: clock(),
                recover: true
            ) else { return .unavailable }
            guard let record = profile.records.first(where: { $0.handle == handle }),
                  record.configurationKey == configurationKey else { return .missing }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                return .pending
            case .completed(_, let responseData):
                guard let response = responseJSON(responseData, id: handle.id) else {
                    return .unavailable
                }
                return .response(response)
            }
        }
    }

    private func finish(
        handle: ExtensionBridge.Handle,
        response: ResponseToExtension
    ) -> ExtensionBridge.StoreMutationResult {
        withLock(or: .retryablePersistenceFailure) {
            let now = clock()
            guard response.id == handle.id,
                  case .state(var profile) = readProfileLocked(
                    profileIdentifier: handle.profileIdentifier,
                    now: now,
                    recover: false
                  ),
                  let index = profile.records.firstIndex(where: { $0.handle == handle }) else {
                return .ownershipLost
            }
            guard case .pending = profile.records[index].state else {
                return .ownershipLost
            }
            let request: SafariRequest
            switch transitionExpiredPending(
                &profile.records[index],
                now: now
            ) {
            case .active(let activeRequest):
                request = activeRequest
            case .expired:
                return writeProfileLocked(profile)
                    ? .ownershipLost
                    : .retryablePersistenceFailure
            case .unavailable:
                return .retryablePersistenceFailure
            }
            guard let responseData = boundedResponseData(response, request: request) else {
                return .retryablePersistenceFailure
            }
            profile.records[index].state = .completed(
                since: max(profile.records[index].createdAt, now),
                response: responseData
            )
            return writeProfileLocked(profile)
                ? .persisted
                : .retryablePersistenceFailure
        }
    }

    private func readProfileLocked(
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool
    ) -> ProfileRead {
        guard prepareDirectoriesLocked() else { return .unavailable }
        return readProfileFileLocked(
            at: profileURL(profileIdentifier),
            profileIdentifier: profileIdentifier,
            now: now,
            recover: recover,
            removeIfEmpty: false
        )
    }

    private func readProfileFileLocked(
        at url: URL,
        profileIdentifier: UUID?,
        now: Date,
        recover: Bool,
        removeIfEmpty: Bool
    ) -> ProfileRead {
        let data: Data
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .state(emptyProfile(profileIdentifier))
        case .regular:
            break
        case .unsafe, .unavailable:
            return .unavailable
        }
        do {
            guard let size = try readFileSize(url),
                  size > 0, size <= Self.maximumProfileBytes else {
                return .unavailable
            }
            data = try readData(url)
        } catch {
            return .unavailable
        }
        guard data.count <= Self.maximumProfileBytes,
              var profile = try? PropertyListDecoder().decode(ProfileState.self, from: data),
              validate(
                  profile,
                  expectedIdentifier: profileIdentifier
              ) else {
            return .unavailable
        }
        let normalizedDates = normalizeFutureDates(in: &profile, now: now)
        guard recover else { return .state(profile) }
        var changed = normalizedDates
        var locksToRemove = [ExtensionBridge.Handle]()
        var kept = [Record]()
        for var record in profile.records {
            switch record.state {
            case .claimed(_, let request):
                switch operationLockStatusLocked(handle: record.handle) {
                case .held:
                    break
                case .unlocked:
                    record.state = .pending(request: request)
                    changed = true
                    locksToRemove.append(record.handle)
                case .unavailable:
                    return .unavailable
                }
            case .broadcastPrepared(_, _, let recoveryResponse):
                switch operationLockStatusLocked(handle: record.handle) {
                case .held:
                    break
                case .unlocked:
                    record.state = .completed(
                        since: max(record.createdAt, now),
                        response: recoveryResponse
                    )
                    changed = true
                    locksToRemove.append(record.handle)
                case .unavailable:
                    return .unavailable
                }
            case .pending, .completed:
                break
            }
            switch record.state {
            case .pending:
                switch transitionExpiredPending(&record, now: now) {
                case .active:
                    break
                case .expired:
                    changed = true
                    if !locksToRemove.contains(record.handle) {
                        locksToRemove.append(record.handle)
                    }
                case .unavailable:
                    return .unavailable
                }
                kept.append(record)
            case .completed(let since, _):
                if now.timeIntervalSince(since) >= ExtensionBridge.responseExpiry,
                   canRetireAdmissionRecord(record, now: now) {
                    changed = true
                    locksToRemove.append(record.handle)
                } else {
                    kept.append(record)
                }
            case .claimed, .broadcastPrepared:
                kept.append(record)
            }
        }
        guard changed else {
            if removeIfEmpty, profile.records.isEmpty,
               !removeProfileFileLocked(at: url) {
                return .unavailable
            }
            return .state(profile)
        }
        profile.records = kept
        if removeIfEmpty, profile.records.isEmpty {
            guard removeProfileFileLocked(at: url) else { return .unavailable }
        } else {
            guard writeProfileLocked(profile) else { return .unavailable }
        }
        for handle in locksToRemove { removeOperationLockLocked(handle: handle) }
        return .state(profile)
    }

    private func discoverProfileCandidates(
        excluding profileIdentifier: UUID?
    ) -> [ProfileFileCandidate] {
        guard rootURL != nil else { return [] }
        do {
            let attributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                return []
            }
            return try fileManager.contentsOfDirectory(
                at: profileDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).compactMap { url in
                guard let identity = profileFileIdentity(for: url),
                      identity.identifier != profileIdentifier else { return nil }
                return ProfileFileCandidate(url: url, identity: identity)
            }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        } catch {
            return []
        }
    }

    private func sweepProfilesLocked(
        candidates: [ProfileFileCandidate],
        now: Date
    ) {
        let profileSweepCursor = readProfileSweepCursorLocked()
        var startIndex = 0
        if let profileSweepCursor {
            startIndex = candidates.firstIndex(where: {
                $0.url.lastPathComponent > profileSweepCursor
            }) ?? 0
        }
        let selectedCount = min(Self.profileSweepBatchSize, candidates.count)
        let selected = (0..<selectedCount).map {
            candidates[(startIndex + $0) % candidates.count]
        }
        for candidate in selected {
            guard let identity = profileFileIdentity(for: candidate.url),
                  identity.identifier == candidate.identity.identifier else {
                continue
            }
            _ = readProfileFileLocked(
                at: candidate.url,
                profileIdentifier: candidate.identity.identifier,
                now: now,
                recover: true,
                removeIfEmpty: true
            )
        }
        if let last = selected.last {
            persistProfileSweepCursorLocked(last.url.lastPathComponent)
        }
    }

    private func readProfileSweepCursorLocked() -> String? {
        switch regularFileStatusLocked(at: profileSweepCursorURL) {
        case .regular:
            break
        case .missing, .unsafe, .unavailable:
            return nil
        }
        let data: Data
        do {
            guard let size = try readFileSize(profileSweepCursorURL),
                  size > 0, size <= 64 else { return nil }
            data = try readData(profileSweepCursorURL)
            guard data.count == size else { return nil }
        } catch {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              value == URL(fileURLWithPath: value).lastPathComponent,
              profileFileIdentity(
                for: profileDirectoryURL.appendingPathComponent(value)
              ) != nil else { return nil }
        return value
    }

    private func persistProfileSweepCursorLocked(_ value: String) {
        switch regularFileStatusLocked(at: profileSweepCursorURL) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return
        }
        guard let data = value.data(using: .utf8),
              data.count <= 64 else { return }
        try? atomicWrite(data, profileSweepCursorURL)
    }

    private func expirationResponseData(for request: SafariRequest) -> Data? {
        boundedResponseData(
            ResponseToExtension(for: request, payload: .error(.userRejected)),
            request: request
        )
    }

    private func transitionExpiredPending(
        _ record: inout Record,
        now: Date
    ) -> PendingDeadlineTransition {
        guard case .pending(let requestData) = record.state,
              let request = parseRequest(requestData) else {
            return .unavailable
        }
        guard request.admissionDeadline <= now else {
            return .active(request)
        }
        guard let responseData = expirationResponseData(for: request) else {
            return .unavailable
        }
        record.state = .completed(
            since: max(record.createdAt, now),
            response: responseData
        )
        return .expired
    }

    private func validate(
        _ profile: ProfileState,
        expectedIdentifier: UUID?
    ) -> Bool {
        guard profile.schemaVersion == Self.profileSchemaVersion,
              profile.workflowVersion == ExtensionBridge.workflowVersion,
              profile.profileIdentifier == expectedIdentifier,
              profile.records.count <= ExtensionBridge.maximumRetainedRequests,
              Set(profile.records.map(\.requestToken)).count == profile.records.count,
              Set(profile.records.map(\.enqueueAttempt)).count == profile.records.count else {
            return false
        }
        return profile.records.allSatisfy { record in
            guard record.profileIdentifier == expectedIdentifier,
                  !record.host.isEmpty,
                  ExtensionBridge.ProviderRevisions(
                      rawValue: record.revisions.json
                  ) != nil,
                  ExtensionBridge.isValidIdentity(
                      host: record.host,
                      configurationKey: record.configurationKey
                  ),
                  ExtensionBridge.isValidEnqueueAttempt(record.enqueueAttempt),
                  record.createdAt <= record.admissionCreatedAt else {
                return false
            }
            if let requestData = record.state.requestData {
                guard requestData.count <= ExtensionBridge.maximumPayloadBytes,
                      let rawObject = try? JSONSerialization.jsonObject(
                          with: requestData
                      ) as? [String: Any],
                      ExtensionBridge.ProviderRevisions(
                          rawValue: rawObject["revisions"]
                      ) == record.revisions,
                      ExtensionBridge.correlationFingerprint(rawObject) ==
                        record.requestFingerprint,
                      let request = parseRequest(requestData),
                      request.id == record.id,
                      request.host == record.host,
                      request.configurationKey == record.configurationKey,
                      request.enqueueAttempt == record.enqueueAttempt,
                      ExtensionBridge.admissionDeadlineDisposition(
                          request.admissionDeadline,
                          now: record.admissionCreatedAt
                      ) == .admissible,
                      request.workflowVersion == ExtensionBridge.workflowVersion else {
                    return false
                }
            }
            if let responseData = record.state.responseData,
               responseJSON(responseData, id: record.id) == nil {
                return false
            }
            switch record.state {
            case .completed(let since, _):
                return since >= record.createdAt
            case .pending, .claimed, .broadcastPrepared:
                return true
            }
        }
    }

    private func normalizeFutureDates(
        in profile: inout ProfileState,
        now: Date
    ) -> Bool {
        let futureLimit = now.addingTimeInterval(Self.futureSkew)
        var changed = false
        for index in profile.records.indices {
            var record = profile.records[index]
            if record.createdAt > futureLimit {
                record.createdAt = now
                changed = true
            }
            switch record.state {
            case .pending, .claimed, .broadcastPrepared:
                break
            case .completed(let since, let response):
                if since > futureLimit {
                    record.state = .completed(
                        since: max(record.createdAt, now),
                        response: response
                    )
                    changed = true
                }
            }
            profile.records[index] = record
        }
        return changed
    }

    private func snapshot(
        _ record: Record,
        sequence: Int
    ) -> ExtensionBridge.Snapshot {
        let request = record.state.requestData.flatMap(parseRequest)
        let phase: ExtensionBridge.Phase
        switch record.state {
        case .pending:
            phase = .queued
        case .claimed, .broadcastPrepared:
            phase = .approving
        case .completed:
            phase = .responded
        }
        return ExtensionBridge.Snapshot(
            handle: record.handle,
            phase: phase,
            request: request,
            host: record.host,
            configurationKey: record.configurationKey,
            revisions: record.revisions,
            createdAt: record.createdAt,
            enqueueAttempt: record.enqueueAttempt,
            sequence: sequence
        )
    }

    private func oldestEvictableCompletedRecordIndex(
        in records: [Record],
        now: Date,
        configurationKey: String? = nil
    ) -> Int? {
        var oldest: (index: Int, since: Date)?
        for (index, record) in records.enumerated() {
            guard configurationKey == nil || record.configurationKey == configurationKey,
                  canRetireAdmissionRecord(record, now: now),
                  case .completed(let since, _) = record.state else { continue }
            if let current = oldest, since >= current.since {
                continue
            } else {
                oldest = (index, since)
            }
        }
        return oldest?.index
    }

    private func canRetireAdmissionRecord(_ record: Record, now: Date) -> Bool {
        let retryWindow = ExtensionBridge.requestTTL + Self.futureSkew
        return record.admissionCreatedAt.addingTimeInterval(retryWindow) <= now
    }

    private func boundedResponseData(
        _ response: ResponseToExtension,
        request: SafariRequest,
        recoveryResponseData: Data? = nil
    ) -> Data? {
        if let data = exactResponseData(response) { return data }
        if let recoveryResponseData { return recoveryResponseData }
        var fallback = ResponseToExtension(
            for: request,
            payload: .error(.internalError)
        )
        if response.json[ExtensionBridge.approvalCommittedKey] as? Bool == true {
            fallback = fallback.markingApprovalCommitted()
        }
        return exactResponseData(fallback)
    }

    private func exactResponseData(_ response: ResponseToExtension) -> Data? {
        guard let data = ExtensionBridge.payloadData(response.json, options: [.sortedKeys]),
              data.count <= ExtensionBridge.maximumPayloadBytes,
              responseJSON(data, id: response.id) != nil else { return nil }
        return data
    }

    private func responseJSON(_ data: Data, id: Int) -> [String: Any]? {
        guard data.count <= ExtensionBridge.maximumPayloadBytes,
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["id"] as? Int == id else { return nil }
        return response
    }

    private func acquireOperationLeaseLocked(
        handle: ExtensionBridge.Handle
    ) -> ExtensionBridge.OperationLease? {
        guard prepareDirectoriesLocked() else { return nil }
        let url = operationLockURL(handle)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return nil
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            try lock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
            return .init(fileURL: url, lock: lock)
        } catch {
            return nil
        }
    }

    private func operationLockStatusLocked(
        handle: ExtensionBridge.Handle
    ) -> OperationLockStatus {
        operationLockStatusLocked(at: operationLockURL(handle))
    }

    private func operationLockStatusLocked(at url: URL) -> OperationLockStatus {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return .unlocked
        case .regular:
            break
        case .unsafe, .unavailable:
            return .unavailable
        }
        let lock = CrossProcessFileLock(fileURL: url)
        do {
            guard try lock.tryAcquireExisting() else { return .held }
            lock.release()
            return .unlocked
        } catch {
            return .unavailable
        }
    }

    private func removeOperationLockLocked(handle: ExtensionBridge.Handle) {
        removeOperationLockLocked(at: operationLockURL(handle))
    }

    private func removeOperationLockLocked(at url: URL) {
        guard case .unlocked = operationLockStatusLocked(at: url),
              case .regular = regularFileStatusLocked(at: url) else { return }
        try? removeItem(url)
    }

    private func uniqueToken(in records: [Record]) -> UUID? {
        for _ in 0..<16 {
            let candidate = token()
            if !records.contains(where: { $0.requestToken == candidate }) {
                return candidate
            }
        }
        return nil
    }

    private func nextID(excluding value: UUID) -> UUID? {
        for _ in 0..<16 {
            let candidate = token()
            if candidate != value { return candidate }
        }
        return nil
    }

    private func writeProfileLocked(_ profile: ProfileState) -> Bool {
        guard prepareDirectoriesLocked() else { return false }
        let url = profileURL(profile.profileIdentifier)
        switch regularFileStatusLocked(at: url) {
        case .missing, .regular:
            break
        case .unsafe, .unavailable:
            return false
        }
        guard let data = try? PropertyListEncoder().encode(profile),
              data.count <= Self.maximumProfileBytes else { return false }
        do {
            try atomicWrite(data, url)
            return true
        } catch {
            return false
        }
    }

    private func removeProfileFileLocked(at url: URL) -> Bool {
        switch regularFileStatusLocked(at: url) {
        case .missing:
            return true
        case .regular:
            break
        case .unsafe, .unavailable:
            return false
        }
        do {
            try removeItem(url)
            return true
        } catch {
            return false
        }
    }

    private func regularFileStatusLocked(at url: URL) -> RegularFileStatus {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else {
                return .unavailable
            }
            return type == .typeRegular ? .regular : .unsafe
        } catch {
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return .unsafe
            }
            return fileManager.fileExists(atPath: url.path) ? .unavailable : .missing
        }
    }

    private func emptyProfile(_ profileIdentifier: UUID?) -> ProfileState {
        ProfileState(
            schemaVersion: Self.profileSchemaVersion,
            workflowVersion: ExtensionBridge.workflowVersion,
            profileIdentifier: profileIdentifier,
            records: []
        )
    }

    private func prepareDirectoriesLocked() -> Bool {
        guard let rootURL else { return false }
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.profileDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(
                    Self.operationLockDirectoryName,
                    isDirectory: true
                ),
                withIntermediateDirectories: true
            )
            let profileAttributes = try fileManager.attributesOfItem(
                atPath: profileDirectoryURL.path
            )
            let lockAttributes = try fileManager.attributesOfItem(
                atPath: operationLockDirectoryURL.path
            )
            return profileAttributes[.type] as? FileAttributeType == .typeDirectory &&
                lockAttributes[.type] as? FileAttributeType == .typeDirectory
        } catch {
            return false
        }
    }

    private func withLock<T>(or fallback: T, _ body: () -> T) -> T {
        guard let rootURL, let storeLock else { return fallback }
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableRootURL = rootURL
            try mutableRootURL.setResourceValues(resourceValues)
            try storeLock.acquire(
                timeoutNanoseconds: lockTimeout,
                pollNanoseconds: lockPoll
            )
        } catch {
            return fallback
        }
        defer { storeLock.release() }
        return body()
    }

    private func profileURL(_ profileIdentifier: UUID?) -> URL {
        let name = profileIdentifier?.uuidString.lowercased() ?? "default"
        return profileDirectoryURL
            .appendingPathComponent(name)
            .appendingPathExtension("state")
    }

    private func operationLockURL(_ handle: ExtensionBridge.Handle) -> URL {
        let profile = handle.profileIdentifier?.uuidString.lowercased() ?? "default"
        return operationLockDirectoryURL
            .appendingPathComponent("\(profile)-\(handle.token.rawValue)")
            .appendingPathExtension("lock")
    }

    private var profileDirectoryURL: URL {
        rootURL!.appendingPathComponent(Self.profileDirectoryName, isDirectory: true)
    }

    private var operationLockDirectoryURL: URL {
        rootURL!.appendingPathComponent(
            Self.operationLockDirectoryName,
            isDirectory: true
        )
    }

    private var profileSweepCursorURL: URL {
        profileDirectoryURL.appendingPathComponent(Self.profileSweepCursorName)
    }

    private func profileFileIdentity(for url: URL) -> ProfileFileIdentity? {
        let name = url.lastPathComponent
        if name == "default.state" {
            return .init(identifier: nil)
        }
        guard name.hasSuffix(".state") else { return nil }
        let namespace = String(name.dropLast(".state".count))
        guard let identifier = UUID(uuidString: namespace),
              namespace == identifier.uuidString.lowercased(),
              name == "\(namespace).state" else { return nil }
        return .init(identifier: identifier)
    }
}
