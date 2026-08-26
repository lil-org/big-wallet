// ∅ 2026 lil org

import Foundation

#if os(macOS)
enum CrossProcessLockTestFixture {
    enum Failure: Error {
        case holderDidNotBecomeReady(String)
        case holderDidNotTerminate
    }

    static func withHeldLock<Value>(
        at lockURL: URL,
        readyURL: URL,
        pollNanoseconds: UInt64 = 10_000_000,
        maximumPolls: Int = 200,
        operation: () async throws -> Value
    ) async throws -> Value {
        try? FileManager.default.removeItem(at: readyURL)
        let input = Pipe()
        let errors = Pipe()
        let terminationSignal = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = [
            lockURL.path,
            "/bin/sh",
            "-c",
            ": > \"$1\"; IFS= read -r _",
            "lock-holder",
            readyURL.path,
        ]
        process.standardInput = input
        process.standardError = errors
        process.terminationHandler = { _ in terminationSignal.signal() }
        do {
            try process.run()
        } catch {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: readyURL)
            throw error
        }
        try? input.fileHandleForReading.close()
        try? errors.fileHandleForWriting.close()

        var result: Result<Value, Error>?
        do {
            for _ in 0..<maximumPolls {
                if FileManager.default.fileExists(atPath: readyURL.path) {
                    do {
                        result = .success(try await operation())
                    } catch {
                        result = .failure(error)
                    }
                    break
                }
                try await Task.sleep(nanoseconds: pollNanoseconds)
            }
        } catch {
            result = .failure(error)
        }
        let didTerminate = await stop(
            process: process,
            input: input.fileHandleForWriting,
            terminationSignal: terminationSignal
        )
        try? FileManager.default.removeItem(at: readyURL)
        if let result {
            if !didTerminate, case .success = result {
                throw Failure.holderDidNotTerminate
            }
            return try result.get()
        }
        guard didTerminate else {
            throw Failure.holderDidNotTerminate
        }
        let detail = String(
            decoding: errors.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        throw Failure.holderDidNotBecomeReady(detail)
    }

    private static func stop(
        process: Process,
        input: FileHandle,
        terminationSignal: DispatchSemaphore
    ) async -> Bool {
        try? input.write(contentsOf: Data([10]))
        try? input.close()
        if await waitForTermination(terminationSignal) {
            process.terminationHandler = nil
            return true
        }
        if process.isRunning {
            process.terminate()
        }
        let didTerminate = await waitForTermination(terminationSignal)
        process.terminationHandler = nil
        return didTerminate
    }

    private static func waitForTermination(
        _ signal: DispatchSemaphore
    ) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: signal.wait(timeout: .now() + 2) == .success
                )
            }
        }
    }
}
#endif
