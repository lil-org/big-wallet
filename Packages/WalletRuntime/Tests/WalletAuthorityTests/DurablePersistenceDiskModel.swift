import Darwin
import Foundation
import Synchronization
import XCTest
@testable import WalletAuthority
import WalletStorageSupport

final class DurablePersistenceDiskModel: Sendable {
    private let state: Mutex<DurablePersistenceDiskState>

    init(
        fileURL: URL = URL(fileURLWithPath: "/group/bridge/profiles/profile.state"),
        contents: Data? = Data("old checkpoint".utf8)
    ) {
        state = Mutex(DurablePersistenceDiskState(fileURL: fileURL, contents: contents))
    }

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
    var maximumRead: Int {
        get { state.withLock { $0.maximumRead } }
        set { state.withLock { $0.maximumRead = newValue } }
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

    func replaceVisibleContents(_ data: Data) {
        state.withLock { model in
            let file = model.nextFile
            model.nextFile += 1
            model.files[file] = DurablePersistenceDiskState.File(contents: data, durableContents: Data())
            model.entries[model.profilePath] = file
        }
    }

    func modifyVisibleContents(_ data: Data) {
        state.withLock { model in
            guard let file = model.entries[model.profilePath] else { return }
            model.files[file]?.contents = data
            model.files[file]?.revision += 1
        }
    }

    func resetEvents() {
        state.withLock { model in
            model.events = []
            model.writes = 0
            model.reads = 0
            model.fullSyncs = 0
        }
    }

    func recordEvent(_ name: String) {
        state.withLock { $0.events.append(name) }
    }

    func readSnapshot(at url: URL, maximumBytes: Int) -> RegularFileSnapshotReader.Result {
        state.withLock { model in
            guard let data = model.contents(at: url.standardizedFileURL.path) else { return .missing }
            return data.count <= maximumBytes ? .data(data) : .tooLarge
        }
    }

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
                    if flags & O_DIRECTORY != 0 {
                        try model.event("openDirectory:\(path)")
                        XCTAssertEqual(flags, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                        XCTAssertEqual(mode, 0)
                        return model.allocate(.directory(path))
                    }
                    if flags & O_CREAT != 0 {
                        try model.event("create")
                        model.createFlags = flags
                        model.createMode = mode
                        guard model.entries[path] == nil else { throw POSIXError(.EEXIST) }
                        let file = model.nextFile
                        model.nextFile += 1
                        model.files[file] = DurablePersistenceDiskState.File(contents: Data(), durableContents: Data())
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
                    model.files[file]?.revision += 1
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
                    _ = model.offsets.removeValue(forKey: descriptor)
                }
            },
            metadata: { descriptor in
                try self.state.withLock { model in
                    try model.event("metadata")
                    return try model.metadata(for: model.file(descriptor))
                }
            },
            entryMetadata: { directory, name in
                try self.state.withLock { model in
                    try model.event("entryMetadata")
                    guard let file = model.entries[try model.path(directory, name)] else { throw POSIXError(.ENOENT) }
                    return try model.metadata(for: file)
                }
            },
            read: { descriptor, bytes, count in
                try self.state.withLock { model in
                    model.reads += 1
                    try model.event("read:\(model.reads)")
                    let file = try model.file(descriptor)
                    guard let contents = model.files[file]?.contents,
                          let offset = model.offsets[descriptor] else { throw POSIXError(.EBADF) }
                    let readCount = min(count, model.maximumRead, max(0, contents.count - offset))
                    if readCount > 0 {
                        contents.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), from: offset..<(offset + readCount))
                    }
                    model.offsets[descriptor] = offset + readCount
                    return readCount
                }
            }
        )
    }
}

private final class DurablePersistenceDiskState {
    struct File {
        var contents: Data
        var durableContents: Data
        var revision = 0
    }

    enum Descriptor {
        case directory(String)
        case file(Int)
    }

    let profilePath: String
    var files = [Int: File]()
    var entries = [String: Int]()
    var synchronizedEntries = [String: Int]()
    var durableEntries = [String: Int]()

    init(fileURL: URL, contents: Data?) {
        profilePath = fileURL.standardizedFileURL.path
        if let contents {
            files[1] = File(contents: contents, durableContents: contents)
            entries[profilePath] = 1
            synchronizedEntries = entries
            durableEntries = entries
        }
    }
    var descriptors = [Int32: Descriptor]()
    var offsets = [Int32: Int]()
    var nextDescriptor: Int32 = 10
    var nextFile = 2
    var writes = 0
    var reads = 0
    var fullSyncs = 0
    var events = [String]()
    var failures = [String: [POSIXErrorCode]]()
    var maximumWrite = Int.max
    var maximumRead = Int.max
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
        if case .file = descriptor { offsets[value] = 0 }
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

    func metadata(for identifier: Int) throws -> FileDescriptorMetadata {
        guard let file = files[identifier] else { throw POSIXError(.EBADF) }
        var metadata = stat()
        metadata.st_dev = 1
        metadata.st_ino = ino_t(identifier)
        metadata.st_mode = mode_t(S_IFREG | S_IRUSR | S_IWUSR)
        metadata.st_size = off_t(file.contents.count)
        metadata.st_mtimespec = timespec(tv_sec: file.revision, tv_nsec: 0)
        metadata.st_ctimespec = metadata.st_mtimespec
        return FileDescriptorMetadata(metadata)
    }

    func parent(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}
