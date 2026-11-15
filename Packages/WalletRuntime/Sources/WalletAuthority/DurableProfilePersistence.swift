import WalletDomain
import WalletStorageSupport
import Darwin
import Foundation

struct DurableProfilePersistence: Sendable {
    struct Operations: Sendable {
        var files: SharedFileOperations = .live
        var write: @Sendable (Int32, UnsafeRawPointer, Int) throws -> Int
        var fullSync: @Sendable (Int32) throws -> Void
        var syncDirectory: @Sendable (Int32) throws -> Void
        var rename: @Sendable (Int32, String, String) throws -> Void
        var unlink: @Sendable (Int32, String) throws -> Void

        static let live = Operations(
            write: { descriptor, bytes, count in
                let written = Darwin.write(descriptor, bytes, count)
                let errorNumber = errno
                guard written >= 0 else { throw failure(errorNumber: errorNumber) }
                return written
            },
            fullSync: { descriptor in
                let result = Darwin.fcntl(descriptor, F_FULLFSYNC)
                let errorNumber = errno
                try checked(result, errorNumber: errorNumber)
            },
            syncDirectory: { descriptor in
                let result = Darwin.fsync(descriptor)
                let errorNumber = errno
                try checked(result, errorNumber: errorNumber)
            },
            rename: { directory, source, destination in
                let (result, errorNumber) = source.withCString { source in
                    destination.withCString { destination in
                        let result = Darwin.renameat(directory, source, directory, destination)
                        let errorNumber = errno
                        return (result, errorNumber)
                    }
                }
                try checked(result, errorNumber: errorNumber)
            },
            unlink: { directory, name in
                let (result, errorNumber) = name.withCString { name in
                    let result = Darwin.unlinkat(directory, name, 0)
                    let errorNumber = errno
                    return (result, errorNumber)
                }
                try checked(result, errorNumber: errorNumber)
            }
        )

        @discardableResult
        private static func checked(_ result: Int32, errorNumber: Int32) throws -> Int32 {
            guard result >= 0 else { throw failure(errorNumber: errorNumber) }
            return result
        }

        private static func failure(errorNumber: Int32) -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }
    }

    private let directoryBoundary: URL
    private let operations: Operations
    private let temporaryName: @Sendable () -> String

    init(
        directoryBoundary: URL,
        operations: Operations = .live,
        temporaryName: @escaping @Sendable () -> String = {
            ".profile-write-\(UUID().uuidString.lowercased()).tmp"
        }
    ) {
        self.directoryBoundary = directoryBoundary.standardizedFileURL
        self.operations = operations
        self.temporaryName = temporaryName
    }

    static func isTemporaryFileName(_ name: String) -> Bool {
        let prefix = ".profile-write-"
        let suffix = ".tmp"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix),
              let identifier = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
        else { return false }
        return name == "\(prefix)\(identifier.uuidString.lowercased())\(suffix)"
    }

    func replace(_ data: Data, at url: URL) throws {
        let directories = try openDirectories(for: url)
        defer { directories.reversed().forEach(operations.files.directories.close) }
        let directory = directories[0]
        let destination = url.standardizedFileURL.lastPathComponent
        do {
            guard try retryInterrupted({ try operations.files.entryMetadata(directory, destination) }).isRegular else {
                throw POSIXError(.EINVAL)
            }
        } catch let error as POSIXError where error.code == .ENOENT {}
        let temporary = try openTemporaryFile(in: directory)
        var replaced = false
        defer {
            operations.files.close(temporary.descriptor)
            if !replaced {
                try? retryInterrupted { try operations.unlink(directory, temporary.name) }
            }
        }
        guard try retryInterrupted({ try operations.files.metadata(temporary.descriptor) }).isRegular else {
            throw POSIXError(.EINVAL)
        }
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = try retryInterrupted {
                    try operations.write(
                        temporary.descriptor,
                        address.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                guard written > 0, written <= bytes.count - offset else { throw POSIXError(.EIO) }
                offset += written
            }
        }
        try retryInterrupted { try operations.fullSync(temporary.descriptor) }
        try retryInterrupted { try operations.rename(directory, temporary.name, destination) }
        replaced = true
        try synchronizeDirectories(directories)
        try retryInterrupted { try operations.fullSync(temporary.descriptor) }
    }

    func synchronizePublishedFile(at url: URL) throws {
        let directories = try openDirectories(for: url)
        defer { directories.reversed().forEach(operations.files.directories.close) }
        let descriptor = try retryInterrupted {
            try operations.files.openFile(
                directories[0], url.standardizedFileURL.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0
            )
        }
        defer { operations.files.close(descriptor) }
        guard try retryInterrupted({ try operations.files.metadata(descriptor) }).isRegular else {
            throw POSIXError(.EINVAL)
        }
        try retryInterrupted { try operations.fullSync(descriptor) }
        try synchronizeDirectories(directories)
        try retryInterrupted { try operations.fullSync(descriptor) }
    }

    func readSnapshot(at url: URL, maximumBytes: Int) -> RegularFileSnapshotReader.Result {
        snapshotReader.read(at: url, maximumBytes: maximumBytes)
    }

    func readDurableSnapshot(at url: URL, maximumBytes: Int) -> RegularFileSnapshotReader.Result {
        snapshotReader.read(at: url, maximumBytes: maximumBytes, synchronizing: { descriptor, directories in
            try retryInterrupted { try operations.fullSync(descriptor) }
            try synchronizeDirectories(directories)
            try retryInterrupted { try operations.fullSync(descriptor) }
        })
    }

    private var snapshotReader: RegularFileSnapshotReader {
        RegularFileSnapshotReader(directoryBoundary: directoryBoundary, operations: operations.files)
    }

    private func openDirectories(for url: URL) throws -> [Int32] {
        try AnchoredDirectoryAccess.openParent(of: url, within: directoryBoundary, operations: operations.files.directories)
    }

    private func openTemporaryFile(in directory: Int32) throws -> (descriptor: Int32, name: String) {
        for _ in 0..<16 {
            let name = temporaryName()
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0") else { throw POSIXError(.EINVAL) }
            do {
                let descriptor = try retryInterrupted {
                    try operations.files.openFile(
                        directory, name,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        S_IRUSR | S_IWUSR
                    )
                }
                return (descriptor, name)
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    private func synchronizeDirectories(_ directories: [Int32]) throws {
        for descriptor in directories {
            try retryInterrupted { try operations.syncDirectory(descriptor) }
        }
    }

    private func retryInterrupted<Value>(_ operation: () throws -> Value) throws -> Value {
        while true {
            do { return try operation() }
            catch let error as POSIXError where error.code == .EINTR { continue }
        }
    }
}

