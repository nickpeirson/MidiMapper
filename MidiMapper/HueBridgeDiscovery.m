#import "HueBridgeDiscovery.h"
#import "DedupingLogger.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <dns_sd.h>

@interface HueBridgeDiscovery ()
- (BOOL)startService:(DNSServiceRef)ref;
- (void)finishService:(DNSServiceRef)ref;
@end

@implementation HueBridgeDiscovery {
    DNSServiceRef browseRef;
    NSMutableSet<NSValue *> *services;
    void (^releaseService)(DNSServiceRef);
}

- (instancetype)init {
    return [self initWithReleaseService:^(DNSServiceRef ref) { DNSServiceRefDeallocate(ref); }];
}

// All DNS-SD callbacks and ownership changes run on the main queue.
- (instancetype)initWithReleaseService:(void (^)(DNSServiceRef))release {
    if ((self = [super init])) {
        services = [NSMutableSet set];
        releaseService = [release copy];
    }
    return self;
}

- (BOOL)startService:(DNSServiceRef)ref {
    [services addObject:[NSValue valueWithPointer:ref]];
    DNSServiceErrorType error = DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
    if (error != kDNSServiceErr_NoError) {
        MMLogError(@"Hue", @"Error scheduling discovery: %d", error);
        [self finishService:ref];
        return NO;
    }
    return YES;
}

- (void)finishService:(DNSServiceRef)ref {
    NSValue *value = [NSValue valueWithPointer:ref];
    if ([services containsObject:value]) {
        [services removeObject:value];
        if (browseRef == ref) browseRef = NULL;
        releaseService(ref);
    }
}

- (void)dealloc {
    for (NSValue *value in services) releaseService(value.pointerValue);
}

- (void)discoverBridge {
    if (browseRef) return;
    DNSServiceRef ref = NULL;
    DNSServiceErrorType error = DNSServiceBrowse(&ref, 0, 0, "_hue._tcp", NULL, browseCallback, (__bridge void *)(self));
    if (error != kDNSServiceErr_NoError) {
        MMLogError(@"Hue", @"Error discovering Hue bridge: %d", error);
    } else if ([self startService:ref]) {
        browseRef = ref;
    }
}

- (NSString *)getBridgeIPAddress { return self.bridgeIPAddress; }

static void browseCallback(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *serviceName, const char *regtype, const char *replyDomain, void *context) {
    HueBridgeDiscovery *discovery = (__bridge HueBridgeDiscovery *)context;
    if (errorCode != kDNSServiceErr_NoError) {
        MMLogError(@"Hue", @"Browse failed: %d", errorCode);
        [discovery finishService:ref];
        return;
    }
    if (!(flags & kDNSServiceFlagsAdd)) return;
    DNSServiceRef resolveRef = NULL;
    DNSServiceErrorType error = DNSServiceResolve(&resolveRef, 0, interfaceIndex, serviceName, regtype, replyDomain, resolveCallback, context);
    if (error != kDNSServiceErr_NoError) MMLogError(@"Hue", @"Error resolving Hue bridge: %d", error);
    else [discovery startService:resolveRef];
}

static void resolveCallback(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *fullname, const char *hosttarget, uint16_t port, uint16_t txtLen, const unsigned char *txtRecord, void *context) {
    HueBridgeDiscovery *discovery = (__bridge HueBridgeDiscovery *)context;
    if (errorCode == kDNSServiceErr_NoError) {
        DNSServiceRef addrRef = NULL;
        DNSServiceErrorType error = DNSServiceGetAddrInfo(&addrRef, 0, interfaceIndex, kDNSServiceProtocol_IPv4, hosttarget, addrInfoCallback, context);
        if (error != kDNSServiceErr_NoError) MMLogError(@"Hue", @"Error getting address info: %d", error);
        else [discovery startService:addrRef];
    } else MMLogError(@"Hue", @"Resolve failed: %d", errorCode);
    [discovery finishService:ref];
}

static void addrInfoCallback(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType errorCode, const char *hostname, const struct sockaddr *address, uint32_t ttl, void *context) {
    HueBridgeDiscovery *discovery = (__bridge HueBridgeDiscovery *)context;
    if (errorCode == kDNSServiceErr_NoError && address && (flags & kDNSServiceFlagsAdd) && address->sa_family == AF_INET) {
        char ip[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &((const struct sockaddr_in *)address)->sin_addr, ip, sizeof(ip))) {
            discovery->_bridgeIPAddress = [NSString stringWithUTF8String:ip];
            MMLogInfo(@"Hue", @"Discovered Hue bridge at IP: %@", discovery.bridgeIPAddress);
        }
    } else if (errorCode != kDNSServiceErr_NoError) MMLogError(@"Hue", @"Address lookup failed: %d", errorCode);
    [discovery finishService:ref];
}
@end
