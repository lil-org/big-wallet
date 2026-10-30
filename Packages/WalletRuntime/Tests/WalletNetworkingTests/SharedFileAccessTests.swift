import Darwin
import Foundation
import Synchronization
import WalletStorageSupport
import XCTest

final class SharedFileAccessTests: XCTestCase {
    func testSnapshotAcceptsExactLimitAndEmptyFiles() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("state")
            let reader = RegularFileSnapshotReader(directoryBoundary: root)
            try Data([1, 2, 3]).write(to: url)
            XCTAssertEqual(reader.read(at: url, maximumBytes: 3), .data(Data([1, 2, 3])))
            XCTAssertEqual(reader.read(at: url, maximumBytes: 2), .tooLarge)
            try Data().write(to: url)
            XCTAssertEqual(reader.read(at: url, maximumBytes: 0), .data(Data()))
        }
    }

    func testSnapshotRejectsSparseOversizeBeforeReading() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("state")
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            XCTAssertEqual(Darwin.ftruncate(descriptor, 8 * 1_024 * 1_024 + 1), 0)
            Darwin.close(descriptor)
            let tracker = DescriptorTracker()
            let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: tracker.operations)
            XCTAssertEqual(reader.read(at: url, maximumBytes: 8 * 1_024 * 1_024), .tooLarge)
            XCTAssertEqual(tracker.calls("read"), 0)
            XCTAssertTrue(tracker.allClosed)
        }
    }

    func testSnapshotDistinguishesMissingAndUnsafeLeaves() throws {
        try withDirectory { root in
            let reader = RegularFileSnapshotReader(directoryBoundary: root)
            let target = root.appendingPathComponent("target")
            let link = root.appendingPathComponent("link")
            XCTAssertEqual(reader.read(at: target, maximumBytes: 16), .missing)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertEqual(reader.read(at: link, maximumBytes: 16), .unsafe)
            try Data([1]).write(to: target)
            XCTAssertEqual(reader.read(at: link, maximumBytes: 16), .unsafe)
            XCTAssertEqual(reader.read(at: root, maximumBytes: 16), .unsafe)
            let directory = root.appendingPathComponent("directory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            XCTAssertEqual(reader.read(at: directory, maximumBytes: 16), .unsafe)
            let fifo = root.appendingPathComponent("fifo")
            XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
            XCTAssertEqual(reader.read(at: fifo, maximumBytes: 16), .unsafe)
        }
    }

    func testSnapshotRejectsSymlinkInAnyDescendantDirectory() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("target/nested", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data([1]).write(to: target.appendingPathComponent("state"))
            let link = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
            let tracker = DescriptorTracker()
            let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: tracker.operations)
            XCTAssertEqual(reader.read(at: link.appendingPathComponent("nested/state"), maximumBytes: 16), .unsafe)
            XCTAssertEqual(tracker.calls("openFile"), 0)
            XCTAssertTrue(tracker.allClosed)
        }
    }

    func testSnapshotRejectsPathsOutsideBoundaryBeforeOpening() throws {
        try withDirectory { root in
            let tracker = DescriptorTracker()
            let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: tracker.operations)
            let outside = root.deletingLastPathComponent().appendingPathComponent("outside-state")
            XCTAssertEqual(reader.read(at: outside, maximumBytes: 16), .unsafe)
            XCTAssertEqual(tracker.calls("openDirectory"), 0)
        }
    }

    func testSnapshotRetriesInterruptedOperationsAndCompletesPartialReads() throws {
        try withDirectory { root in
            let parent = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let url = parent.appendingPathComponent("state")
            let expected = Data((0..<19).map(UInt8.init))
            try expected.write(to: url)
            let tracker = DescriptorTracker()
            tracker.maximumRead = 2
            for operation in ["openDirectory", "openDirectoryAt", "openFile", "metadata", "read", "entryMetadata"] {
                tracker.fail(operation, onCall: 1, with: .EINTR)
            }
            let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: tracker.operations)
            XCTAssertEqual(reader.read(at: url, maximumBytes: expected.count), .data(expected))
            XCTAssertGreaterThan(tracker.calls("read"), 9)
            XCTAssertTrue(tracker.allClosed)
        }
    }

    func testSnapshotClosesDescriptorsAfterEveryIOFailure() throws {
        try withDirectory { root in
            let parent = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let url = parent.appendingPathComponent("state")
            try Data([1, 2, 3]).write(to: url)
            let failures = [
                ("openDirectory", 1), ("openDirectoryAt", 1), ("openFile", 1),
                ("metadata", 1), ("read", 1), ("read", 2), ("metadata", 2), ("entryMetadata", 1),
            ]
            for (operation, call) in failures {
                let tracker = DescriptorTracker()
                tracker.fail(operation, onCall: call, with: .EIO)
                let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: tracker.operations)
                XCTAssertEqual(reader.read(at: url, maximumBytes: 16), .unavailable, "\(operation) #\(call)")
                XCTAssertTrue(tracker.allClosed, "\(operation) #\(call)")
            }
        }
    }

    func testSnapshotRejectsTruncationAndGrowthAfterInitialStat() throws {
        for grows in [false, true] {
            try withDirectory { root in
                let url = root.appendingPathComponent("state")
                try Data([1, 2, 3]).write(to: url)
                let tracker = DescriptorTracker()
                var operations = tracker.operations
                let metadata = operations.metadata
                operations.metadata = { descriptor in
                    let value = try metadata(descriptor)
                    if tracker.calls("metadata") == 1 {
                        let writer = Darwin.open(url.path, O_WRONLY)
                        guard writer >= 0 else { throw POSIXError(.EIO) }
                        defer { Darwin.close(writer) }
                        guard Darwin.ftruncate(writer, grows ? 4 : 2) == 0 else { throw POSIXError(.EIO) }
                    }
                    return value
                }
                let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: operations)
                XCTAssertEqual(reader.read(at: url, maximumBytes: 16), .changed)
                XCTAssertTrue(tracker.allClosed)
            }
        }
    }

    func testSnapshotRejectsSameSizeMetadataChange() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("state")
            try Data([1, 2, 3]).write(to: url)
            let tracker = DescriptorTracker()
            var operations = tracker.operations
            let metadata = operations.metadata
            operations.metadata = { descriptor in
                var value = try metadata(descriptor)
                if tracker.calls("metadata") == 2 { value.changeNanoseconds ^= 1 }
                return value
            }
            let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: operations)
            XCTAssertEqual(reader.read(at: url, maximumBytes: 16), .changed)
            XCTAssertTrue(tracker.allClosed)
        }
    }

    func testSnapshotRejectsPathReplacementOrRemovalAfterOpening() throws {
        for replaces in [false, true] {
            try withDirectory { root in
                let url = root.appendingPathComponent("state")
                try Data([1, 2, 3]).write(to: url)
                let tracker = DescriptorTracker()
                var operations = tracker.operations
                let entryMetadata = operations.entryMetadata
                operations.entryMetadata = { directory, name in
                    try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old-state"))
                    if replaces { try Data([4, 5, 6]).write(to: url) }
                    return try entryMetadata(directory, name)
                }
                let reader = RegularFileSnapshotReader(directoryBoundary: root, operations: operations)
                XCTAssertEqual(reader.read(at: url, maximumBytes: 16), .changed)
                XCTAssertTrue(tracker.allClosed)
            }
        }
    }

    func testAnchoredTraversalUsesOpenedParentsAndReturnsLeafFirst() throws {
        let opened = Mutex([(Int32, String)]())
        let closed = Mutex([Int32]())
        let operations = AnchoredDirectoryAccess.Operations(
            openDirectory: { path in
                XCTAssertEqual(path, "/group")
                return 10
            },
            openDirectoryAt: { descriptor, name in
                opened.withLock { $0.append((descriptor, name)) }
                return descriptor + 1
            },
            close: { descriptor in closed.withLock { $0.append(descriptor) } }
        )
        let descriptors = try AnchoredDirectoryAccess.openParent(
            of: URL(fileURLWithPath: "/group/bridge/profiles/state"),
            within: URL(fileURLWithPath: "/group"), operations: operations
        )
        XCTAssertEqual(descriptors, [12, 11, 10])
        XCTAssertEqual(opened.withLock { $0.map(\.0) }, [10, 11])
        XCTAssertEqual(opened.withLock { $0.map(\.1) }, ["bridge", "profiles"])
        XCTAssertTrue(closed.withLock { $0.isEmpty })
        descriptors.forEach(operations.close)
        XCTAssertEqual(closed.withLock { $0 }, descriptors)
    }

    func testLockRejectsUnsafeLeafAndDescendantDirectory() throws {
        try withDirectory { root in
            let target = root.appendingPathComponent("target")
            try Data([1]).write(to: target)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let fifo = root.appendingPathComponent("fifo")
            XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
            let directory = root.appendingPathComponent("directory", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let linkedDirectory = root.appendingPathComponent("linked-directory", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
            for url in [link, fifo, directory, linkedDirectory.appendingPathComponent("lock")] {
                let tracker = DescriptorTracker()
                var operations = CrossProcessFileLock.Operations.live
                operations.files = tracker.operations
                let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
                XCTAssertThrowsError(try lock.tryAcquire(), url.path)
                XCTAssertTrue(tracker.allClosed, url.path)
            }
            XCTAssertEqual(try Data(contentsOf: target), Data([1]))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lock").path))
        }
    }

    func testLockPreservesExistingOnlyAndContentionSemantics() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("lock")
            let first = CrossProcessFileLock(fileURL: url, directoryBoundary: root)
            XCTAssertThrowsError(try first.tryAcquireExisting())
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(try first.tryAcquire())
            XCTAssertFalse(try first.tryAcquire())
            let second = CrossProcessFileLock(fileURL: url, directoryBoundary: root)
            XCTAssertFalse(try second.tryAcquireExisting())
            XCTAssertThrowsError(try second.acquire(timeoutNanoseconds: 0, pollNanoseconds: 1))
            first.release()
            XCTAssertTrue(try second.tryAcquireExisting())
            second.release()
            XCTAssertTrue(try first.tryAcquireExisting())
            first.release()
        }
    }

    func testConcurrentInitialLockCreationHasExactlyOneOwner() throws {
        try withDirectory { root in
            for batch in 0..<32 {
                let url = root.appendingPathComponent("lock-\(batch)")
                let diagnostics = (0..<8).map { _ in LockAttemptDiagnostics() }
                let locks = diagnostics.map {
                    CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: $0.operations)
                }
                let outcomes = Mutex([(Int, Bool)]())
                let errors = Mutex([String]())
                DispatchQueue.concurrentPerform(iterations: locks.count) { index in
                    do {
                        let acquired = try locks[index].tryAcquire()
                        outcomes.withLock { $0.append((index, acquired)) }
                    } catch {
                        errors.withLock { $0.append("batch \(batch), worker \(index), \(diagnostics[index].failure): \(error)") }
                    }
                }
                defer { locks.forEach { $0.release() } }
                XCTAssertEqual(errors.withLock { $0 }, [])
                let observed = outcomes.withLock { $0 }
                XCTAssertEqual(observed.count, locks.count, "batch \(batch)")
                XCTAssertEqual(observed.filter(\.1).count, 1, "batch \(batch)")
                let contender = CrossProcessFileLock(fileURL: url, directoryBoundary: root)
                XCTAssertFalse(try contender.tryAcquireExisting(), "batch \(batch)")
                locks.forEach { $0.release() }
                XCTAssertTrue(try contender.tryAcquireExisting(), "batch \(batch)")
                contender.release()
            }
        }
    }

    func testLockUsesExclusiveCreationAndPlainExistingOpen() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("lock")
            let calls = Mutex([(Int32, mode_t)]())
            let live = CrossProcessFileLock.Operations.live
            var operations = live
            operations.files.openFile = { directory, name, flags, mode in
                calls.withLock { $0.append((flags, mode)) }
                return try live.files.openFile(directory, name, flags, mode)
            }
            let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
            let baseFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            XCTAssertTrue(try lock.tryAcquire())
            lock.release()
            XCTAssertEqual(calls.withLock { $0.map(\.0) }, [baseFlags | O_CREAT | O_EXCL])
            XCTAssertEqual(calls.withLock { $0.map(\.1) }, [0o600])
            calls.withLock { $0.removeAll() }
            XCTAssertTrue(try lock.tryAcquire())
            lock.release()
            XCTAssertEqual(calls.withLock { $0.map(\.0) }, [baseFlags | O_CREAT | O_EXCL, baseFlags])
            calls.withLock { $0.removeAll() }
            XCTAssertTrue(try lock.tryAcquireExisting())
            lock.release()
            XCTAssertEqual(calls.withLock { $0.map(\.0) }, [baseFlags])
        }
    }

    func testLockDoesNotRecreateMissingOrUnsafeEntryAfterExclusiveConflict() throws {
        for substitutesLink in [false, true] {
            try withDirectory { root in
                let url = root.appendingPathComponent("lock")
                let target = root.appendingPathComponent("target")
                try Data().write(to: url)
                try Data([1, 2, 3]).write(to: target)
                let calls = Mutex([Int32]())
                let live = CrossProcessFileLock.Operations.live
                var operations = live
                operations.files.openFile = { directory, name, flags, mode in
                    calls.withLock { $0.append(flags) }
                    do { return try live.files.openFile(directory, name, flags, mode) }
                    catch let error as POSIXError where error.code == .EEXIST {
                        try FileManager.default.removeItem(at: url)
                        if substitutesLink {
                            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
                        }
                        throw error
                    }
                }
                let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
                XCTAssertThrowsError(try lock.tryAcquire()) { error in
                    XCTAssertEqual((error as? POSIXError)?.code, substitutesLink ? .ELOOP : .ENOENT)
                }
                let baseFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                XCTAssertEqual(calls.withLock { $0 }, [baseFlags | O_CREAT | O_EXCL, baseFlags])
                if substitutesLink {
                    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                }
                XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
            }
        }
    }

    func testLockOnlyFallsBackAfterExclusiveCreateConflict() throws {
        for code: POSIXErrorCode in [.ENOENT, .EACCES, .EIO] {
            try withDirectory { root in
                let url = root.appendingPathComponent("lock")
                let calls = Mutex(0)
                var operations = CrossProcessFileLock.Operations.live
                operations.files.openFile = { _, _, _, _ in
                    calls.withLock { $0 += 1 }
                    throw POSIXError(code)
                }
                let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
                XCTAssertThrowsError(try lock.tryAcquire()) { error in
                    XCTAssertEqual((error as? POSIXError)?.code, code)
                }
                XCTAssertEqual(calls.withLock { $0 }, 1)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testLockRejectsReplacementAfterFlockAndReleasesOldDescriptor() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("lock")
            let displaced = root.appendingPathComponent("old-lock")
            let tracker = DescriptorTracker()
            let live = CrossProcessFileLock.Operations.live
            var operations = live
            operations.files = tracker.operations
            operations.flock = { descriptor, flags in
                try live.flock(descriptor, flags)
                if flags & LOCK_EX != 0 {
                    try FileManager.default.moveItem(at: url, to: displaced)
                    try Data().write(to: url)
                }
            }
            let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
            XCTAssertThrowsError(try lock.tryAcquire())
            XCTAssertTrue(tracker.allClosed)
            let old = CrossProcessFileLock(fileURL: displaced, directoryBoundary: root)
            XCTAssertTrue(try old.tryAcquireExisting())
            old.release()
            let replacement = CrossProcessFileLock(fileURL: url, directoryBoundary: root)
            XCTAssertTrue(try replacement.tryAcquireExisting())
            replacement.release()
        }
    }

    func testLockRetriesInterruptionsAndClosesOnPostAcquisitionFailure() throws {
        try withDirectory { root in
            let url = root.appendingPathComponent("lock")
            let tracker = DescriptorTracker()
            for operation in ["openDirectory", "openFile", "metadata", "entryMetadata"] {
                tracker.fail(operation, onCall: 1, with: .EINTR)
            }
            let attempts = Mutex(0)
            let live = CrossProcessFileLock.Operations.live
            var operations = live
            operations.files = tracker.operations
            operations.flock = { descriptor, flags in
                let first = attempts.withLock { attempts in
                    attempts += 1
                    return attempts == 1
                }
                if first { throw POSIXError(.EINTR) }
                try live.flock(descriptor, flags)
            }
            let lock = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: operations)
            XCTAssertTrue(try lock.tryAcquire())
            lock.release()
            XCTAssertTrue(tracker.allClosed)

            let failedTracker = DescriptorTracker()
            failedTracker.fail("entryMetadata", onCall: 1, with: .EIO)
            var failedOperations = live
            failedOperations.files = failedTracker.operations
            let failed = CrossProcessFileLock(fileURL: url, directoryBoundary: root, operations: failedOperations)
            XCTAssertThrowsError(try failed.tryAcquire())
            XCTAssertTrue(failedTracker.allClosed)
            XCTAssertTrue(try failed.tryAcquireExisting())
            failed.release()
            XCTAssertTrue(failedTracker.allClosed)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}

private final class LockAttemptDiagnostics: Sendable {
    private let lastFailure = Mutex<String?>(nil)

    var failure: String { lastFailure.withLock { $0 ?? "unknown operation" } }

    private func perform<Value>(_ name: String, _ operation: () throws -> Value) throws -> Value {
        do { return try operation() }
        catch {
            lastFailure.withLock { $0 = name }
            throw error
        }
    }

    var operations: CrossProcessFileLock.Operations {
        let live = CrossProcessFileLock.Operations.live
        var operations = live
        operations.files.directories.openDirectory = { [self] path in
            try perform("openDirectory") { try live.files.directories.openDirectory(path) }
        }
        operations.files.directories.openDirectoryAt = { [self] descriptor, name in
            try perform("openDirectoryAt") { try live.files.directories.openDirectoryAt(descriptor, name) }
        }
        operations.files.openFile = { [self] descriptor, name, flags, mode in
            try perform("openFile") { try live.files.openFile(descriptor, name, flags, mode) }
        }
        operations.files.metadata = { [self] descriptor in
            try perform("fstat") { try live.files.metadata(descriptor) }
        }
        operations.flock = { [self] descriptor, flags in
            try perform("flock") { try live.flock(descriptor, flags) }
        }
        operations.files.entryMetadata = { [self] descriptor, name in
            try perform("fstatat") { try live.files.entryMetadata(descriptor, name) }
        }
        return operations
    }
}

private final class DescriptorTracker: Sendable {
    private struct State {
        var descriptors = Set<Int32>()
        var invalidClose = false
        var calls = [String: Int]()
        var failures = [String: [Int: POSIXErrorCode]]()
        var maximumRead: Int?
    }

    private let state = Mutex(State())

    var maximumRead: Int? {
        get { state.withLock { $0.maximumRead } }
        set { state.withLock { $0.maximumRead = newValue } }
    }

    var allClosed: Bool { state.withLock { $0.descriptors.isEmpty && !$0.invalidClose } }

    func fail(_ operation: String, onCall call: Int, with code: POSIXErrorCode) {
        state.withLock { $0.failures[operation, default: [:]][call] = code }
    }

    func calls(_ operation: String) -> Int { state.withLock { $0.calls[operation, default: 0] } }

    private func checkpoint(_ operation: String) throws {
        let failure = state.withLock { state in
            state.calls[operation, default: 0] += 1
            return state.failures[operation]?[state.calls[operation, default: 0]]
        }
        if let failure { throw POSIXError(failure) }
    }

    private func opened(_ descriptor: Int32) -> Int32 {
        state.withLock { $0.descriptors.insert(descriptor) }
        return descriptor
    }

    private func close(_ descriptor: Int32) {
        state.withLock {
            if $0.descriptors.remove(descriptor) == nil { $0.invalidClose = true }
        }
        Darwin.close(descriptor)
    }

    var operations: SharedFileOperations {
        let live = SharedFileOperations.live
        var operations = live
        operations.directories.openDirectory = { [self] path in
            try checkpoint("openDirectory")
            return opened(try live.directories.openDirectory(path))
        }
        operations.directories.openDirectoryAt = { [self] directory, name in
            try checkpoint("openDirectoryAt")
            return opened(try live.directories.openDirectoryAt(directory, name))
        }
        operations.directories.close = { [self] in close($0) }
        operations.openFile = { [self] directory, name, flags, mode in
            try checkpoint("openFile")
            return opened(try live.openFile(directory, name, flags, mode))
        }
        operations.metadata = { [self] descriptor in
            try checkpoint("metadata")
            return try live.metadata(descriptor)
        }
        operations.entryMetadata = { [self] directory, name in
            try checkpoint("entryMetadata")
            return try live.entryMetadata(directory, name)
        }
        operations.read = { [self] descriptor, pointer, count in
            try checkpoint("read")
            return try live.read(descriptor, pointer, min(count, maximumRead ?? count))
        }
        operations.close = { [self] in close($0) }
        return operations
    }
}
