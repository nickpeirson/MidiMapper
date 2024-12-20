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
    NSDictionary<NSString *, id> *sliderActions;
    NSMutableDictionary<NSString *, NSAppleScript *> *scriptCache;
    NSString *currentControl;
    UInt8 currentControlId;
    SpotifyApplication *spotifyApp;
    HueAPI *hueAPI;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        spotifyApp = [SBApplication applicationWithBundleIdentifier:@"com.spotify.client"];
        scriptCache = [NSMutableDictionary dictionaryWithCapacity:200];
        hueAPI = [[HueAPI alloc] init];
        [self initMaps];
    }
    return self;
}

NSString* byteToStr(UInt8 byte)
{
    return [NSString stringWithFormat:@"%d", byte];
}

- (void)scriptAction:(NSString *)command
{
    NSDictionary* errorDict;
    
    NSAppleScript *theScript = [scriptCache objectForKey:command];
    if (theScript == nil) {
        theScript = [[NSAppleScript alloc] initWithSource:command];
        [scriptCache setObject:theScript forKey:command];
    }
        
    (void) [theScript executeAndReturnError: &errorDict];
}

static void sliderMoved(MIKMIDIControlChangeCommand *command, NSDictionary<NSString *, id> *sliderActions, NSString *currentControl) {
    void (^sliderAction)(UInt8) = [sliderActions objectForKey:currentControl];
    if (sliderAction == nil) return;

    sliderAction(command.controllerValue);
}

- (void)setControl:(MIKMIDIControlChangeCommand *)command {
    if (command.dataByte1 == 15) {
        currentControlId = command.dataByte2;
        currentControl = byteToStr(currentControlId);
        return;
    }
    if (command.dataByte1 == currentControlId) {
        sliderMoved(command, sliderActions, currentControl);
        return;
    }
}

- (void)mapControlToAction:(MIKMIDICommand *) command {
    [self mapControlToAction:command forControl: currentControl];
}

- (void)mapControlToAction:(MIKMIDICommand *) command forControl:(NSString *) control {
    NSDictionary *controlMap = [controlToActionMap objectForKey:control];
    if (controlMap == nil) {
        NSLog(@"No control map defined for current control");
        return;
    }

    NSString *actionId = byteToStr(command.dataByte2);

    void (^action)(void) = [controlMap objectForKey:actionId];
    if (action == nil) {
        NSLog(@"No action defined for current control");
        return;
    }

    action();
}
/*
 Listen for commands then call the appropriate mapper
 */
- (void)handleMIDIControlChangeCommands:(NSArray<MIKMIDIControlChangeCommand*> *)commands
{
    for (MIKMIDIControlChangeCommand *command in commands) {
        NSLog(@"");
        NSLog(@"Command values: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
        if (!command.isFourteenBitCommand) {
            NSLog(@"7bit command:");
            NSLog(@"Controller number: %lu, Controller value: %lu", command.controllerNumber, command.controllerValue);
            NSString *control = byteToStr(command.dataByte1);
            [self mapControlToAction:command forControl: control];
            continue;
        }
        NSLog(@"14bit command:");
        NSLog(@"commandForMostSignificantBits:: Controller number: %lu, Controller value: %lu", command.commandForMostSignificantBits.controllerNumber, command.commandForMostSignificantBits.controllerValue);
        [self setControl:command.commandForMostSignificantBits];
        NSLog(@"commandForLeastSignificantBits:: Controller number: %lu, Controller value: %lu", command.commandForLeastSignificantBits.controllerNumber, command.commandForLeastSignificantBits.controllerValue);
        [self mapControlToAction:command.commandForLeastSignificantBits];
    }
}

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

    currentControl = nil;
    currentControlId = -1;
}

@end
