#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for an Objective-C exception caught by
/// `TRNObjCExceptionCatcher`. `userInfo` carries the exception's name under
/// `TRNObjCExceptionNameKey` and its reason as the localized description.
extern NSErrorDomain const TRNObjCExceptionErrorDomain;
extern NSString *const TRNObjCExceptionNameKey;

/// Swift cannot catch an Objective-C exception; one that escapes an Apple API
/// call ends the process. Some AVFoundation calls raise instead of returning
/// an error (`-[AVAudioNode installTapOnBus:...]` raises on a format mismatch
/// when the input route changes underneath it), so wrap those calls here.
///
/// Only wrap a single framework call whose exception is a documented,
/// recoverable condition. The block must not own resources that need
/// cleanup on unwind: Swift frames do not run `defer` during an Objective-C
/// exception, so anything the block allocates before the raise can leak.
@interface TRNObjCExceptionCatcher : NSObject

/// Runs `block` and returns YES. If it raises an Objective-C exception,
/// returns NO and fills `error` instead of letting the exception escape.
+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
