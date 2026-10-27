import Darwin
import Foundation

@main
struct WalletUpgradeConsumer {
    @MainActor
    static func main() async {
        var verification: UpgradeVerification?
        var reportURL: URL?
        var initialReport: ConsumerReport?
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            try require(arguments.count == 7, "Usage: WalletUpgradeConsumer <mode> --fixture <path> --state <path> --report <path>")
            let modes = ["verify-existing", "mutate-existing", "verify-reopened", "restore", "verify-restored", "failures"]
            try require(modes.contains(arguments[0]), "Unknown consumer mode")
            var options = [String: String]()
            for index in stride(from: 1, to: arguments.count, by: 2) {
                let key = arguments[index]
                try require(["--fixture", "--state", "--report"].contains(key) && options[key] == nil, "Invalid consumer option")
                options[key] = arguments[index + 1]
            }
            func path(_ option: String, directory: Bool) throws -> URL {
                guard let raw = options[option], raw.hasPrefix("/"), !raw.contains("\0") else { throw UpgradeFailure.invalid("Consumer paths must be absolute") }
                let url = URL(fileURLWithPath: raw, isDirectory: directory).standardizedFileURL
                try require(url.resolvingSymlinksInPath().path == url.path, "Consumer path traverses a symlink")
                if directory {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    try require(attributes[.type] as? FileAttributeType == .typeDirectory, "Consumer directory is unavailable")
                }
                return url
            }
            let fixture = try path("--fixture", directory: true)
            let state = try path("--state", directory: true)
            let report = try path("--report", directory: false)
            reportURL = report
            try require(fixture != state && !state.path.hasPrefix(fixture.path + "/"), "Consumer state must not replace the predecessor fixture")
            let hashes = try StorageHashes(root: state)
            initialReport = ConsumerReport(mode: arguments[0], storage: .init(before: hashes, after: hashes))
            let current = try UpgradeVerification(mode: arguments[0], fixture: fixture, state: state)
            verification = current
            try await current.run()
            try writeJSON(current.report, to: report)
            print("Wallet upgrade consumer \(arguments[0]) passed")
        } catch {
            if let verification, let reportURL {
                verification.failed(error)
                try? writeJSON(verification.report, to: reportURL)
            } else if var initialReport, let reportURL {
                initialReport.error = String(describing: error)
                try? writeJSON(initialReport, to: reportURL)
            }
            FileHandle.standardError.write(Data("Wallet upgrade consumer failed: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
