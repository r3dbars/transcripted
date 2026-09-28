#import "TranscriptedObjCSupport.h"

NSErrorDomain const TRNObjCExceptionErrorDomain = @"TranscriptedObjCException";
NSString *const TRNObjCExceptionNameKey = @"TRNObjCExceptionName";

@implementation TRNObjCExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:TRNObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason ?: @"Objective-C exception",
                                         TRNObjCExceptionNameKey: exception.name ?: @"",
                                     }];
        }
        return NO;
    }
}

@end
