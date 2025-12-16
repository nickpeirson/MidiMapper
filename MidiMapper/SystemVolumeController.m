//
//  SystemVolumeController.m
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import "SystemVolumeController.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

NSString * const SystemVolumeControllerErrorDomain = @"com.nickpeirson.MidiMapper.SystemVolumeController";

@implementation SystemVolumeController

#pragma mark - Private Helpers

/**
 * Gets the default output audio device ID.
 */
+ (AudioDeviceID)defaultOutputDeviceWithError:(NSError **)error {
    AudioDeviceID deviceId = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceId);
    
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceId);
    
    if (status != noErr || deviceId == kAudioObjectUnknown) {
        if (error) {
            *error = [NSError errorWithDomain:SystemVolumeControllerErrorDomain
                                         code:SystemVolumeControllerErrorNoDefaultDevice
                                     userInfo:@{
                NSLocalizedDescriptionKey: @"Could not get default output device",
                @"OSStatus": @(status)
            }];
        }
        return kAudioObjectUnknown;
    }
    
    return deviceId;
}

/**
 * Checks if a property is settable on the given device.
 */
+ (BOOL)isPropertySettable:(AudioObjectPropertySelector)selector
                    scope:(AudioObjectPropertyScope)scope
                  element:(AudioObjectPropertyElement)element
                 onDevice:(AudioDeviceID)deviceId {
    
    AudioObjectPropertyAddress addr = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = element
    };
    
    Boolean isSettable = false;
    OSStatus status = AudioObjectIsPropertySettable(deviceId, &addr, &isSettable);
    
    return (status == noErr && isSettable);
}

/**
 * Checks if a property exists on the given device.
 */
+ (BOOL)hasProperty:(AudioObjectPropertySelector)selector
              scope:(AudioObjectPropertyScope)scope
            element:(AudioObjectPropertyElement)element
           onDevice:(AudioDeviceID)deviceId {
    
    AudioObjectPropertyAddress addr = {
        .mSelector = selector,
        .mScope = scope,
        .mElement = element
    };
    
    return AudioObjectHasProperty(deviceId, &addr);
}

#pragma mark - Volume Control

+ (BOOL)setOutputVolumePercent:(float)percent error:(NSError **)error {
    // Clamp to valid range
    float scalar = fmaxf(0.0f, fminf(100.0f, percent)) / 100.0f;
    
    AudioDeviceID deviceId = [self defaultOutputDeviceWithError:error];
    if (deviceId == kAudioObjectUnknown) {
        return NO;
    }
    
    // Try virtual master volume first (works for most devices)
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    if ([self isPropertySettable:kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                           scope:kAudioObjectPropertyScopeOutput
                         element:kAudioObjectPropertyElementMain
                        onDevice:deviceId]) {
        
        OSStatus status = AudioObjectSetPropertyData(deviceId, &addr, 0, NULL, sizeof(scalar), &scalar);
        
        if (status == noErr) {
            return YES;
        }
        
        NSLog(@"[SystemVolumeController] VirtualMainVolume set failed with OSStatus=%d, trying per-channel", (int)status);
    }
    
    // Fall back to per-channel volume (left/right)
    BOOL anyChannelSet = NO;
    OSStatus lastError = noErr;
    
    // Try channels 1 and 2 (left and right)
    for (UInt32 channel = 1; channel <= 2; channel++) {
        addr.mSelector = kAudioDevicePropertyVolumeScalar;
        addr.mScope = kAudioObjectPropertyScopeOutput;
        addr.mElement = channel;
        
        if ([self isPropertySettable:kAudioDevicePropertyVolumeScalar
                               scope:kAudioObjectPropertyScopeOutput
                             element:channel
                            onDevice:deviceId]) {
            
            OSStatus status = AudioObjectSetPropertyData(deviceId, &addr, 0, NULL, sizeof(scalar), &scalar);
            
            if (status == noErr) {
                anyChannelSet = YES;
            } else {
                lastError = status;
                NSLog(@"[SystemVolumeController] Channel %u volume set failed with OSStatus=%d", (unsigned int)channel, (int)status);
            }
        }
    }
    
    if (anyChannelSet) {
        return YES;
    }
    
    // No volume control available
    if (error) {
        *error = [NSError errorWithDomain:SystemVolumeControllerErrorDomain
                                     code:SystemVolumeControllerErrorVolumeNotSettable
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"Output device does not support software volume control",
            @"OSStatus": @(lastError)
        }];
    }
    
    return NO;
}

+ (float)currentOutputVolumePercent:(NSError **)error {
    AudioDeviceID deviceId = [self defaultOutputDeviceWithError:error];
    if (deviceId == kAudioObjectUnknown) {
        return -1.0f;
    }
    
    Float32 volume = 0.0f;
    UInt32 size = sizeof(volume);
    
    // Try virtual master volume first
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    if ([self hasProperty:kAudioHardwareServiceDeviceProperty_VirtualMainVolume
                    scope:kAudioObjectPropertyScopeOutput
                  element:kAudioObjectPropertyElementMain
                 onDevice:deviceId]) {
        
        OSStatus status = AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &size, &volume);
        
        if (status == noErr) {
            return volume * 100.0f;
        }
        
        NSLog(@"[SystemVolumeController] VirtualMainVolume get failed with OSStatus=%d, trying per-channel", (int)status);
    }
    
    // Fall back to per-channel volume (use left channel as representative)
    addr.mSelector = kAudioDevicePropertyVolumeScalar;
    addr.mScope = kAudioObjectPropertyScopeOutput;
    addr.mElement = 1;  // Left channel
    
    if ([self hasProperty:kAudioDevicePropertyVolumeScalar
                    scope:kAudioObjectPropertyScopeOutput
                  element:1
                 onDevice:deviceId]) {
        
        OSStatus status = AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &size, &volume);
        
        if (status == noErr) {
            return volume * 100.0f;
        }
    }
    
    if (error) {
        *error = [NSError errorWithDomain:SystemVolumeControllerErrorDomain
                                     code:SystemVolumeControllerErrorVolumeNotReadable
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"Could not read output volume"
        }];
    }
    
    return -1.0f;
}

+ (BOOL)adjustOutputVolumeByDeltaPercent:(float)delta error:(NSError **)error {
    float currentVolume = [self currentOutputVolumePercent:error];
    if (currentVolume < 0) {
        return NO;
    }
    
    float newVolume = fmaxf(0.0f, fminf(100.0f, currentVolume + delta));
    return [self setOutputVolumePercent:newVolume error:error];
}

#pragma mark - Mute Control

+ (BOOL)setMuted:(BOOL)muted error:(NSError **)error {
    AudioDeviceID deviceId = [self defaultOutputDeviceWithError:error];
    if (deviceId == kAudioObjectUnknown) {
        return NO;
    }
    
    UInt32 muteValue = muted ? 1 : 0;
    
    // Try master mute first
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyMute,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    if ([self isPropertySettable:kAudioDevicePropertyMute
                           scope:kAudioObjectPropertyScopeOutput
                         element:kAudioObjectPropertyElementMain
                        onDevice:deviceId]) {
        
        OSStatus status = AudioObjectSetPropertyData(deviceId, &addr, 0, NULL, sizeof(muteValue), &muteValue);
        
        if (status == noErr) {
            return YES;
        }
        
        NSLog(@"[SystemVolumeController] Master mute set failed with OSStatus=%d, trying per-channel", (int)status);
    }
    
    // Fall back to per-channel mute
    BOOL anyChannelSet = NO;
    OSStatus lastError = noErr;
    
    for (UInt32 channel = 1; channel <= 2; channel++) {
        addr.mSelector = kAudioDevicePropertyMute;
        addr.mScope = kAudioObjectPropertyScopeOutput;
        addr.mElement = channel;
        
        if ([self isPropertySettable:kAudioDevicePropertyMute
                               scope:kAudioObjectPropertyScopeOutput
                             element:channel
                            onDevice:deviceId]) {
            
            OSStatus status = AudioObjectSetPropertyData(deviceId, &addr, 0, NULL, sizeof(muteValue), &muteValue);
            
            if (status == noErr) {
                anyChannelSet = YES;
            } else {
                lastError = status;
                NSLog(@"[SystemVolumeController] Channel %u mute set failed with OSStatus=%d", (unsigned int)channel, (int)status);
            }
        }
    }
    
    if (anyChannelSet) {
        return YES;
    }
    
    if (error) {
        *error = [NSError errorWithDomain:SystemVolumeControllerErrorDomain
                                     code:SystemVolumeControllerErrorMuteNotSettable
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"Output device does not support mute control",
            @"OSStatus": @(lastError)
        }];
    }
    
    return NO;
}

+ (BOOL)isMuted:(NSError **)error {
    AudioDeviceID deviceId = [self defaultOutputDeviceWithError:error];
    if (deviceId == kAudioObjectUnknown) {
        return NO;
    }
    
    UInt32 muteValue = 0;
    UInt32 size = sizeof(muteValue);
    
    // Try master mute first
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyMute,
        .mScope = kAudioObjectPropertyScopeOutput,
        .mElement = kAudioObjectPropertyElementMain
    };
    
    if ([self hasProperty:kAudioDevicePropertyMute
                    scope:kAudioObjectPropertyScopeOutput
                  element:kAudioObjectPropertyElementMain
                 onDevice:deviceId]) {
        
        OSStatus status = AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &size, &muteValue);
        
        if (status == noErr) {
            return muteValue != 0;
        }
    }
    
    // Fall back to per-channel mute (left channel)
    addr.mElement = 1;
    
    if ([self hasProperty:kAudioDevicePropertyMute
                    scope:kAudioObjectPropertyScopeOutput
                  element:1
                 onDevice:deviceId]) {
        
        OSStatus status = AudioObjectGetPropertyData(deviceId, &addr, 0, NULL, &size, &muteValue);
        
        if (status == noErr) {
            return muteValue != 0;
        }
    }
    
    if (error) {
        *error = [NSError errorWithDomain:SystemVolumeControllerErrorDomain
                                     code:SystemVolumeControllerErrorMuteNotReadable
                                 userInfo:@{
            NSLocalizedDescriptionKey: @"Could not read mute state"
        }];
    }
    
    return NO;
}

#pragma mark - Debug/Test

+ (BOOL)runSelfTest {
    NSLog(@"[SystemVolumeController] === SELF TEST START ===");
    
    NSError *error = nil;
    BOOL success = YES;
    
    // Step 1: Read current volume
    float originalVolume = [self currentOutputVolumePercent:&error];
    if (originalVolume < 0) {
        NSLog(@"[SystemVolumeController] FAIL: Could not read current volume: %@", error);
        return NO;
    }
    NSLog(@"[SystemVolumeController] Original volume: %.1f%%", originalVolume);
    
    // Step 2: Read current mute state
    BOOL originalMuted = [self isMuted:&error];
    NSLog(@"[SystemVolumeController] Original mute state: %@", originalMuted ? @"muted" : @"unmuted");
    
    // Step 3: Set to 20%
    if (![self setOutputVolumePercent:20.0f error:&error]) {
        NSLog(@"[SystemVolumeController] FAIL: Could not set volume to 20%%: %@", error);
        success = NO;
    } else {
        NSLog(@"[SystemVolumeController] Set volume to 20%%: OK");
    }
    
    // Step 4: Read back and verify
    float readBack = [self currentOutputVolumePercent:&error];
    if (readBack < 0) {
        NSLog(@"[SystemVolumeController] FAIL: Could not read back volume: %@", error);
        success = NO;
    } else {
        NSLog(@"[SystemVolumeController] Read back volume: %.1f%%", readBack);
        if (fabsf(readBack - 20.0f) > 2.0f) {
            NSLog(@"[SystemVolumeController] WARN: Volume read back differs from set value by %.1f%%", fabsf(readBack - 20.0f));
        }
    }
    
    // Step 5: Test mute
    if (![self setMuted:YES error:&error]) {
        NSLog(@"[SystemVolumeController] WARN: Could not set mute: %@", error);
    } else {
        NSLog(@"[SystemVolumeController] Set mute: OK");
        
        BOOL muted = [self isMuted:&error];
        NSLog(@"[SystemVolumeController] Read mute state: %@", muted ? @"muted" : @"unmuted");
    }
    
    // Step 6: Restore original state
    if (![self setMuted:originalMuted error:&error]) {
        NSLog(@"[SystemVolumeController] WARN: Could not restore mute state: %@", error);
    }
    
    if (![self setOutputVolumePercent:originalVolume error:&error]) {
        NSLog(@"[SystemVolumeController] WARN: Could not restore original volume: %@", error);
    } else {
        NSLog(@"[SystemVolumeController] Restored original volume: %.1f%%", originalVolume);
    }
    
    NSLog(@"[SystemVolumeController] === SELF TEST %@ ===", success ? @"PASSED" : @"FAILED");
    
    return success;
}

@end
