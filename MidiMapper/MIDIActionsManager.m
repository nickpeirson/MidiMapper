//
//  MIDIActionsManager.m
//  MidiMapper
//
//  Created by Nick Peirson on 28/05/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

// MIDIActionsManager.m
#import "HueAPI.h"
#import "MIDIActionsManager.h"
#import "DedupingLogger.h"
#import "ActionContext.h"
#import "SystemVolumeController.h"
#import <Carbon/Carbon.h>   // for kAENoReply, etc.
#import <stdatomic.h>

// Queue health thresholds
static const uint64_t kInFlightWarningThreshold = 8;
static const NSTimeInterval kLongActionThresholdMs = 2000.0;
static const NSTimeInterval kHealthLogIntervalSeconds = 30.0;

// Blocking action protection
static const NSTimeInterval kBlockingActionTimeoutSeconds = 5.0;
static const NSTimeInterval kBlockingGroupCooldownSeconds = 5.0;

double const SLIDER_SCALE_FACTOR = 0.787;

NSString *const PLAYBACK_BUTTONS_ID = @"14";
NSString *const PLAYBACK_BUTTON_PAUSE_PRESSED = @"67";
NSString *const PLAYBACK_BUTTON_PLAY_PRESSED = @"68";

NSString *const TRACK_BUTTONS_ID = @"10";
NSString *const TRACK_BUTTON_PREV_PRESSED = @"65";
NSString *const TRACK_BUTTON_NEXT_PRESSED = @"67";

NSString *const SLIDER_0_CONTROLS = @"0";
NSString *const SLIDER_1_CONTROLS = @"1";
NSString *const SLIDER_2_CONTROLS = @"2";
NSString *const SLIDER_3_CONTROLS = @"3";
NSString *const SLIDER_4_CONTROLS = @"4";
NSString *const SLIDER_5_CONTROLS = @"5";
NSString *const SLIDER_6_CONTROLS = @"6";
NSString *const SLIDER_7_CONTROLS = @"7";
NSString *const SLIDER_M_BUTTON_PRESSED = @"66";
NSString *const SLIDER_M_BUTTON_RELEASED = @"2";

NSString *const KNOB_0 = @"64";
NSString *const KNOB_1 = @"64";
NSString *const KNOB_2 = @"64";

NSString *const KNOB_MIN = @"63";
NSString *const KNOB_MAX = @"127";
NSString *const KNOB_INCREMENT = @"65";
NSString *const KNOB_DECREMENT = @"1";



@implementation MIDIActionsManager {
    NSDictionary *playbackButtonMap;
    NSDictionary *trackButtonMap;
    NSDictionary *slider0ButtonMap;
    NSDictionary *slider1ButtonMap;
    NSDictionary *knob0Map;
    NSDictionary<NSString *, id> *controlToActionMap;
    NSDictionary<NSString *, NSString *> *actionNameMap;  // Maps control:actionId to human-readable name
    NSDictionary<NSString *, NSString *> *actionGroupMap; // Maps actionName to blocking group (e.g., "spotify", "applescript")
    NSDictionary<NSString *, id> *sliderActions;
    NSDictionary<NSString *, NSString *> *sliderActionNames;  // Maps control to human-readable name
    NSDictionary<NSString *, NSString *> *sliderActionGroups; // Maps control to blocking group
    NSMutableDictionary<NSString *, NSAppleScript *> *scriptCache;
    NSString *currentControl;
    UInt8 currentControlId;
    SpotifyApplication *spotifyApp;
    HueAPI *hueAPI;
    dispatch_queue_t actionQueue;   // serial queue for bookkeeping and coordination
    dispatch_queue_t blockingActionQueue;  // concurrent queue for potentially blocking actions
    dispatch_queue_t timeoutQueue;   // serial queue for timeout scheduling (avoids actionQueue backlog)
    NSMutableDictionary<NSString *, NSNumber *> *pendingSliderValues;  // latest value per slider
    NSMutableDictionary<NSString *, NSNumber *> *sliderUpdateScheduled; // whether update is scheduled
    
    // Queue health metrics
    atomic_uint_fast64_t actionsEnqueued;
    atomic_uint_fast64_t actionsStarted;
    atomic_uint_fast64_t actionsFinished;
    atomic_uint_fast64_t actionsInFlight;
    NSDate *lastHealthLog;
    
    // Blocking action protection
    NSMutableSet<NSString *> *blockingGroupsInFlight;
    NSMutableDictionary<NSString *, NSDate *> *blockingGroupCooldownUntil;
    NSMutableDictionary<NSNumber *, NSNumber *> *blockingActionTimedOut;  // eventId -> YES if timed out
    NSLock *blockingStateLock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        spotifyApp = [SBApplication applicationWithBundleIdentifier:@"com.spotify.client"];
        
        // Fire-and-forget AppleEvents to Spotify with reasonable timeout
        [spotifyApp setSendMode:kAENoReply];
        [spotifyApp setTimeout:5 * 60];  // 5 second timeout (in ticks: 60 ticks/sec)
        
        scriptCache = [NSMutableDictionary dictionaryWithCapacity:200];
        hueAPI = [[HueAPI alloc] init];
        
        // Serial queue for bookkeeping and coordination
        actionQueue = dispatch_queue_create("com.nickpeirson.MidiMapper.actions", DISPATCH_QUEUE_SERIAL);
        
        // Concurrent queue for potentially blocking actions (Spotify, AppleScript)
        blockingActionQueue = dispatch_queue_create("com.nickpeirson.MidiMapper.blockingActions", DISPATCH_QUEUE_CONCURRENT);
        
        // Serial queue for timeout scheduling (fires even if actionQueue is backlogged)
        timeoutQueue = dispatch_queue_create("com.nickpeirson.MidiMapper.timeoutQueue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(timeoutQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        
        // Throttling state for sliders
        pendingSliderValues = [NSMutableDictionary dictionary];
        sliderUpdateScheduled = [NSMutableDictionary dictionary];
        
        // Initialize queue health metrics
        atomic_store(&actionsEnqueued, 0);
        atomic_store(&actionsStarted, 0);
        atomic_store(&actionsFinished, 0);
        atomic_store(&actionsInFlight, 0);
        lastHealthLog = [NSDate date];
        
        // Initialize blocking action protection
        blockingGroupsInFlight = [NSMutableSet set];
        blockingGroupCooldownUntil = [NSMutableDictionary dictionary];
        blockingActionTimedOut = [NSMutableDictionary dictionary];
        blockingStateLock = [[NSLock alloc] init];
        
        [self initMaps];
        
        NSLog(@"[INIT] MIDIActionsManager initialized");
    }
    return self;
}

NSString* byteToStr(UInt8 byte)
{
    return [NSString stringWithFormat:@"%d", byte];
}

#pragma mark - Queue Health

- (void)logHealthIfNeeded {
    uint64_t inFlight = atomic_load(&actionsInFlight);
    NSDate *now = [NSDate date];
    
    BOOL shouldLog = (inFlight > kInFlightWarningThreshold) ||
                     ([now timeIntervalSinceDate:lastHealthLog] >= kHealthLogIntervalSeconds);
    
    if (shouldLog) {
        uint64_t enq = atomic_load(&actionsEnqueued);
        uint64_t start = atomic_load(&actionsStarted);
        uint64_t fin = atomic_load(&actionsFinished);
        
        NSLog(@"[HEALTH] inFlight=%llu enq=%llu start=%llu fin=%llu",
              inFlight, enq, start, fin);
        lastHealthLog = now;
    }
}

- (void)actionWillEnqueue {
    atomic_fetch_add(&actionsEnqueued, 1);
}

- (void)actionDidStart {
    atomic_fetch_add(&actionsStarted, 1);
    atomic_fetch_add(&actionsInFlight, 1);
    [self logHealthIfNeeded];
}

- (void)actionDidFinishWithDuration:(NSTimeInterval)durationMs {
    atomic_fetch_add(&actionsFinished, 1);
    atomic_fetch_sub(&actionsInFlight, 1);
    
    if (durationMs > kLongActionThresholdMs) {
        NSLog(@"[HEALTH] Long action detected: %.1fms (threshold: %.1fms)", durationMs, kLongActionThresholdMs);
    }
}

#pragma mark - Blocking Action Protection

- (NSString *)blockingGroupForActionName:(NSString *)actionName {
    return actionGroupMap[actionName];
}

- (NSString *)blockingGroupForSliderControl:(NSString *)control {
    return sliderActionGroups[control];
}

- (BOOL)isBlockingGroup:(NSString *)groupKey {
    // Groups that are known to potentially block
    return groupKey != nil;
}

- (BOOL)canExecuteBlockingGroup:(NSString *)groupKey reason:(NSString **)outReason {
    if (!groupKey) {
        return YES;  // Non-blocking action
    }
    
    [blockingStateLock lock];
    
    // Check cooldown
    NSDate *cooldownUntil = blockingGroupCooldownUntil[groupKey];
    if (cooldownUntil && [[NSDate date] compare:cooldownUntil] == NSOrderedAscending) {
        [blockingStateLock unlock];
        if (outReason) {
            *outReason = [NSString stringWithFormat:@"group '%@' in cooldown until %@", groupKey, cooldownUntil];
        }
        return NO;
    }
    
    // Check if already in flight
    if ([blockingGroupsInFlight containsObject:groupKey]) {
        [blockingStateLock unlock];
        if (outReason) {
            *outReason = [NSString stringWithFormat:@"group '%@' already in flight", groupKey];
        }
        return NO;
    }
    
    [blockingStateLock unlock];
    return YES;
}

- (void)markBlockingGroupInFlight:(NSString *)groupKey {
    if (!groupKey) return;
    
    [blockingStateLock lock];
    [blockingGroupsInFlight addObject:groupKey];
    [blockingStateLock unlock];
}

- (void)markBlockingGroupFinished:(NSString *)groupKey timedOut:(BOOL)timedOut {
    if (!groupKey) return;
    
    [blockingStateLock lock];
    [blockingGroupsInFlight removeObject:groupKey];
    
    if (timedOut) {
        // Set cooldown
        NSDate *cooldownUntil = [NSDate dateWithTimeIntervalSinceNow:kBlockingGroupCooldownSeconds];
        blockingGroupCooldownUntil[groupKey] = cooldownUntil;
        NSLog(@"[BLOCKING] Group '%@' timed out, cooldown until %@", groupKey, cooldownUntil);
    }
    [blockingStateLock unlock];
}

- (void)markEventTimedOut:(uint64_t)eventId {
    [blockingStateLock lock];
    blockingActionTimedOut[@(eventId)] = @YES;
    [blockingStateLock unlock];
}

- (BOOL)isEventTimedOut:(uint64_t)eventId {
    [blockingStateLock lock];
    BOOL timedOut = [blockingActionTimedOut[@(eventId)] boolValue];
    [blockingStateLock unlock];
    return timedOut;
}

- (void)clearEventTimedOut:(uint64_t)eventId {
    [blockingStateLock lock];
    [blockingActionTimedOut removeObjectForKey:@(eventId)];
    [blockingStateLock unlock];
}

/// Execute a potentially blocking action with timeout protection
- (void)executeBlockingAction:(void (^)(void))actionBlock
                   actionName:(NSString *)actionName
                    groupKey:(NSString *)groupKey
                     context:(ActionContext *)ctx {
    
    uint64_t eventId = ctx ? ctx.eventId : 0;
    NSDate *startTime = [NSDate date];
    
    // Mark group as in-flight
    [self markBlockingGroupInFlight:groupKey];
    
    // Capture timeout token for cancellation (token is incremented on completion)
    uint64_t token = ctx ? ++ctx.timeoutToken : 0;
    
    // Schedule timeout on timeoutQueue (fires even if actionQueue is backlogged)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBlockingActionTimeoutSeconds * NSEC_PER_SEC)), timeoutQueue, ^{
        // Dispatch to actionQueue for state mutations
        dispatch_async(self->actionQueue, ^{
            // Check if token is still valid (not invalidated by completion)
            if (ctx && ctx.timeoutToken != token) {
                NSLog(@"[TIMEOUT] IGNORE stale timeout eventId=%llu group=%@ token=%llu (current=%llu)",
                      eventId, groupKey, token, ctx.timeoutToken);
                return;
            }
            [self handleTimeoutForEventId:eventId actionName:actionName groupKey:groupKey context:ctx];
        });
    });
    
    // Execute on blocking queue
    dispatch_async(blockingActionQueue, ^{
        [self actionDidStart];
        
        if (ctx) {
            [ctx markStarted];
        }
        NSLog(@"%@ START action=%@ group=%@", ctx ? [ctx logPrefix] : @"[ev=?]", actionName, groupKey);
        
        @autoreleasepool {
            actionBlock();
        }
        
        NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
        
        // Invalidate the scheduled timeout by bumping the token
        if (ctx) {
            ctx.timeoutToken++;
        }
        
        // Check if we already timed out
        BOOL alreadyTimedOut = [self isEventTimedOut:eventId];
        [self clearEventTimedOut:eventId];
        
        if (alreadyTimedOut) {
            // Timeout already handled, just log completion
            NSLog(@"%@ FINISH_LATE action=%@ duration=%.1fms (after timeout)", 
                  ctx ? [ctx logPrefix] : @"[ev=?]", actionName, durationMs);
        } else {
            // Normal completion
            [self actionDidFinishWithDuration:durationMs];
            [self markBlockingGroupFinished:groupKey timedOut:NO];
            
            if (ctx) {
                [ctx markFinished];
            }
            NSLog(@"%@ FINISH action=%@ duration=%.1fms", ctx ? [ctx logPrefix] : @"[ev=?]", actionName, durationMs);
        }
    });
}

- (void)handleTimeoutForEventId:(uint64_t)eventId
                     actionName:(NSString *)actionName
                       groupKey:(NSString *)groupKey
                        context:(ActionContext *)ctx {
    
    // Check if still in flight
    [blockingStateLock lock];
    BOOL stillInFlight = [blockingGroupsInFlight containsObject:groupKey];
    [blockingStateLock unlock];
    
    if (!stillInFlight) {
        // Already finished normally
        return;
    }
    
    // Mark as timed out
    [self markEventTimedOut:eventId];
    [self markBlockingGroupFinished:groupKey timedOut:YES];
    [self actionDidFinishWithDuration:kBlockingActionTimeoutSeconds * 1000.0];
    
    if (ctx) {
        [ctx markTimeout];
    }
    
    NSLog(@"%@ TIMEOUT action=%@ group=%@ (%.1fs)", 
          ctx ? [ctx logPrefix] : @"[ev=?]", actionName, groupKey, kBlockingActionTimeoutSeconds);
}

#pragma mark - CoreAudio Volume Control

- (void)setSystemVolumeFromMidiValue:(UInt8)midiValue {
    // Convert MIDI value (0-127) to percentage (0-100), applying scale factor
    float percent = (float)midiValue * SLIDER_SCALE_FACTOR;
    
    NSError *error = nil;
    BOOL success = [SystemVolumeController setOutputVolumePercent:percent error:&error];
    
    if (!success) {
        [[DedupingLogger shared] logfWithLevel:DLogLevelError
                                      category:@"CoreAudio"
                                     dedupeKey:@"VolumeSetFailed"
                                        format:@"[CoreAudio] Failed to set volume to %.1f%%: %@", percent, error];
    }
}

- (void)setSystemMuted:(BOOL)muted {
    NSError *error = nil;
    BOOL success = [SystemVolumeController setMuted:muted error:&error];
    
    if (!success) {
        [[DedupingLogger shared] logfWithLevel:DLogLevelError
                                      category:@"CoreAudio"
                                     dedupeKey:@"MuteSetFailed"
                                        format:@"[CoreAudio] Failed to set mute=%@: %@", muted ? @"YES" : @"NO", error];
    }
}

#pragma mark - AppleScript Backend

- (void)scriptAction:(NSString *)command {
    [self scriptAction:command context:nil];
}

- (void)scriptAction:(NSString *)command context:(ActionContext *)ctx
{
    if (command.length == 0) {
        return;
    }
    
    if (ctx) {
        ctx.backend = @"AppleScript";
    }

    NSDictionary *errorDict = nil;

    NSAppleScript *theScript;
    @synchronized (scriptCache) {
        theScript = [scriptCache objectForKey:command];
        if (!theScript) {
            // Wrap command with timeout
            NSString *wrappedCommand = [NSString stringWithFormat:
                @"with timeout of 5 seconds\n%@\nend timeout", command];
            theScript = [[NSAppleScript alloc] initWithSource:wrappedCommand];
            if (theScript) {
                [scriptCache setObject:theScript forKey:command];
            } else {
                [[DedupingLogger shared] logfWithLevel:DLogLevelError
                                              category:@"AE"
                                             dedupeKey:@"CompileFailed"
                                                format:@"%@ COMPILE_FAILED command='%@'",
                                                       ctx ? [ctx logPrefix] : @"[ev=?]", command];
                return;
            }
        }
    }

    NSDate *startTime = [NSDate date];
    NSAppleEventDescriptor *result = [theScript executeAndReturnError:&errorDict];
    NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;

    if (!result && errorDict) {
        if (ctx) {
            [ctx markFinishedWithErrorDict:errorDict];
        }
        NSString *keyCommand = command.length > 30 ? [command substringToIndex:30] : command;
        [[DedupingLogger shared] logfWithLevel:DLogLevelError
                                      category:@"AE"
                                     dedupeKey:[NSString stringWithFormat:@"ExecError:%@", keyCommand]
                                        format:@"%@ ERROR duration=%.1fms command='%@' error=%@",
                                               ctx ? [ctx logPrefix] : @"[ev=?]", durationMs, command, errorDict];
    } else if (ctx) {
        [ctx markFinished];
    }
}

#pragma mark - Slider Handling

- (void)sliderMovedForControl:(NSString *)control value:(UInt8)value context:(ActionContext *)ctx {
    void (^sliderAction)(UInt8) = [sliderActions objectForKey:control];
    if (sliderAction == nil) return;
    
    NSString *actionName = sliderActionNames[control] ?: @"UnknownSlider";
    NSString *groupKey = [self blockingGroupForSliderControl:control];
    
    if (ctx) {
        ctx.controlKey = control;
        ctx.matchedActionName = actionName;
        ctx.actionFound = YES;
    }
    
    // Store the latest value (overwrites any pending value)
    @synchronized (pendingSliderValues) {
        pendingSliderValues[control] = @(value);
        
        // If an update is already scheduled for this slider, let it pick up the new value
        if ([sliderUpdateScheduled[control] boolValue]) {
            if (ctx) {
                [ctx markThrottled];
            }
            [[DedupingLogger shared] logfWithLevel:DLogLevelDebug
                                          category:@"MIDI"
                                         dedupeKey:[NSString stringWithFormat:@"SliderThrottle:%@", control]
                                            format:@"%@ THROTTLED slider=%@",
                                                   ctx ? [ctx logPrefix] : @"[ev=?]", control];
            return;
        }
        
        // Schedule an update
        sliderUpdateScheduled[control] = @YES;
    }
    
    if (ctx) {
        [ctx markEnqueued];
    }
    [self actionWillEnqueue];
    
    // Dispatch after a short delay to coalesce rapid updates
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)), actionQueue, ^{
        NSNumber *latestValue;
        @synchronized (self->pendingSliderValues) {
            latestValue = self->pendingSliderValues[control];
            [self->pendingSliderValues removeObjectForKey:control];
            self->sliderUpdateScheduled[control] = @NO;
        }
        
        if (latestValue) {
            UInt8 val = latestValue.unsignedCharValue;
            
            // Check blocking group protection for sliders
            if (groupKey) {
                NSString *skipReason = nil;
                if (![self canExecuteBlockingGroup:groupKey reason:&skipReason]) {
                    [[DedupingLogger shared] logfWithLevel:DLogLevelDebug
                                                  category:@"BLOCKING"
                                                 dedupeKey:[NSString stringWithFormat:@"SliderSkip:%@", groupKey]
                                                    format:@"[slider=%@] SKIP group=%@ reason=%@", control, groupKey, skipReason];
                    return;
                }
                
                // Execute as blocking action
                [self markBlockingGroupInFlight:groupKey];
                
                // Capture timeout token for cancellation
                uint64_t eventId = ctx ? ctx.eventId : 0;
                uint64_t token = ctx ? ++ctx.timeoutToken : 0;
                
                // Schedule timeout on timeoutQueue (fires even if actionQueue is backlogged)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBlockingActionTimeoutSeconds * NSEC_PER_SEC)), self->timeoutQueue, ^{
                    // Dispatch to actionQueue for state mutations
                    dispatch_async(self->actionQueue, ^{
                        // Check if token is still valid
                        if (ctx && ctx.timeoutToken != token) {
                            NSLog(@"[TIMEOUT] IGNORE stale timeout slider=%@ group=%@ token=%llu (current=%llu)",
                                  control, groupKey, token, ctx.timeoutToken);
                            return;
                        }
                        [self handleSliderTimeoutForControl:control groupKey:groupKey eventId:eventId];
                    });
                });
                
                dispatch_async(self->blockingActionQueue, ^{
                    [self actionDidStart];
                    NSDate *startTime = [NSDate date];
                    
                    @autoreleasepool {
                        sliderAction(val);
                    }
                    
                    NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
                    
                    // Invalidate the scheduled timeout by bumping the token
                    if (ctx) {
                        ctx.timeoutToken++;
                    }
                    
                    BOOL alreadyTimedOut = [self isEventTimedOut:eventId];
                    [self clearEventTimedOut:eventId];
                    
                    if (!alreadyTimedOut) {
                        [self actionDidFinishWithDuration:durationMs];
                        [self markBlockingGroupFinished:groupKey timedOut:NO];
                    }
                });
            } else {
                // Non-blocking slider action
                [self actionDidStart];
                NSDate *startTime = [NSDate date];
                
                @autoreleasepool {
                    sliderAction(val);
                }
                
                NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
                [self actionDidFinishWithDuration:durationMs];
            }
        }
    });
}

- (void)handleSliderTimeoutForControl:(NSString *)control groupKey:(NSString *)groupKey eventId:(uint64_t)eventId {
    [blockingStateLock lock];
    BOOL stillInFlight = [blockingGroupsInFlight containsObject:groupKey];
    [blockingStateLock unlock];
    
    if (!stillInFlight) {
        return;
    }
    
    [self markEventTimedOut:eventId];
    [self markBlockingGroupFinished:groupKey timedOut:YES];
    [self actionDidFinishWithDuration:kBlockingActionTimeoutSeconds * 1000.0];
    
    NSLog(@"[slider=%@] TIMEOUT group=%@ (%.1fs)", control, groupKey, kBlockingActionTimeoutSeconds);
}

- (void)sliderMovedForControl:(NSString *)control value:(UInt8)value {
    [self sliderMovedForControl:control value:value context:nil];
}

#pragma mark - Control Handling

- (void)setControl:(MIKMIDIControlChangeCommand *)command context:(ActionContext *)ctx {
    if (command.dataByte1 == 15) {
        currentControlId = command.dataByte2;
        currentControl = byteToStr(currentControlId);
        return;
    }
    if (command.dataByte1 == currentControlId) {
        [self sliderMovedForControl:currentControl value:command.controllerValue context:ctx];
        return;
    }
}

- (void)setControl:(MIKMIDIControlChangeCommand *)command {
    [self setControl:command context:nil];
}

- (void)mapControlToAction:(MIKMIDICommand *)command {
    [self mapControlToAction:command forControl:currentControl context:nil];
}

- (void)mapControlToAction:(MIKMIDICommand *)command forControl:(NSString *)control {
    [self mapControlToAction:command forControl:control context:nil];
}

- (void)mapControlToAction:(MIKMIDICommand *)command forControl:(NSString *)control context:(ActionContext *)ctx {
    if (ctx) {
        ctx.controlKey = control;
    }
    
    NSDictionary *controlMap = [controlToActionMap objectForKey:control];
    if (controlMap == nil) {
        if (ctx) {
            ctx.actionFound = NO;
        }
        [[DedupingLogger shared] logfWithLevel:DLogLevelDebug
                                      category:@"MIDI"
                                     dedupeKey:[NSString stringWithFormat:@"NoControlMap:%@", control ?: @"nil"]
                                        format:@"%@ MAP_MISS no control map for control=%@",
                                               ctx ? [ctx logPrefix] : @"[ev=?]", control];
        return;
    }

    NSString *actionId = byteToStr(command.dataByte2);
    NSString *actionKey = [NSString stringWithFormat:@"%@:%@", control, actionId];

    void (^action)(void) = [controlMap objectForKey:actionId];
    if (action == nil) {
        if (ctx) {
            ctx.actionFound = NO;
        }
        [[DedupingLogger shared] logfWithLevel:DLogLevelDebug
                                      category:@"MIDI"
                                     dedupeKey:[NSString stringWithFormat:@"NoAction:%@", actionKey]
                                        format:@"%@ MAP_MISS no action for control=%@ actionId=%@",
                                               ctx ? [ctx logPrefix] : @"[ev=?]", control, actionId];
        return;
    }

    // Found an action
    NSString *actionName = actionNameMap[actionKey] ?: @"UnknownAction";
    NSString *groupKey = [self blockingGroupForActionName:actionName];
    
    if (ctx) {
        ctx.actionFound = YES;
        ctx.matchedActionName = actionName;
    }
    
    // Check if this is a blocking action and if we can execute it
    if (groupKey) {
        NSString *skipReason = nil;
        if (![self canExecuteBlockingGroup:groupKey reason:&skipReason]) {
            [[DedupingLogger shared] logfWithLevel:DLogLevelWarn
                                          category:@"BLOCKING"
                                         dedupeKey:[NSString stringWithFormat:@"Skip:%@", groupKey]
                                            format:@"%@ SKIP action=%@ reason=%@",
                                                   ctx ? [ctx logPrefix] : @"[ev=?]", actionName, skipReason];
            return;
        }
    }
    
    if (ctx) {
        [ctx markEnqueued];
    }
    [self actionWillEnqueue];
    NSLog(@"%@ ENQUEUE action=%@ group=%@", ctx ? [ctx logPrefix] : @"[ev=?]", actionName, groupKey ?: @"none");

    if (groupKey) {
        // Blocking action - use protected execution
        [self executeBlockingAction:action actionName:actionName groupKey:groupKey context:ctx];
    } else {
        // Non-blocking action - run directly on actionQueue
        dispatch_async(actionQueue, ^{
            [self actionDidStart];
            NSDate *startTime = [NSDate date];
            
            if (ctx) {
                [ctx markStarted];
            }
            NSLog(@"%@ START action=%@", ctx ? [ctx logPrefix] : @"[ev=?]", actionName);
            
            @autoreleasepool {
                action();
            }
            
            NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
            [self actionDidFinishWithDuration:durationMs];
            
            if (ctx) {
                [ctx markFinished];
            }
            NSLog(@"%@ FINISH action=%@ duration=%.1fms", ctx ? [ctx logPrefix] : @"[ev=?]", actionName, durationMs);
        });
    }
}
/*
 Listen for commands then call the appropriate mapper
 */
#pragma mark - MIDI Command Handling

- (void)handleMIDIControlChangeCommands:(NSArray<MIKMIDIControlChangeCommand*> *)commands
{
    for (MIKMIDIControlChangeCommand *command in commands) {
        
        if (!command.isFourteenBitCommand) {
            // 7-bit command
            ActionContext *ctx = [ActionContext contextWithStatus:command.statusByte
                                                            data1:command.dataByte1
                                                            data2:command.dataByte2];
            
            NSLog(@"%@ RECV %@", [ctx logPrefix], [ctx midiDescription]);
            
            NSString *control = byteToStr(command.dataByte1);
            [self mapControlToAction:command forControl:control context:ctx];
            continue;
        }
        
        // 14-bit command
        ActionContext *ctx = [ActionContext contextWithStatus:command.statusByte
                                           msbControllerNumber:command.commandForMostSignificantBits.controllerNumber
                                           msbControllerValue:command.commandForMostSignificantBits.controllerValue
                                           lsbControllerNumber:command.commandForLeastSignificantBits.controllerNumber
                                           lsbControllerValue:command.commandForLeastSignificantBits.controllerValue];
        
        NSLog(@"%@ RECV %@", [ctx logPrefix], [ctx midiDescription]);
        
        [self setControl:command.commandForMostSignificantBits context:ctx];
        [self mapControlToAction:command.commandForLeastSignificantBits forControl:currentControl context:ctx];
    }
}

#pragma mark - Initialization

- (void)initMaps
{
    playbackButtonMap = @{
        PLAYBACK_BUTTON_PAUSE_PRESSED:^(){ [self->spotifyApp pause]; },
        PLAYBACK_BUTTON_PLAY_PRESSED:^(){ [self->spotifyApp play]; },
    };

    trackButtonMap = @{
        TRACK_BUTTON_NEXT_PRESSED:^(){ [self->spotifyApp nextTrack]; },
        TRACK_BUTTON_PREV_PRESSED:^(){ [self->spotifyApp previousTrack]; },
    };

    slider0ButtonMap = @{
        SLIDER_M_BUTTON_PRESSED:^(){ [self setSystemMuted:YES]; },
        SLIDER_M_BUTTON_RELEASED:^(){ [self setSystemMuted:NO]; },
    };

    slider1ButtonMap = @{
        SLIDER_M_BUTTON_PRESSED:^(){ [self setSystemMuted:YES]; },
        SLIDER_M_BUTTON_RELEASED:^(){ [self setSystemMuted:NO]; },
    };
    
    knob0Map = @{
        KNOB_MIN:^() { NSLog(@"Knob1 min"); },
        KNOB_MAX:^() { NSLog(@"Knob1 max"); },
        KNOB_INCREMENT:^() { NSLog(@"Knob1 increment"); },
        KNOB_DECREMENT:^() { NSLog(@"Knob1 decrement"); }
    };

    controlToActionMap = @{
        PLAYBACK_BUTTONS_ID: playbackButtonMap,
        TRACK_BUTTONS_ID: trackButtonMap,
        SLIDER_0_CONTROLS: slider0ButtonMap,
        SLIDER_1_CONTROLS: slider1ButtonMap,
        KNOB_0: knob0Map
    };
    
    // Human-readable action names for logging
    actionNameMap = @{
        [NSString stringWithFormat:@"%@:%@", PLAYBACK_BUTTONS_ID, PLAYBACK_BUTTON_PAUSE_PRESSED]: @"Spotify:Pause",
        [NSString stringWithFormat:@"%@:%@", PLAYBACK_BUTTONS_ID, PLAYBACK_BUTTON_PLAY_PRESSED]: @"Spotify:Play",
        [NSString stringWithFormat:@"%@:%@", TRACK_BUTTONS_ID, TRACK_BUTTON_NEXT_PRESSED]: @"Spotify:NextTrack",
        [NSString stringWithFormat:@"%@:%@", TRACK_BUTTONS_ID, TRACK_BUTTON_PREV_PRESSED]: @"Spotify:PrevTrack",
        [NSString stringWithFormat:@"%@:%@", SLIDER_0_CONTROLS, SLIDER_M_BUTTON_PRESSED]: @"System:Mute",
        [NSString stringWithFormat:@"%@:%@", SLIDER_0_CONTROLS, SLIDER_M_BUTTON_RELEASED]: @"System:Unmute",
        [NSString stringWithFormat:@"%@:%@", SLIDER_1_CONTROLS, SLIDER_M_BUTTON_PRESSED]: @"System:Mute",
        [NSString stringWithFormat:@"%@:%@", SLIDER_1_CONTROLS, SLIDER_M_BUTTON_RELEASED]: @"System:Unmute",
        [NSString stringWithFormat:@"%@:%@", KNOB_0, KNOB_MIN]: @"Knob:Min",
        [NSString stringWithFormat:@"%@:%@", KNOB_0, KNOB_MAX]: @"Knob:Max",
        [NSString stringWithFormat:@"%@:%@", KNOB_0, KNOB_INCREMENT]: @"Knob:Increment",
        [NSString stringWithFormat:@"%@:%@", KNOB_0, KNOB_DECREMENT]: @"Knob:Decrement",
    };

    sliderActions = @{
        SLIDER_0_CONTROLS: ^(UInt8 volume){ [self setSystemVolumeFromMidiValue:volume]; },
        SLIDER_1_CONTROLS: ^(UInt8 volume){ [self->spotifyApp setSoundVolume:(NSInteger)(volume * SLIDER_SCALE_FACTOR)]; },
        SLIDER_2_CONTROLS: ^(UInt8 volume){
            [self->hueAPI setBrightness:(NSInteger)(volume * SLIDER_SCALE_FACTOR)
                       forResourceType:@"grouped_light"
                           resourceID:@"1d70a073-d47a-4e02-931c-a35db2a8bf1e"];
        },
        SLIDER_3_CONTROLS: ^(UInt8 volume){ // Office lamp left
            [self->hueAPI setBrightness:(NSInteger)(volume * SLIDER_SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"192bf44d-0f3c-4ed3-9bca-f31d8ac35227"];
        },
        SLIDER_4_CONTROLS: ^(UInt8 volume){ // Office lamp right
            [self->hueAPI setBrightness:(NSInteger)(volume * SLIDER_SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"2d1e7d28-e998-43b3-93f7-f0d9775f71a9"];
        },
        SLIDER_5_CONTROLS: ^(UInt8 volume){
            [self->hueAPI setBrightness:(NSInteger)(volume * SLIDER_SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"41dbbcd1-0999-422a-ad43-a7c182f0f432"];
        }
    };
    
    // Human-readable slider action names
    sliderActionNames = @{
        SLIDER_0_CONTROLS: @"System:Volume",
        SLIDER_1_CONTROLS: @"Spotify:Volume",
        SLIDER_2_CONTROLS: @"Hue:GroupedLight",
        SLIDER_3_CONTROLS: @"Hue:OfficeLampLeft",
        SLIDER_4_CONTROLS: @"Hue:OfficeLampRight",
        SLIDER_5_CONTROLS: @"Hue:Light5",
    };
    
    // Map action keys to blocking groups (for timeout/circuit-breaker protection)
    actionGroupMap = @{
        [NSString stringWithFormat:@"%@:%@", PLAYBACK_BUTTONS_ID, PLAYBACK_BUTTON_PAUSE_PRESSED]: @"spotify",
        [NSString stringWithFormat:@"%@:%@", PLAYBACK_BUTTONS_ID, PLAYBACK_BUTTON_PLAY_PRESSED]: @"spotify",
        [NSString stringWithFormat:@"%@:%@", TRACK_BUTTONS_ID, TRACK_BUTTON_NEXT_PRESSED]: @"spotify",
        [NSString stringWithFormat:@"%@:%@", TRACK_BUTTONS_ID, TRACK_BUTTON_PREV_PRESSED]: @"spotify",
        [NSString stringWithFormat:@"%@:%@", SLIDER_0_CONTROLS, SLIDER_M_BUTTON_PRESSED]: @"coreaudio",
        [NSString stringWithFormat:@"%@:%@", SLIDER_0_CONTROLS, SLIDER_M_BUTTON_RELEASED]: @"coreaudio",
        [NSString stringWithFormat:@"%@:%@", SLIDER_1_CONTROLS, SLIDER_M_BUTTON_PRESSED]: @"coreaudio",
        [NSString stringWithFormat:@"%@:%@", SLIDER_1_CONTROLS, SLIDER_M_BUTTON_RELEASED]: @"coreaudio",
        // Knob actions are non-blocking (just NSLog)
    };
    
    // Map slider controls to blocking groups
    sliderActionGroups = @{
        SLIDER_0_CONTROLS: @"coreaudio",     // System volume via CoreAudio
        SLIDER_1_CONTROLS: @"spotify",       // Spotify volume via ScriptingBridge
        // Hue sliders (2-5) are non-blocking (async HTTP), no entry needed
    };

    currentControl = nil;
    currentControlId = -1;
}

@end
