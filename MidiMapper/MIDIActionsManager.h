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

@end

#endif /* MIDIActionsManager_h */

