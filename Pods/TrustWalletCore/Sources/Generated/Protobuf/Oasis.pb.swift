// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Oasis.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.

import Foundation
import SwiftProtobuf

// If the compiler emits an error on this type, it is because this file
// was generated by a version of the `protoc` Swift plug-in that is
// incompatible with the version of SwiftProtobuf to which you are linking.
// Please ensure that you are building against the same version of the API
// that was used to generate this file.
fileprivate struct _GeneratedWithProtocGenSwiftVersion: SwiftProtobuf.ProtobufAPIVersionCheck {
  struct _2: SwiftProtobuf.ProtobufAPIVersion_2 {}
  typealias Version = _2
}

/// Transfer
public struct TW_Oasis_Proto_TransferMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// destination address
  public var to: String = String()

  /// Gas price
  public var gasPrice: UInt64 = 0

  /// Amount values strings prefixed by zero. e.g. "\u000010000000"
  public var gasAmount: String = String()

  /// Amount values strings prefixed by zero
  public var amount: String = String()

  /// Nonce (should be larger than in the last transaction of the account)
  public var nonce: UInt64 = 0

  /// Context, see https://docs.oasis.dev/oasis-core/common-functionality/crypto#domain-separation
  public var context: String = String()

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct TW_Oasis_Proto_EscrowMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var gasPrice: UInt64 = 0

  public var gasAmount: String = String()

  public var nonce: UInt64 = 0

  public var account: String = String()

  public var amount: String = String()

  public var context: String = String()

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

public struct TW_Oasis_Proto_ReclaimEscrowMessage {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  public var gasPrice: UInt64 = 0

  public var gasAmount: String = String()

  public var nonce: UInt64 = 0

  public var account: String = String()

  public var shares: String = String()

  public var context: String = String()

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Input data necessary to create a signed transaction.
public struct TW_Oasis_Proto_SigningInput {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// The secret private key used for signing (32 bytes).
  public var privateKey: Data = Data()

  /// Transfer payload
  public var message: TW_Oasis_Proto_SigningInput.OneOf_Message? = nil

  public var transfer: TW_Oasis_Proto_TransferMessage {
    get {
      if case .transfer(let v)? = message {return v}
      return TW_Oasis_Proto_TransferMessage()
    }
    set {message = .transfer(newValue)}
  }

  public var escrow: TW_Oasis_Proto_EscrowMessage {
    get {
      if case .escrow(let v)? = message {return v}
      return TW_Oasis_Proto_EscrowMessage()
    }
    set {message = .escrow(newValue)}
  }

  public var reclaimEscrow: TW_Oasis_Proto_ReclaimEscrowMessage {
    get {
      if case .reclaimEscrow(let v)? = message {return v}
      return TW_Oasis_Proto_ReclaimEscrowMessage()
    }
    set {message = .reclaimEscrow(newValue)}
  }

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  /// Transfer payload
  public enum OneOf_Message: Equatable {
    case transfer(TW_Oasis_Proto_TransferMessage)
    case escrow(TW_Oasis_Proto_EscrowMessage)
    case reclaimEscrow(TW_Oasis_Proto_ReclaimEscrowMessage)

  #if !swift(>=4.1)
    public static func ==(lhs: TW_Oasis_Proto_SigningInput.OneOf_Message, rhs: TW_Oasis_Proto_SigningInput.OneOf_Message) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.transfer, .transfer): return {
        guard case .transfer(let l) = lhs, case .transfer(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.escrow, .escrow): return {
        guard case .escrow(let l) = lhs, case .escrow(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      case (.reclaimEscrow, .reclaimEscrow): return {
        guard case .reclaimEscrow(let l) = lhs, case .reclaimEscrow(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      default: return false
      }
    }
  #endif
  }

  public init() {}
}

/// Result containing the signed and encoded transaction.
public struct TW_Oasis_Proto_SigningOutput {
  // SwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the SwiftProtobuf library for
  // methods supported on all messages.

  /// Signed and encoded transaction bytes.
  public var encoded: Data = Data()

  /// error code, 0 is ok, other codes will be treated as errors
  public var error: TW_Common_Proto_SigningError = .ok

  /// error code description
  public var errorMessage: String = String()

  public var unknownFields = SwiftProtobuf.UnknownStorage()

  public init() {}
}

// MARK: - Code below here is support for the SwiftProtobuf runtime.

fileprivate let _protobuf_package = "TW.Oasis.Proto"

extension TW_Oasis_Proto_TransferMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".TransferMessage"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "to"),
    2: .standard(proto: "gas_price"),
    3: .standard(proto: "gas_amount"),
    4: .same(proto: "amount"),
    5: .same(proto: "nonce"),
    6: .same(proto: "context"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.to) }()
      case 2: try { try decoder.decodeSingularUInt64Field(value: &self.gasPrice) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.gasAmount) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.amount) }()
      case 5: try { try decoder.decodeSingularUInt64Field(value: &self.nonce) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.context) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.to.isEmpty {
      try visitor.visitSingularStringField(value: self.to, fieldNumber: 1)
    }
    if self.gasPrice != 0 {
      try visitor.visitSingularUInt64Field(value: self.gasPrice, fieldNumber: 2)
    }
    if !self.gasAmount.isEmpty {
      try visitor.visitSingularStringField(value: self.gasAmount, fieldNumber: 3)
    }
    if !self.amount.isEmpty {
      try visitor.visitSingularStringField(value: self.amount, fieldNumber: 4)
    }
    if self.nonce != 0 {
      try visitor.visitSingularUInt64Field(value: self.nonce, fieldNumber: 5)
    }
    if !self.context.isEmpty {
      try visitor.visitSingularStringField(value: self.context, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Oasis_Proto_TransferMessage, rhs: TW_Oasis_Proto_TransferMessage) -> Bool {
    if lhs.to != rhs.to {return false}
    if lhs.gasPrice != rhs.gasPrice {return false}
    if lhs.gasAmount != rhs.gasAmount {return false}
    if lhs.amount != rhs.amount {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.context != rhs.context {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Oasis_Proto_EscrowMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".EscrowMessage"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .standard(proto: "gas_price"),
    2: .standard(proto: "gas_amount"),
    3: .same(proto: "nonce"),
    4: .same(proto: "account"),
    5: .same(proto: "amount"),
    6: .same(proto: "context"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt64Field(value: &self.gasPrice) }()
      case 2: try { try decoder.decodeSingularStringField(value: &self.gasAmount) }()
      case 3: try { try decoder.decodeSingularUInt64Field(value: &self.nonce) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.account) }()
      case 5: try { try decoder.decodeSingularStringField(value: &self.amount) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.context) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.gasPrice != 0 {
      try visitor.visitSingularUInt64Field(value: self.gasPrice, fieldNumber: 1)
    }
    if !self.gasAmount.isEmpty {
      try visitor.visitSingularStringField(value: self.gasAmount, fieldNumber: 2)
    }
    if self.nonce != 0 {
      try visitor.visitSingularUInt64Field(value: self.nonce, fieldNumber: 3)
    }
    if !self.account.isEmpty {
      try visitor.visitSingularStringField(value: self.account, fieldNumber: 4)
    }
    if !self.amount.isEmpty {
      try visitor.visitSingularStringField(value: self.amount, fieldNumber: 5)
    }
    if !self.context.isEmpty {
      try visitor.visitSingularStringField(value: self.context, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Oasis_Proto_EscrowMessage, rhs: TW_Oasis_Proto_EscrowMessage) -> Bool {
    if lhs.gasPrice != rhs.gasPrice {return false}
    if lhs.gasAmount != rhs.gasAmount {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.account != rhs.account {return false}
    if lhs.amount != rhs.amount {return false}
    if lhs.context != rhs.context {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Oasis_Proto_ReclaimEscrowMessage: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".ReclaimEscrowMessage"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .standard(proto: "gas_price"),
    2: .standard(proto: "gas_amount"),
    3: .same(proto: "nonce"),
    4: .same(proto: "account"),
    5: .same(proto: "shares"),
    6: .same(proto: "context"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt64Field(value: &self.gasPrice) }()
      case 2: try { try decoder.decodeSingularStringField(value: &self.gasAmount) }()
      case 3: try { try decoder.decodeSingularUInt64Field(value: &self.nonce) }()
      case 4: try { try decoder.decodeSingularStringField(value: &self.account) }()
      case 5: try { try decoder.decodeSingularStringField(value: &self.shares) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.context) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.gasPrice != 0 {
      try visitor.visitSingularUInt64Field(value: self.gasPrice, fieldNumber: 1)
    }
    if !self.gasAmount.isEmpty {
      try visitor.visitSingularStringField(value: self.gasAmount, fieldNumber: 2)
    }
    if self.nonce != 0 {
      try visitor.visitSingularUInt64Field(value: self.nonce, fieldNumber: 3)
    }
    if !self.account.isEmpty {
      try visitor.visitSingularStringField(value: self.account, fieldNumber: 4)
    }
    if !self.shares.isEmpty {
      try visitor.visitSingularStringField(value: self.shares, fieldNumber: 5)
    }
    if !self.context.isEmpty {
      try visitor.visitSingularStringField(value: self.context, fieldNumber: 6)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Oasis_Proto_ReclaimEscrowMessage, rhs: TW_Oasis_Proto_ReclaimEscrowMessage) -> Bool {
    if lhs.gasPrice != rhs.gasPrice {return false}
    if lhs.gasAmount != rhs.gasAmount {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.account != rhs.account {return false}
    if lhs.shares != rhs.shares {return false}
    if lhs.context != rhs.context {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Oasis_Proto_SigningInput: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningInput"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .standard(proto: "private_key"),
    2: .same(proto: "transfer"),
    3: .same(proto: "escrow"),
    4: .same(proto: "reclaimEscrow"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.privateKey) }()
      case 2: try {
        var v: TW_Oasis_Proto_TransferMessage?
        var hadOneofValue = false
        if let current = self.message {
          hadOneofValue = true
          if case .transfer(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.message = .transfer(v)
        }
      }()
      case 3: try {
        var v: TW_Oasis_Proto_EscrowMessage?
        var hadOneofValue = false
        if let current = self.message {
          hadOneofValue = true
          if case .escrow(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.message = .escrow(v)
        }
      }()
      case 4: try {
        var v: TW_Oasis_Proto_ReclaimEscrowMessage?
        var hadOneofValue = false
        if let current = self.message {
          hadOneofValue = true
          if case .reclaimEscrow(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.message = .reclaimEscrow(v)
        }
      }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    if !self.privateKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.privateKey, fieldNumber: 1)
    }
    switch self.message {
    case .transfer?: try {
      guard case .transfer(let v)? = self.message else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    }()
    case .escrow?: try {
      guard case .escrow(let v)? = self.message else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 3)
    }()
    case .reclaimEscrow?: try {
      guard case .reclaimEscrow(let v)? = self.message else { preconditionFailure() }
      try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
    }()
    case nil: break
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Oasis_Proto_SigningInput, rhs: TW_Oasis_Proto_SigningInput) -> Bool {
    if lhs.privateKey != rhs.privateKey {return false}
    if lhs.message != rhs.message {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Oasis_Proto_SigningOutput: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase, SwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningOutput"
  public static let _protobuf_nameMap: SwiftProtobuf._NameMap = [
    1: .same(proto: "encoded"),
    2: .same(proto: "error"),
    3: .standard(proto: "error_message"),
  ]

  public mutating func decodeMessage<D: SwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.encoded) }()
      case 2: try { try decoder.decodeSingularEnumField(value: &self.error) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.errorMessage) }()
      default: break
      }
    }
  }

  public func traverse<V: SwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.encoded.isEmpty {
      try visitor.visitSingularBytesField(value: self.encoded, fieldNumber: 1)
    }
    if self.error != .ok {
      try visitor.visitSingularEnumField(value: self.error, fieldNumber: 2)
    }
    if !self.errorMessage.isEmpty {
      try visitor.visitSingularStringField(value: self.errorMessage, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Oasis_Proto_SigningOutput, rhs: TW_Oasis_Proto_SigningOutput) -> Bool {
    if lhs.encoded != rhs.encoded {return false}
    if lhs.error != rhs.error {return false}
    if lhs.errorMessage != rhs.errorMessage {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}