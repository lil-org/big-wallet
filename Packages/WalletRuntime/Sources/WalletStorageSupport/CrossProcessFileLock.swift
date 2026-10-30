import Foundation
import Darwin
import Synchronization

@_silgen_name("flock")
private func storageSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public final class CrossProcessFileLock:
    Sendable {

    private enum FileLockError: Error {
        case missingFileURL
        case unsafeFile
        case lockTimedOut
    }

    public struct Operations: Sendable {
        public var files: SharedFileOperations
        public var flock: @Sendable (Int32, Int32) throws -> Void

        public init(
            files: SharedFileOperations,
            flock: @escaping @Sendable (Int32, Int32) throws -> Void
        ) {
            self.files = files
            self.flock = flock
        }

        public static let live = Self(files: .live, flock: { descriptor, operation in
            let result = storageSystemFlock(descriptor, operation)
            let code = errno
            try FileSystemCall.checked(result, errorCode: code)
        })
    }

    private let fileURL: URL?
    private let directoryBoundary: URL?
    private let operations: Operations
    private struct DescriptorState {
        var descriptor: Int32 = -1
        var acquisitionInProgress = false
    }
    private let descriptorState = Mutex(DescriptorState())

    public init(fileURL: URL?, directoryBoundary: URL? = nil, operations: Operations = .live) {
        self.fileURL = fileURL
        self.directoryBoundary = directoryBoundary ?? fileURL?.deletingLastPathComponent()
        self.operations = operations
    }

    public func acquire(
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64
    ) throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let (deadline, deadlineOverflow) = startedAt.addingReportingOverflow(
            timeoutNanoseconds
        )
        let effectiveDeadline = deadlineOverflow ? UInt64.max : deadline

        while true {
            if try tryAcquire() {
                return
            }

            let currentTime = DispatchTime.now().uptimeNanoseconds
            guard currentTime < effectiveDeadline else {
                throw FileLockError.lockTimedOut
            }
            let remaining = effectiveDeadline - currentTime
            let interval = min(max(pollNanoseconds, 1), remaining)
            Thread.sleep(
                forTimeInterval: TimeInterval(interval) / 1_000_000_000
            )
        }
    }

    public func tryAcquire() throws -> Bool {
        return try tryAcquire(createIfMissing: true)
    }

    public func tryAcquireExisting() throws -> Bool {
        return try tryAcquire(createIfMissing: false)
    }

    private func tryAcquire(createIfMissing: Bool) throws -> Bool {
        guard let fileURL, let directoryBoundary else { throw FileLockError.missingFileURL }

        guard
            descriptorState.withLock({ state in
                guard state.descriptor < 0, !state.acquisitionInProgress else { return false }
                state.acquisitionInProgress = true
                return true
            })
        else { return false }

        var adopted = false
        defer { if !adopted { finishFailedAcquisition() } }
        let directories = try AnchoredDirectoryAccess.openParent(
            of: fileURL, within: directoryBoundary, operations: operations.files.directories
        )
        defer { directories.forEach(operations.files.directories.close) }
        let directory = directories[0]
        let name = fileURL.standardizedFileURL.lastPathComponent
        let openedDescriptor = try openLockFile(in: directory, name: name, createIfMissing: createIfMissing)
        defer { if !adopted { operations.files.close(openedDescriptor) } }
        let initial = try FileSystemCall.retryInterrupted { try operations.files.metadata(openedDescriptor) }
        guard initial.isRegular else { throw FileLockError.unsafeFile }
        do {
            try FileSystemCall.retryInterrupted { try operations.flock(openedDescriptor, LOCK_EX | LOCK_NB) }
        } catch let error as POSIXError where error.code == .EACCES || error.code == .EAGAIN || error.code.rawValue == EWOULDBLOCK {
            return false
        }
        let current = try FileSystemCall.retryInterrupted { try operations.files.entryMetadata(directory, name) }
        guard current.isRegular, current.identifiesSameFile(as: initial) else { throw FileLockError.unsafeFile }

        descriptorState.withLock { state in
            state.descriptor = openedDescriptor
            state.acquisitionInProgress = false
        }
        adopted = true
        return true
    }

    private func openLockFile(in directory: Int32, name: String, createIfMissing: Bool) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        if createIfMissing {
            // Darwin openat can fail with ENOENT when concurrent creators omit O_EXCL.
            do {
                return try FileSystemCall.retryInterrupted {
                    try operations.files.openFile(directory, name, flags | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                }
            } catch let error as POSIXError where error.code == .EEXIST {}
        }
        return try FileSystemCall.retryInterrupted {
            try operations.files.openFile(directory, name, flags, S_IRUSR | S_IWUSR)
        }
    }

    public func release() {
        let openedDescriptor = descriptorState.withLock { state in
            defer { state.descriptor = -1 }
            return state.descriptor
        }

        guard openedDescriptor >= 0 else { return }
        try? FileSystemCall.retryInterrupted { try operations.flock(openedDescriptor, LOCK_UN) }
        operations.files.close(openedDescriptor)
    }

    private func finishFailedAcquisition() {
        descriptorState.withLock { $0.acquisitionInProgress = false }
    }

    deinit {
        release()
    }

}

