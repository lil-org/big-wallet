// DO NOT EDIT.
// swift-format-ignore-file
//
// Generated by the Swift generator plugin for the protocol buffer compiler.
// Source: Filecoin.proto
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

/// Defines the type of `from` address derivation.
public enum TW_Filecoin_Proto_DerivationType: WalletCoreSwiftProtobuf.Enum {
  public typealias RawValue = Int

  /// Defines a Secp256k1 (`f1`) derivation for the sender address.
  /// Default derivation type.
  case secp256K1 // = 0

  /// Defines a Delegated (`f4`) derivation for the sender address.
  case delegated // = 1
  case UNRECOGNIZED(Int)

  public init() {
    self = .secp256K1
  }

  public init?(rawValue: Int) {
    switch rawValue {
    case 0: self = .secp256K1
    case 1: self = .delegated
    default: self = .UNRECOGNIZED(rawValue)
    }
  }

  public var rawValue: Int {
    switch self {
    case .secp256K1: return 0
    case .delegated: return 1
    case .UNRECOGNIZED(let i): return i
    }
  }

}

#if swift(>=4.2)

extension TW_Filecoin_Proto_DerivationType: CaseIterable {
  // The compiler won't synthesize support with the UNRECOGNIZED case.
  public static var allCases: [TW_Filecoin_Proto_DerivationType] = [
    .secp256K1,
    .delegated,
  ]
}

#endif  // swift(>=4.2)

/// Input data necessary to create a signed transaction.
public struct TW_Filecoin_Proto_SigningInput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// The secret private key of the sender account, used for signing (32 bytes).
  public var privateKey: Data = Data()

  /// Recipient's address.
  public var to: String = String()

  /// Transaction nonce.
  public var nonce: UInt64 = 0

  /// Transfer value (uint256, serialized big endian)
  public var value: Data = Data()

  /// Gas limit.
  public var gasLimit: Int64 = 0

  /// Gas fee cap (uint256, serialized big endian)
  public var gasFeeCap: Data = Data()

  /// Gas premium (uint256, serialized big endian)
  public var gasPremium: Data = Data()

  /// Message params.
  public var params: Data = Data()

  /// Sender address derivation type.
  public var derivation: TW_Filecoin_Proto_DerivationType = .secp256K1

  /// Public key secp256k1 extended
  public var publicKey: Data = Data()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

/// Result containing the signed and encoded transaction.
public struct TW_Filecoin_Proto_SigningOutput {
  // WalletCoreSwiftProtobuf.Message conformance is added in an extension below. See the
  // `Message` and `Message+*Additions` files in the WalletCoreSwiftProtobuf.library for
  // methods supported on all messages.

  /// Resulting transaction, in JSON.
  public var json: String = String()

  /// Error code, 0 is ok, other codes will be treated as errors
  public var error: TW_Common_Proto_SigningError = .ok

  /// Error description
  public var errorMessage: String = String()

  public var unknownFields = WalletCoreSwiftProtobuf.UnknownStorage()

  public init() {}
}

// MARK: - Code below here is support for the WalletCoreSwiftProtobuf.runtime.

fileprivate let _protobuf_package = "TW.Filecoin.Proto"

extension TW_Filecoin_Proto_DerivationType: WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    0: .same(proto: "SECP256K1"),
    1: .same(proto: "DELEGATED"),
  ]
}

extension TW_Filecoin_Proto_SigningInput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningInput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .standard(proto: "private_key"),
    2: .same(proto: "to"),
    3: .same(proto: "nonce"),
    4: .same(proto: "value"),
    5: .standard(proto: "gas_limit"),
    6: .standard(proto: "gas_fee_cap"),
    7: .standard(proto: "gas_premium"),
    8: .same(proto: "params"),
    9: .same(proto: "derivation"),
    10: .standard(proto: "public_key"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularBytesField(value: &self.privateKey) }()
      case 2: try { try decoder.decodeSingularStringField(value: &self.to) }()
      case 3: try { try decoder.decodeSingularUInt64Field(value: &self.nonce) }()
      case 4: try { try decoder.decodeSingularBytesField(value: &self.value) }()
      case 5: try { try decoder.decodeSingularInt64Field(value: &self.gasLimit) }()
      case 6: try { try decoder.decodeSingularBytesField(value: &self.gasFeeCap) }()
      case 7: try { try decoder.decodeSingularBytesField(value: &self.gasPremium) }()
      case 8: try { try decoder.decodeSingularBytesField(value: &self.params) }()
      case 9: try { try decoder.decodeSingularEnumField(value: &self.derivation) }()
      case 10: try { try decoder.decodeSingularBytesField(value: &self.publicKey) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.privateKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.privateKey, fieldNumber: 1)
    }
    if !self.to.isEmpty {
      try visitor.visitSingularStringField(value: self.to, fieldNumber: 2)
    }
    if self.nonce != 0 {
      try visitor.visitSingularUInt64Field(value: self.nonce, fieldNumber: 3)
    }
    if !self.value.isEmpty {
      try visitor.visitSingularBytesField(value: self.value, fieldNumber: 4)
    }
    if self.gasLimit != 0 {
      try visitor.visitSingularInt64Field(value: self.gasLimit, fieldNumber: 5)
    }
    if !self.gasFeeCap.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasFeeCap, fieldNumber: 6)
    }
    if !self.gasPremium.isEmpty {
      try visitor.visitSingularBytesField(value: self.gasPremium, fieldNumber: 7)
    }
    if !self.params.isEmpty {
      try visitor.visitSingularBytesField(value: self.params, fieldNumber: 8)
    }
    if self.derivation != .secp256K1 {
      try visitor.visitSingularEnumField(value: self.derivation, fieldNumber: 9)
    }
    if !self.publicKey.isEmpty {
      try visitor.visitSingularBytesField(value: self.publicKey, fieldNumber: 10)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Filecoin_Proto_SigningInput, rhs: TW_Filecoin_Proto_SigningInput) -> Bool {
    if lhs.privateKey != rhs.privateKey {return false}
    if lhs.to != rhs.to {return false}
    if lhs.nonce != rhs.nonce {return false}
    if lhs.value != rhs.value {return false}
    if lhs.gasLimit != rhs.gasLimit {return false}
    if lhs.gasFeeCap != rhs.gasFeeCap {return false}
    if lhs.gasPremium != rhs.gasPremium {return false}
    if lhs.params != rhs.params {return false}
    if lhs.derivation != rhs.derivation {return false}
    if lhs.publicKey != rhs.publicKey {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}

extension TW_Filecoin_Proto_SigningOutput: WalletCoreSwiftProtobuf.Message, WalletCoreSwiftProtobuf._MessageImplementationBase, WalletCoreSwiftProtobuf._ProtoNameProviding {
  public static let protoMessageName: String = _protobuf_package + ".SigningOutput"
  public static let _protobuf_nameMap: WalletCoreSwiftProtobuf._NameMap = [
    1: .same(proto: "json"),
    2: .same(proto: "error"),
    3: .standard(proto: "error_message"),
  ]

  public mutating func decodeMessage<D: WalletCoreSwiftProtobuf.Decoder>(decoder: inout D) throws {
    while let fieldNumber = try decoder.nextFieldNumber() {
      // The use of inline closures is to circumvent an issue where the compiler
      // allocates stack space for every case branch when no optimizations are
      // enabled. https://github.com/apple/swift-protobuf/issues/1034
      switch fieldNumber {
      case 1: try { try decoder.decodeSingularStringField(value: &self.json) }()
      case 2: try { try decoder.decodeSingularEnumField(value: &self.error) }()
      case 3: try { try decoder.decodeSingularStringField(value: &self.errorMessage) }()
      default: break
      }
    }
  }

  public func traverse<V: WalletCoreSwiftProtobuf.Visitor>(visitor: inout V) throws {
    if !self.json.isEmpty {
      try visitor.visitSingularStringField(value: self.json, fieldNumber: 1)
    }
    if self.error != .ok {
      try visitor.visitSingularEnumField(value: self.error, fieldNumber: 2)
    }
    if !self.errorMessage.isEmpty {
      try visitor.visitSingularStringField(value: self.errorMessage, fieldNumber: 3)
    }
    try unknownFields.traverse(visitor: &visitor)
  }

  public static func ==(lhs: TW_Filecoin_Proto_SigningOutput, rhs: TW_Filecoin_Proto_SigningOutput) -> Bool {
    if lhs.json != rhs.json {return false}
    if lhs.error != rhs.error {return false}
    if lhs.errorMessage != rhs.errorMessage {return false}
    if lhs.unknownFields != rhs.unknownFields {return false}
    return true
  }
}
