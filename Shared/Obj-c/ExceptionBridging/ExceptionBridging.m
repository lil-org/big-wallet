// Copyright © 2022 Tokenary. All rights reserved.

#import "ExceptionBridging.h"

NS_ASSUME_NONNULL_BEGIN

@implementation NSObject(ObjC_Exception)

+ (void) objc_try:(void (^) (void)) tryBlock
       objc_catch:(void (^) (NSException* exception)) catchBlock
       objc_final:(nullable void (^) (void)) finallyBlock
{
    @try {
        tryBlock();
    } @catch (NSException* exception) {
        catchBlock(exception);
    } @finally {
        finallyBlock();
    }
}

+ (void) objc_throw:(NSException*) exception {
    @throw exception;
}

@end

NS_INLINE void objc_try(
                        void (^ tryBlock)(void),
                        void (^ catchBlock)(NSException* exception),
                        void (^_Nullable finallyBlock)(void)
) {
    @try {
        tryBlock();
    } @catch (NSException* exception) {
        catchBlock(exception);
    } @finally {
        finallyBlock();
    }
}

NS_INLINE void objc_throw(NSException* exception) {
    @throw exception;
}

NS_ASSUME_NONNULL_END
