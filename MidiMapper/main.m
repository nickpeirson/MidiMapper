//
//  main.m
//  MidiMapper
//
//  Created by Nick Peirson on 17/10/2020.
//  Copyright © 2020 Nick Peirson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <MIKMIDI/MIKMIDI.h>
#import "Spotify.h"
#import "MIDIControllerManager.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        MIDIControllerManager *midiControllerManager = [[MIDIControllerManager alloc] init];
        [midiControllerManager setupMIDIDeviceManager];
        
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
