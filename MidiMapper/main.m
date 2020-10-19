//
//  main.m
//  MidiMapper
//
//  Created by Nick Peirson on 17/10/2020.
//  Copyright © 2020 Nick Peirson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <MIKMIDI/MIKMIDI.h>

#define SCALE_FACTOR 0.787

NSString *const playbackButtonsId = @"14";
NSString *const playbackButtonPausePressed = @"67";
NSString *const playbackButtonPlayPressed = @"68";

NSString *const trackButtonsId = @"10";
NSString *const trackButtonPrevPressed = @"65";
NSString *const trackButtonNextPressed = @"67";

NSString *const slider0Controls = @"0";
NSString *const slider1Controls = @"1";
NSString *const slider7Controls = @"7";
NSString *const slider7MButtonPressed = @"66";
NSString *const slider7MButtonReleased = @"2";

NSString *currentControl = NULL;
UInt8 currentControlId = -1;

NSString* byteToStr(UInt8 byte)
{
    return [NSString stringWithFormat:@"%d", byte];
}

void scriptAction(NSString *command)
{
    NSDictionary* errorDict;
    NSAppleEventDescriptor* returnDescriptor = NULL;

    NSAppleScript* scriptObject = [[NSAppleScript alloc] initWithSource:command];

    returnDescriptor = [scriptObject executeAndReturnError: &errorDict];
}

void spotifyAction(NSString *command)
{
    scriptAction([@"tell application \"Spotify\" to " stringByAppendingString:command]);
}

static void sliderMoved(MIKMIDIControlChangeCommand *command) {
    NSDictionary<NSString *, id> *sliderActions = @{
        slider0Controls: ^(UInt8 volume){ scriptAction([NSString stringWithFormat:@"set volume output volume %d", (int)(volume * SCALE_FACTOR)]); },
        slider1Controls: ^(UInt8 volume){ spotifyAction([NSString stringWithFormat:@"set sound volume to %d", (int)(volume * SCALE_FACTOR)]); }
    };
    
    NSLog(@"sliderMoved Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
    
    void (^sliderAction)(UInt8);
    sliderAction = [sliderActions objectForKey:currentControl];
    if (sliderAction == nil) return;
    
    sliderAction(command.controllerValue);
}

void setControl(MIKMIDIControlChangeCommand *command) {
    if (command.dataByte1 == 15) {
        NSLog(@"setControl Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
        currentControlId = command.dataByte2;
        currentControl = byteToStr(currentControlId);
        return;
    }
    if (command.dataByte1 == currentControlId) {
        //Slider time
        sliderMoved(command);
        return;
    }
    NSLog(@"??? Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
}

void mapControlToAction(MIKMIDICommand *command)
{
    NSDictionary *playbackButtonMap = @{
        playbackButtonPausePressed:^(){ spotifyAction(@"pause"); },
        playbackButtonPlayPressed:^(){ spotifyAction(@"play"); },
    };
    
    NSDictionary *trackButtonMap = @{
        trackButtonNextPressed:^(){ spotifyAction(@"next track"); },
        trackButtonPrevPressed:^(){ spotifyAction(@"previous track"); },
    };
    
    NSDictionary *slider0ButtonMap = @{
        slider7MButtonPressed:^(){ scriptAction(@"set volume with output muted"); },
        slider7MButtonReleased:^(){ scriptAction(@"set volume without output muted"); },
    };
    
    NSDictionary *slider1ButtonMap = @{
        slider7MButtonPressed:^(){ scriptAction(@"set volume with output muted"); },
        slider7MButtonReleased:^(){ scriptAction(@"set volume without output muted"); },
    };
    
    NSDictionary<NSString *, id> *dict = @{
        playbackButtonsId: playbackButtonMap,
        trackButtonsId: trackButtonMap,
        slider0Controls: slider0ButtonMap,
        slider1Controls: slider1ButtonMap
    };
    
    NSLog(@"buttonPressed Status: %d, Data1: %d, Data2: %d", command.statusByte, command.dataByte1, command.dataByte2);
    
    NSDictionary *controlMap = [dict objectForKey:currentControl];
    if (controlMap == nil) return;
    
    NSString *actionId = byteToStr(command.dataByte2);
    
    void (^action)(void);
    action = [controlMap objectForKey:actionId];
    if (action == nil) return;
    
    action();
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        MIKMIDIDeviceManager *deviceManager = [MIKMIDIDeviceManager alloc];
       
        MIKMIDIDevice *device;
        for (device in [deviceManager availableDevices]) {
            NSLog(@"%@ %@", [device manufacturer], [device model]);
            
            if ([[device model] isNotEqualTo:@"nanoKONTROL2"]) continue;
            NSError *error = nil;
            [deviceManager connectDevice:device error:&error eventHandler:^(MIKMIDISourceEndpoint *source, NSArray<MIKMIDIControlChangeCommand *> *commands) {
                for (MIKMIDIControlChangeCommand *command in commands) {
                    if (!command.isFourteenBitCommand) {
                        mapControlToAction(command);
                        continue;
                    }
                    setControl(command.commandForMostSignificantBits);
                    mapControlToAction(command.commandForLeastSignificantBits);
                }
            }];
        }
        
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
