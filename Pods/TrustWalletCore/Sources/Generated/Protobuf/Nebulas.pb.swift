// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Nebulas.proto
//
// For information on using the generated types, please see the documentation:
//   https://github.com/apple/swift-protobuf/

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

/// Input data necessary to create a signed transaction.
public struct TW_Nebulas_Proto_SigningInput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// sender's address.
  public var fromAddress: String = String()

  /// Chain identifier (uint256, serialized big endian)
  public var chainID: Data = Data()

  /// Nonce (uint256, serialized big endian)
  public var nonce: Data = Data()

  /// Gas price (uint256, serialized big endian)
  public var gasPrice: Data = Data()

  /// Gas limit (uint256, serialized big endian)
  public var gasLimit: Data = Data()

  /// Recipient's address.
  public var toAddress: String = String()

  /// Amount to send in wei, 1 NAS = 10^18 Wei (uint256, serialized big endian)
  public var amount: Data = Data()

  /// Timestamp to create transaction (uint256, serialized big endian)
  public var timestamp: Data = Data()

  /// Optional payload
  public var payload: String = String()

  /// The secret private key used for signing (32 bytes).
  public var privateKey: Data = Data()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Result containing the signed and encoded transaction.
public struct TW_Nebulas_Proto_SigningOutput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Algorithm code
  public var algorithm: UInt32 = 0

  /// The signature
  public var signature: Data = Data()

  /// Encoded transaction
  public var raw: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Generic data
public struct TW_Nebulas_Proto_Data {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  public var type: String = String()

  public var payload: Data = Data()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Raw transaction data
public struct TW_Nebulas_Proto_RawTransaction {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// tx hash
  public var hash: Data = Data()

  /// source address
  public var from: Data = Data()

  /// destination address
  public var to: Data = Data()

  /// amount (uint256, serialized big endian)
  public var value: Data = Data()

  /// Nonce (should be larger than in the last transaction of the account)
  public var nonce: UInt64 = 0

  /// transaction timestamp
  public var timestamp: Int64 = 0

  /// generic data
  public var data: TW_Nebulas_Proto_Data {
    get {return _data ?? TW_Nebulas_Proto_Data()}
    set {_data = newValue}
  }
  /// Returns true if `data` has been explicitly set.
  public var hasData: Bool {return self._data != nil}
  /// Clears the value of `data`. Subsequent reads from it will return its default value.
  public mutating func clearData() {self._data = nil}

  /// chain ID (4 bytes)
  public var chainID: UInt32 = 0

  /// gas price (uint256, serialized big endian)
  public var gasPrice: Data = Data()

  /// gas limit (uint256, serialized big endian)
  public var gasLimit: Data = Data()

  /// algorithm
  public var alg: UInt32 = 0

  /// signature
  public var sign: Data = Data()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}

  fileprivate var _data: TW_Nebulas_Proto_Data? = nil
}

// MARK: - Code below here is support for the WalletCoreSwiftProtobuf.runtime.

fileprivate let _protobuf_package = "TW.Nebulas.Proto"

extension TW_Nebulas_Proto_SigningInput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningInput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "from_address"),
    2: .standard(proto: "chain_id"),
    3: .same(proto: "nonce"),
    4: .standard(proto: "gas_price"),
    5: .standard(proto: "gas_limit"),
    6: .standard(proto: "to_address"),
    7: .same(proto: "amount"),
    8: .same(proto: "timestamp"),
    9: .same(proto: "payload"),
    10: .standard(proto: "private_key"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.fromAddress) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.chainID) }()
      case 3: try { try decoder.decodeSingularBytesField(value: &self.nonce) }()
      case 4: try { try decoder.decodeSingularBytesField(value: &self.gasPrice) }()
      case 5: try { try decoder.decodeSingularBytesField(value: &self.gasLimit) }()
      case 6: try { try decoder.decodeSingularStringField(value: &self.toAddress) }()
      case 7: try { try decoder.decodeSingularBytesField(value: &self.amount) }()
      case 8: try { try decoder.decodeSingularBytesField(value: &self.timestamp) }()
      case 9: try { try decoder.decodeSingularStringField(value: &self.payload) }()
      case 10: try { try decoder.decodeSingularBytesField(value: &self.privateKey) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.fromAddress.isEmpty {
      try visitor.visitSingularStringField(value: self.fromAddress, fieldNumber: 1)
    }
    if !self.chainID.isEmpty {
      try visitor.visitSingularBytesField(value: self.chainID, fieldNumber: 2)
    }
    if !self.nonce.isEmpty {
      try visitor.visitSingularBytesField(value: self.nonce, fieldNumber: 3)
    }
    if !self.gasPrice.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasPrice, fieldNumber: 4)
    }
    if !self.gasLimit.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasLimit, fieldNumber: 5)
    }
    if !self.toAddress.isEmpty {
      try visitor.visitSingularStringField(value: self.toAddress, fieldNumber: 6)
    }
    if !self.amount.isEmpty {
      try visitor.visitSingularBytesField(value: self.amount, fieldNumber: 7)
    }
    if !self.timestamp.isEmpty {
      try visitor.visitSingularBytesField(value: self.timestamp, fieldNumber: 8)
    }
    if !self.payload.isEmpty {
      try visitor.visitSingularStringField(value: self.payload, fieldNumber: 9)
    }
    if !self.privateKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.privateKey, fieldNumber: 10)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Nebulas_Proto_SigningInput, rhs: TW_Nebulas_Proto_SigningInput) -> Bool {
    if lhs.fromAddress != rhs.fromAddress {return false}
    if lhs.chainID != rhs.chainID {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.gasPrice != rhs.gasPrice {return false}
    if lhs.gasLimit != rhs.gasLimit {return false}
    if lhs.toAddress != rhs.toAddress {return false}
    if lhs.amount != rhs.amount {return false}
    if lhs.timestamp != rhs.timestamp {return false}
    if lhs.payload != rhs.payload {return false}
    if lhs.privateKey != rhs.privateKey {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Nebulas_Proto_SigningOutput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningOutput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "algorithm"),
    2: .same(proto: "signature"),
    3: .same(proto: "raw"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularUInt32Field(value: &self.algorithm) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.signature) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.raw) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if self.algorithm != 0 {
      try visitor.visitSingularUInt32Field(value: self.algorithm, fieldNumber: 1)
    }
    if !self.signature.isEmpty {
      try visitor.visitSingularBytesField(value: self.signature, fieldNumber: 2)
    }
    if !self.raw.isEmpty {
      try visitor.visitSingularStringField(value: self.raw, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Nebulas_Proto_SigningOutput, rhs: TW_Nebulas_Proto_SigningOutput) -> Bool {
    if lhs.algorithm != rhs.algorithm {return false}
    if lhs.signature != rhs.signature {return false}
    if lhs.raw != rhs.raw {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Nebulas_Proto_Data: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".Data"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "type"),
    2: .same(proto: "payload"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.type) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.payload) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.type.isEmpty {
      try visitor.visitSingularStringField(value: self.type, fieldNumber: 1)
    }
    if !self.payload.isEmpty {
      try visitor.visitSingularBytesField(value: self.payload, fieldNumber: 2)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Nebulas_Proto_Data, rhs: TW_Nebulas_Proto_Data) -> Bool {
    if lhs.type != rhs.type {return false}
    if lhs.payload != rhs.payload {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Nebulas_Proto_RawTransaction: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".RawTransaction"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "hash"),
    2: .same(proto: "from"),
    3: .same(proto: "to"),
    4: .same(proto: "value"),
    5: .same(proto: "nonce"),
    6: .same(proto: "timestamp"),
    7: .same(proto: "data"),
    8: .standard(proto: "chain_id"),
    9: .standard(proto: "gas_price"),
    10: .standard(proto: "gas_limit"),
    11: .same(proto: "alg"),
    12: .same(proto: "sign"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.hash) }()
      case 2: try { try decoder.decodeSingularBytesField(value: &self.from) }()
      case 3: try { try decoder.decodeSingularBytesField(value: &self.to) }()
      case 4: try { try decoder.decodeSingularBytesField(value: &self.value) }()
      case 5: try { try decoder.decodeSingularUInt64Field(value: &self.nonce) }()
      case 6: try { try decoder.decodeSingularInt64Field(value: &self.timestamp) }()
      case 7: try { try decoder.decodeSingularMessageField(value: &self._data) }()
      case 8: try { try decoder.decodeSingularUInt32Field(value: &self.chainID) }()
      case 9: try { try decoder.decodeSingularBytesField(value: &self.gasPrice) }()
      case 10: try { try decoder.decodeSingularBytesField(value: &self.gasLimit) }()
      case 11: try { try decoder.decodeSingularUInt32Field(value: &self.alg) }()
      case 12: try { try decoder.decodeSingularBytesField(value: &self.sign) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    // The use of inline closures is to circumvent an issue where the compiler
    // allocates stack space for every if/case branch local when no optimizations
    // are enabled. https://github.com/apple/swift-protobuf/issues/1034 and
    // https://github.com/apple/swift-protobuf/issues/1182
    if !self.hash.isEmpty {
      try visitor.visitSingularBytesField(value: self.hash, fieldNumber: 1)
    }
    if !self.from.isEmpty {
      try visitor.visitSingularBytesField(value: self.from, fieldNumber: 2)
    }
    if !self.to.isEmpty {
      try visitor.visitSingularBytesField(value: self.to, fieldNumber: 3)
    }
    if !self.value.isEmpty {
      try visitor.visitSingularBytesField(value: self.value, fieldNumber: 4)
    }
    if self.nonce != 0 {
      try visitor.visitSingularUInt64Field(value: self.nonce, fieldNumber: 5)
    }
    if self.timestamp != 0 {
      try visitor.visitSingularInt64Field(value: self.timestamp, fieldNumber: 6)
    }
    try { if let v = self._data {
      try visitor.visitSingularMessageField(value: v, fieldNumber: 7)
    } }()
    if self.chainID != 0 {
      try visitor.visitSingularUInt32Field(value: self.chainID, fieldNumber: 8)
    }
    if !self.gasPrice.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasPrice, fieldNumber: 9)
    }
    if !self.gasLimit.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasLimit, fieldNumber: 10)
    }
    if self.alg != 0 {
      try visitor.visitSingularUInt32Field(value: self.alg, fieldNumber: 11)
    }
    if !self.sign.isEmpty {
      try visitor.visitSingularBytesField(value: self.sign, fieldNumber: 12)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Nebulas_Proto_RawTransaction, rhs: TW_Nebulas_Proto_RawTransaction) -> Bool {
    if lhs.hash != rhs.hash {return false}
    if lhs.from != rhs.from {return false}
    if lhs.to != rhs.to {return false}
    if lhs.value != rhs.value {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.timestamp != rhs.timestamp {return false}
    if lhs._data != rhs._data {return false}
    if lhs.chainID != rhs.chainID {return false}
    if lhs.gasPrice != rhs.gasPrice {return false}
    if lhs.gasLimit != rhs.gasLimit {return false}
    if lhs.alg != rhs.alg {return false}
    if lhs.sign != rhs.sign {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
