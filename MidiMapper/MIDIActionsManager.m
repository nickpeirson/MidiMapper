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
#import <Carbon/Carbon.h>   // for kAENoReply, etc.
#import <stdatomic.h>

// Queue health thresholds
static const uint64_t kInFlightWarningThreshold = 8;
static const NSTimeInterval kLongActionThresholdMs = 2000.0;
static const NSTimeInterval kHealthLogIntervalSeconds = 30.0;

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
    NSDictionary<NSString *, id> *sliderActions;
    NSDictionary<NSString *, NSString *> *sliderActionNames;  // Maps control to human-readable name
    NSMutableDictionary<NSString *, NSAppleScript *> *scriptCache;
    NSString *currentControl;
    UInt8 currentControlId;
    SpotifyApplication *spotifyApp;
    HueAPI *hueAPI;
    dispatch_queue_t actionQueue;   // concurrent queue for executing actions without blocking
    NSMutableDictionary<NSString *, NSNumber *> *pendingSliderValues;  // latest value per slider
    NSMutableDictionary<NSString *, NSNumber *> *sliderUpdateScheduled; // whether update is scheduled
    
    // Queue health metrics
    atomic_uint_fast64_t actionsEnqueued;
    atomic_uint_fast64_t actionsStarted;
    atomic_uint_fast64_t actionsFinished;
    atomic_uint_fast64_t actionsInFlight;
    NSDate *lastHealthLog;
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
        
        // concurrent queue for executing actions without blocking MIDI callback
        actionQueue = dispatch_queue_create("com.nickpeirson.MidiMapper.actions", DISPATCH_QUEUE_CONCURRENT);
        
        // Throttling state for sliders
        pendingSliderValues = [NSMutableDictionary dictionary];
        sliderUpdateScheduled = [NSMutableDictionary dictionary];
        
        // Initialize queue health metrics
        atomic_store(&actionsEnqueued, 0);
        atomic_store(&actionsStarted, 0);
        atomic_store(&actionsFinished, 0);
        atomic_store(&actionsInFlight, 0);
        lastHealthLog = [NSDate date];
        
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
            [self actionDidStart];
            NSDate *startTime = [NSDate date];
            
            @autoreleasepool {
                sliderAction(latestValue.unsignedCharValue);
            }
            
            NSTimeInterval durationMs = [[NSDate date] timeIntervalSinceDate:startTime] * 1000.0;
            [self actionDidFinishWithDuration:durationMs];
        }
    });
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
    if (ctx) {
        ctx.actionFound = YES;
        ctx.matchedActionName = actionName;
        [ctx markEnqueued];
    }
    
    [self actionWillEnqueue];
    NSLog(@"%@ ENQUEUE action=%@", ctx ? [ctx logPrefix] : @"[ev=?]", actionName);

    // Run the mapped action on the concurrent actionQueue
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
        SLIDER_M_BUTTON_PRESSED:^(){ [self scriptAction:@"set volume with output muted"]; },
        SLIDER_M_BUTTON_RELEASED:^(){ [self scriptAction:@"set volume without output muted"]; },
    };

    slider1ButtonMap = @{
        SLIDER_M_BUTTON_PRESSED:^(){ [self scriptAction:@"set volume with output muted"]; },
        SLIDER_M_BUTTON_RELEASED:^(){ [self scriptAction:@"set volume without output muted"]; },
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
        SLIDER_0_CONTROLS: ^(UInt8 volume){ [self scriptAction:[NSString stringWithFormat:@"set volume output volume %d", (int)(volume * SLIDER_SCALE_FACTOR)]]; },
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

    currentControl = nil;
    currentControlId = -1;
}

@end
