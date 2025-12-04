#import "HueAPI.h"
#import "HueBridgeDiscovery.h"

@interface HueAPI () <NSURLSessionDelegate>
- (NSString *)generateUniqueKeyForResourceType:(NSString *)resourceType resourceID:(NSString *)resourceID bodyDict:(NSDictionary *)bodyDict {
    return [NSString stringWithFormat:@"%@_%@_%@", resourceType, resourceID, bodyDict.allKeys.firstObject];
}

- (void)performPUTForResourceType:(NSString *)resourceType
                       resourceID:(NSString *)resourceID
                         bodyDict:(NSDictionary *)bodyDict
                       completion:(void (^)(NSError *error))completion;

@end

@implementation HueAPI {
    HueBridgeDiscovery *bridgeDiscovery;
    NSMutableDictionary *pendingRequests;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSLog(@"HueAPI initialized");
        bridgeDiscovery = [[HueBridgeDiscovery alloc] init];
        [bridgeDiscovery discoverBridge];
        pendingRequests = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)performPUTForResourceType:(NSString *)resourceType
                       resourceID:(NSString *)resourceID
                         bodyDict:(NSDictionary *)bodyDict
                       completion:(void (^)(NSError *error))completion {
    NSString *bridgeIP = [self getBridgeIPAddress];
    if (!bridgeIP) {
        NSLog(@"Bridge IP address not found.");
        if (completion) completion([NSError errorWithDomain:@"HueAPI" code:0 userInfo:nil]);
        return;
    }
    NSString *uniqueKey = [self generateUniqueKeyForResourceType:resourceType resourceID:resourceID bodyDict:bodyDict];
    if (pendingRequests[uniqueKey]) {
        // Replace or queue new body
        pendingRequests[uniqueKey] = bodyDict;
        return;
    }
    pendingRequests[uniqueKey] = bodyDict;
    NSString *urlString = [NSString stringWithFormat:@"https://%@/clip/v2/resource/%@/%@", bridgeIP, resourceType, resourceID];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"PUT";

    // Set the header with the application key
    NSString *applicationKey = @"hBJ7J1M4esLnNC5yfyjLPqHygpyXgmU6vNLsHXQG";
    [request setValue:applicationKey forHTTPHeaderField:@"hue-application-key"];

    // Set the JSON body
    NSError *error;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:&error];
    if (!bodyData) {
        NSLog(@"Error serializing JSON: %@", error.localizedDescription);
        if (completion) completion(error);
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
        NSDictionary *queuedBody = pendingRequests[uniqueKey];
        pendingRequests[uniqueKey] = nil;
        if (completion) completion(error);
        if ([queuedBody isKindOfClass:[NSDictionary class]] && !error) {
            [self performPUTForResourceType:resourceType resourceID:resourceID bodyDict:queuedBody completion:nil];
        }
    }];
    [task resume];
}

- (void)setBrightness:(NSInteger)brightness forResourceType:(NSString *)resourceType resourceID:(NSString *)resourceID {
    NSDictionary *bodyDict = @{@"dimming": @{@"brightness": @(brightness)}};
    [self performPUTForResourceType:resourceType resourceID:resourceID bodyDict:bodyDict completion:^(NSError *error) {
        if (error) {
            NSLog(@"Error setting brightness: %@", error.localizedDescription);
        } else {
            NSLog(@"Brightness set to %ld", (long)brightness);
        }
    }];
}

- (void)setColorTemperature:(NSInteger)temperature forResourceType:(NSString *)resourceType resourceID:(NSString *)resourceID {
    NSLog(@"Setting color temperature: %ld", (long)temperature);
    NSDictionary *bodyDict = @{@"color_temperature": @{@"mirek": @(temperature)}};
    [self performPUTForResourceType:resourceType resourceID:resourceID bodyDict:bodyDict completion:^(NSError *error) {
        if (error) {
            NSLog(@"Error setting color temperature: %@", error.localizedDescription);
        } else {
            NSLog(@"Color temperature set to %ld", (long)temperature);
        }
    }];
}

- (void)changeColorTemperatureBy:(NSInteger)delta forResourceType:(NSString *)resourceType resourceID:(NSString *)resourceID {
    NSLog(@"Changing color temperature by offset: %ld for resourceType: %@ resourceID: %@", (long)delta, resourceType, resourceID);
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