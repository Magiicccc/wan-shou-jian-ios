#import "NowPlayingReader.h"
#import <dlfcn.h>
#import <TargetConditionals.h>

@implementation WSJNowPlayingReader
+ (void)read:(void (^)(NSDictionary * _Nullable))completion {
#if TARGET_OS_SIMULATOR
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
#else
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    });
    typedef void (*ReadInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
    ReadInfo readInfo = handle ? (ReadInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!readInfo) { completion(nil); return; }
    // Both callbacks are serialized on main; some system versions never answer.
    __block BOOL finished = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!finished) { finished = YES; completion(nil); }
    });
    readInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *raw = [(__bridge NSDictionary *)info copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            NSDictionary *fields = @{@"title": @"Title", @"artist": @"Artist", @"album": @"Album",
                                     @"duration": @"Duration", @"elapsed": @"ElapsedTime",
                                     @"rate": @"PlaybackRate", @"timestamp": @"Timestamp"};
            for (NSString *field in fields) {
                NSString *symbol = [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:fields[field]];
                CFStringRef *key = (CFStringRef *)dlsym(handle, symbol.UTF8String);
                id value = raw[key && *key ? (__bridge NSString *)*key : symbol];
                if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSDate.class]) {
                    result[field] = value;
                }
            }
            completion(result.count ? result : nil);
        });
    });
#endif
}
@end
