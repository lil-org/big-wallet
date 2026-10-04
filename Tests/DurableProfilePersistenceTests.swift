import Darwin
import Foundation
import Synchronization
import XCTest
@testable import Big_Wallet

final class DurableProfilePersistenceTests: XCTestCase {
    private let boundary = URL(fileURLWithPath: "/group", isDirectory: true)
    private let profile = URL(fileURLWithPath: "/group/bridge/profiles/profile.state")

    func testReplacementFlushesContentsBeforeRenameAndParentsBeforeFinalFlush() throws {
        let disk = DiskModel()
        try persistence(disk).replace(Data("checkpoint".utf8), at: profile)

        XCTAssertEqual(disk.events, [
            "openDirectory:/group/bridge/profiles", "openDirectory:/group/bridge", "openDirectory:/group",
            "entryKind", "create", "kind", "write:1", "full:1", "rename",
            "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2",
        ])
        XCTAssertEqual(disk.createFlags, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertEqual(disk.createMode, 0o600)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
        disk.crash()
        XCTAssertEqual(disk.published, Data("checkpoint".utf8))
    }

    func testShortWritesAndInterruptedOperationsAreRetried() throws {
        let disk = DiskModel()
        disk.maximumWrite = 2
        disk.failures["write:1"] = [.EINTR]
        disk.failures["full:1"] = [.EINTR]
        disk.failures["sync:/group/bridge"] = [.EINTR]
        let data = Data("checkpoint".utf8)
        try persistence(disk).replace(data, at: profile)

        disk.crash()
        XCTAssertEqual(disk.published, data)
        XCTAssertEqual(disk.events.filter { $0 == "sync:/group/bridge" }.count, 2)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testEveryFailedStageClosesDescriptorsAndPreservesTheDurableCheckpoint() throws {
        let stages = [
            "openDirectory:/group/bridge/profiles", "openDirectory:/group/bridge", "openDirectory:/group",
            "entryKind", "create", "kind", "write:1", "full:1", "rename",
            "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2",
        ]
        for stage in stages {
            let disk = DiskModel()
            disk.failures[stage] = [.EIO]
            XCTAssertThrowsError(try persistence(disk).replace(Data("new response".utf8), at: profile), stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
            XCTAssertFalse(disk.hasTemporaryEntry, stage)
            disk.crash()
            XCTAssertEqual(disk.published, Data("old checkpoint".utf8), stage)
        }
    }

    func testZeroByteWriteFailsWithoutPublishing() throws {
        let disk = DiskModel()
        disk.maximumWrite = 0
        XCTAssertThrowsError(try persistence(disk).replace(Data([1]), at: profile)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertFalse(disk.events.contains("rename"))
        XCTAssertFalse(disk.hasTemporaryEntry)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testVisibleReplacementNeedsASuccessfulBarrierBeforeItIsDurable() throws {
        let disk = DiskModel()
        let writer = persistence(disk)
        let data = Data("new response".utf8)
        disk.failures["full:2"] = [.EIO]
        XCTAssertThrowsError(try writer.replace(data, at: profile))
        XCTAssertEqual(disk.published, data)
        XCTAssertEqual(disk.durablePublished, Data("old checkpoint".utf8))

        disk.failures["full:3"] = [.EIO]
        XCTAssertThrowsError(try writer.synchronizePublishedFile(at: profile))
        XCTAssertEqual(disk.durablePublished, Data("old checkpoint".utf8))

        try writer.synchronizePublishedFile(at: profile)
        disk.crash()
        XCTAssertEqual(disk.published, data)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testLaterProfileMutationCannotReplaceCheckpointWithUnflushedContents() throws {
        for stage in ["write:2", "full:3", "rename", "sync:/group/bridge/profiles", "full:4"] {
            let disk = DiskModel()
            let writer = persistence(disk)
            let checkpoint = Data("broadcastPrepared A".utf8)
            try writer.replace(checkpoint, at: profile)
            disk.failures[stage] = [.EIO]
            let updated = Data("broadcastPrepared A; queued B".utf8)
            XCTAssertThrowsError(try writer.replace(updated, at: profile), stage)
            disk.crash()
            XCTAssertEqual(disk.published, checkpoint, stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
        }
    }

    func testPublishedFileBarrierRejectsNonregularFilesAndPropagatesFailures() throws {
        let stages = [
            "openDirectory:/group/bridge", "openPublished", "kind", "full:1",
            "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2",
        ]
        for stage in stages {
            let disk = DiskModel()
            disk.failures[stage] = [.EIO]
            XCTAssertThrowsError(try persistence(disk).synchronizePublishedFile(at: profile), stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
        }
        let disk = DiskModel()
        var operations = disk.operations
        operations.fileKind = { _ in .other }
        let writer = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
        XCTAssertThrowsError(try writer.synchronizePublishedFile(at: profile))
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testBoundaryValidationPrecedesFilesystemOperations() throws {
        for path in ["/outside/profile.state", "/group-other/profile.state", "/group"] {
            let disk = DiskModel()
            XCTAssertThrowsError(try persistence(disk).replace(Data([1]), at: URL(fileURLWithPath: path)))
            XCTAssertTrue(disk.events.isEmpty)
        }
    }

    func testRealDiskReplacementAndPostRenameFailureLeaveNoTemporaryFiles() throws {
        try withRealDirectory { boundary, profile in
            let writer = DurableProfilePersistence(directoryBoundary: boundary)
            try writer.replace(Data("checkpoint".utf8), at: profile)
            var operations = DurableProfilePersistence.Operations.live
            let fullSync = operations.fullSync
            let flushes = LockedTestValue(0)
            operations.fullSync = { descriptor in
                flushes.withValue { $0 += 1 }
                if flushes.value == 2 { throw POSIXError(.EIO) }
                try fullSync(descriptor)
            }
            let interrupted = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
            XCTAssertThrowsError(try interrupted.replace(Data("response".utf8), at: profile))
            XCTAssertEqual(try Data(contentsOf: profile), Data("response".utf8))
            try writer.synchronizePublishedFile(at: profile)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile.deletingLastPathComponent().path), ["profile.state"])

            operations = .live
            operations.fullSync = { _ in throw POSIXError(.EIO) }
            let failed = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
            XCTAssertThrowsError(try failed.replace(Data("discard".utf8), at: profile))
            XCTAssertEqual(try Data(contentsOf: profile), Data("response".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile.deletingLastPathComponent().path), ["profile.state"])
        }
    }

    func testNewDirectorySynchronizationFailureCanBeRetriedThroughTheBoundary() throws {
        try withRealDirectory { boundary, profile in
            var operations = DurableProfilePersistence.Operations.live
            let openDirectory = operations.openDirectory
            let syncDirectory = operations.syncDirectory
            let paths = LockedTestValue([Int32: String]())
            let synchronizedPaths = LockedTestValue([String]())
            let shouldFail = LockedTestValue(true)
            let parent = profile.deletingLastPathComponent().deletingLastPathComponent().path
            operations.openDirectory = { path in
                let descriptor = try openDirectory(path)
                paths.withValue { $0[descriptor] = path }
                return descriptor
            }
            operations.syncDirectory = { descriptor in
                let path = try XCTUnwrap(paths.value[descriptor])
                synchronizedPaths.withValue { $0.append(path) }
                if shouldFail.value, path == parent {
                    shouldFail.value = false
                    throw POSIXError(.EIO)
                }
                try syncDirectory(descriptor)
            }
            let writer = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
            let checkpoint = Data("checkpoint".utf8)
            XCTAssertThrowsError(try writer.replace(checkpoint, at: profile))
            XCTAssertEqual(try Data(contentsOf: profile), checkpoint)
            XCTAssertEqual(synchronizedPaths.value, [profile.deletingLastPathComponent().path, parent])

            synchronizedPaths.withValue { $0.removeAll() }
            try writer.synchronizePublishedFile(at: profile)
            XCTAssertEqual(synchronizedPaths.value, [profile.deletingLastPathComponent().path, parent, boundary.path])
            XCTAssertEqual(try Data(contentsOf: profile), checkpoint)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: profile.deletingLastPathComponent().path), ["profile.state"])
        }
    }

    func testRealDiskRejectsSymbolicLinkDestinationsAndDirectories() throws {
        try withRealDirectory { boundary, profile in
            let external = boundary.appendingPathComponent("external")
            try Data("original".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: external)
            let writer = DurableProfilePersistence(directoryBoundary: boundary)
            XCTAssertThrowsError(try writer.replace(Data("replacement".utf8), at: profile))
            XCTAssertThrowsError(try writer.synchronizePublishedFile(at: profile))
            XCTAssertEqual(try Data(contentsOf: external), Data("original".utf8))
            try FileManager.default.removeItem(at: profile)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
            XCTAssertThrowsError(try writer.replace(Data([1]), at: profile))
            XCTAssertThrowsError(try writer.synchronizePublishedFile(at: profile))
        }
    }

    func testNewProfileThroughPrivateVarAliasStaysInsideBoundary() throws {
        let aliasedBoundary = URL(fileURLWithPath: "/private/var", isDirectory: true)
        let aliasedProfile = aliasedBoundary.appendingPathComponent("profile-\(UUID().uuidString).state")
        let canonicalPath = aliasedBoundary.standardizedFileURL.appendingPathComponent(aliasedProfile.lastPathComponent).path
        let disk = DiskModel()
        let writer = DurableProfilePersistence(directoryBoundary: aliasedBoundary, operations: disk.operations)
        let checkpoint = Data("checkpoint".utf8)

        try writer.replace(checkpoint, at: aliasedProfile)
        XCTAssertEqual(disk.contents(at: canonicalPath), checkpoint)
        try writer.synchronizePublishedFile(at: aliasedProfile)
        disk.crash()
        XCTAssertEqual(disk.contents(at: canonicalPath), checkpoint)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testRealDiskRejectsSymbolicLinkParentDirectory() throws {
        try withRealDirectory { boundary, profile in
            let linkedDirectory = boundary.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory, withDestinationURL: profile.deletingLastPathComponent()
            )
            let linkedProfile = linkedDirectory.appendingPathComponent("profile.state")
            let writer = DurableProfilePersistence(directoryBoundary: boundary)

            XCTAssertThrowsError(try writer.replace(Data("new".utf8), at: linkedProfile))
            XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))

            let original = Data("original".utf8)
            try original.write(to: profile)
            XCTAssertThrowsError(try writer.replace(Data("replacement".utf8), at: linkedProfile))
            XCTAssertThrowsError(try writer.synchronizePublishedFile(at: linkedProfile))
            XCTAssertEqual(try Data(contentsOf: profile), original)
        }
    }

    private func persistence(_ disk: DiskModel) -> DurableProfilePersistence {
        DurableProfilePersistence(
            directoryBoundary: boundary,
            operations: disk.operations,
            temporaryName: { ".profile-write-test.tmp" }
        )
    }

    private func withRealDirectory(_ body: (URL, URL) throws -> Void) throws {
        let boundary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = boundary.appendingPathComponent("bridge/profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: boundary) }
        try body(boundary, directory.appendingPathComponent("profile.state"))
    }

    private final class DiskModel: Sendable {
        private let state = Mutex(DiskState())
        var events: [String] {
            get { state.withLock { $0.events } }
            set { state.withLock { $0.events = newValue } }
        }
        var failures: [String: [POSIXErrorCode]] {
            get { state.withLock { $0.failures } }
            set { state.withLock { $0.failures = newValue } }
        }
        var maximumWrite: Int {
            get { state.withLock { $0.maximumWrite } }
            set { state.withLock { $0.maximumWrite = newValue } }
        }
        var createFlags: Int32? {
            get { state.withLock { $0.createFlags } }
        }
        var createMode: mode_t? {
            get { state.withLock { $0.createMode } }
        }
        var openDescriptors: Set<Int32> {
            get { state.withLock { $0.openDescriptors } }
        }
        var hasTemporaryEntry: Bool {
            get { state.withLock { $0.hasTemporaryEntry } }
        }
        var published: Data? {
            get { state.withLock { $0.published } }
        }
        var durablePublished: Data? {
            get { state.withLock { $0.durablePublished } }
        }
        func contents(at path: String) -> Data? { state.withLock { $0.contents(at: path) } }
        func crash() { state.withLock { $0.crash() } }

        var operations: DurableProfilePersistence.Operations {
            .init(
                openDirectory: { path in
                    try self.state.withLock { model in
                    try model.event("openDirectory:\(path)")
                    return model.allocate(.directory(path))

                    }
                },
                openFile: { directory, name, flags, mode in
                    try self.state.withLock { model in
                    let path = try model.path(directory, name)
                    if flags & O_CREAT != 0 {
                        try model.event("create")
                        model.createFlags = flags
                        model.createMode = mode
                        guard model.entries[path] == nil else { throw POSIXError(.EEXIST) }
                        let file = model.nextFile
                        model.nextFile += 1
                        model.files[file] = DiskState.File(contents: Data(), durableContents: Data())
                        model.entries[path] = file
                        return model.allocate(.file(file))
                    }
                    try model.event("openPublished")
                    guard let file = model.entries[path] else { throw POSIXError(.ENOENT) }
                    return model.allocate(.file(file))

                    }
                },
                fileKind: { descriptor in
                    try self.state.withLock { model in
                    try model.event("kind")
                    guard case .file = model.descriptors[descriptor] else { return .other }
                    return .regular

                    }
                },
                entryKind: { directory, name in
                    try self.state.withLock { model in
                    try model.event("entryKind")
                    return model.entries[try model.path(directory, name)] == nil ? nil : .regular

                    }
                },
                write: { descriptor, bytes, count in
                    try self.state.withLock { model in
                    model.writes += 1
                    try model.event("write:\(model.writes)")
                    let file = try model.file(descriptor)
                    let written = min(model.maximumWrite, count)
                    model.files[file]?.contents.append(bytes.assumingMemoryBound(to: UInt8.self), count: written)
                    return written

                    }
                },
                fullSync: { descriptor in
                    try self.state.withLock { model in
                    model.fullSyncs += 1
                    try model.event("full:\(model.fullSyncs)")
                    let file = try model.file(descriptor)
                    let contents = model.files[file]?.contents ?? Data()
                    model.files[file]?.durableContents = contents
                    model.durableEntries = model.synchronizedEntries

                    }
                },
                syncDirectory: { descriptor in
                    try self.state.withLock { model in
                    guard case .directory(let path) = model.descriptors[descriptor] else { throw POSIXError(.EBADF) }
                    try model.event("sync:\(path)")
                    model.synchronizedEntries = model.synchronizedEntries.filter { model.parent($0.key) != path }
                    for (name, file) in model.entries where model.parent(name) == path {
                        model.synchronizedEntries[name] = file
                    }

                    }
                },
                rename: { directory, source, destination in
                    try self.state.withLock { model in
                    try model.event("rename")
                    let sourcePath = try model.path(directory, source)
                    let destinationPath = try model.path(directory, destination)
                    guard let file = model.entries.removeValue(forKey: sourcePath) else { throw POSIXError(.ENOENT) }
                    model.entries[destinationPath] = file

                    }
                },
                unlink: { directory, name in
                    _ = try self.state.withLock { model in
                    model.entries.removeValue(forKey: try model.path(directory, name))

                    }
                },
                close: { descriptor in
                    self.state.withLock { model in
                        _ = model.descriptors.removeValue(forKey: descriptor)
                    }
                }
            )
        }
    }

    private final class DiskState {
        struct File {
            var contents: Data
            var durableContents: Data
        }

        enum Descriptor {
            case directory(String)
            case file(Int)
        }

        let profilePath = "/group/bridge/profiles/profile.state"
        var files = [1: File(contents: Data("old checkpoint".utf8), durableContents: Data("old checkpoint".utf8))]
        var entries = ["/group/bridge/profiles/profile.state": 1]
        var synchronizedEntries = ["/group/bridge/profiles/profile.state": 1]
        var durableEntries = ["/group/bridge/profiles/profile.state": 1]
        var descriptors = [Int32: Descriptor]()
        var nextDescriptor: Int32 = 10
        var nextFile = 2
        var writes = 0
        var fullSyncs = 0
        var events = [String]()
        var failures = [String: [POSIXErrorCode]]()
        var maximumWrite = Int.max
        var createFlags: Int32?
        var createMode: mode_t?

        var openDescriptors: Set<Int32> { Set(descriptors.keys) }
        var hasTemporaryEntry: Bool { entries.keys.contains { $0.contains(".profile-write-") } }
        var published: Data? { entries[profilePath].flatMap { files[$0]?.contents } }
        var durablePublished: Data? { durableEntries[profilePath].flatMap { files[$0]?.durableContents } }

        func contents(at path: String) -> Data? { entries[path].flatMap { files[$0]?.contents } }


        func crash() {
            entries = durableEntries
            synchronizedEntries = durableEntries
            for file in Array(files.keys) {
                let contents = files[file]?.durableContents ?? Data()
                files[file]?.contents = contents
            }
        }

        func event(_ name: String) throws {
            events.append(name)
            guard var queued = failures[name], !queued.isEmpty else { return }
            let code = queued.removeFirst()
            failures[name] = queued
            throw POSIXError(code)
        }

        func allocate(_ descriptor: Descriptor) -> Int32 {
            let value = nextDescriptor
            nextDescriptor += 1
            descriptors[value] = descriptor
            return value
        }

        func path(_ directory: Int32, _ name: String) throws -> String {
            guard case .directory(let path) = descriptors[directory] else { throw POSIXError(.EBADF) }
            return path + "/" + name
        }

        func file(_ descriptor: Int32) throws -> Int {
            guard case .file(let file) = descriptors[descriptor] else { throw POSIXError(.EBADF) }
            return file
        }

        func parent(_ path: String) -> String {
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
    }
}
