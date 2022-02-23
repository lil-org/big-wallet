// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

public func objc(
    try tryBlock: @autoclosure @escaping () -> Void,
    catch catchBlock: @escaping (_ exception: NSException) -> Void,
    finally finallyBlock: (() -> Void)? = nil
) {
    NSObject.objc_try(tryBlock, objc_catch: catchBlock, objc_final: finallyBlock)
}

public func objc(
    throw objCException: (name: String, message: String?, userInfo: [AnyHashable: Any]?)
) {
    NSObject.objc_throw(
        NSException(
            name: NSExceptionName(objCException.name),
            reason: objCException.message ?? objCException.name,
            userInfo: objCException.userInfo
        )
    )
}
