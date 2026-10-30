import Darwin
import Foundation

public struct FileDescriptorMetadata: Equatable, Sendable {
    public var device: dev_t
    public var inode: ino_t
    public var mode: mode_t
    public var size: off_t
    public var modificationSeconds: Int
    public var modificationNanoseconds: Int
    public var changeSeconds: Int
    public var changeNanoseconds: Int

    public init(_ metadata: stat) {
        device = metadata.st_dev
        inode = metadata.st_ino
        mode = metadata.st_mode
        size = metadata.st_size
        modificationSeconds = metadata.st_mtimespec.tv_sec
        modificationNanoseconds = metadata.st_mtimespec.tv_nsec
        changeSeconds = metadata.st_ctimespec.tv_sec
        changeNanoseconds = metadata.st_ctimespec.tv_nsec
    }

    public var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }

    public func identifiesSameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode
    }
}

public struct SharedFileOperations: Sendable {
    public var directories: AnchoredDirectoryAccess.Operations
    public var openFile: @Sendable (Int32, String, Int32, mode_t) throws -> Int32
    public var metadata: @Sendable (Int32) throws -> FileDescriptorMetadata
    public var entryMetadata: @Sendable (Int32, String) throws -> FileDescriptorMetadata
    public var read: @Sendable (Int32, UnsafeMutableRawPointer, Int) throws -> Int
    public var close: @Sendable (Int32) -> Void

    public init(
        directories: AnchoredDirectoryAccess.Operations,
        openFile: @escaping @Sendable (Int32, String, Int32, mode_t) throws -> Int32,
        metadata: @escaping @Sendable (Int32) throws -> FileDescriptorMetadata,
        entryMetadata: @escaping @Sendable (Int32, String) throws -> FileDescriptorMetadata,
        read: @escaping @Sendable (Int32, UnsafeMutableRawPointer, Int) throws -> Int,
        close: @escaping @Sendable (Int32) -> Void
    ) {
        self.directories = directories
        self.openFile = openFile
        self.metadata = metadata
        self.entryMetadata = entryMetadata
        self.read = read
        self.close = close
    }

    public static let live = Self(
        directories: .live,
        openFile: { directory, name, flags, mode in
            let outcome = name.withCString {
                let result = Darwin.openat(directory, $0, flags, mode)
                let code = errno
                return (result, code)
            }
            return try FileSystemCall.checked(outcome.0, errorCode: outcome.1)
        },
        metadata: { descriptor in
            var metadata = stat()
            let result = Darwin.fstat(descriptor, &metadata)
            let code = errno
            try FileSystemCall.checked(result, errorCode: code)
            return FileDescriptorMetadata(metadata)
        },
        entryMetadata: { directory, name in
            var metadata = stat()
            let outcome = name.withCString {
                let result = Darwin.fstatat(directory, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                let code = errno
                return (result, code)
            }
            try FileSystemCall.checked(outcome.0, errorCode: outcome.1)
            return FileDescriptorMetadata(metadata)
        },
        read: { descriptor, bytes, count in
            let result = Darwin.read(descriptor, bytes, count)
            let code = errno
            guard result >= 0 else { throw FileSystemCall.failure(code) }
            return result
        },
        close: { _ = Darwin.close($0) }
    )
}

public struct RegularFileSnapshotReader: Sendable {
    public typealias Operations = SharedFileOperations

    public enum Result: Equatable, Sendable {
        case data(Data)
        case missing
        case unsafe
        case tooLarge
        case changed
        case unavailable
    }

    private let directoryBoundary: URL
    private let operations: Operations

    public init(directoryBoundary: URL, operations: Operations = .live) {
        self.directoryBoundary = directoryBoundary
        self.operations = operations
    }

    public func read(at url: URL, maximumBytes: Int) -> Result {
        guard maximumBytes >= 0 else { return .unavailable }
        do {
            let directories = try AnchoredDirectoryAccess.openParent(
                of: url, within: directoryBoundary, operations: operations.directories
            )
            defer { directories.forEach(operations.directories.close) }
            let directory = directories[0]
            let name = url.standardizedFileURL.lastPathComponent
            let descriptor = try FileSystemCall.retryInterrupted {
                try operations.openFile(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0)
            }
            defer { operations.close(descriptor) }
            do {
                return try read(descriptor: descriptor, directory: directory, name: name, maximumBytes: maximumBytes)
            } catch {
                return .unavailable
            }
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT: return .missing
            case .ELOOP, .ENOTDIR, .EINVAL: return .unsafe
            default: return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    private func read(descriptor: Int32, directory: Int32, name: String, maximumBytes: Int) throws -> Result {
        let initial = try FileSystemCall.retryInterrupted { try operations.metadata(descriptor) }
        guard initial.isRegular, initial.size >= 0 else { return .unsafe }
        guard initial.size <= off_t(maximumBytes) else { return .tooLarge }
        let expectedCount = Int(initial.size)
        var data = Data(count: expectedCount)
        let complete = try data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress, !bytes.isEmpty else { return true }
            var offset = 0
            while offset < expectedCount {
                let count = try FileSystemCall.retryInterrupted {
                    try operations.read(descriptor, address.advanced(by: offset), expectedCount - offset)
                }
                guard count >= 0, count <= expectedCount - offset else { throw POSIXError(.EIO) }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard complete else { return .changed }
        var trailingByte: UInt8 = 0
        let trailingCount = try withUnsafeMutableBytes(of: &trailingByte) { bytes in
            try FileSystemCall.retryInterrupted {
                try operations.read(descriptor, bytes.baseAddress!, 1)
            }
        }
        guard trailingCount >= 0, trailingCount <= 1 else { throw POSIXError(.EIO) }
        guard trailingCount == 0 else { return .changed }
        let final = try FileSystemCall.retryInterrupted { try operations.metadata(descriptor) }
        guard final == initial else { return .changed }
        let current: FileDescriptorMetadata
        do {
            current = try FileSystemCall.retryInterrupted { try operations.entryMetadata(directory, name) }
        } catch let error as POSIXError where error.code == .ENOENT {
            return .changed
        }
        guard current.isRegular, current.identifiesSameFile(as: final) else { return .changed }
        return .data(data)
    }
}
