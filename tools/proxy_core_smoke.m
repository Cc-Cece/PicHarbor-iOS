#import <Foundation/Foundation.h>
#import "ProxyCoreBridge.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
        NSArray *cases = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        for (NSDictionary *entry in cases) {
            NSData *payload = [NSJSONSerialization dataWithJSONObject:entry[@"configuration"] options:NSJSONWritingWithoutEscapingSlashes | NSJSONWritingSortedKeys error:nil];
            BOOL success = [ProxyCoreBridge start:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] home:home];
            NSDictionary *result = @{@"case": entry[@"name"], @"started": @(success), @"detail": [ProxyCoreBridge failureMessage]};
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
            [ProxyCoreBridge stop];
        }
    }
    return 0;
}
