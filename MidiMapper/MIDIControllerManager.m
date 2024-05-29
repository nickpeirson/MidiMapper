//
//  MIDIControllerManager.m
//  MidiMapper
//
//  Created by Nick Peirson on 28/05/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import "MIDIControllerManager.h"

@implementation MIDIControllerManager {
    MIDIActionsManager *actionsManager;
    id connectionToken;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        actionsManager = [[MIDIActionsManager alloc] init];
        [actionsManager initMaps];
    }
    return self;
}

- (void)setupMIDIDeviceManager
{
    //MIKMIDIDeviceManager *deviceManager = [MIKMIDIDeviceManager sharedDeviceManager];

    // Register for device notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMIDIDeviceWasAddedNotification:)
                                                 name:MIKMIDIDeviceWasAddedNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMIDIDeviceWasRemovedNotification:)
                                                 name:MIKMIDIDeviceWasRemovedNotification
                                               object:nil];

    [self connectToMIDIController];
}

- (void)connectToMIDIController
{
    MIKMIDIDeviceManager *deviceManager = [MIKMIDIDeviceManager sharedDeviceManager];
    for (MIKMIDIDevice *device in [deviceManager availableDevices]) {

        [self connectDevice:device];
    }
}

- (void)handleMIDIDeviceWasAddedNotification:(NSNotification *)notification
{
    MIKMIDIDevice *addedDevice = notification.userInfo[MIKMIDIDeviceKey];

    [self connectDevice:addedDevice];
}


- (void)connectDevice:(MIKMIDIDevice *)device
{
    printf("Device Added: %s %s\n", [[device manufacturer] UTF8String], [[device model] UTF8String]);
    if (![[device model] isEqualToString:@"nanoKONTROL2"]) {
        return;
    }
    NSError *error = nil;
    self->connectionToken = [[MIKMIDIDeviceManager sharedDeviceManager] connectDevice:device error:&error eventHandler:^(MIKMIDISourceEndpoint *source, NSArray<MIKMIDIControlChangeCommand *> *commands) {
        for (MIKMIDIControlChangeCommand *command in commands) {
            if (!command.isFourteenBitCommand) {
                [self->actionsManager mapControlToAction:command];
                continue;
            }
            [self->actionsManager setControl:command.commandForMostSignificantBits];
            [self->actionsManager mapControlToAction:command.commandForLeastSignificantBits];
        }
    }];
    printf("Connecting Device(s):\n");
    for (id token in self->connectionToken) {
        printf("  Token: %s\n", [[token description] UTF8String]);
    }
}

- (void)handleMIDIDeviceWasRemovedNotification:(NSNotification *)notification
{
    MIKMIDIDevice *removedDevice = notification.userInfo[MIKMIDIDeviceKey];
    printf("Device Removed: %s %s\n", [[removedDevice manufacturer] UTF8String], [[removedDevice model] UTF8String]);
    
    if (![[removedDevice model] isEqualToString:@"nanoKONTROL2"] && self->connectionToken) return;
    [self disconnectDevice];
}

- (void)disconnectDevice {
    if (self->connectionToken) {
        printf("Disconnecting Device(s):\n");
        for (id token in self->connectionToken) {
            printf("  Token: %s\n", [[token description] UTF8String]);
        }
        [[MIKMIDIDeviceManager sharedDeviceManager] disconnectConnectionForToken:self->connectionToken];
    }
}

// Make sure to remove the observers when they are no longer needed
- (void)dealloc
{
    [self disconnectDevice];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
