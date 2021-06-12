////
//// This source file is part of the 0x.swift open source project
//// Copyright 2019 The 0x.swift Authors
//// Licensed under Apache License v2.0
////
//// EIP712SignatureVerifier.swift
////
//// Created by Igor Shmakov on 19/04/2019
////
//
//import Foundation
//import Web3Swift
//import secp256k1_ios
//import CryptoSwift
//
//public final class EIP712SignatureVerifier {
//
//    private let context: OpaquePointer
//
//    public init() {
//
//        context = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_VERIFY))!
//    }
//
//    deinit {
//
//        secp256k1_context_destroy(context)
//    }
//
//    public func verify(data: EIP712Hashable, signature: Data, address: EthAddress) throws -> Bool {
//
//        guard var convertedSignature = convertSignature(signature: signature) else {
//            throw EIP712Error.signatureVerificationError
//        }
//
//        guard var recoveredPublicKey = publicKey(signature: &convertedSignature, hash: try data.hash()) else {
//            throw EIP712Error.signatureVerificationError
//        }
//
//        let publicKey = convertPublicKey(publicKey: &recoveredPublicKey, compressed: false)
//        return try publicKeyToEthAddress(publicKey: publicKey) == address.value()
//    }
//
//    private func publicKeyToEthAddress(publicKey: Data) -> Data {
//
//        // Drop constant prefix 0x04
//        return publicKey.dropFirst().sha3(.keccak256).suffix(20)
//    }
//}
//
//private extension EIP712SignatureVerifier {
//
//    private func publicKey(privateKey: Data) -> secp256k1_pubkey? {
//
//        let privateKey = privateKey.bytes
//        var outPubKey = secp256k1_pubkey()
//        let status = secp256k1_ec_pubkey_create(context, &outPubKey, privateKey)
//        return status == 1 ? outPubKey : nil
//    }
//
//    private func publicKey(signature: inout secp256k1_ecdsa_recoverable_signature, hash: Data) -> secp256k1_pubkey? {
//
//        let hash = hash.bytes
//        var outPubKey = secp256k1_pubkey()
//        let status = secp256k1_ecdsa_recover(context, &outPubKey, &signature, hash)
//        return status == 1 ? outPubKey : nil
//    }
//
//    private func convertPublicKey(publicKey: inout secp256k1_pubkey, compressed: Bool) -> Data {
//
//        var output = Data(count: compressed ? 33 : 65)
//        var outputLen: Int = output.count
//        let compressedFlags = compressed ? UInt32(SECP256K1_EC_COMPRESSED) : UInt32(SECP256K1_EC_UNCOMPRESSED)
//        output.withUnsafeMutableBytes { (pointer: UnsafeMutablePointer<UInt8>) -> Void in
//            secp256k1_ec_pubkey_serialize(context, pointer, &outputLen, &publicKey, compressedFlags)
//        }
//        return output
//    }
//
//    private func convertSignature(signature: Data) -> secp256k1_ecdsa_recoverable_signature? {
//
//        var sig = secp256k1_ecdsa_recoverable_signature()
//        let recid = Int32(signature[64]) - 27
//        let result = signature.withUnsafeBytes { (input: UnsafePointer<UInt8>) -> Int32 in
//            return secp256k1_ecdsa_recoverable_signature_parse_compact(context, &sig, input, recid)
//        }
//        return result == 1 ? sig : nil
//    }
//}
