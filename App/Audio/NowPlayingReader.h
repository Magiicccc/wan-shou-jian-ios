#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface WSJNowPlayingReader : NSObject
+ (void)read:(void (^)(NSDictionary * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
