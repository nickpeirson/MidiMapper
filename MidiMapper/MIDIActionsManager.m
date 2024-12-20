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

double const SCALE_FACTOR = 0.787;

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

@implementation MIDIActionsManager {
    NSDictionary *playbackButtonMap;
    NSDictionary *trackButtonMap;
    NSDictionary *slider0ButtonMap;
    NSDictionary *slider1ButtonMap;
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
    NSLog(@"??? Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
}

- (void)mapControlToAction:(MIKMIDICommand *) command {
    // NSLog(@"buttonPressed Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
    NSDictionary *controlMap = [controlToActionMap objectForKey:currentControl];
    if (controlMap == nil) return;

    NSString *actionId = byteToStr(command.dataByte2);

    void (^action)(void) = [controlMap objectForKey:actionId];
    if (action == nil) return;

    action();
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

    controlToActionMap = @{
        PLAYBACK_BUTTONS_ID: playbackButtonMap,
        TRACK_BUTTONS_ID: trackButtonMap,
        SLIDER_0_CONTROLS: slider0ButtonMap,
        SLIDER_1_CONTROLS: slider1ButtonMap
    };

    sliderActions = @{
        SLIDER_0_CONTROLS: ^(UInt8 volume){ [self scriptAction:[NSString stringWithFormat:@"set volume output volume %d", (int)(volume * SCALE_FACTOR)]]; },
        SLIDER_1_CONTROLS: ^(UInt8 volume){ [self->spotifyApp setSoundVolume:(NSInteger)(volume * SCALE_FACTOR)]; },
        SLIDER_2_CONTROLS: ^(UInt8 volume){
            [self->hueAPI setBrightness:(NSInteger)(volume * SCALE_FACTOR)
                       forResourceType:@"grouped_light"
                           resourceID:@"1d70a073-d47a-4e02-931c-a35db2a8bf1e"];
        },
        SLIDER_3_CONTROLS: ^(UInt8 volume){ // Office lamp left
            [self->hueAPI setBrightness:(NSInteger)(volume * SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"192bf44d-0f3c-4ed3-9bca-f31d8ac35227"];
        },
        SLIDER_4_CONTROLS: ^(UInt8 volume){ // Office lamp right
            [self->hueAPI setBrightness:(NSInteger)(volume * SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"2d1e7d28-e998-43b3-93f7-f0d9775f71a9"];
        },
        SLIDER_5_CONTROLS: ^(UInt8 volume){
            [self->hueAPI setBrightness:(NSInteger)(volume * SCALE_FACTOR)
                       forResourceType:@"light"
                           resourceID:@"41dbbcd1-0999-422a-ad43-a7c182f0f432"];
        }
    };

    currentControl = nil;
    currentControlId = -1;
}

@end
