#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#import "friday_host.h"

extern "C" size_t friday_host_spike_json(char *buffer, size_t capacity) {
    if (buffer == nullptr || capacity == 0) return 0;

    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unbundled";
        NSDictionary *payload = @{
            @"bridge": @"ok",
            @"platform": @"macos",
            @"architecture": @"arm64",
            @"bundleIdentifier": bundleID,
            @"accessibilityTrusted": @(AXIsProcessTrusted()),
            @"inputMonitoringUsable": @(CGPreflightListenEventAccess()),
        };
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
        if (json == nil || error != nil || json.length >= capacity) return 0;
        memcpy(buffer, json.bytes, json.length);
        buffer[json.length] = '\0';
        return json.length;
    }
}
