#import <arpa/inet.h>
#import <netinet/in.h>
#import "HueAPI.h"
#import <dns_sd.h>

@implementation HueAPI

- (instancetype)init {
    self = [super init];
    if (self) {
        NSLog(@"HueAPI initialized");
        [self discoverBridge];
    }
    return self;
}

- (void)setBrightness:(NSInteger)brightness {
    // Stubbed method: Implement the actual API call to set brightness
    NSLog(@"Setting brightness to %ld", (long)brightness);
}

- (void)discoverBridge {
    DNSServiceRef serviceRef;
    DNSServiceErrorType error = DNSServiceBrowse(&serviceRef, 0, 0, "_hue._tcp", NULL, browseCallback, (__bridge void *)(self));
    if (error != kDNSServiceErr_NoError) {
        NSLog(@"Error discovering Hue bridge: %d", error);
    } else {
        // Schedule the serviceRef on a dispatch queue
        DNSServiceSetDispatchQueue(serviceRef, dispatch_get_main_queue());
    }
}

static void browseCallback(DNSServiceRef serviceRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *serviceName, const char *regtype, const char *replyDomain, void *context) {
    if (errorCode == kDNSServiceErr_NoError) {
        HueAPI *hueAPI = (__bridge HueAPI *)context;
        DNSServiceRef resolveRef;
        DNSServiceErrorType error = DNSServiceResolve(&resolveRef, 0, interfaceIndex, serviceName, regtype, replyDomain, resolveCallback, (__bridge void *)(hueAPI));
        if (error != kDNSServiceErr_NoError) {
            NSLog(@"Error resolving Hue bridge: %d", error);
        } else {
            NSLog(@"Resolved Hue bridge (domain): %s", replyDomain);
            // Schedule the resolveRef on a dispatch queue
            DNSServiceSetDispatchQueue(resolveRef, dispatch_get_main_queue());
        }
    }
}

static void resolveCallback(DNSServiceRef serviceRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *fullname, const char *hosttarget, uint16_t port, uint16_t txtLen, const unsigned char *txtRecord, void *context) {
    if (errorCode == kDNSServiceErr_NoError) {
        HueAPI *hueAPI = (__bridge HueAPI *)context;
        char ip[INET6_ADDRSTRLEN];
        DNSServiceRef addrRef;
        DNSServiceErrorType error = DNSServiceGetAddrInfo(&addrRef, 0, interfaceIndex, kDNSServiceProtocol_IPv4, hosttarget, addrInfoCallback, (__bridge void *)(hueAPI));
        if (error != kDNSServiceErr_NoError) {
            NSLog(@"Error getting address info for Hue bridge: %d", error);
        } else {
            NSLog(@"Resolved Hue bridge: %s", hosttarget);
            // Schedule the addrRef on a dispatch queue
            DNSServiceSetDispatchQueue(addrRef, dispatch_get_main_queue());
        }
    }
}

static void addrInfoCallback(DNSServiceRef serviceRef, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *hostname, const struct sockaddr *address, uint32_t ttl, void *context) {
    if (errorCode == kDNSServiceErr_NoError) {
        HueAPI *hueAPI = (__bridge HueAPI *)context;
        char ip[INET6_ADDRSTRLEN];
        if (address->sa_family == AF_INET) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)address)->sin_addr, ip, sizeof(ip));
        } else if (address->sa_family == AF_INET6) {
            inet_ntop(AF_INET6, &((struct sockaddr_in6 *)address)->sin6_addr, ip, sizeof(ip));
        }
        hueAPI.bridgeIPAddress = [NSString stringWithUTF8String:ip];
        NSLog(@"Discovered Hue bridge at IP: %@", hueAPI.bridgeIPAddress);
    }
}

@end
