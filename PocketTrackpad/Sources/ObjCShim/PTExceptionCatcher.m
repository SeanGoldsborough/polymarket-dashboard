//
//  PTExceptionCatcher.m
//  PocketTrackpad
//
//  See PTExceptionCatcher.h for why this file exists.
//

#import "PTExceptionCatcher.h"

NSErrorDomain const PTObjCExceptionErrorDomain = @"PocketTrackpad.ObjCException";
NSString *const PTObjCExceptionNameKey = @"PTObjCExceptionName";
NSString *const PTObjCExceptionReasonKey = @"PTObjCExceptionReason";

@implementation PTExceptionCatcher

+ (BOOL)tryBlock:(NS_NOESCAPE dispatch_block_t)block
           error:(NSError *_Nullable *_Nullable)error {
    // A nil block is a programmer error at the call site, but trapping here would
    // defeat the entire purpose of a function whose contract is "never crash".
    if (block == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:PTObjCExceptionErrorDomain
                                         code:PTObjCExceptionErrorCodeRaised
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"PTExceptionCatcher was passed a nil block.",
                PTObjCExceptionNameKey: @"PTNilBlock",
                PTObjCExceptionReasonKey: @"nil block"
            }];
        }
        return NO;
    }

    @try {
        block();
    }
    @catch (NSException *exception) {
        if (error != NULL) {
            // `exception.name` is nonnull by contract but defensive anyway: an
            // exception raised by third-party code with a nil reason is legal, and
            // stuffing nil into an NSDictionary literal throws a *second*
            // exception — from inside the @catch, where nothing would catch it.
            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: @"(no reason given)";

            NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo =
                [NSMutableDictionary dictionaryWithCapacity:4];
            userInfo[NSLocalizedDescriptionKey] =
                [NSString stringWithFormat:@"%@: %@", name, reason];
            userInfo[NSLocalizedFailureReasonErrorKey] = reason;
            userInfo[PTObjCExceptionNameKey] = name;
            userInfo[PTObjCExceptionReasonKey] = reason;

            // Deliberately NOT capturing exception.userInfo: CoreBluetooth puts
            // non-plist objects in there, and an NSError that cannot be described
            // or logged is worse than one missing a field.
            *error = [NSError errorWithDomain:PTObjCExceptionErrorDomain
                                         code:PTObjCExceptionErrorCodeRaised
                                     userInfo:userInfo];
        }
        return NO;
    }
    @finally {
        // Nothing to release — the block owns whatever it touched, and the whole
        // point of this shim is that the caller's own state is untouched by the
        // failed call. @finally is present so the intent is explicit rather than
        // implied by its absence.
    }

    if (error != NULL) {
        *error = nil;
    }
    return YES;
}

@end
