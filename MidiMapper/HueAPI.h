#import <Foundation/Foundation.h>

@interface HueAPI : NSObject

@property (nonatomic, strong) NSString *bridgeIPAddress;

- (void)setBrightness:(NSInteger)brightness forResourceType:(NSString *)resourceType resourceID:(NSString *)resourceID;

@end
