//
//  ActionContext.h
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ActionContext : NSObject

// Event identification
@property (nonatomic, readonly) uint64_t eventId;
@property (nonatomic, strong, readonly) NSDate *receivedAt;

// Raw MIDI data
@property (nonatomic) UInt8 status;
@property (nonatomic) UInt8 data1;
@property (nonatomic) UInt8 data2;

// 14-bit command data (if applicable)
@property (nonatomic) BOOL isFourteenBit;
@property (nonatomic) NSUInteger msbControllerNumber;
@property (nonatomic) NSUInteger msbControllerValue;
@property (nonatomic) NSUInteger lsbControllerNumber;
@property (nonatomic) NSUInteger lsbControllerValue;

// Mapping details
@property (nonatomic, copy, nullable) NSString *controlKey;
@property (nonatomic, copy, nullable) NSString *matchedActionName;
@property (nonatomic) BOOL actionFound;

// Execution details
@property (nonatomic, copy, nullable) NSString *backend;  // "Spotify", "AppleScript", "Hue", "None"
@property (nonatomic, strong, nullable) NSDate *enqueuedAt;
@property (nonatomic, strong, nullable) NSDate *startedAt;
@property (nonatomic, strong, nullable) NSDate *finishedAt;
@property (nonatomic) NSTimeInterval durationMs;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, copy, nullable) NSDictionary *errorDict;  // For AppleScript errors
@property (nonatomic) BOOL wasThrottled;
@property (nonatomic) BOOL didTimeout;

// Timeout cancellation token (incremented to invalidate scheduled timeouts)
@property (atomic, assign) uint64_t timeoutToken;

// Factory method - creates context with unique eventId and current timestamp
+ (instancetype)contextWithStatus:(UInt8)status data1:(UInt8)data1 data2:(UInt8)data2;

// Convenience initializer for 14-bit commands
+ (instancetype)contextWithStatus:(UInt8)status
                   msbControllerNumber:(NSUInteger)msbNum
                   msbControllerValue:(NSUInteger)msbVal
                   lsbControllerNumber:(NSUInteger)lsbNum
                   lsbControllerValue:(NSUInteger)lsbVal;

// Lifecycle methods
- (void)markEnqueued;
- (void)markStarted;
- (void)markFinished;
- (void)markFinishedWithError:(nullable NSError *)error;
- (void)markFinishedWithErrorDict:(nullable NSDictionary *)errorDict;
- (void)markThrottled;
- (void)markTimeout;

// Logging helpers
- (NSString *)logPrefix;
- (NSString *)midiDescription;
- (NSString *)timingDescription;

@end

NS_ASSUME_NONNULL_END
