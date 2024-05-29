//
//  MIDIControllerManager.h
//  MidiMapper
//
//  Created by Nick Peirson on 28/05/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#ifndef MIDIControllerManager_h
#define MIDIControllerManager_h

#import <Foundation/Foundation.h>
#import <MIKMIDI/MIKMIDI.h>
#import "MIDIActionsManager.h"

@interface MIDIControllerManager : NSObject

- (void)setupMIDIDeviceManager;

@end


#endif /* MIDIControllerManager_h */
