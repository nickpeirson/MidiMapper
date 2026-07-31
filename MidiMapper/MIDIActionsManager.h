//
//  MIDIActionsManager.h
//  MidiMapper
//
//  Created by Nick Peirson on 28/05/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#ifndef MIDIActionsManager_h
#define MIDIActionsManager_h

// MIDIActionsManager.h
#import <Foundation/Foundation.h>
#import <MIKMIDI/MIKMIDI.h>
#import "Spotify.h"

@interface MIDIActionsManager : NSObject

- (void)initMaps;
- (void)setControl:(MIKMIDIControlChangeCommand *)command;
- (void)mapControlToAction:(MIKMIDICommand *)command;
- (void)handleMIDIControlChangeCommands:(NSArray<MIKMIDIControlChangeCommand*> *)commands;

// These narrow inspection and injection points keep the regression suite independent
// of MIDI hardware and the external applications controlled by the mapper.
- (instancetype)initForTesting;
- (nullable NSString *)actionNameForControl:(NSString *)control actionID:(NSString *)actionID;
- (nullable NSString *)actionGroupForControl:(NSString *)control actionID:(NSString *)actionID;
- (nullable NSString *)sliderActionNameForControl:(NSString *)control;
- (nullable NSString *)sliderActionGroupForControl:(NSString *)control;
- (void)setSliderActionForTesting:(void (^)(UInt8 value))action forControl:(NSString *)control;
- (void)handleSliderValueForTesting:(UInt8)value control:(NSString *)control;

@end

#endif /* MIDIActionsManager_h */
