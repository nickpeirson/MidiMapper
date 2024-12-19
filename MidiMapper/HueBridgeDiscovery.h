#import <Foundation/Foundation.h>

@interface HueBridgeDiscovery : NSObject

@property (nonatomic, strong, readonly) NSString *bridgeIPAddress;

- (void)discoverBridge;
- (NSString *)getBridgeIPAddress;

@end