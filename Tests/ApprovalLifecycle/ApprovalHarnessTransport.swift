import Foundation
import Synchronization

struct HarnessRejectAuthorization: AlchemyAuthorizationProviding {
    func authorization(for url: URL) async throws -> AlchemyAuthorization? {
        throw HarnessError.invalid("Unexpected live authorization in approval worker")
    }
    func replacementAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async throws -> AlchemyAuthorization? {
        throw HarnessError.invalid("Unexpected live authorization in approval worker")
    }
    func invalidateAuthorization(afterUnauthorized rejected: AlchemyAuthorization, for url: URL) async {}
}

final class HarnessRPCTransport: Sendable {
    struct Reply: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
    }

    private static let transports = Mutex([String: HarnessRPCTransport]())
    fileprivate static let header = "X-Approval-Harness-Transport"
    private let identifier = UUID().uuidString.lowercased()
    private let ipc: HarnessIPC
    private let identity: HarnessValue
    private let endpoints: Set<String>
    private let sessionStorage = Mutex<URLSession?>(nil)

    init(ipc: HarnessIPC, identity: HarnessValue, endpoints: [URL]) {
        self.ipc = ipc
        self.identity = identity
        self.endpoints = Set(endpoints.map(\.absoluteString))
        Self.transports.withLock { $0[identifier] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HarnessRPCProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: identifier]
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        sessionStorage.withLock { $0 = URLSession(configuration: configuration) }
    }

    var session: URLSession {
        sessionStorage.withLock { $0! }
    }

    func close() {
        Self.transports.withLock { _ = $0.removeValue(forKey: identifier) }
        let session = sessionStorage.withLock { stored in let value = stored; stored = nil; return value }
        session?.invalidateAndCancel()
    }

    fileprivate static func transport(for request: URLRequest) -> HarnessRPCTransport? {
        guard let identifier = request.value(forHTTPHeaderField: header) else { return nil }
        return transports.withLock { $0[identifier] }
    }

    fileprivate func reply(to request: URLRequest, body: Data) async throws -> Reply {
        guard let url = request.url, endpoints.contains(url.absoluteString), request.httpMethod == "POST" else {
            throw HarnessError.invalid("Unexpected endpoint or method in isolated RPC transport")
        }
        let body = try JSONDecoder().decode(HarnessValue.self, from: body)
        guard body["method"].string != nil, case .array = body["params"] else {
            throw HarnessError.invalid("Production RPC client emitted malformed JSON")
        }
        let value = try await ipc.request("rpc", details: identity.merging([
            "request": body, "endpoint": .string(url.absoluteString), "httpMethod": .string(request.httpMethod ?? ""),
        ]))
        if let code = value["transportError"].int { throw NSError(domain: NSURLErrorDomain, code: code) }
        let status = value["httpStatus"].int ?? 200
        guard (100...599).contains(status) else { throw HarnessError.invalid("Invalid scripted HTTP status") }
        let responseBody = value.object["body"] ?? value
        let headers = value["headers"].object.compactMapValues(\.string)
        return Reply(data: try JSONEncoder().encode(responseBody), status: status,
            headers: headers.merging(["Content-Type": "application/json"]) { old, _ in old })
    }
}

private final class HarnessRPCProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var stopped = false
    }
    private let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let transport = HarnessRPCTransport.transport(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: HarnessError.invalid("Unregistered isolated RPC request"))
            return
        }
        let body: Data
        do { body = try requestBody() }
        catch { client?.urlProtocol(self, didFailWithError: error); return }
        let request = request
        let task = Task.detached { @Sendable [weak self, transport, request, body, url] in
            do {
                let reply = try await transport.reply(to: request, body: body)
                guard let self, !Task.isCancelled, !self.state.withLock({ $0.stopped }),
                      let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard let self, !self.state.withLock({ $0.stopped }) else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
        let shouldCancel = state.withLock { state in
            guard !state.stopped else { return true }
            state.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    override func stopLoading() {
        let task = state.withLock { state in
            state.stopped = true
            let task = state.task
            state.task = nil
            return task
        }
        task?.cancel()
    }

    private func requestBody() throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw HarnessError.invalid("RPC request has no body") }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? HarnessError.invalid("RPC body stream failed") }
            if count == 0 { return data }
            guard data.count + count <= 16 * 1024 * 1024 else { throw HarnessError.invalid("RPC body exceeds harness limit") }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
