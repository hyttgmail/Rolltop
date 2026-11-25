#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The only boundary to macOS 27's private MenuBarClientCore framework
/// (`MBAssessmentModeConfiguration` / `MBAssessmentModeAssertion`, see docs/PLATFORM.md §3).
/// Everything is resolved at run time and every call runs inside @try, so a changed or
/// missing private API reports "unavailable" or an error instead of crashing.
@interface RLTMenuBarRestriction : NSObject

/// Whether the framework, both classes and every selector used here resolve.
+ (BOOL)isAvailable;

/// Asks macOS to keep only the given system item ids and bundle ids visible.
/// Returns the assertion object to hold (opaque), or nil when it could not even be
/// created; `completion` then still runs with an error. `completion` always runs
/// exactly once, on the main queue. The restriction lasts until `invalidate:` or
/// until this process exits.
+ (nullable id)activateWithSystemItems:(NSArray<NSNumber *> *)systemItems
                     bundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                            completion:(void (^)(NSError * _Nullable error))completion;

/// Releases an assertion returned by `activateWithSystemItems:…`. Safe to call twice.
+ (void)invalidate:(id)assertion;

@end

FOUNDATION_EXPORT NSErrorDomain const RLTMenuBarRestrictionErrorDomain;

NS_ASSUME_NONNULL_END
