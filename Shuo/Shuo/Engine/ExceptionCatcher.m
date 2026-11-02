#import "ExceptionCatcher.h"

@implementation ExceptionCatcher

+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}

@end
