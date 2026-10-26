import Darwin
import WalletDomain
@testable import WalletAuthority
@testable import WalletNetworking
import Foundation

struct HarnessWorkerOptions: Sendable {
    let role: String
    let root: URL
    let epoch: String
    let mode: String

    init(arguments: [String]) throws {
        var values = [String: String]()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard ["--role", "--root", "--epoch", "--mode"].contains(option), index + 1 < arguments.count,
                  values[option] == nil else { throw HarnessError.invalid("Invalid worker arguments") }
            values[option] = arguments[index + 1]
            index += 2
        }
        guard let role = values["--role"], ["bridge", "approval"].contains(role),
              let root = values["--root"], root.hasPrefix("/"),
              let epoch = values["--epoch"], !epoch.isEmpty,
              let mode = values["--mode"], ["native", "popup"].contains(mode) else {
            throw HarnessError.invalid("Usage: ApprovalCrashWorker --role bridge|approval --root PATH --epoch ID --mode native|popup")
        }
        self.role = role
        self.root = URL(fileURLWithPath: root, isDirectory: true)
        self.epoch = epoch
        self.mode = mode
    }
}

@main
struct ApprovalCrashWorker {
    @MainActor
    static func main() async {
        do {
            let options = try HarnessWorkerOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let ipc = HarnessIPC(epoch: options.epoch, role: options.role)
            let runtime = try HarnessRuntime(options: options, ipc: ipc)
            try await runtime.start()
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    while let line = readLine(strippingNewline: true) {
                        guard line.utf8.count <= 16 * 1024 * 1024,
                              let input = try? JSONDecoder().decode(HarnessValue.self, from: Data(line.utf8)) else {
                            ipc.event("protocolError", details: .object(["message": .string("Invalid JSON-lines envelope")]))
                            continue
                        }
                        if input["kind"].string == "release" {
                            ipc.receiveRelease(input)
                            continue
                        }
                        if input["kind"].string == "control" {
                            ipc.receiveControl(input)
                            continue
                        }
                        do {
                            let label = input["label"].string ?? "command:\(input["operation"].string ?? "invalid"):\(input["id"].int ?? -1)"
                            try ipc.startTask(label: label) { await runtime.receive(input) }
                        } catch { ipc.reply(id: input["id"], result: .failure(error)) }
                    }
                    ipc.close()
                    finished.resume()
                }
            }
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("ApprovalCrashWorker: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
