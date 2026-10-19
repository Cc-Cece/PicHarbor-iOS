#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface ProxyCoreBridge : NSObject
+ (nullable NSString *)parse:(NSString *)text home:(NSString *)home;
+ (BOOL)start:(NSString *)configuration home:(NSString *)home;
+ (NSString *)failureMessage;
+ (void)stop;
@end
NS_ASSUME_NONNULL_END
