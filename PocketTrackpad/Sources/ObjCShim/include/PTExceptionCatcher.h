//
//  PTExceptionCatcher.h
//  PocketTrackpad
//
//  A four-line Objective-C shim that exists because of one specific, load-bearing
//  CoreBluetooth behaviour.
//
//  THE PROBLEM
//  -----------
//  `-[CBPeripheralManager addService:]` does not validate its argument and return
//  an error. When the service contains something iOS refuses to publish — most
//  importantly a `CBMutableDescriptor` whose UUID is anything other than
//  kCBUUIDCharacteristicUserDescriptionString or
//  kCBUUIDCharacteristicFormatString — it raises an
//  NSInternalInconsistencyException. The HOGP-mandated Report Reference
//  descriptor (0x2908) is exactly such a descriptor, so the spec-correct
//  `.perReportCharacteristic` topology cannot be attempted without risking it.
//  (`+[CBMutableDescriptor initWithType:value:]` may raise for the same reason on
//  some iOS versions — which one raises first has changed between releases — so
//  callers should wrap the descriptor construction as well as the add.)
//
//  An Objective-C exception is not a Swift error. `try` cannot catch it, `do/catch`
//  cannot catch it, and Swift's runtime has no @catch. An uncaught NSException
//  unwinds through Swift frames that were compiled without unwind tables, so the
//  process does not merely fail — it terminates, usually with a stack that blames
//  CoreBluetooth rather than us. The only supported way to survive it is to make
//  the raising call from Objective-C, inside a real @try/@catch.
//
//  Every `addService:` in `HIDPeripheralManager` therefore goes through this shim,
//  which converts the exception into an NSError and hence into a Swift `throw`.
//  That is what lets `start(topology:)` fail cleanly and lets the diagnostics
//  screen walk down the list of candidate topologies instead of crashing on the
//  first one.
//
//  WIRING IT UP
//  ------------
//  * Xcode app target: add `#import "PTExceptionCatcher.h"` to the target's
//    Objective-C bridging header. No import statement is needed in Swift.
//  * SwiftPM: declare `Sources/ObjCShim` as a C target with
//    `publicHeadersPath: "include"` (this directory layout is already the
//    convention SwiftPM expects) and `import ObjCShim` from the Swift target.
//
//  Because the method returns BOOL, takes `NSError **` as its final parameter, and
//  names that parameter `error`, Swift imports it as a throwing function:
//
//      try PTExceptionCatcher.tryBlock { peripheral.add(service) }
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// NSError domain for exceptions converted by this shim.
FOUNDATION_EXPORT NSErrorDomain const PTObjCExceptionErrorDomain;

/// userInfo key carrying the original `NSException.name`.
FOUNDATION_EXPORT NSString *const PTObjCExceptionNameKey;

/// userInfo key carrying the original `NSException.reason`.
FOUNDATION_EXPORT NSString *const PTObjCExceptionReasonKey;

/// Error codes within `PTObjCExceptionErrorDomain`.
typedef NS_ERROR_ENUM(PTObjCExceptionErrorDomain, PTObjCExceptionErrorCode) {
    /// An NSException was raised and caught. `userInfo` carries name and reason.
    PTObjCExceptionErrorCodeRaised = 1
};

@interface PTExceptionCatcher : NSObject

/// Run `block`, converting any NSException it raises into an NSError.
///
/// @param block The work to attempt. Non-escaping: it is invoked exactly once,
///        synchronously, before this method returns, so Swift callers may capture
///        and mutate local state inside it.
/// @param error On return, populated when the block raised. Domain is
///        `PTObjCExceptionErrorDomain`; `localizedDescription` is
///        "<name>: <reason>"; `userInfo` also carries the name and reason
///        separately under `PTObjCExceptionNameKey` / `PTObjCExceptionReasonKey`
///        so a caller can branch on the exception class without string matching.
/// @return YES if the block completed normally, NO if it raised.
///
/// @warning This catches NSException only. It does NOT catch Swift runtime traps
///          (force-unwrap of nil, array bounds, integer overflow, `fatalError`) —
///          those are not exceptions and are not recoverable by any means. It is
///          also NOT a general-purpose error handling mechanism: an Objective-C
///          exception generally means the framework's internal state is already
///          suspect. It is used here only because CoreBluetooth gives no
///          alternative, and only around `addService:`/descriptor construction,
///          which are pure input validation and leave nothing half-built.
+ (BOOL)tryBlock:(NS_NOESCAPE dispatch_block_t)block
           error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
