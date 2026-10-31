import Darwin
import Foundation
import Synchronization
import XCTest
@testable import WalletAuthority
import WalletDomain
import WalletRuntimeTestSupport

final class DurableProfilePersistenceTests: XCTestCase {
    private let boundary = URL(fileURLWithPath: "/group", isDirectory: true)
    private let profile = URL(fileURLWithPath: "/group/bridge/profiles/profile.state")

    func testReplacementFlushesContentsBeforeRenameAndParentsBeforeFinalFlush() throws {
        let disk = DurablePersistenceDiskModel()
        try persistence(disk).replace(Data("checkpoint".utf8), at: profile)

        XCTAssertEqual(disk.events, [
            "openDirectory:/group", "openDirectory:/group/bridge", "openDirectory:/group/bridge/profiles",
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
        let disk = DurablePersistenceDiskModel()
        disk.maximumWrite = 2
        disk.failures["openDirectory:/group"] = [.EINTR]
        disk.failures["openDirectory:/group/bridge"] = [.EINTR]
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
            "openDirectory:/group", "openDirectory:/group/bridge", "openDirectory:/group/bridge/profiles",
            "entryKind", "create", "kind", "write:1", "full:1", "rename",
            "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2",
        ]
        for stage in stages {
            let disk = DurablePersistenceDiskModel()
            disk.failures[stage] = [.EIO]
            XCTAssertThrowsError(try persistence(disk).replace(Data("new response".utf8), at: profile), stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
            XCTAssertFalse(disk.hasTemporaryEntry, stage)
            disk.crash()
            XCTAssertEqual(disk.published, Data("old checkpoint".utf8), stage)
        }
    }

    func testZeroByteWriteFailsWithoutPublishing() throws {
        let disk = DurablePersistenceDiskModel()
        disk.maximumWrite = 0
        XCTAssertThrowsError(try persistence(disk).replace(Data([1]), at: profile)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertFalse(disk.events.contains("rename"))
        XCTAssertFalse(disk.hasTemporaryEntry)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testVisibleReplacementNeedsASuccessfulBarrierBeforeItIsDurable() throws {
        let disk = DurablePersistenceDiskModel()
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
            let disk = DurablePersistenceDiskModel()
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
            let disk = DurablePersistenceDiskModel()
            disk.failures[stage] = [.EIO]
            XCTAssertThrowsError(try persistence(disk).synchronizePublishedFile(at: profile), stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
        }
        let disk = DurablePersistenceDiskModel()
        var operations = disk.operations
        operations.fileKind = { _ in .other }
        let writer = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
        XCTAssertThrowsError(try writer.synchronizePublishedFile(at: profile))
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testBoundaryValidationPrecedesFilesystemOperations() throws {
        for path in ["/outside/profile.state", "/group-other/profile.state", "/group"] {
            let disk = DurablePersistenceDiskModel()
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
            let openFile = operations.openFile
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
            operations.openFile = { directory, name, flags, mode in
                let descriptor = try openFile(directory, name, flags, mode)
                let parent = try XCTUnwrap(paths.value[directory])
                paths.withValue { $0[descriptor] = (parent as NSString).appendingPathComponent(name) }
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
        let disk = DurablePersistenceDiskModel()
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

    func testRealDiskRejectsSymbolicLinkAncestorBeforeOpeningLeafDirectory() throws {
        try withRealDirectory { boundary, profile in
            let linkedDirectory = boundary.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: linkedDirectory,
                withDestinationURL: profile.deletingLastPathComponent().deletingLastPathComponent()
            )
            let linkedProfile = linkedDirectory.appendingPathComponent("profiles/profile.state")
            let openedNames = LockedTestValue([String]())
            var operations = DurableProfilePersistence.Operations.live
            let openFile = operations.openFile
            operations.openFile = { directory, name, flags, mode in
                openedNames.withValue { $0.append(name) }
                return try openFile(directory, name, flags, mode)
            }
            let writer = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)
            let original = Data("original".utf8)
            try original.write(to: profile)

            XCTAssertThrowsError(try writer.replace(Data("replacement".utf8), at: linkedProfile))
            XCTAssertEqual(openedNames.value, ["linked"])
            XCTAssertEqual(try Data(contentsOf: profile), original)

            openedNames.value = []
            XCTAssertThrowsError(try writer.synchronizePublishedFile(at: linkedProfile))
            XCTAssertEqual(openedNames.value, ["linked"])
        }
    }

    func testReadSnapshotUsesInjectedDescriptorOperations() throws {
        try withRealDirectory { boundary, profile in
            let contents = Data("bounded snapshot".utf8)
            try contents.write(to: profile)
            let reads = LockedTestValue(0)
            let metadataReads = LockedTestValue(0)
            let opened = LockedTestValue(Set<Int32>())
            var operations = DurableProfilePersistence.Operations.live
            let live = operations
            operations.openDirectory = { path in
                let descriptor = try live.openDirectory(path)
                opened.withValue { _ = $0.insert(descriptor) }
                return descriptor
            }
            operations.openFile = { directory, name, flags, mode in
                let descriptor = try live.openFile(directory, name, flags, mode)
                opened.withValue { _ = $0.insert(descriptor) }
                return descriptor
            }
            operations.metadata = { descriptor in
                metadataReads.withValue { $0 += 1 }
                return try live.metadata(descriptor)
            }
            operations.read = { descriptor, bytes, count in
                reads.withValue { $0 += 1 }
                return try live.read(descriptor, bytes, min(count, 2))
            }
            operations.close = { descriptor in
                XCTAssertTrue(opened.withValue { $0.remove(descriptor) != nil })
                live.close(descriptor)
            }
            let reader = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)

            XCTAssertEqual(reader.readSnapshot(at: profile, maximumBytes: contents.count), .data(contents))
            XCTAssertGreaterThan(reads.value, 2)
            XCTAssertEqual(metadataReads.value, 2)
            XCTAssertTrue(opened.value.isEmpty)

            reads.value = 0
            XCTAssertEqual(reader.readSnapshot(at: profile, maximumBytes: contents.count - 1), .tooLarge)
            XCTAssertEqual(reads.value, 0)
            XCTAssertTrue(opened.value.isEmpty)
        }
    }

    func testDurableSnapshotFlushesTheReadFileBeforeValidatingItsIdentity() {
        let disk = DurablePersistenceDiskModel()
        let data = Data("visible checkpoint".utf8)
        disk.replaceVisibleContents(data)

        XCTAssertEqual(persistence(disk).readDurableSnapshot(at: profile, maximumBytes: data.count), .data(data))
        XCTAssertEqual(disk.events, [
            "openDirectory:/group", "openDirectory:/group/bridge", "openDirectory:/group/bridge/profiles",
            "openPublished", "metadata", "read:1", "read:2", "full:1",
            "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2",
            "metadata", "entryMetadata",
        ])
        XCTAssertTrue(disk.openDescriptors.isEmpty)
        disk.crash()
        XCTAssertEqual(disk.published, data)
    }

    func testDurableSnapshotBarrierFailuresNeverReturnData() {
        for stage in ["full:1", "sync:/group/bridge/profiles", "sync:/group/bridge", "sync:/group", "full:2"] {
            let disk = DurablePersistenceDiskModel()
            let data = Data("visible checkpoint".utf8)
            disk.replaceVisibleContents(data)
            disk.failures[stage] = [.EIO]

            XCTAssertEqual(persistence(disk).readDurableSnapshot(at: profile, maximumBytes: data.count), .unavailable, stage)
            XCTAssertTrue(disk.openDescriptors.isEmpty, stage)
            XCTAssertFalse(disk.events.contains("entryMetadata"), stage)
            disk.crash()
            XCTAssertEqual(disk.published, Data("old checkpoint".utf8), stage)
        }
    }

    func testDurableSnapshotRejectsReplacementWithIdenticalBytesDuringSynchronization() {
        let data = Data("checkpoint".utf8)
        let disk = DurablePersistenceDiskModel(contents: data)
        var operations = disk.operations
        let fullSync = operations.fullSync
        let changed = LockedTestValue(false)
        operations.fullSync = { descriptor in
            try fullSync(descriptor)
            let replace = changed.withValue { changed in
                let previous = changed
                changed = true
                return !previous
            }
            if replace { disk.replaceVisibleContents(data) }
        }
        let reader = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)

        XCTAssertEqual(reader.readDurableSnapshot(at: profile, maximumBytes: data.count), .changed)
        XCTAssertTrue(disk.events.contains("entryMetadata"))
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testDurableSnapshotRejectsInPlaceModificationDuringSynchronization() {
        let data = Data("checkpoint".utf8)
        let disk = DurablePersistenceDiskModel(contents: data)
        var operations = disk.operations
        let fullSync = operations.fullSync
        operations.fullSync = { descriptor in
            try fullSync(descriptor)
            disk.modifyVisibleContents(data)
        }
        let reader = DurableProfilePersistence(directoryBoundary: boundary, operations: operations)

        XCTAssertEqual(reader.readDurableSnapshot(at: profile, maximumBytes: data.count), .changed)
        XCTAssertFalse(disk.events.contains("entryMetadata"))
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testDurableSnapshotReadsAreBoundedAndRetryInterruptedOperations() throws {
        let disk = DurablePersistenceDiskModel()
        let data = try XCTUnwrap(disk.published)
        let reader = persistence(disk)
        XCTAssertEqual(reader.readDurableSnapshot(at: profile, maximumBytes: data.count - 1), .tooLarge)
        XCTAssertFalse(disk.events.contains { $0.hasPrefix("read:") || $0.hasPrefix("full:") })
        XCTAssertTrue(disk.openDescriptors.isEmpty)

        disk.resetEvents()
        disk.maximumRead = 2
        disk.failures["read:1"] = [.EINTR]
        disk.failures["full:1"] = [.EINTR]
        disk.failures["sync:/group/bridge"] = [.EINTR]
        XCTAssertEqual(reader.readDurableSnapshot(at: profile, maximumBytes: data.count), .data(data))
        XCTAssertGreaterThan(disk.events.filter { $0.hasPrefix("read:") }.count, 2)
        XCTAssertEqual(disk.events.filter { $0 == "sync:/group/bridge" }.count, 2)
        XCTAssertTrue(disk.openDescriptors.isEmpty)
    }

    func testDurableEmptySnapshotStillSynchronizesItsPublication() {
        let disk = DurablePersistenceDiskModel()
        disk.replaceVisibleContents(Data())

        XCTAssertEqual(persistence(disk).readDurableSnapshot(at: profile, maximumBytes: 0), .data(Data()))
        XCTAssertEqual(disk.events.filter { $0.hasPrefix("read:") }, ["read:1"])
        XCTAssertTrue(disk.events.contains("full:2"))
        XCTAssertTrue(disk.openDescriptors.isEmpty)
        disk.crash()
        XCTAssertEqual(disk.published, Data())
    }

    private func persistence(_ disk: DurablePersistenceDiskModel) -> DurableProfilePersistence {
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

}
