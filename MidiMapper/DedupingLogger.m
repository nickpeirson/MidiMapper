//
//  DedupingLogger.m
//  MidiMapper
//
//  Created by Nick Peirson on 16/12/2024.
//  Copyright © 2024 Nick Peirson. All rights reserved.
//

#import "DedupingLogger.h"
#import <os/lock.h>
#import <os/log.h>

static NSString *const kLogSubsystem = @"com.nickpeirson.MidiMapper";

static os_log_t MMLoggerForCategory(NSString *category) {
    static os_log_t midiLog;
    static os_log_t actionLog;
    static os_log_t spotifyLog;
    static os_log_t hueLog;
    static os_log_t coreAudioLog;
    static os_log_t generalLog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const char *subsystem = kLogSubsystem.UTF8String;
        midiLog = os_log_create(subsystem, "MIDI");
        actionLog = os_log_create(subsystem, "Action");
        spotifyLog = os_log_create(subsystem, "Spotify");
        hueLog = os_log_create(subsystem, "Hue");
        coreAudioLog = os_log_create(subsystem, "CoreAudio");
        generalLog = os_log_create(subsystem, "General");
    });

    if ([category caseInsensitiveCompare:@"MIDI"] == NSOrderedSame) return midiLog;
    if ([category caseInsensitiveCompare:@"Action"] == NSOrderedSame ||
        [category caseInsensitiveCompare:@"AE"] == NSOrderedSame) return actionLog;
    if ([category caseInsensitiveCompare:@"Spotify"] == NSOrderedSame) return spotifyLog;
    if ([category caseInsensitiveCompare:@"Hue"] == NSOrderedSame) return hueLog;
    if ([category caseInsensitiveCompare:@"CoreAudio"] == NSOrderedSame) return coreAudioLog;
    return generalLog;
}

void MMLog(DLogLevel level, NSString *category, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    switch (level) {
        case DLogLevelDebug: type = OS_LOG_TYPE_DEBUG; break;
        case DLogLevelInfo: type = OS_LOG_TYPE_INFO; break;
        case DLogLevelWarn: type = OS_LOG_TYPE_ERROR; break;
        case DLogLevelError: type = OS_LOG_TYPE_FAULT; break;
    }
    os_log_with_type(MMLoggerForCategory(category), type, "%{public}s", message.UTF8String);
}

#pragma mark - LogEntry

@interface DedupingLogEntry : NSObject
@property (nonatomic) uint64_t totalCount;
@property (nonatomic) uint64_t suppressedCount;
@property (nonatomic) uint64_t suppressedSinceLastSummary;
@property (nonatomic) CFAbsoluteTime firstSeen;
@property (nonatomic) CFAbsoluteTime lastSeen;
@property (nonatomic) CFAbsoluteTime lastSummaryEmitted;
@property (nonatomic) CFAbsoluteTime lastAccess;
@property (nonatomic, copy) NSString *lastMessageSample;
@property (nonatomic) DLogLevel level;
@property (nonatomic, copy) NSString *category;
@end

@implementation DedupingLogEntry
@end

#pragma mark - DedupingLogger

@implementation DedupingLogger {
    NSMutableDictionary<NSString *, DedupingLogEntry *> *_entries;
    NSMutableArray<NSString *> *_accessOrder;  // LRU tracking: most recent at end
    os_unfair_lock _lock;
    dispatch_source_t _flushTimer;
}

+ (instancetype)shared {
    static DedupingLogger *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DedupingLogger alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _entries = [NSMutableDictionary dictionaryWithCapacity:200];
        _accessOrder = [NSMutableArray arrayWithCapacity:200];
        _lock = OS_UNFAIR_LOCK_INIT;
        
        // Defaults
        _burstAllowance = 3;
        _summaryInterval = 10.0;
        _quietPeriod = 5.0;
        _maxKeys = 200;
        
        // Start periodic flush timer
        [self startFlushTimer];
    }
    return self;
}

- (void)startFlushTimer {
    _flushTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    
    // Fire every 5 seconds
    dispatch_source_set_timer(_flushTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC);
    
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_flushTimer, ^{
        [weakSelf flushQuietKeys];
    });
    
    dispatch_resume(_flushTimer);
}

- (NSString *)compositeKeyForCategory:(NSString *)category dedupeKey:(NSString *)dedupeKey {
    return [NSString stringWithFormat:@"%@:%@", category, dedupeKey];
}

- (void)logWithLevel:(DLogLevel)level
            category:(NSString *)category
           dedupeKey:(NSString *)dedupeKey
             message:(NSString *)message {
    
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *compositeKey = [self compositeKeyForCategory:category dedupeKey:dedupeKey];
    
    // Truncate message sample for storage
    NSString *messageSample = message.length > 200 ? [message substringToIndex:200] : message;
    
    BOOL shouldEmit = NO;
    BOOL shouldEmitSummary = NO;
    uint64_t suppressedDelta = 0;
    
    os_unfair_lock_lock(&_lock);
    
    DedupingLogEntry *entry = _entries[compositeKey];
    
    if (!entry) {
        // Create new entry, possibly evicting LRU
        if ((NSInteger)_entries.count >= _maxKeys) {
            [self evictLRUEntryLocked];
        }
        
        entry = [[DedupingLogEntry alloc] init];
        entry.firstSeen = now;
        entry.lastSummaryEmitted = now;
        entry.level = level;
        entry.category = category;
        _entries[compositeKey] = entry;
        [_accessOrder addObject:compositeKey];
    } else {
        // Update LRU position
        [_accessOrder removeObject:compositeKey];
        [_accessOrder addObject:compositeKey];
    }
    
    entry.totalCount++;
    entry.lastSeen = now;
    entry.lastAccess = now;
    entry.lastMessageSample = messageSample;
    entry.level = level;
    
    if (entry.totalCount <= (uint64_t)_burstAllowance) {
        // Within burst allowance, emit normally
        shouldEmit = YES;
    } else {
        // Suppressing
        entry.suppressedCount++;
        entry.suppressedSinceLastSummary++;
        
        // Check if we should emit a summary
        if (now - entry.lastSummaryEmitted >= _summaryInterval) {
            shouldEmitSummary = YES;
            suppressedDelta = entry.suppressedSinceLastSummary;
            entry.suppressedSinceLastSummary = 0;
            entry.lastSummaryEmitted = now;
        }
    }
    
    os_unfair_lock_unlock(&_lock);
    
    // Emit outside the lock
    if (shouldEmit) {
        [self emitLogWithLevel:level category:category message:message];
    } else if (shouldEmitSummary) {
        [self emitSummaryForCategory:category
                           dedupeKey:dedupeKey
                     suppressedCount:suppressedDelta
                       messageSample:messageSample];
    }
}

- (void)logfWithLevel:(DLogLevel)level
             category:(NSString *)category
            dedupeKey:(NSString *)dedupeKey
               format:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    [self logWithLevel:level category:category dedupeKey:dedupeKey message:message];
}

- (void)flushQuietKeys {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary *> *summariesToEmit = [NSMutableArray array];
    NSMutableArray<NSString *> *keysToRemove = [NSMutableArray array];
    
    os_unfair_lock_lock(&_lock);
    
    for (NSString *compositeKey in _entries) {
        DedupingLogEntry *entry = _entries[compositeKey];
        
        // Check if quiet (no activity for quietPeriod)
        if (now - entry.lastSeen >= _quietPeriod) {
            if (entry.suppressedSinceLastSummary > 0) {
                // Extract category and dedupeKey from composite
                NSRange colonRange = [compositeKey rangeOfString:@":"];
                NSString *category = [compositeKey substringToIndex:colonRange.location];
                NSString *dedupeKey = [compositeKey substringFromIndex:colonRange.location + 1];
                
                [summariesToEmit addObject:@{
                    @"category": category,
                    @"dedupeKey": dedupeKey,
                    @"count": @(entry.suppressedSinceLastSummary),
                    @"message": entry.lastMessageSample ?: @"",
                    @"final": @YES
                }];
            }
            
            // Remove the entry entirely (reset for next storm)
            [keysToRemove addObject:compositeKey];
        }
    }
    
    for (NSString *key in keysToRemove) {
        [_entries removeObjectForKey:key];
        [_accessOrder removeObject:key];
    }
    
    os_unfair_lock_unlock(&_lock);
    
    // Emit summaries outside the lock
    for (NSDictionary *summary in summariesToEmit) {
        [self emitSummaryForCategory:summary[@"category"]
                           dedupeKey:summary[@"dedupeKey"]
                     suppressedCount:[summary[@"count"] unsignedLongLongValue]
                       messageSample:summary[@"message"]];
    }
}

#pragma mark - Private

- (void)evictLRUEntryLocked {
    // _accessOrder[0] is the least recently used
    if (_accessOrder.count == 0) return;
    
    NSString *lruKey = _accessOrder[0];
    DedupingLogEntry *entry = _entries[lruKey];
    
    // If there are suppressed messages, emit a final summary before evicting
    if (entry && entry.suppressedSinceLastSummary > 0) {
        NSRange colonRange = [lruKey rangeOfString:@":"];
        NSString *category = [lruKey substringToIndex:colonRange.location];
        NSString *dedupeKey = [lruKey substringFromIndex:colonRange.location + 1];
        
        // Schedule summary emission after we release the lock
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [self emitSummaryForCategory:category
                               dedupeKey:dedupeKey
                         suppressedCount:entry.suppressedSinceLastSummary
                           messageSample:entry.lastMessageSample ?: @""
                               isEvicted:YES];
        });
    }
    
    [_entries removeObjectForKey:lruKey];
    [_accessOrder removeObjectAtIndex:0];
}

- (void)emitLogWithLevel:(DLogLevel)level
                category:(NSString *)category
                 message:(NSString *)message {
    MMLog(level, category, @"%@", message);
}

- (void)emitSummaryForCategory:(NSString *)category
                     dedupeKey:(NSString *)dedupeKey
               suppressedCount:(uint64_t)count
                 messageSample:(NSString *)messageSample {
    [self emitSummaryForCategory:category
                       dedupeKey:dedupeKey
                 suppressedCount:count
                   messageSample:messageSample
                       isEvicted:NO];
}

- (void)emitSummaryForCategory:(NSString *)category
                     dedupeKey:(NSString *)dedupeKey
               suppressedCount:(uint64_t)count
                 messageSample:(NSString *)messageSample
                     isEvicted:(BOOL)isEvicted {
    NSString *suffix = isEvicted ? @" (evicted)" : @"";
    MMLogInfo(category, @"[suppressed x%llu] key=%@ last=\"%@\"%@",
              count, dedupeKey, messageSample, suffix);
}

@end
