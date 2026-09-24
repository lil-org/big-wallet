import Darwin
import Foundation
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
            var flushes = 0
            operations.fullSync = { descriptor in
                flushes += 1
                if flushes == 2 { throw POSIXError(.EIO) }
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
            var paths = [Int32: String]()
            var synchronizedPaths = [String]()
            var shouldFail = true
            let parent = profile.deletingLastPathComponent().deletingLastPathComponent().path
            operations.openDirectory = { path in
                let descriptor = try openDirectory(path)
                paths[descriptor] = path
                return descriptor
            }
            operations.syncDirectory = { descriptor in
                let path = try XCTUnwrap(paths[descriptor])
                synchronizedPaths.append(path)
                if shouldFail, path == parent {
                    shouldFail = false
                    throw POSIXError(.EIO)
                }
                try syncDirectory(descriptor)
            }
            let writer = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
            let checkpoint = Data("checkpoint".utf8)
            XCTAssertThrowsError(try writer.replace(checkpoint, at: profile))
            XCTAssertEqual(try Data(contentsOf: profile), checkpoint)
            XCTAssertEqual(synchronizedPaths, [profile.deletingLastPathComponent().path, parent])

            synchronizedPaths.removeAll()
            try writer.synchronizePublishedFile(at: profile)
            XCTAssertEqual(synchronizedPaths, [profile.deletingLastPathComponent().path, parent, boundary.path])
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

    private final class DiskModel {
        private struct File {
            var contents: Data
            var durableContents: Data
        }

        private enum Descriptor {
            case directory(String)
            case file(Int)
        }

        private let profilePath = "/group/bridge/profiles/profile.state"
        private var files = [1: File(contents: Data("old checkpoint".utf8), durableContents: Data("old checkpoint".utf8))]
        private var entries = ["/group/bridge/profiles/profile.state": 1]
        private var synchronizedEntries = ["/group/bridge/profiles/profile.state": 1]
        private var durableEntries = ["/group/bridge/profiles/profile.state": 1]
        private var descriptors = [Int32: Descriptor]()
        private var nextDescriptor: Int32 = 10
        private var nextFile = 2
        private var writes = 0
        private var fullSyncs = 0
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

        var operations: DurableProfilePersistence.Operations {
            .init(
                openDirectory: { path in
                    try self.event("openDirectory:\(path)")
                    return self.allocate(.directory(path))
                },
                openFile: { directory, name, flags, mode in
                    let path = try self.path(directory, name)
                    if flags & O_CREAT != 0 {
                        try self.event("create")
                        self.createFlags = flags
                        self.createMode = mode
                        guard self.entries[path] == nil else { throw POSIXError(.EEXIST) }
                        let file = self.nextFile
                        self.nextFile += 1
                        self.files[file] = File(contents: Data(), durableContents: Data())
                        self.entries[path] = file
                        return self.allocate(.file(file))
                    }
                    try self.event("openPublished")
                    guard let file = self.entries[path] else { throw POSIXError(.ENOENT) }
                    return self.allocate(.file(file))
                },
                fileKind: { descriptor in
                    try self.event("kind")
                    guard case .file = self.descriptors[descriptor] else { return .other }
                    return .regular
                },
                entryKind: { directory, name in
                    try self.event("entryKind")
                    return self.entries[try self.path(directory, name)] == nil ? nil : .regular
                },
                write: { descriptor, bytes, count in
                    self.writes += 1
                    try self.event("write:\(self.writes)")
                    let file = try self.file(descriptor)
                    let written = min(self.maximumWrite, count)
                    self.files[file]?.contents.append(bytes.assumingMemoryBound(to: UInt8.self), count: written)
                    return written
                },
                fullSync: { descriptor in
                    self.fullSyncs += 1
                    try self.event("full:\(self.fullSyncs)")
                    let file = try self.file(descriptor)
                    let contents = self.files[file]?.contents ?? Data()
                    self.files[file]?.durableContents = contents
                    self.durableEntries = self.synchronizedEntries
                },
                syncDirectory: { descriptor in
                    guard case .directory(let path) = self.descriptors[descriptor] else { throw POSIXError(.EBADF) }
                    try self.event("sync:\(path)")
                    self.synchronizedEntries = self.synchronizedEntries.filter { self.parent($0.key) != path }
                    for (name, file) in self.entries where self.parent(name) == path {
                        self.synchronizedEntries[name] = file
                    }
                },
                rename: { directory, source, destination in
                    try self.event("rename")
                    let sourcePath = try self.path(directory, source)
                    let destinationPath = try self.path(directory, destination)
                    guard let file = self.entries.removeValue(forKey: sourcePath) else { throw POSIXError(.ENOENT) }
                    self.entries[destinationPath] = file
                },
                unlink: { directory, name in
                    self.entries.removeValue(forKey: try self.path(directory, name))
                },
                close: { self.descriptors.removeValue(forKey: $0) }
            )
        }

        func crash() {
            entries = durableEntries
            synchronizedEntries = durableEntries
            for file in Array(files.keys) {
                let contents = files[file]?.durableContents ?? Data()
                files[file]?.contents = contents
            }
        }

        private func event(_ name: String) throws {
            events.append(name)
            guard var queued = failures[name], !queued.isEmpty else { return }
            let code = queued.removeFirst()
            failures[name] = queued
            throw POSIXError(code)
        }

        private func allocate(_ descriptor: Descriptor) -> Int32 {
            let value = nextDescriptor
            nextDescriptor += 1
            descriptors[value] = descriptor
            return value
        }

        private func path(_ directory: Int32, _ name: String) throws -> String {
            guard case .directory(let path) = descriptors[directory] else { throw POSIXError(.EBADF) }
            return path + "/" + name
        }

        private func file(_ descriptor: Int32) throws -> Int {
            guard case .file(let file) = descriptors[descriptor] else { throw POSIXError(.EBADF) }
            return file
        }

        private func parent(_ path: String) -> String {
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
    }
}
