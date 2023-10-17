// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

extension HDVersion {
    /// Determine if the HD Version is public
    ///
    /// - Parameter version: HD version
    /// - Returns: true if the version is public, false otherwise
    public var isPublic: Bool {
        return TWHDVersionIsPublic(TWHDVersion(rawValue: rawValue))
    }
    /// Determine if the HD Version is private
    ///
    /// - Parameter version: HD version
    /// - Returns: true if the version is private, false otherwise
    public var isPrivate: Bool {
        return TWHDVersionIsPrivate(TWHDVersion(rawValue: rawValue))
    }
}
