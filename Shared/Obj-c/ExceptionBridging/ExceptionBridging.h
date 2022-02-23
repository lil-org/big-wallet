// Copyright © 2022 Tokenary. All rights reserved.

#ifndef ExceptionBridging_h
#define ExceptionBridging_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSObject(ObjC_Exception)
+ (void) objc_try:(void (^) (void)) tryBlock
       objc_catch:(void (^) (NSException* exception)) catchBlock
       objc_final:(nullable void (^) (void)) finallyBlock;

+ (void) objc_throw:(NSException*) exception;
@end

NS_INLINE void objc_try(
                        void (^ tryBlock)(void),
                        void (^ catchBlock)(NSException* exception),
                        void (^_Nullable finallyBlock)(void)
                        );
NS_INLINE void objc_throw(NSException* exception);

NS_ASSUME_NONNULL_END

#endif /* ExceptionBridging_h */
