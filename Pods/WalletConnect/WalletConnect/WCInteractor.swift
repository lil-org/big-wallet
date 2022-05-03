// Copyright © 2017-2019 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import Starscream
import PromiseKit

public typealias SessionRequestClosure = (_ id: Int64, _ peerParam: WCSessionRequestParam) -> Void
public typealias DisconnectClosure = (Error?) -> Void
public typealias CustomRequestClosure = (_ id: Int64, _ request: [String: Any]) -> Void
public typealias ErrorClosure = (Error) -> Void

public enum WCInteractorState {
    case connected
    case connecting
    case paused
    case disconnected
}

open class WCInteractor {
    public let session: WCSession

    public private(set) var state: WCInteractorState

    public let clientId: String
    public let clientMeta: WCPeerMeta

    public var eth: WCEthereumInteractor
    public var bnb: WCBinanceInteractor
    public var trust: WCTrustInteractor
    public var okt: WCOKExChainInteractor

    // incoming event handlers
    public var onSessionRequest: SessionRequestClosure?
    public var onDisconnect: DisconnectClosure?
    public var onError: ErrorClosure?
    public var onCustomRequest: CustomRequestClosure?

    // outgoing promise resolvers
    private var connectResolver: Resolver<Bool>?

    private let socket: WebSocket
    private var handshakeId: Int64 = -1
    private weak var pingTimer: Timer?
    private weak var sessionTimer: Timer?
    private let sessionRequestTimeout: TimeInterval

    private var peerId: String?
    private var peerMeta: WCPeerMeta?

    public init(session: WCSession, meta: WCPeerMeta, uuid: UUID, sessionRequestTimeout: TimeInterval = 20) {
        self.session = session
        self.clientId = uuid.description.lowercased()
        self.clientMeta = meta
        self.sessionRequestTimeout = sessionRequestTimeout
        self.state = .disconnected

        var request = URLRequest(url: session.bridge)
        request.timeoutInterval = sessionRequestTimeout
        self.socket = WebSocket(request: request)

        self.eth = WCEthereumInteractor()
        self.bnb = WCBinanceInteractor()
        self.trust = WCTrustInteractor()
        self.okt = WCOKExChainInteractor()

        socket.onConnect = { [weak self] in self?.onConnect() }
        socket.onDisconnect = { [weak self] error in self?.onDisconnect(error: error) }
        socket.onText = { [weak self] text in self?.onReceiveMessage(text: text) }
        socket.onPong = { _ in WCLog("<== pong") }
        socket.onData = { data in WCLog("<== websocketDidReceiveData: \(data.toHexString())") }
    }

    deinit {
        disconnect()
    }

    open func connect() -> Promise<Bool> {
        if socket.isConnected {
            return Promise.value(true)
        }
        socket.connect()
        state = .connecting
        return Promise<Bool> { [weak self] seal in
            self?.connectResolver = seal
        }
    }

    open func pause() {
        state = .paused
        socket.disconnect(forceTimeout: nil, closeCode: CloseCode.goingAway.rawValue)
    }

    open func resume() {
        socket.connect()
        state = .connecting
    }

    open func disconnect() {
        stopTimers()

        socket.disconnect()
        state = .disconnected

        connectResolver = nil
        handshakeId = -1

        WCSessionStore.clear(session.topic)
    }

    open func approveSession(accounts: [String], chainId: Int) -> Promise<Void> {
        guard handshakeId > 0 else {
            return Promise(error: WCError.sessionInvalid)
        }
        let result = WCApproveSessionResponse(
            approved: true,
            chainId: chainId,
            accounts: accounts,
            peerId: clientId,
            peerMeta: clientMeta
        )
        let response = JSONRPCResponse(id: handshakeId, result: result)
        return encryptAndSend(data: response.encoded)
    }

    open func rejectSession(_ message: String = "Session Rejected") -> Promise<Void> {
        guard handshakeId > 0 else {
            return Promise(error: WCError.sessionInvalid)
        }
        let response = JSONRPCErrorResponse(id: handshakeId, error: JSONRPCError(code: -32000, message: message))
        return encryptAndSend(data: response.encoded)
    }

    open func killSession() -> Promise<Void> {
        let result = WCSessionUpdateParam(approved: false, chainId: nil, accounts: nil)
        let response = JSONRPCRequest(id: generateId(), method: WCEvent.sessionUpdate.rawValue, params: [result])
        return encryptAndSend(data: response.encoded)
            .map { [weak self] in
                self?.disconnect()
            }
    }

    open func approveBnbOrder(id: Int64, signed: WCBinanceOrderSignature) -> Promise<WCBinanceTxConfirmParam> {
        let result = signed.encodedString
        return approveRequest(id: id, result: result)
            .then { _ -> Promise<WCBinanceTxConfirmParam> in
                return Promise { [weak self] seal in
                    self?.bnb.confirmResolvers[id] = seal
                }
            }
    }

    open func approveRequest<T: Codable>(id: Int64, result: T) -> Promise<Void> {
        let response = JSONRPCResponse(id: id, result: result)
        return encryptAndSend(data: response.encoded)
    }

    open func rejectRequest(id: Int64, message: String) -> Promise<Void> {
        let response = JSONRPCErrorResponse(id: id, error: JSONRPCError(code: -32000, message: message))
        return encryptAndSend(data: response.encoded)
    }
}

// MARK: internal funcs
extension WCInteractor {
    private func subscribe(topic: String) {
        let message = WCSocketMessage(topic: topic, type: .sub, payload: "")
        let data = try! JSONEncoder().encode(message)
        socket.write(data: data)
        WCLog("==> subscribe: \(String(data: data, encoding: .utf8)!)")
    }

    private func encryptAndSend(data: Data) -> Promise<Void> {
        WCLog("==> encrypt: \(String(data: data, encoding: .utf8)!) ")
        let encoder = JSONEncoder()
        let payload = try! WCEncryptor.encrypt(data: data, with: session.key)
        let payloadString = encoder.encodeAsUTF8(payload)
        let message = WCSocketMessage(topic: peerId ?? session.topic, type: .pub, payload: payloadString)
        let data = message.encoded
        return Promise { seal in
            socket.write(data: data) {
                WCLog("==> sent \(String(data: data, encoding: .utf8)!) ")
                seal.fulfill(())
            }
        }
    }

    private func handleEvent(_ event: WCEvent, topic: String, decrypted: Data) throws {
        switch event {
        case .sessionRequest:
            // topic == session.topic
            let request: JSONRPCRequest<[WCSessionRequestParam]> = try event.decode(decrypted)
            guard let params = request.params.first else { throw WCError.badJSONRPCRequest }
            handshakeId = request.id
            peerId = params.peerId
            peerMeta = params.peerMeta
            sessionTimer?.invalidate()
            onSessionRequest?(request.id, params)
        case .sessionUpdate:
            // topic == clientId
            let request: JSONRPCRequest<[WCSessionUpdateParam]> = try event.decode(decrypted)
            guard let param = request.params.first else { throw WCError.badJSONRPCRequest }
            if param.approved == false {
                disconnect()
            }
        default:
            if WCEvent.eth.contains(event) {
                try eth.handleEvent(event, topic: topic, decrypted: decrypted)
            } else if WCEvent.bnb.contains(event) {
                try bnb.handleEvent(event, topic: topic, decrypted: decrypted)
            } else if WCEvent.trust.contains(event) {
                try trust.handleEvent(event, topic: topic, decrypted: decrypted)
            }else if WCEvent.okt.contains(event) {
                try okt.handleEvent(event, topic: topic, decrypted: decrypted)
            }
        }
    }

    private func setupPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak socket] _ in
            WCLog("==> ping")
            socket?.write(ping: Data())
        }
    }

    private func checkExistingSession() {
        // check if it's an existing session
        if let existing = WCSessionStore.load(session.topic), existing.session == session {
            peerId = existing.peerId
            peerMeta = existing.peerMeta
            return
        }

        // we only setup timer for new sessions
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionRequestTimeout, repeats: false) { [weak self] _ in
            self?.onSessionRequestTimeout()
        }
    }

    private func stopTimers() {
        pingTimer?.invalidate()
        sessionTimer?.invalidate()
    }

    private func onSessionRequestTimeout() {
        onDisconnect(error: WCError.sessionRequestTimeout)
    }
}

// MARK: WebSocket event handler
extension WCInteractor {
    private func onConnect() {
        WCLog("<== websocketDidConnect")

        setupPingTimer()
        checkExistingSession()

        subscribe(topic: session.topic)
        subscribe(topic: clientId)

        connectResolver?.fulfill(true)
        connectResolver = nil

        state = .connected
    }

    private func onDisconnect(error: Error?) {
        WCLog("<== websocketDidDisconnect, error: \(error.debugDescription)")

        stopTimers()

        if let error = error {
            connectResolver?.reject(error)
        } else {
            connectResolver?.fulfill(false)
        }

        connectResolver = nil
        onDisconnect?(error)

        state = .disconnected
    }

    private func onReceiveMessage(text: String) {
        WCLog("<== receive: \(text)")
        // handle ping in text format :(
        if text == "ping" { return socket.write(pong: Data()) }
        guard let (topic, payload) = WCEncryptionPayload.extract(text) else { return }
        do {
            let decrypted = try WCEncryptor.decrypt(payload: payload, with: session.key)
            guard let json = try JSONSerialization.jsonObject(with: decrypted, options: [])
                as? [String: Any] else {
                throw WCError.badJSONRPCRequest
            }
            WCLog("<== decrypted: \(String(data: decrypted, encoding: .utf8)!)")
            if let method = json["method"] as? String {
                if let event = WCEvent(rawValue: method) {
                    try handleEvent(event, topic: topic, decrypted: decrypted)
                } else if let id = json["id"] as? Int64 {
                    onCustomRequest?(id, json)
                }
            }
        } catch let error {
            onError?(error)
            WCLog("==> onReceiveMessage error: \(error.localizedDescription)")
        }
    }
}
