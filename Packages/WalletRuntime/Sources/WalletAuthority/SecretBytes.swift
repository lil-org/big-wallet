import Foundation
import Synchronization
import CryptoKit

final class SecretBytes: Sendable {
    enum Error: Swift.Error { case unavailable }

    private struct Allocation: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        let count: Int
        let onWipe: (@Sendable (UnsafeRawBufferPointer) -> Void)?

        func destroy() {
            bwWalletZeroMemory(pointer, count)
            onWipe?(UnsafeRawBufferPointer(start: pointer, count: count))
            pointer.deallocate()
        }
    }

    private struct State {
        var allocation: Allocation?
        var borrows = 0
        var invalidated = false

        mutating func retireIfIdle() -> Allocation? {
            guard invalidated, borrows == 0 else { return nil }
            defer { allocation = nil }
            return allocation
        }
    }

    let count: Int
    private let state: Mutex<State>

    init(
        count: Int,
        onWipe: (@Sendable (UnsafeRawBufferPointer) -> Void)? = nil,
        initialize: (UnsafeMutableRawBufferPointer) throws -> Void
    ) rethrows {
        precondition(count >= 0)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        let allocation = Allocation(pointer: pointer, count: count, onWipe: onWipe)
        do {
            try initialize(UnsafeMutableRawBufferPointer(start: pointer, count: count))
        } catch {
            allocation.destroy()
            throw error
        }
        self.count = count
        state = Mutex(State(allocation: allocation))
    }

    convenience init(copying data: Data) {
        self.init(count: data.count) { destination in
            data.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
    }

    convenience init(utf8 string: String) {
        self.init(count: string.utf8.count) { destination in
            for (index, byte) in string.utf8.enumerated() { destination[index] = byte }
        }
    }

    func copy(in range: Range<Int>) throws -> SecretBytes {
        precondition(range.lowerBound >= 0 && range.upperBound <= count)
        return try withUnsafeBytes { bytes in
            SecretBytes(count: range.count) { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[range]))
            }
        }
    }

    var isEmpty: Bool { count == 0 }
    var isAvailable: Bool { state.withLock { !$0.invalidated } }

    func withUnsafeBytes<Result>(_ operation: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        let allocation = try state.withLock { state in
            guard !state.invalidated, let allocation = state.allocation else { throw Error.unavailable }
            state.borrows += 1
            return allocation
        }
        defer {
            let retired = state.withLock { state in
                state.borrows -= 1
                return state.retireIfIdle()
            }
            retired?.destroy()
        }
        return try operation(UnsafeRawBufferPointer(start: allocation.pointer, count: allocation.count))
    }

    func withTemporaryData<Result>(_ operation: (Data) throws -> Result) throws -> Result {
        try withUnsafeBytes { bytes in
            var data = Data(bytes)
            defer { data.resetBytes(in: 0..<data.count) }
            return try operation(data)
        }
    }

    func withUTF8String<Result>(_ operation: (String) throws -> Result) throws -> Result {
        try withUnsafeBytes { try operation(String(decoding: $0, as: UTF8.self)) }
    }

    func sha256Digest() throws -> Data {
        try withUnsafeBytes { bytes in
            var hash = SHA256()
            hash.update(bufferPointer: bytes)
            return Data(hash.finalize())
        }
    }

    func invalidate() {
        let retired = state.withLock { state in
            state.invalidated = true
            return state.retireIfIdle()
        }
        retired?.destroy()
    }

    deinit { invalidate() }
}

@_silgen_name("bw_wallet_zero_memory")
private func bwWalletZeroMemory(_ pointer: UnsafeMutableRawPointer, _ count: Int)
