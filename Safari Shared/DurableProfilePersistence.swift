import Darwin
import Foundation

struct DurableProfilePersistence {
    enum FileKind {
        case regular, directory, other
    }

    struct Operations {
        var openDirectory: (String) throws -> Int32
        var openFile: (Int32, String, Int32, mode_t) throws -> Int32
        var fileKind: (Int32) throws -> FileKind
        var entryKind: (Int32, String) throws -> FileKind?
        var write: (Int32, UnsafeRawPointer, Int) throws -> Int
        var fullSync: (Int32) throws -> Void
        var syncDirectory: (Int32) throws -> Void
        var rename: (Int32, String, String) throws -> Void
        var unlink: (Int32, String) throws -> Void
        var close: (Int32) -> Void

        static let live = Operations(
            openDirectory: { path in
                try checked(Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW))
            },
            openFile: { directory, name, flags, mode in
                try checked(Darwin.openat(directory, name, flags, mode))
            },
            fileKind: { descriptor in
                var metadata = stat()
                try checked(Darwin.fstat(descriptor, &metadata))
                return kind(metadata.st_mode)
            },
            entryKind: { directory, name in
                var metadata = stat()
                guard Darwin.fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { return nil }
                    throw failure()
                }
                return kind(metadata.st_mode)
            },
            write: { descriptor, bytes, count in
                let written = Darwin.write(descriptor, bytes, count)
                guard written >= 0 else { throw failure() }
                return written
            },
            fullSync: { try checked(Darwin.fcntl($0, F_FULLFSYNC)) },
            syncDirectory: { try checked(Darwin.fsync($0)) },
            rename: { directory, source, destination in
                try checked(Darwin.renameat(directory, source, directory, destination))
            },
            unlink: { directory, name in
                try checked(Darwin.unlinkat(directory, name, 0))
            },
            close: { _ = Darwin.close($0) }
        )

        @discardableResult
        private static func checked(_ result: Int32) throws -> Int32 {
            guard result >= 0 else { throw failure() }
            return result
        }

        private static func failure() -> POSIXError {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        private static func kind(_ mode: mode_t) -> FileKind {
            switch mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG): .regular
            case mode_t(S_IFDIR): .directory
            default: .other
            }
        }
    }

    private let directoryBoundary: URL
    private let operations: Operations
    private let temporaryName: () -> String

    init(
        directoryBoundary: URL,
        operations: Operations = .live,
        temporaryName: @escaping () -> String = {
            ".profile-write-\(UUID().uuidString.lowercased()).tmp"
        }
    ) {
        self.directoryBoundary = directoryBoundary.standardizedFileURL
        self.operations = operations
        self.temporaryName = temporaryName
    }

    func replace(_ data: Data, at url: URL) throws {
        let directories = try openDirectories(for: url)
        defer { directories.reversed().forEach(operations.close) }
        let directory = directories[0]
        let destination = url.standardizedFileURL.lastPathComponent
        if let kind = try retryInterrupted({ try operations.entryKind(directory, destination) }),
           kind != .regular {
            throw POSIXError(.EINVAL)
        }
        let temporary = try openTemporaryFile(in: directory)
        var replaced = false
        defer {
            operations.close(temporary.descriptor)
            if !replaced {
                try? retryInterrupted { try operations.unlink(directory, temporary.name) }
            }
        }
        guard try retryInterrupted({ try operations.fileKind(temporary.descriptor) }) == .regular else {
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
        defer { directories.reversed().forEach(operations.close) }
        let descriptor = try retryInterrupted {
            try operations.openFile(
                directories[0], url.standardizedFileURL.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0
            )
        }
        defer { operations.close(descriptor) }
        guard try retryInterrupted({ try operations.fileKind(descriptor) }) == .regular else {
            throw POSIXError(.EINVAL)
        }
        try retryInterrupted { try operations.fullSync(descriptor) }
        try synchronizeDirectories(directories)
        try retryInterrupted { try operations.fullSync(descriptor) }
    }

    private func openDirectories(for url: URL) throws -> [Int32] {
        guard url.isFileURL, directoryBoundary.isFileURL else { throw POSIXError(.EINVAL) }
        let parent = url.standardizedFileURL.deletingLastPathComponent().standardizedFileURL
        let boundaryComponents = directoryBoundary.pathComponents
        guard parent.pathComponents.starts(with: boundaryComponents) else { throw POSIXError(.EINVAL) }
        var descriptors = [Int32]()
        var current = parent
        do {
            while true {
                let descriptor = try retryInterrupted { try operations.openDirectory(current.path) }
                descriptors.append(descriptor)
                if current.pathComponents == boundaryComponents { return descriptors }
                current.deleteLastPathComponent()
            }
        } catch {
            descriptors.reversed().forEach(operations.close)
            throw error
        }
    }

    private func openTemporaryFile(in directory: Int32) throws -> (descriptor: Int32, name: String) {
        for _ in 0..<16 {
            let name = temporaryName()
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\0") else { throw POSIXError(.EINVAL) }
            do {
                let descriptor = try retryInterrupted {
                    try operations.openFile(
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
