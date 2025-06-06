// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: InternetComputer.proto
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

/// Internet Computer Transactions
public struct TW_InternetComputer_Proto_Transaction {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Payload transfer
  public var transactionOneof: TW_InternetComputer_Proto_Transaction.OneOf_TransactionOneof? = nil

  public var transfer: TW_InternetComputer_Proto_Transaction.Transfer {
    get {
      if case .transfer(let v)? = transactionOneof {return v}
      return TW_InternetComputer_Proto_Transaction.Transfer()
    }
    set {transactionOneof = .transfer(newValue)}
  }

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  /// Payload transfer
  public enum OneOf_TransactionOneof: Equatable {
    case transfer(TW_InternetComputer_Proto_Transaction.Transfer)

  #if !swift(>=4.1)
    public static func ==(lhs: TW_InternetComputer_Proto_Transaction.OneOf_TransactionOneof, rhs: TW_InternetComputer_Proto_Transaction.OneOf_TransactionOneof) -> Bool {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch (lhs, rhs) {
      case (.transfer, .transfer): return {
        guard case .transfer(let l) = lhs, case .transfer(let r) = rhs else { preconditionFailure() }
        return l == r
      }()
      }
    }
  #endif
  }

  /// ICP ledger transfer arguments
  public struct Transfer {
    // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
    // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
    // methods supported on all messages.

    public var toAccountIdentifier: String = String()

    public var amount: UInt64 = 0

    public var memo: UInt64 = 0

    public var currentTimestampNanos: UInt64 = 0

    public var permittedDrift: UInt64 = 0

    public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

    public init() {}
  }

  public init() {}
}

/// Input data necessary to create a signed transaction.
public struct TW_InternetComputer_Proto_SigningInput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  public var privateKey: Data = Data()

  public var transaction: TW_InternetComputer_Proto_Transaction {
    get {return _transaction ?? TW_InternetComputer_Proto_Transaction()}
    set {_transaction = newValue}
  }
  /// Returns true if `transaction` has been explicitly set.
  public var hasTransaction: Bool {return self._transaction != nil}
  /// Clears the value of `transaction`. Subsequent reads from it will return its default value.
  public mutating func clearTransaction() {self._transaction = nil}

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _transaction: TW_InternetComputer_Proto_Transaction? = nil
}

/// Transaction signing output.
public struct TW_InternetComputer_Proto_SigningOutput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Signed and encoded transaction bytes.
  /// NOTE: Before sending to the Rosetta node, this value should be hex-encoded before using with the JSON structure.
  public var signedTransaction: Data = Data()

  public var error: TW_Common_Proto_SigningError = .ok

  public var errorMessage: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

// MARK: - Code below here is support for the WalletCoreSwiftProtobuf.runtime.

fileprivate let _protobuf_package = "TW.InternetComputer.Proto"

extension TW_InternetComputer_Proto_Transaction: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".Transaction"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "transfer"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try {
        var v: TW_InternetComputer_Proto_Transaction.Transfer?
        var hadOneofValue = false
        if let current = self.transactionOneof {
          hadOneofValue = true
          if case .transfer(let m) = current {v = m}
        }
        try decoder.decodeSingularMessageField(value: &v)
        if let v = v {
          if hadOneofValue {try decoder.handleConflictingOneOf()}
          self.transactionOneof = .transfer(v)
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
    try { if case .transfer(let v)? = self.transactionOneof {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 1)
    } }()
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_InternetComputer_Proto_Transaction, rhs: TW_InternetComputer_Proto_Transaction) -> Bool {
    if lhs.transactionOneof != rhs.transactionOneof {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_InternetComputer_Proto_Transaction.Transfer: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = TW_InternetComputer_Proto_Transaction.protoMessageName + ".Transfer"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "to_account_identifier"),
    2: .same(proto: "amount"),
    3: .same(proto: "memo"),
    4: .standard(proto: "current_timestamp_nanos"),
    5: .standard(proto: "permitted_drift"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.toAccountIdentifier) }()
      case 2: try { try decoder.decodeSingularUInt64Field(value: &self.amount) }()
      case 3: try { try decoder.decodeSingularUInt64Field(value: &self.memo) }()
      case 4: try { try decoder.decodeSingularUInt64Field(value: &self.currentTimestampNanos) }()
      case 5: try { try decoder.decodeSingularUInt64Field(value: &self.permittedDrift) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.toAccountIdentifier.isEmpty {
      try visitor.visitSingularStringField(value: self.toAccountIdentifier, fieldNumber: 1)
    }
    if self.amount != 0 {
      try visitor.visitSingularUInt64Field(value: self.amount, fieldNumber: 2)
    }
    if self.memo != 0 {
      try visitor.visitSingularUInt64Field(value: self.memo, fieldNumber: 3)
    }
    if self.currentTimestampNanos != 0 {
      try visitor.visitSingularUInt64Field(value: self.currentTimestampNanos, fieldNumber: 4)
    }
    if self.permittedDrift != 0 {
      try visitor.visitSingularUInt64Field(value: self.permittedDrift, fieldNumber: 5)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_InternetComputer_Proto_Transaction.Transfer, rhs: TW_InternetComputer_Proto_Transaction.Transfer) -> Bool {
    if lhs.toAccountIdentifier != rhs.toAccountIdentifier {return false}
    if lhs.amount != rhs.amount {return false}
    if lhs.memo != rhs.memo {return false}
    if lhs.currentTimestampNanos != rhs.currentTimestampNanos {return false}
    if lhs.permittedDrift != rhs.permittedDrift {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_InternetComputer_Proto_SigningInput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningInput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "private_key"),
    2: .same(proto: "transaction"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.privateKey) }()
      case 2: try { try decoder.decodeSingularMessageField(value: &self._transaction) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    if !self.privateKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.privateKey, fieldNumber: 1)
    }
    try { if let v = self._transaction {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 2)
    } }()
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_InternetComputer_Proto_SigningInput, rhs: TW_InternetComputer_Proto_SigningInput) -> Bool {
    if lhs.privateKey != rhs.privateKey {return false}
    if lhs._transaction != rhs._transaction {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_InternetComputer_Proto_SigningOutput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningOutput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "signed_transaction"),
    2: .same(proto: "error"),
    3: .standard(proto: "error_message"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.signedTransaction) }()
      case 2: try { try decoder.decodeSingularEnumField(value: &self.error) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.errorMessage) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.signedTransaction.isEmpty {
      try visitor.visitSingularBytesField(value: self.signedTransaction, fieldNumber: 1)
    }
    if self.error != .ok {
      try visitor.visitSingularEnumField(value: self.error, fieldNumber: 2)
    }
    if !self.errorMessage.isEmpty {
      try visitor.visitSingularStringField(value: self.errorMessage, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_InternetComputer_Proto_SigningOutput, rhs: TW_InternetComputer_Proto_SigningOutput) -> Bool {
    if lhs.signedTransaction != rhs.signedTransaction {return false}
    if lhs.error != rhs.error {return false}
    if lhs.errorMessage != rhs.errorMessage {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
