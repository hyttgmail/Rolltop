#import "RLTMenuBarRestriction.h"

#import <dlfcn.h>
#import <objc/message.h>

NSErrorDomain const RLTMenuBarRestrictionErrorDomain = @"com.alphapengwang.rolltop.MenuBarRestriction";

static NSString *const RLTFrameworkPath = @"/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore";
static NSString *const RLTConfigurationClassName = @"MBAssessmentModeConfiguration";
static NSString *const RLTAssertionClassName = @"MBAssessmentModeAssertion";

static SEL RLTConfigurationInit(void) { return NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"); }
static SEL RLTActivate(void) { return NSSelectorFromString(@"activateWithConfiguration:completionHandler:"); }
static SEL RLTInvalidate(void) { return NSSelectorFromString(@"invalidate"); }

static NSError *RLTError(NSInteger code, NSString *reason) {
    return [NSError errorWithDomain:RLTMenuBarRestrictionErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: reason}];
}

@implementation RLTMenuBarRestriction

+ (BOOL)isAvailable {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            if (!dlopen(RLTFrameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
                return;
            }
            Class configuration = NSClassFromString(RLTConfigurationClassName);
            Class assertion = NSClassFromString(RLTAssertionClassName);
            available = configuration && assertion
                && [configuration instancesRespondToSelector:RLTConfigurationInit()]
                && [assertion instancesRespondToSelector:@selector(init)]
                && [assertion instancesRespondToSelector:RLTActivate()]
                && [assertion instancesRespondToSelector:RLTInvalidate()];
        } @catch (NSException *exception) {
            NSLog(@"Rolltop: MenuBarClientCore probe raised %@: %@", exception.name, exception.reason);
            available = NO;
        }
    });
    return available;
}

+ (nullable id)activateWithSystemItems:(NSArray<NSNumber *> *)systemItems
                     bundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                            completion:(void (^)(NSError * _Nullable error))completion {
    // The framework may call back more than once or never; the caller gets exactly one
    // main-queue callback for the first answer (a watchdog lives in the engine).
    NSObject *lock = [NSObject new];
    __block BOOL finished = NO;
    void (^finish)(NSError *) = ^(NSError *error) {
        @synchronized (lock) {
            if (finished) { return; }
            finished = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    };

    if (![self isAvailable]) {
        finish(RLTError(1, @"MenuBarClientCore is unavailable on this macOS version"));
        return nil;
    }
    @try {
        // Both lists must be NSArrays: an NSSet raises -objectAtIndex: unrecognized.
        NSArray *items = [NSArray arrayWithArray:systemItems];
        NSArray *bundles = [NSArray arrayWithArray:bundleIdentifiers];
        id allocated = [NSClassFromString(RLTConfigurationClassName) alloc];
        id configuration = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(allocated, RLTConfigurationInit(), items, bundles);
        id assertion = [[NSClassFromString(RLTAssertionClassName) alloc] init];
        if (!configuration || !assertion) {
            finish(RLTError(2, @"Could not create the menu bar restriction"));
            return nil;
        }
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(assertion, RLTActivate(), configuration, ^(NSError *error) {
            finish(error);
        });
        return assertion;
    } @catch (NSException *exception) {
        finish(RLTError(3, [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]));
        return nil;
    }
}

+ (void)invalidate:(id)assertion {
    @try {
        if ([assertion respondsToSelector:RLTInvalidate()]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, RLTInvalidate());
        }
    } @catch (NSException *exception) {
        NSLog(@"Rolltop: invalidate raised %@: %@", exception.name, exception.reason);
    }
}

@end
