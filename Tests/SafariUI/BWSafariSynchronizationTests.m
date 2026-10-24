#import <XCTest/XCTest.h>
#import "BWSafariSynchronizationInternal.h"
#import <objc/message.h>

@interface BWSafariProcessSpy : NSObject
@property (nonatomic, copy, nullable) NSString *testBundleIdentifier;
@property (nonatomic, strong) NSMutableArray<NSArray<NSNumber *> *> *calls;
- (NSString *)bundleID;
- (void)waitForQuiescenceIncludingAnimationsIdle:(BOOL)animations isPreEvent:(BOOL)preEvent;
- (void)waitForQuiescenceIncludingAnimationsIdle:(BOOL)animations usingActivity:(BOOL)activity isPreEvent:(BOOL)preEvent;
@end

@implementation BWSafariProcessSpy
- (NSString *)bundleID { return self.testBundleIdentifier; }
- (void)waitForQuiescenceIncludingAnimationsIdle:(BOOL)animations isPreEvent:(BOOL)preEvent {
    [self waitForQuiescenceIncludingAnimationsIdle:animations usingActivity:YES isPreEvent:preEvent];
}
- (void)waitForQuiescenceIncludingAnimationsIdle:(BOOL)animations usingActivity:(BOOL)activity isPreEvent:(BOOL)preEvent {
    @synchronized (self) { [self.calls addObject:@[@(animations), @(activity), @(preEvent)]]; }
}
@end

static BWSafariSynchronizationState *BWSpyState;

static void BWSpyReplacement(id receiver, SEL selector, BOOL animations, BOOL activity, BOOL preEvent) {
    BWSafariSynchronizationForward(BWSpyState, receiver, selector, animations, activity, preEvent);
}

static void BWUnexpectedReplacement(id receiver, SEL selector, BOOL animations, BOOL activity, BOOL preEvent) {
}

@interface BWSafariSynchronizationTests : XCTestCase
@end

@implementation BWSafariSynchronizationTests
- (void)testForwardingAndRuntimeGuards {
    NSDictionary *identity = @{@"bundleIdentifier": @"com.apple.dt.XCUIAutomation", @"version": @"25228",
        @"imageUUID": @"6C9998E3-2351-34D3-BAAB-B523F500A26A"};
    SEL selector = @selector(waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:);
    Method central = class_getInstanceMethod(BWSafariProcessSpy.class, selector);
    IMP original = method_getImplementation(central);
    BWSpyState = [[BWSafariSynchronizationState alloc] init];
    @try {
        NSError *error;
        XCTAssertFalse(BWSafariSynchronizationInstallRuntime(BWSpyState, Nil, identity, (IMP)BWSpyReplacement, &error));
        XCTAssertNotNil(error);
        XCTAssertEqual(method_getImplementation(central), original);
        for (NSString *key in @[@"bundleIdentifier", @"version", @"imageUUID"]) {
            NSMutableDictionary *invalid = [identity mutableCopy];
            invalid[key] = @"unsupported";
            error = nil;
            XCTAssertFalse(BWSafariSynchronizationInstallRuntime(BWSpyState, BWSafariProcessSpy.class,
                invalid, (IMP)BWSpyReplacement, &error));
            XCTAssertNotNil(error);
            XCTAssertEqual(method_getImplementation(central), original);
        }
        NSString *invalidClassName = [@"BWSafariInvalidQuiescenceABI_" stringByAppendingString:NSUUID.UUID.UUIDString];
        Class invalidABI = objc_allocateClassPair(NSObject.class, invalidClassName.UTF8String, 0);
        XCTAssertNotNil(invalidABI);
        XCTAssertTrue(class_addMethod(invalidABI, selector, original, "v24@0:8B16B20"));
        objc_registerClassPair(invalidABI);
        XCTAssertFalse(BWSafariSynchronizationInstallRuntime(BWSpyState, invalidABI, identity,
            (IMP)BWSpyReplacement, &error));
        XCTAssertFalse(BWSafariSynchronizationInstallRuntime(BWSpyState, NSObject.class, identity,
            (IMP)BWSpyReplacement, &error));
        XCTAssertEqual(method_getImplementation(central), original);

        XCTAssertTrue(BWSafariSynchronizationInstallRuntime(BWSpyState, BWSafariProcessSpy.class,
            identity, (IMP)BWSpyReplacement, &error));
        NSDictionary *first = BWSafariSynchronizationStateSnapshot(BWSpyState);
        XCTAssertTrue([first[@"hookInstalled"] boolValue]);
        XCTAssertTrue([first[@"hookActive"] boolValue]);
        XCTAssertNotNil([[NSUUID alloc] initWithUUIDString:first[@"installationID"]]);
        XCTAssertTrue(BWSafariSynchronizationInstallRuntime(BWSpyState, BWSafariProcessSpy.class,
            identity, (IMP)BWSpyReplacement, &error));
        XCTAssertEqualObjects(BWSafariSynchronizationStateSnapshot(BWSpyState), first);

        BWSafariProcessSpy *spy = [[BWSafariProcessSpy alloc] init];
        spy.calls = [NSMutableArray array];
        NSArray *bundles = @[@"com.apple.mobilesafari", @"org.lil.wallet", @"com.apple.Preferences",
            @"com.apple.springboard", @"com.apple.mobilesafari.other", NSNull.null];
        for (id bundle in bundles) {
            spy.testBundleIdentifier = bundle == NSNull.null ? nil : bundle;
            for (NSUInteger bits = 0; bits < 8; bits += 1) {
                BOOL animations = (bits & 1) != 0;
                BOOL activity = (bits & 2) != 0;
                BOOL preEvent = (bits & 4) != 0;
                NSUInteger count = spy.calls.count;
                [spy waitForQuiescenceIncludingAnimationsIdle:animations usingActivity:activity isPreEvent:preEvent];
                XCTAssertEqual(spy.calls.count, count + 1);
                XCTAssertEqualObjects(spy.calls.lastObject, (@[@([bundle isEqual:@"com.apple.mobilesafari"] ? NO : animations),
                    @(activity), @(preEvent)]));
            }
        }
        NSDictionary *snapshot = BWSafariSynchronizationStateSnapshot(BWSpyState);
        XCTAssertEqualObjects(snapshot[@"counters"], (@{@"interceptedCalls": @48, @"originalForwards": @48,
            @"safariPreRewrites": @2, @"safariPostRewrites": @2, @"nonSafariForwards": @40,
            @"nonSafariArgumentChanges": @0}));
        XCTAssertTrue([NSJSONSerialization isValidJSONObject:snapshot]);
        spy.testBundleIdentifier = @"com.apple.mobilesafari";
        [spy waitForQuiescenceIncludingAnimationsIdle:YES isPreEvent:YES];
        XCTAssertEqualObjects(spy.calls.lastObject, (@[@NO, @YES, @YES]));

        dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            [spy waitForQuiescenceIncludingAnimationsIdle:YES usingActivity:NO isPreEvent:(index % 2 == 0)];
        });
        NSDictionary *counts = BWSafariSynchronizationStateSnapshot(BWSpyState)[@"counters"];
        XCTAssertEqualObjects(counts[@"interceptedCalls"], @113);
        XCTAssertEqualObjects(counts[@"originalForwards"], @113);
        XCTAssertEqualObjects(counts[@"safariPreRewrites"], @35);
        XCTAssertEqualObjects(counts[@"safariPostRewrites"], @34);
        XCTAssertEqual(spy.calls.count, 113U);

        method_setImplementation(central, (IMP)BWUnexpectedReplacement);
        XCTAssertFalse([BWSafariSynchronizationStateSnapshot(BWSpyState)[@"hookActive"] boolValue]);
        error = nil;
        XCTAssertFalse(BWSafariSynchronizationInstallRuntime(BWSpyState, BWSafariProcessSpy.class,
            identity, (IMP)BWSpyReplacement, &error));
        XCTAssertNotNil(error);
        XCTAssertEqual(method_getImplementation(central), (IMP)BWUnexpectedReplacement);
        XCTAssertEqualObjects(BWSafariSynchronizationStateSnapshot(BWSpyState)[@"installationID"], first[@"installationID"]);
    } @finally {
        method_setImplementation(central, original);
        BWSpyState = nil;
    }
}
@end
