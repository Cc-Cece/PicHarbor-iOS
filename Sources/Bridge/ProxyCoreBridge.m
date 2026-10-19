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
        if (![self prepare:home]) return NO;
        [self stop]; NSError *error = nil;
        service = ClashNewService([PHProxyPlatform new], &error);
        if (error || !service) { service = nil; return NO; }
        BOOL success = [service start:configuration error:&error] && !error;
        if (!success) [self stop];
        return success;
    }
}
+ (void)stop { @synchronized(self) { NSError *error = nil; [service close:&error]; service = nil; } }
@end
