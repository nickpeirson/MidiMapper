#import "HueAPI.h"
#import "HueBridgeDiscovery.h"

@interface HueAPI () <NSURLSessionDelegate>
@end

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
    NSString *bridgeIP = [self getBridgeIPAddress];
    if (!bridgeIP) {
        NSLog(@"Bridge IP address not found.");
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"https://%@/clip/v2/resource/grouped_light/1d70a073-d47a-4e02-931c-a35db2a8bf1e", bridgeIP];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"PUT";

    // Set the header with the application key
    NSString *applicationKey = @"hBJ7J1M4esLnNC5yfyjLPqHygpyXgmU6vNLsHXQG";
    [request setValue:applicationKey forHTTPHeaderField:@"hue-application-key"];

    // Set the JSON body
    NSDictionary *bodyDict = @{@"dimming": @{@"brightness": @(brightness)}};
    NSError *error;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:&error];
    if (!bodyData) {
        NSLog(@"Error serializing JSON: %@", error.localizedDescription);
        return;
    }
    request.HTTPBody = bodyData;

    // Create a session configuration
    NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];

    // Create the session with the delegate set to self
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfig delegate:self delegateQueue:nil];

    // Create the data task
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"Error setting brightness: %@", error.localizedDescription);
        } else {
            NSLog(@"Brightness set to %ld", (long)brightness);
        }
    }];

    [task resume];
}

// Implement NSURLSessionDelegate method to ignore SSL errors
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLCredential *credential = [[NSURLCredential alloc] initWithTrust:challenge.protectionSpace.serverTrust];
    completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
}

- (NSString *)getBridgeIPAddress {
    return [bridgeDiscovery getBridgeIPAddress];
}

@end