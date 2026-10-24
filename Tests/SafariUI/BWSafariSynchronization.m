#import "BWSafariSynchronizationInternal.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/message.h>

static NSString *const BWFrameworkIdentifier = @"com.apple.dt.XCUIAutomation";
static NSString *const BWFrameworkVersion = @"25228";
static NSString *const BWFrameworkUUID = @"6C9998E3-2351-34D3-BAAB-B523F500A26A";
static const char *const BWQuiescenceSelector = "waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:";
static const char *const BWQuiescenceEncoding = "v28@0:8B16B20B24";
static const uint64_t BWMaximumJSONInteger = 9007199254740991ULL;

@implementation BWSafariSynchronizationState
- (instancetype)init {
    self = [super init];
    if (self) {
        lock = [[NSLock alloc] init];
        installationID = @"";
        framework = @{};
    }
    return self;
}
@end

static BOOL BWFail(NSError **error, NSString *description) {
    if (error) {
        *error = [NSError errorWithDomain:@"BWSafariSynchronization" code:1
                                userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

static void BWIncrement(uint64_t *value) {
    if (*value < BWMaximumJSONInteger) { *value += 1; }
}

static BOOL BWMethodMatches(Method method, const char *encoding, unsigned int arguments) {
    return method && method_getNumberOfArguments(method) == arguments &&
        strcmp(method_getTypeEncoding(method), encoding) == 0;
}

BOOL BWSafariSynchronizationInstallRuntime(BWSafariSynchronizationState *state, Class processClass,
    NSDictionary<NSString *, id> *identity, IMP implementation, NSError **error) {
    [state->lock lock];
    @try {
        if (!processClass || !implementation ||
            ![identity[@"bundleIdentifier"] isEqual:BWFrameworkIdentifier] ||
            ![identity[@"version"] isEqual:BWFrameworkVersion] ||
            ![identity[@"imageUUID"] isEqual:BWFrameworkUUID]) {
            return BWFail(error, @"Unsupported XCUIAutomation image for Safari synchronization");
        }
        Method central = class_getInstanceMethod(processClass, sel_registerName(BWQuiescenceSelector));
        Method forwarding = class_getInstanceMethod(processClass,
            sel_registerName("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:"));
        Method identifier = class_getInstanceMethod(processClass, sel_registerName("bundleID"));
        if (!BWMethodMatches(central, BWQuiescenceEncoding, 5) ||
            !BWMethodMatches(forwarding, "v24@0:8B16B20", 4) ||
            !BWMethodMatches(identifier, "@16@0:8", 2)) {
            return BWFail(error, @"Unsupported XCUIApplicationProcess method ABI for Safari synchronization");
        }
        if (state->installed) {
            if (state->processClass != processClass || state->method != central || state->replacement != implementation ||
                method_getImplementation(state->method) != state->replacement) {
                return BWFail(error, @"The Safari synchronization hook implementation changed after installation");
            }
            return YES;
        }
        IMP previous = method_getImplementation(central);
        if (!previous || previous == implementation) {
            return BWFail(error, @"The Safari synchronization method was already replaced");
        }
        state->method = central;
        state->original = previous;
        state->replacement = implementation;
        state->processClass = processClass;
        state->framework = [identity copy];
        state->installationID = NSUUID.UUID.UUIDString;
        IMP observed = method_setImplementation(central, implementation);
        if (observed != previous || method_getImplementation(central) != implementation) {
            if (method_getImplementation(central) == implementation) { method_setImplementation(central, observed); }
            state->original = NULL;
            state->replacement = NULL;
            state->method = NULL;
            state->processClass = Nil;
            state->framework = @{};
            state->installationID = @"";
            return BWFail(error, @"The Safari synchronization implementation changed during installation");
        }
        state->installed = YES;
        return YES;
    } @finally {
        [state->lock unlock];
    }
}

void BWSafariSynchronizationForward(BWSafariSynchronizationState *state, id receiver, SEL selector,
    BOOL animations, BOOL activity, BOOL preEvent) {
    NSString *bundleID = ((id (*)(id, SEL))objc_msgSend)(receiver, sel_registerName("bundleID"));
    BOOL safari = [bundleID isKindOfClass:NSString.class] && [bundleID isEqualToString:@"com.apple.mobilesafari"];
    BOOL forwardedAnimations = safari ? NO : animations;
    [state->lock lock];
    BWSafariQuiescenceImplementation implementation = (BWSafariQuiescenceImplementation)state->original;
    BWIncrement(&state->interceptedCalls);
    if (safari && animations) { BWIncrement(preEvent ? &state->safariPreRewrites : &state->safariPostRewrites); }
    if (!safari && forwardedAnimations != animations) { BWIncrement(&state->nonSafariArgumentChanges); }
    [state->lock unlock];
    implementation(receiver, selector, forwardedAnimations, activity, preEvent);
    [state->lock lock];
    BWIncrement(&state->originalForwards);
    if (!safari) { BWIncrement(&state->nonSafariForwards); }
    [state->lock unlock];
}

NSDictionary<NSString *, id> *BWSafariSynchronizationStateSnapshot(BWSafariSynchronizationState *state) {
    [state->lock lock];
    @try {
        BOOL active = state->installed && method_getImplementation(state->method) == state->replacement;
        return @{@"schemaVersion": @1, @"policy": @"safari-event-loop-only",
            @"installationID": state->installationID, @"hookInstalled": @(state->installed), @"hookActive": @(active),
            @"framework": state->framework, @"selector": @(BWQuiescenceSelector), @"methodEncoding": @(BWQuiescenceEncoding),
            @"counters": @{@"interceptedCalls": @(state->interceptedCalls), @"originalForwards": @(state->originalForwards),
                @"safariPreRewrites": @(state->safariPreRewrites), @"safariPostRewrites": @(state->safariPostRewrites),
                @"nonSafariForwards": @(state->nonSafariForwards), @"nonSafariArgumentChanges": @(state->nonSafariArgumentChanges)}};
    } @finally {
        [state->lock unlock];
    }
}

static BWSafariSynchronizationState *BWState(void) {
    static BWSafariSynchronizationState *state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ state = [[BWSafariSynchronizationState alloc] init]; });
    return state;
}

#if TARGET_OS_SIMULATOR && TARGET_OS_IOS && defined(__arm64__)
static void BWWait(id receiver, SEL selector, BOOL animations, BOOL activity, BOOL preEvent) {
    BWSafariSynchronizationForward(BWState(), receiver, selector, animations, activity, preEvent);
}

static NSString *BWImageUUID(const char *imagePath) {
    if (!imagePath) { return nil; }
    for (uint32_t index = 0; index < _dyld_image_count(); index += 1) {
        const char *name = _dyld_get_image_name(index);
        if (!name || strcmp(name, imagePath) != 0) { continue; }
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) { return nil; }
        const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
        const uint8_t *end = cursor + header->sizeofcmds;
        for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex += 1) {
            if ((size_t)(end - cursor) < sizeof(struct load_command)) { return nil; }
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) { return nil; }
            if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) {
                return [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
            }
            cursor += command->cmdsize;
        }
    }
    return nil;
}
#endif

BOOL BWSafariSynchronizationInstall(NSError **error) {
#if TARGET_OS_SIMULATOR && TARGET_OS_IOS && defined(__arm64__)
    BWSafariSynchronizationState *state = BWState();
    @synchronized (state) {
        [state->lock lock];
        BOOL alreadyInstalled = state->installed;
        [state->lock unlock];
        Class processClass = NSClassFromString(@"XCUIApplicationProcess");
        NSBundle *bundle = processClass ? [NSBundle bundleForClass:processClass] : nil;
        NSString *uuid = processClass ? BWImageUUID(class_getImageName(processClass)) : nil;
        NSDictionary *identity = @{@"bundleIdentifier": bundle.bundleIdentifier ?: @"",
            @"version": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"", @"imageUUID": uuid ?: @""};
        if (!alreadyInstalled) {
            Method method = processClass ? class_getInstanceMethod(processClass, sel_registerName(BWQuiescenceSelector)) : NULL;
            Dl_info implementationImage = {0};
            if (!method || !dladdr((const void *)method_getImplementation(method), &implementationImage) ||
                ![BWImageUUID(implementationImage.dli_fname) isEqual:BWFrameworkUUID]) {
                return BWFail(error, @"The original Safari synchronization implementation is outside the pinned XCUIAutomation image");
            }
        }
        return BWSafariSynchronizationInstallRuntime(state, processClass, identity, (IMP)BWWait, error);
    }
#else
    return BWFail(error, @"Safari synchronization requires the pinned arm64 iOS Simulator");
#endif
}

NSDictionary<NSString *, id> *BWSafariSynchronizationSnapshot(void) {
    return BWSafariSynchronizationStateSnapshot(BWState());
}
