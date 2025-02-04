// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
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
