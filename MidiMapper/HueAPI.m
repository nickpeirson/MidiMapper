#import "HueAPI.h"
#import "HueBridgeDiscovery.h"

@implementation HueAPI {
    HueBridgeDiscovery *bridgeDiscovery;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSLog(@"HueAPI initialized");
        bridgeDiscovery = [[HueBridgeDiscovery alloc] init];
        [bridgeDiscovery discoverBridge];
    }
    return self;
}

- (void)setBrightness:(NSInteger)brightness {
    // Stubbed method: Implement the actual API call to set brightness
    NSLog(@"Setting brightness to %ld", (long)brightness);
}

- (NSString *)getBridgeIPAddress {
    return [bridgeDiscovery getBridgeIPAddress];
}

@end