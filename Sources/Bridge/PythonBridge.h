#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface PythonBridge : NSObject
+ (BOOL)start:(NSString *)home;
+ (void)cancelRequest:(NSString *)requestID reason:(NSString *)reason;
+ (NSString *)call:(NSString *)action payload:(NSString *)payload
             event:(void (^)(NSString *))event;
@end
NS_ASSUME_NONNULL_END
