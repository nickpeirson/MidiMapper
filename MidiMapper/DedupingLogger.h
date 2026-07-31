//
//  DedupingLogger.h
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DLogLevel) {
    DLogLevelDebug,
    DLogLevelInfo,
    DLogLevelWarn,
    DLogLevelError
};

/// Write an operational message to macOS Unified Logging. Categories are
/// exposed in Console and can be filtered with `log stream`.
FOUNDATION_EXPORT void MMLog(DLogLevel level,
                             NSString *category,
                             NSString *format, ...) NS_FORMAT_FUNCTION(3,4);

#define MMLogDebug(category, format, ...) MMLog(DLogLevelDebug, category, format, ##__VA_ARGS__)
#define MMLogInfo(category, format, ...)  MMLog(DLogLevelInfo, category, format, ##__VA_ARGS__)
#define MMLogWarn(category, format, ...)  MMLog(DLogLevelWarn, category, format, ##__VA_ARGS__)
#define MMLogError(category, format, ...) MMLog(DLogLevelError, category, format, ##__VA_ARGS__)

@interface DedupingLogger : NSObject

+ (instancetype)shared;

// Configuration
@property (atomic) NSInteger burstAllowance;       // default 3
@property (atomic) NSTimeInterval summaryInterval; // default 10
@property (atomic) NSTimeInterval quietPeriod;     // default 5
@property (atomic) NSInteger maxKeys;              // default 200

/// Log a message with deduplication
/// @param level The log level
/// @param category Category string (e.g., "MIDI", "AE", "HUE")
/// @param dedupeKey Unique key for grouping duplicates (e.g., "NoActionDefined:14")
/// @param message The message to log
- (void)logWithLevel:(DLogLevel)level
            category:(NSString *)category
           dedupeKey:(NSString *)dedupeKey
             message:(NSString *)message;

/// Log a formatted message with deduplication
/// @param level The log level
/// @param category Category string (e.g., "MIDI", "AE", "HUE")
/// @param dedupeKey Unique key for grouping duplicates
/// @param format Format string followed by arguments
- (void)logfWithLevel:(DLogLevel)level
             category:(NSString *)category
            dedupeKey:(NSString *)dedupeKey
               format:(NSString *)format, ... NS_FORMAT_FUNCTION(4,5);

/// Flush summaries for keys that have been quiet
/// Call periodically (e.g., on a timer) to emit final summaries
- (void)flushQuietKeys;

@end

NS_ASSUME_NONNULL_END
