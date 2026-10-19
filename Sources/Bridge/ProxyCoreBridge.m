#import "ProxyCoreBridge.h"
#import <Clash/Clash.h>

@interface PHEmptyInterfaces : NSObject <ClashNetworkInterfaceIterator>
@end
@implementation PHEmptyInterfaces
- (int32_t)len { return 0; }
- (BOOL)hasNext { return NO; }
- (ClashNetworkInterface *)next { return nil; }
@end
@interface PHProxyPlatform : NSObject <ClashPlatformInterface>
@end
@implementation PHProxyPlatform
- (void)writeLog:(NSString *)message {}
- (BOOL)underNetworkExtension { return NO; }
- (BOOL)usePlatformAutoDetectInterfaceControl { return NO; }
- (BOOL)autoDetectInterfaceControl:(int32_t)fd error:(NSError **)error { return YES; }
- (BOOL)startDefaultInterfaceMonitor:(id<ClashInterfaceUpdateListener>)listener error:(NSError **)error { return YES; }
- (BOOL)closeDefaultInterfaceMonitor:(id<ClashInterfaceUpdateListener>)listener error:(NSError **)error { return YES; }
- (id<ClashNetworkInterfaceIterator>)getInterfaces:(NSError **)error { return [PHEmptyInterfaces new]; }
- (BOOL)openTun:(id<ClashTunOptions>)options ret0_:(int32_t *)result error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:@"PicHarbor.Proxy" code:1 userInfo:nil];
    return NO;
}
@end
@implementation ProxyCoreBridge
static ClashBoxService *service;
static BOOL configured;
static NSString *lastFailure = @"";
+ (NSString *)failureMessage { @synchronized(self) { return lastFailure ?: @""; } }
+ (void)collectStrings:(id)value into:(NSMutableArray<NSString *> *)strings {
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in value) { if (![key isEqualToString:@"type"]) [self collectStrings:value[key] into:strings]; }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id child in value) [self collectStrings:child into:strings];
    } else if ([value isKindOfClass:[NSString class]] && [value length] > 0) { [strings addObject:value]; }
}
+ (void)capture:(NSError *)error configuration:(NSString *)configuration {
    NSString *message = error.localizedDescription ?: @"Core returned no error detail";
    NSMutableArray<NSString *> *strings = [NSMutableArray new];
    id document = [NSJSONSerialization JSONObjectWithData:[configuration dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!document) { lastFailure = @"Core configuration error"; return; }
    [self collectStrings:document into:strings];
    [strings sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length > b.length ? NSOrderedAscending : (a.length < b.length ? NSOrderedDescending : NSOrderedSame);
    }];
    for (NSString *value in strings) { message = [message stringByReplacingOccurrencesOfString:value withString:@"[hidden]"]; }
    NSRegularExpression *urls = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\\\"<>]+" options:NSRegularExpressionCaseInsensitive error:nil];
    message = [urls stringByReplacingMatchesInString:message options:0 range:NSMakeRange(0, message.length) withTemplate:@"[url]"];
    lastFailure = message.length > 500 ? [message substringToIndex:500] : message;
}
+ (BOOL)prepare:(NSString *)home {
    if (configured) return YES;
    for (NSString *name in @[@"", @"working", @"temp"]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[home stringByAppendingPathComponent:name] withIntermediateDirectories:YES attributes:nil error:nil];
    }
    ClashSetupOptions *options = [ClashSetupOptions new];
    options.basePath = home; options.workingPath = [home stringByAppendingPathComponent:@"working"];
    options.tempPath = [home stringByAppendingPathComponent:@"temp"];
    options.systemDNSServerLines = ClashSystemResolverLines();
    options.memoryLimit = 96 * 1024 * 1024; options.logMaxLines = 0;
    NSError *error = nil;
    configured = ClashSetup(options, &error) && !error;
    return configured;
}
+ (NSString *)parse:(NSString *)text home:(NSString *)home {
    @synchronized(self) {
        if (![self prepare:home]) return nil;
        NSError *error = nil; ClashStringBox *box = ClashYamlToJSON(text, &error);
        return error ? nil : box.value;
    }
}
+ (BOOL)start:(NSString *)configuration home:(NSString *)home {
    @synchronized(self) {
        lastFailure = @"";
        if (![self prepare:home]) return NO;
        [self stop]; NSError *error = nil;
        service = ClashNewService([PHProxyPlatform new], &error);
        if (error || !service) { [self capture:error configuration:configuration]; service = nil; return NO; }
        BOOL success = [service start:configuration error:&error] && !error;
        if (!success) { [self capture:error configuration:configuration]; [self stop]; }
        return success;
    }
}
+ (void)stop { @synchronized(self) { NSError *error = nil; [service close:&error]; service = nil; } }
@end
