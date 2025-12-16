//
//  SystemVolumeController.h
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for SystemVolumeController errors
extern NSString * const SystemVolumeControllerErrorDomain;

/// Error codes for SystemVolumeController
typedef NS_ENUM(NSInteger, SystemVolumeControllerErrorCode) {
    SystemVolumeControllerErrorNoDefaultDevice = 1,
    SystemVolumeControllerErrorVolumeNotSettable = 2,
    SystemVolumeControllerErrorVolumeNotReadable = 3,
    SystemVolumeControllerErrorMuteNotSettable = 4,
    SystemVolumeControllerErrorMuteNotReadable = 5,
    SystemVolumeControllerErrorCoreAudioFailure = 6,
};

/**
 * SystemVolumeController provides direct CoreAudio-based control of the system output volume.
 * This avoids AppleScript/NSAppleScript which can fail intermittently in launchd contexts.
 */
@interface SystemVolumeController : NSObject

#pragma mark - Volume Control

/**
 * Sets the system output volume to a percentage value.
 * @param percent Volume level from 0.0 to 100.0
 * @param error On failure, contains the error information
 * @return YES on success, NO on failure
 */
+ (BOOL)setOutputVolumePercent:(float)percent error:(NSError * _Nullable *)error;

/**
 * Gets the current system output volume as a percentage.
 * @param error On failure, contains the error information
 * @return Volume level from 0.0 to 100.0, or -1.0 on error
 */
+ (float)currentOutputVolumePercent:(NSError * _Nullable *)error;

/**
 * Adjusts the system output volume by a delta percentage.
 * @param delta Amount to adjust (-100.0 to +100.0)
 * @param error On failure, contains the error information
 * @return YES on success, NO on failure
 */
+ (BOOL)adjustOutputVolumeByDeltaPercent:(float)delta error:(NSError * _Nullable *)error;

#pragma mark - Mute Control

/**
 * Sets the mute state of the system output.
 * @param muted YES to mute, NO to unmute
 * @param error On failure, contains the error information
 * @return YES on success, NO on failure
 */
+ (BOOL)setMuted:(BOOL)muted error:(NSError * _Nullable *)error;

/**
 * Gets the current mute state of the system output.
 * @param error On failure, contains the error information
 * @return YES if muted, NO if unmuted (also returns NO on error, check error param)
 */
+ (BOOL)isMuted:(NSError * _Nullable *)error;

#pragma mark - Debug/Test

/**
 * Runs a self-test that reads current volume, sets to 20%, reads back, and restores.
 * Logs all steps and results.
 * @return YES if all operations succeeded, NO otherwise
 */
+ (BOOL)runSelfTest;

@end

NS_ASSUME_NONNULL_END
