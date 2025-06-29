// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: TheOpenNetwork.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.

import Foundation
import WalletCoreSwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of WalletCoreSwiftProtobuf.to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: WalletCoreSwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: WalletCoreSwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

public enum TW_TheOpenNetwork_Proto_WalletVersion: WalletCoreSwiftProtobuf.Enum {
  public typealias RawValue = Int
  case walletV3R1 // = 0
  case walletV3R2 // = 1
  case walletV4R2 // = 2
  case walletV5R1 // = 3
  case UNRECOGNIZED(Int)

  public init() {
    self = .walletV3R1
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .walletV3R1
    case 1: self = .walletV3R2
    case 2: self = .walletV4R2
    case 3: self = .walletV5R1
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .walletV3R1: return 0
    case .walletV3R2: return 1
    case .walletV4R2: return 2
    case .walletV5R1: return 3
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension TW_TheOpenNetwork_Proto_WalletVersion: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [TW_TheOpenNetwork_Proto_WalletVersion] = [
    .walletV3R1,
    .walletV3R2,
    .walletV4R2,
    .walletV5R1,
  ]
}

#endif  // swift(>=4.2)

public enum TW_TheOpenNetwork_Proto_SendMode: WalletCoreSwiftProtobuf.Enum {
  public typealias RawValue = Int
  case `default` // = 0
  case payFeesSeparately // = 1
  case ignoreActionPhaseErrors // = 2
  case destroyOnZeroBalance // = 32
  case attachAllInboundMessageValue // = 64
  case attachAllContractBalance // = 128
  case UNRECOGNIZED(Int)

  public init() {
    self = .default
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .default
    case 1: self = .payFeesSeparately
    case 2: self = .ignoreActionPhaseErrors
    case 32: self = .destroyOnZeroBalance
    case 64: self = .attachAllInboundMessageValue
    case 128: self = .attachAllContractBalance
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .default: return 0
    case .payFeesSeparately: return 1
    case .ignoreActionPhaseErrors: return 2
    case .destroyOnZeroBalance: return 32
    case .attachAllInboundMessageValue: return 64
    case .attachAllContractBalance: return 128
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension TW_TheOpenNetwork_Proto_SendMode: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [TW_TheOpenNetwork_Proto_SendMode] = [
    .default,
    .payFeesSeparately,
    .ignoreActionPhaseErrors,
    .destroyOnZeroBalance,
    .attachAllInboundMessageValue,
    .attachAllContractBalance,
  ]
}

#endif  // swift(>=4.2)

public struct TW_TheOpenNetwork_Proto_Transfer {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Recipient address
  public var dest: String = String()

  /// Amount to send in nanotons
  /// uint128 / big endian byte order
  public var amount: Data = Data()

  /// Send mode (optional, 0 by default)
  /// Learn more: https://ton.org/docs/develop/func/stdlib#send_raw_message
  public var mode: UInt32 = 0

  /// Transfer comment message (optional, empty by default)
  /// Ignored if `custom_payload` is specified
  public var comment: String = String()

  /// If the address is bounceable
  public var bounceable: Bool = false

  /// Optional raw one-cell BoC encoded in Base64.
  /// Can be used to deploy a smart contract.
  public var stateInit: String = String()

  /// One of the Transfer message payloads (optional).
  public var payload: TW_TheOpenNetwork_Proto_Transfer.OneOf_Payload? = nil

  /// Jetton transfer payload.
  public var jettonTransfer: TW_TheOpenNetwork_Proto_JettonTransfer {
    get {
      if case .jettonTransfer(let v)? = payload {return v}
      return TW_TheOpenNetwork_Proto_JettonTransfer()
    }
    set {payload = .jettonTransfer(newValue)}
  }

  /// TON transfer with custom payload (contract call). Raw one-cell BoC encoded in Base64.
  public var customPayload: String {
    get {
      if case .customPayload(let v)? = payload {return v}
      return String()
    }
    set {payload = .customPayload(newValue)}
  }

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  /// One of the Transfer message payloads (optional).
  public enum OneOf_Payload: Equatable {
    /// Jetton transfer payload.
    case jettonTransfer(TW_TheOpenNetwork_Proto_JettonTransfer)
    /// TON transfer with custom payload (contract call). Raw one-cell BoC encoded in Base64.
    case customPayload(String)

  #if !swift(>=4.1)
    public static func ==(lhs: TW_TheOpenNetwork_Proto_Transfer.OneOf_Payload, rhs: TW_TheOpenNetwork_Proto_Transfer.OneOf_Payload) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.jettonTransfer, .jettonTransfer): return {
        guard case .jettonTransfer(let l) = lhs, case .jettonTransfer(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.customPayload, .customPayload): return {
        guard case .customPayload(let l) = lhs, case .customPayload(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      default: return false
      }
    }
  #endif
  }

  public init() {}
}

public struct TW_TheOpenNetwork_Proto_JettonTransfer {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Arbitrary request number. Default is 0. Optional field.
  public var queryID: UInt64 = 0

  /// Amount of transferred jettons in elementary integer units. The real value transferred is jetton_amount multiplied by ten to the power of token decimal precision
  /// uint128 / big endian byte order
  public var jettonAmount: Data = Data()

  /// Address of the new owner of the jettons.
  public var toOwner: String = String()

  /// Address where to send a response with confirmation of a successful transfer and the rest of the incoming message Toncoins. Usually the sender should get back their toncoins.
  public var responseAddress: String = String()

  /// Amount in nanotons to forward to recipient. Basically minimum amount - 1 nanoton should be used
  /// uint128 / big endian byte order
  public var forwardAmount: Data = Data()

  /// Optional raw one-cell BoC encoded in Base64.
  /// Can be used in the case of mintless jetton transfers.
  public var customPayload: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct TW_TheOpenNetwork_Proto_SigningInput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// The secret private key used for signing (32 bytes).
  public var privateKey: Data = Data()

  /// Public key of the signer (32 bytes). Used when transaction is going to be signed externally.
  public var publicKey: Data = Data()

  /// Up to 4 internal messages.
  public var messages: [TW_TheOpenNetwork_Proto_Transfer] = []

  /// Message counter (optional, 0 by default used for the first deploy)
  /// This field is required, because we need to protect the smart contract against "replay attacks"
  /// Learn more: https://ton.org/docs/develop/smart-contracts/guidelines/external-messages
  public var sequenceNumber: UInt32 = 0

  /// Expiration UNIX timestamp (optional, now() + 60 by default)
  public var expireAt: UInt32 = 0

  /// Wallet version
  public var walletVersion: TW_TheOpenNetwork_Proto_WalletVersion = .walletV3R1

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Transaction signing output.
public struct TW_TheOpenNetwork_Proto_SigningOutput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Signed and base64 encoded BOC message
  public var encoded: String = String()

  /// Transaction Cell hash
  public var hash: Data = Data()

  /// error code, 0 is ok, other codes will be treated as errors
  public var error: TW_Common_Proto_SigningError = .ok

  /// error code description
  public var errorMessage: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

// MARK: - Code below here is support for the WalletCoreSwiftProtobuf.runtime.

fileprivate let _protobuf_package = "TW.TheOpenNetwork.Proto"

extension TW_TheOpenNetwork_Proto_WalletVersion: WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    0: .same(proto: "WALLET_V3_R1"),
    1: .same(proto: "WALLET_V3_R2"),
    2: .same(proto: "WALLET_V4_R2"),
    3: .same(proto: "WALLET_V5_R1"),
  ]
}

extension TW_TheOpenNetwork_Proto_SendMode: WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    0: .same(proto: "DEFAULT"),
    1: .same(proto: "PAY_FEES_SEPARATELY"),
    2: .same(proto: "IGNORE_ACTION_PHASE_ERRORS"),
    32: .same(proto: "DESTROY_ON_ZERO_BALANCE"),
    64: .same(proto: "ATTACH_ALL_INBOUND_MESSAGE_VALUE"),
    128: .same(proto: "ATTACH_ALL_CONTRACT_BALANCE"),
  ]
}

extension TW_TheOpenNetwork_Proto_Transfer: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".Transfer"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "dest"),
    2: .same(proto: "amount"),
    3: .same(proto: "mode"),
    4: .same(proto: "comment"),
    5: .same(proto: "bounceable"),
    6: .standard(proto: "state_init"),
    7: .standard(proto: "jetton_transfer"),
    8: .standard(proto: "custom_payload"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.dest) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.amount) }()
      case 3: try { try decoder.decodeSingularUInt32Field(value: &self.mode) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.comment) }()
      case 5: try { try decoder.decodeSingularBoolField(value: &self.bounceable) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.stateInit) }()
      case 7: try {
        var v: TW_TheOpenNetwork_Proto_JettonTransfer?
        var hadOneofValue = false
        if let current = self.payload {
          hadOneofValue = true
          if case .jettonTransfer(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.payload = .jettonTransfer(v)
        }
      }()
      case 8: try {
        var v: String?
        try decoder.decodeSingularStringField(value: &v)
        if let v = v {
          if self.payload != nil {try decoder.handleConflictingOneOf()}
          self.payload = .customPayload(v)
        }
      }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    if !self.dest.isEmpty {
      try visitor.visitSingularStringField(value: self.dest, fieldNumber: 1)
    }
    if !self.amount.isEmpty {
      try visitor.visitSingularBytesField(value: self.amount, fieldNumber: 2)
    }
    if self.mode != 0 {
      try visitor.visitSingularUInt32Field(value: self.mode, fieldNumber: 3)
    }
    if !self.comment.isEmpty {
      try visitor.visitSingularStringField(value: self.comment, fieldNumber: 4)
    }
    if self.bounceable != false {
      try visitor.visitSingularBoolField(value: self.bounceable, fieldNumber: 5)
    }
    if !self.stateInit.isEmpty {
      try visitor.visitSingularStringField(value: self.stateInit, fieldNumber: 6)
    }
    switch self.payload {
    case .jettonTransfer?: try {
      guard case .jettonTransfer(let v)? = self.payload else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 7)
    }()
    case .customPayload?: try {
      guard case .customPayload(let v)? = self.payload else { preconditionFailure() }
      try visitor.visitSingularStringField(value: v, fieldNumber: 8)
    }()
    case nil: break
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_TheOpenNetwork_Proto_Transfer, rhs: TW_TheOpenNetwork_Proto_Transfer) -> Bool {
    if lhs.dest != rhs.dest {return false}
    if lhs.amount != rhs.amount {return false}
    if lhs.mode != rhs.mode {return false}
    if lhs.comment != rhs.comment {return false}
    if lhs.bounceable != rhs.bounceable {return false}
    if lhs.stateInit != rhs.stateInit {return false}
    if lhs.payload != rhs.payload {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_TheOpenNetwork_Proto_JettonTransfer: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".JettonTransfer"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "query_id"),
    2: .standard(proto: "jetton_amount"),
    3: .standard(proto: "to_owner"),
    4: .standard(proto: "response_address"),
    5: .standard(proto: "forward_amount"),
    6: .standard(proto: "custom_payload"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt64Field(value: &self.queryID) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.jettonAmount) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.toOwner) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.responseAddress) }()
      case 5: try { try decoder.decodeSingularBytesField(value: &self.forwardAmount) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.customPayload) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.queryID != 0 {
      try visitor.visitSingularUInt64Field(value: self.queryID, fieldNumber: 1)
    }
    if !self.jettonAmount.isEmpty {
      try visitor.visitSingularBytesField(value: self.jettonAmount, fieldNumber: 2)
    }
    if !self.toOwner.isEmpty {
      try visitor.visitSingularStringField(value: self.toOwner, fieldNumber: 3)
    }
    if !self.responseAddress.isEmpty {
      try visitor.visitSingularStringField(value: self.responseAddress, fieldNumber: 4)
    }
    if !self.forwardAmount.isEmpty {
      try visitor.visitSingularBytesField(value: self.forwardAmount, fieldNumber: 5)
    }
    if !self.customPayload.isEmpty {
      try visitor.visitSingularStringField(value: self.customPayload, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_TheOpenNetwork_Proto_JettonTransfer, rhs: TW_TheOpenNetwork_Proto_JettonTransfer) -> Bool {
    if lhs.queryID != rhs.queryID {return false}
    if lhs.jettonAmount != rhs.jettonAmount {return false}
    if lhs.toOwner != rhs.toOwner {return false}
    if lhs.responseAddress != rhs.responseAddress {return false}
    if lhs.forwardAmount != rhs.forwardAmount {return false}
    if lhs.customPayload != rhs.customPayload {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_TheOpenNetwork_Proto_SigningInput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningInput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "private_key"),
    2: .standard(proto: "public_key"),
    3: .same(proto: "messages"),
    4: .standard(proto: "sequence_number"),
    5: .standard(proto: "expire_at"),
    6: .standard(proto: "wallet_version"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.privateKey) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.publicKey) }()
      case 3: try { try decoder.decodeRepeatedMessageField(value: &self.messages) }()
      case 4: try { try decoder.decodeSingularUInt32Field(value: &self.sequenceNumber) }()
      case 5: try { try decoder.decodeSingularUInt32Field(value: &self.expireAt) }()
      case 6: try { try decoder.decodeSingularEnumField(value: &self.walletVersion) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.privateKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.privateKey, fieldNumber: 1)
    }
    if !self.publicKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.publicKey, fieldNumber: 2)
    }
    if !self.messages.isEmpty {
      try visitor.visitRepeatedMessageField(value: self.messages, fieldNumber: 3)
    }
    if self.sequenceNumber != 0 {
      try visitor.visitSingularUInt32Field(value: self.sequenceNumber, fieldNumber: 4)
    }
    if self.expireAt != 0 {
      try visitor.visitSingularUInt32Field(value: self.expireAt, fieldNumber: 5)
    }
    if self.walletVersion != .walletV3R1 {
      try visitor.visitSingularEnumField(value: self.walletVersion, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_TheOpenNetwork_Proto_SigningInput, rhs: TW_TheOpenNetwork_Proto_SigningInput) -> Bool {
    if lhs.privateKey != rhs.privateKey {return false}
    if lhs.publicKey != rhs.publicKey {return false}
    if lhs.messages != rhs.messages {return false}
    if lhs.sequenceNumber != rhs.sequenceNumber {return false}
    if lhs.expireAt != rhs.expireAt {return false}
    if lhs.walletVersion != rhs.walletVersion {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_TheOpenNetwork_Proto_SigningOutput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningOutput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "encoded"),
    2: .same(proto: "hash"),
    3: .same(proto: "error"),
    4: .standard(proto: "error_message"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.encoded) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.hash) }()
      case 3: try { try decoder.decodeSingularEnumField(value: &self.error) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.errorMessage) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.encoded.isEmpty {
      try visitor.visitSingularStringField(value: self.encoded, fieldNumber: 1)
    }
    if !self.hash.isEmpty {
      try visitor.visitSingularBytesField(value: self.hash, fieldNumber: 2)
    }
    if self.error != .ok {
      try visitor.visitSingularEnumField(value: self.error, fieldNumber: 3)
    }
    if !self.errorMessage.isEmpty {
      try visitor.visitSingularStringField(value: self.errorMessage, fieldNumber: 4)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_TheOpenNetwork_Proto_SigningOutput, rhs: TW_TheOpenNetwork_Proto_SigningOutput) -> Bool {
    if lhs.encoded != rhs.encoded {return false}
    if lhs.hash != rhs.hash {return false}
    if lhs.error != rhs.error {return false}
    if lhs.errorMessage != rhs.errorMessage {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
