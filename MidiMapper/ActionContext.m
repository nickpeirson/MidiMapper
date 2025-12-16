//
//  ActionContext.m
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import "ActionContext.h"
#import <stdatomic.h>

static atomic_uint_fast64_t sNextEventId = 1;

@implementation ActionContext

+ (instancetype)contextWithStatus:(UInt8)status data1:(UInt8)data1 data2:(UInt8)data2 {
    ActionContext *ctx = [[ActionContext alloc] init];
    ctx->_eventId = atomic_fetch_add(&sNextEventId, 1);
    ctx->_receivedAt = [NSDate date];
    ctx.status = status;
    ctx.data1 = data1;
    ctx.data2 = data2;
    ctx.isFourteenBit = NO;
    return ctx;
}

+ (instancetype)contextWithStatus:(UInt8)status
                   msbControllerNumber:(NSUInteger)msbNum
                   msbControllerValue:(NSUInteger)msbVal
                   lsbControllerNumber:(NSUInteger)lsbNum
                   lsbControllerValue:(NSUInteger)lsbVal {
    ActionContext *ctx = [[ActionContext alloc] init];
    ctx->_eventId = atomic_fetch_add(&sNextEventId, 1);
    ctx->_receivedAt = [NSDate date];
    ctx.status = status;
    ctx.data1 = (UInt8)msbNum;
    ctx.data2 = (UInt8)msbVal;
    ctx.isFourteenBit = YES;
    ctx.msbControllerNumber = msbNum;
    ctx.msbControllerValue = msbVal;
    ctx.lsbControllerNumber = lsbNum;
    ctx.lsbControllerValue = lsbVal;
    return ctx;
}

- (void)markEnqueued {
    self.enqueuedAt = [NSDate date];
}

- (void)markStarted {
    self.startedAt = [NSDate date];
}

- (void)markFinished {
    self.finishedAt = [NSDate date];
    if (self.startedAt) {
        self.durationMs = [self.finishedAt timeIntervalSinceDate:self.startedAt] * 1000.0;
    }
}

- (void)markFinishedWithError:(NSError *)error {
    [self markFinished];
    self.error = error;
}

- (void)markFinishedWithErrorDict:(NSDictionary *)errorDict {
    [self markFinished];
    self.errorDict = errorDict;
}

- (void)markThrottled {
    self.wasThrottled = YES;
}

- (void)markTimeout {
    self.didTimeout = YES;
    [self markFinished];
}

- (NSString *)logPrefix {
    NSMutableString *prefix = [NSMutableString stringWithFormat:@"[ev=%llu", self.eventId];
    
    if (self.controlKey) {
        [prefix appendFormat:@" key=%@", self.controlKey];
    }
    if (self.matchedActionName) {
        [prefix appendFormat:@" action=%@", self.matchedActionName];
    }
    if (self.backend) {
        [prefix appendFormat:@" backend=%@", self.backend];
    }
    
    [prefix appendString:@"]"];
    return prefix;
}

- (NSString *)midiDescription {
    if (self.isFourteenBit) {
        return [NSString stringWithFormat:@"14bit status=%d MSB(ctrl=%lu,val=%lu) LSB(ctrl=%lu,val=%lu)",
                self.status,
                (unsigned long)self.msbControllerNumber,
                (unsigned long)self.msbControllerValue,
                (unsigned long)self.lsbControllerNumber,
                (unsigned long)self.lsbControllerValue];
    } else {
        return [NSString stringWithFormat:@"7bit status=%d data1=%d data2=%d",
                self.status, self.data1, self.data2];
    }
}

- (NSString *)timingDescription {
    NSMutableString *desc = [NSMutableString string];
    
    if (self.enqueuedAt && self.receivedAt) {
        NSTimeInterval queueDelay = [self.enqueuedAt timeIntervalSinceDate:self.receivedAt] * 1000.0;
        [desc appendFormat:@"queueDelay=%.1fms ", queueDelay];
    }
    
    if (self.startedAt && self.enqueuedAt) {
        NSTimeInterval waitTime = [self.startedAt timeIntervalSinceDate:self.enqueuedAt] * 1000.0;
        [desc appendFormat:@"waitTime=%.1fms ", waitTime];
    }
    
    if (self.durationMs > 0) {
        [desc appendFormat:@"execTime=%.1fms", self.durationMs];
    }
    
    return desc;
}

@end
