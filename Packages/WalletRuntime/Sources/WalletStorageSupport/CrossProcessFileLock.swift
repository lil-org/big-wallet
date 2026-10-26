import Foundation
import Darwin
import Synchronization

@_silgen_name("flock")
private func storageSystemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public final class CrossProcessFileLock:
    Sendable {

    private enum FileLockError: Error {
        case missingFileURL
        case openFailed
        case lockFailed
        case lockTimedOut
    }

    private let fileURL: URL?
    private struct DescriptorState {
        var descriptor: Int32 = -1
        var acquisitionInProgress = false
    }
    private let descriptorState = Mutex(DescriptorState())

    public init(fileURL: URL?) {
        self.fileURL = fileURL
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
        guard let fileURL else { throw FileLockError.missingFileURL }

        guard
            descriptorState.withLock({ state in
                guard state.descriptor < 0, !state.acquisitionInProgress else { return false }
                state.acquisitionInProgress = true
                return true
            })
        else { return false }

        var flags = O_RDWR | O_CLOEXEC
        if createIfMissing {
            flags |= O_CREAT
        }
        let openedDescriptor = Darwin.open(
            fileURL.path,
            flags,
            S_IRUSR | S_IWUSR
        )
        guard openedDescriptor >= 0 else {
            finishFailedAcquisition()
            throw FileLockError.openFailed
        }

        while storageSystemFlock(openedDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            if lockError == EINTR {
                continue
            }
            Darwin.close(openedDescriptor)
            finishFailedAcquisition()
            if lockError == EACCES
                || lockError == EAGAIN
                || lockError == EWOULDBLOCK {
                return false
            }
            throw FileLockError.lockFailed
        }

        descriptorState.withLock { state in
            state.descriptor = openedDescriptor
            state.acquisitionInProgress = false
        }
        return true
    }

    public func release() {
        let openedDescriptor = descriptorState.withLock { state in
            defer { state.descriptor = -1 }
            return state.descriptor
        }

        guard openedDescriptor >= 0 else { return }
        _ = storageSystemFlock(openedDescriptor, LOCK_UN)
        Darwin.close(openedDescriptor)
    }

    private func finishFailedAcquisition() {
        descriptorState.withLock { $0.acquisitionInProgress = false }
    }

    deinit {
        release()
    }

}

