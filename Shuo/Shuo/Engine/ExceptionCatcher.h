#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and catches Objective-C exceptions, which Swift cannot. AVAudioEngine raises them
/// (instead of returning errors) when, for example, a player is started on an engine iOS has stopped.
@interface ExceptionCatcher : NSObject
/// Returns nil when the block finished, or the exception's reason when it raised one.
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
