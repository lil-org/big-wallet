@main
@MainActor
private struct GuestAgentFixture {
    static func main() throws {
        if CommandLine.arguments[3] == "files" {
            let root = URL(fileURLWithPath: exchangePath)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let receipt = root.appendingPathComponent("receipt.json").path
            try writeReceiptAtomically(Data("original".utf8), to: receipt, exclusive: true)
            do {
                try writeReceiptAtomically(Data("duplicate".utf8), to: receipt, exclusive: true)
                fatalError("Duplicate claim was accepted")
            } catch { }
            let original = try readJobFile(receipt)
            precondition(original == Data("original".utf8))
            try writeReceiptAtomically(Data("completed".utf8), to: receipt)
            let completed = try readJobFile(receipt)
            precondition(completed == Data("completed".utf8))
            let oversized = root.appendingPathComponent("oversized").path
            try Data(repeating: 1, count: 1024 * 1024 + 1).write(to: URL(fileURLWithPath: oversized))
            do { _ = try readJobFile(oversized); fatalError("Oversized job accepted") } catch { }
            let link = root.appendingPathComponent("link").path
            precondition(symlink(receipt, link) == 0)
            do { _ = try readJobFile(link); fatalError("Symlink job accepted") } catch { }
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            precondition(files.allSatisfy { !$0.hasSuffix(".tmp") })
            return
        }
        let agent = GuestAgent(console: { (getuid(), "fixture") }, writeReceipt: { data, path, exclusive in
            if CommandLine.arguments[3] == "fail-running",
               let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               value["state"] as? String == "running" {
                let marker = URL(fileURLWithPath: exchangePath).appendingPathComponent("ignoring-term")
                let deadline = Date().addingTimeInterval(2)
                while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            }
            try writeReceiptAtomically(data, to: path, exclusive: exclusive)
        })
        agent.start()
        withExtendedLifetime(agent) { RunLoop.main.run() }
    }
}
