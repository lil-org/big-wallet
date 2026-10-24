#import "BWSafariSynchronization.h"
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (*BWSafariQuiescenceImplementation)(id, SEL, BOOL, BOOL, BOOL);

@interface BWSafariSynchronizationState : NSObject {
@public
    NSLock *lock;
    Method _Nullable method;
    IMP _Nullable original;
    IMP _Nullable replacement;
    Class _Nullable processClass;
    BOOL installed;
    NSString *installationID;
    NSDictionary<NSString *, id> *framework;
    uint64_t interceptedCalls;
    uint64_t originalForwards;
    uint64_t safariPreRewrites;
    uint64_t safariPostRewrites;
    uint64_t nonSafariForwards;
    uint64_t nonSafariArgumentChanges;
}
@end

FOUNDATION_EXPORT BOOL BWSafariSynchronizationInstallRuntime(BWSafariSynchronizationState *state,
    Class _Nullable processClass, NSDictionary<NSString *, id> *identity, IMP implementation,
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BWSafariSynchronizationForward(BWSafariSynchronizationState *state,
    id receiver, SEL selector, BOOL animations, BOOL activity, BOOL preEvent);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *BWSafariSynchronizationStateSnapshot(BWSafariSynchronizationState *state);

NS_ASSUME_NONNULL_END
