import Darwin
import Foundation

public enum AnchoredDirectoryAccess {
    public struct Operations: Sendable {
        public var openDirectory: @Sendable (String) throws -> Int32
        public var openDirectoryAt: @Sendable (Int32, String) throws -> Int32
        public var close: @Sendable (Int32) -> Void

        public init(
            openDirectory: @escaping @Sendable (String) throws -> Int32,
            openDirectoryAt: @escaping @Sendable (Int32, String) throws -> Int32,
            close: @escaping @Sendable (Int32) -> Void
        ) {
            self.openDirectory = openDirectory
            self.openDirectoryAt = openDirectoryAt
            self.close = close
        }

        public static let live = Self(
            openDirectory: { path in
                let outcome = path.withCString {
                    let result = Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    let code = errno
                    return (result, code)
                }
                return try FileSystemCall.checked(outcome.0, errorCode: outcome.1)
            },
            openDirectoryAt: { directory, name in
                let outcome = name.withCString {
                    let result = Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    let code = errno
                    return (result, code)
                }
                return try FileSystemCall.checked(outcome.0, errorCode: outcome.1)
            },
            close: { _ = Darwin.close($0) }
        )
    }

    public static func openParent(
        of url: URL,
        within boundary: URL,
        operations: Operations = .live
    ) throws -> [Int32] {
        guard url.isFileURL, boundary.isFileURL else { throw POSIXError(.EINVAL) }
        let normalizedURL = url.standardizedFileURL
        let normalizedBoundary = boundary.standardizedFileURL
        let parent = normalizedURL.deletingLastPathComponent().standardizedFileURL
        let boundaryComponents = normalizedBoundary.pathComponents
        let name = normalizedURL.lastPathComponent
        guard parent.pathComponents.starts(with: boundaryComponents),
              !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !normalizedURL.path.contains("\0"), !normalizedBoundary.path.contains("\0") else {
            throw POSIXError(.EINVAL)
        }
        var descriptors = [Int32]()
        do {
            let root = try FileSystemCall.retryInterrupted { try operations.openDirectory(normalizedBoundary.path) }
            descriptors.append(root)
            for component in parent.pathComponents.dropFirst(boundaryComponents.count) {
                let descriptor = try FileSystemCall.retryInterrupted {
                    try operations.openDirectoryAt(descriptors.last!, component)
                }
                descriptors.append(descriptor)
            }
            return Array(descriptors.reversed())
        } catch {
            descriptors.reversed().forEach(operations.close)
            throw error
        }
    }
}

enum FileSystemCall {
    @discardableResult
    static func checked(_ value: Int32, errorCode: Int32) throws -> Int32 {
        guard value >= 0 else { throw failure(errorCode) }
        return value
    }

    static func failure(_ errorCode: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
    }

    static func retryInterrupted<Value>(_ operation: () throws -> Value) throws -> Value {
        while true {
            do { return try operation() }
            catch let error as POSIXError where error.code == .EINTR { continue }
        }
    }
}
