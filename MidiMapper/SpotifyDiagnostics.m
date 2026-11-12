#import "SpotifyDiagnostics.h"
#import "DedupingLogger.h"
#import <AppKit/AppKit.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/resource.h>

double MMMonotonicSeconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (double)mach_continuous_time() * timebase.numer / timebase.denom / 1e9;
}

@interface MMSpotifyDiagnosticCall ()
@property (nonatomic, strong, readwrite) ActionContext *context;
@property (nonatomic) double start;
@property (nonatomic) BOOL completed;
@property (nonatomic) BOOL sampleClaimed;
@property (nonatomic, strong) NSMutableDictionary *record;
@property (nonatomic, strong, nullable) NSURL *reportURL;
@end
@implementation MMSpotifyDiagnosticCall
@end

@interface SpotifyDiagnostics ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, copy) double (^clock)(void);
@property (nonatomic, copy) void (^sampler)(MMSpotifyDiagnosticCall *, NSURL *);
@property (nonatomic) NSTimeInterval slowThreshold;
@property (nonatomic) double launchedAt;
@property (nonatomic, strong) NSMutableArray *recentCalls;
@property (nonatomic, strong) NSMutableArray *lifecycleEvents;
@property (nonatomic, strong) NSMutableArray *observers;
@property (nonatomic) BOOL incidentCaptured;
@property (nonatomic) NSUInteger captureCount;
@property (nonatomic) dispatch_queue_t watchdogQueue;
@end

@implementation SpotifyDiagnostics

static NSString *const MMSpotifyCallThreadKey = @"com.nickpeirson.MidiMapper.spotifyCall";

- (void)observeAction:(void (^)(void))action context:(ActionContext *)context {
    context.backend = @"Spotify";
    MMSpotifyDiagnosticCall *call = [self beginCall:context];
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    id previousCall = threadState[MMSpotifyCallThreadKey];
    threadState[MMSpotifyCallThreadKey] = call;
    @try {
        action();
    } @catch (NSException *exception) {
        NSError *error = [NSError errorWithDomain:@"MidiMapper.SpotifyException" code:0
            userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: exception.name,
                       @"exceptionName":exception.name}];
        [self recordError:error eventClass:0 eventID:0 call:call];
        @throw;
    } @finally {
        [self finishCall:call];
        if (previousCall) threadState[MMSpotifyCallThreadKey] = previousCall;
        else [threadState removeObjectForKey:MMSpotifyCallThreadKey];
    }
}

- (id)eventDidFail:(const AppleEvent *)event withError:(NSError *)error {
    MMSpotifyDiagnosticCall *call = NSThread.currentThread.threadDictionary[MMSpotifyCallThreadKey];
    UInt32 eventClass = 0, eventID = 0;
    if (event) {
        AEGetAttributePtr(event, keyEventClassAttr, typeType, NULL, &eventClass, sizeof(eventClass), NULL);
        AEGetAttributePtr(event, keyEventIDAttr, typeType, NULL, &eventID, sizeof(eventID), NULL);
    }
    if (call) [self recordError:error eventClass:eventClass eventID:eventID call:call];
    else MMLogError(@"Spotify", @"UNCORRELATED_APPLE_EVENT_ERROR class=%u id=%u error=%@", eventClass, eventID, error);
    return nil;
}

- (instancetype)init {
    NSString *override = NSProcessInfo.processInfo.environment[@"MIDIMAPPER_DIAGNOSTICS_DIR"];
    NSURL *directory = [NSURL fileURLWithPath:override ?: [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Logs/MidiMapper/Diagnostics"] isDirectory:YES];
    self = [self initWithDirectory:directory clock:^double{ return MMMonotonicSeconds(); }
                    slowThreshold:2.0 sampler:nil];
    if (self) {
        __weak SpotifyDiagnostics *weakSelf = self;
        NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
        for (NSString *name in @[NSWorkspaceWillSleepNotification, NSWorkspaceDidWakeNotification]) {
            id token = [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                [weakSelf recordLifecycleEvent:note.name];
            }];
            [self.observers addObject:token];
        }
        MMLogInfo(@"Spotify", @"Diagnostics enabled: directory=%@ slowThreshold=2s sampleDuration=1s pid=%d",
                  directory.path, getpid());
    }
    return self;
}

- (instancetype)initWithDirectory:(NSURL *)directory clock:(double (^)(void))clock
                   slowThreshold:(NSTimeInterval)threshold
                         sampler:(void (^)(MMSpotifyDiagnosticCall *, NSURL *))sampler {
    self = [super init];
    if (self) {
        _directory = directory;
        _clock = [clock copy];
        _sampler = [sampler copy];
        _slowThreshold = threshold;
        _launchedAt = clock();
        _recentCalls = [NSMutableArray array];
        _lifecycleEvents = [NSMutableArray array];
        _observers = [NSMutableArray array];
        _watchdogQueue = dispatch_queue_create("com.nickpeirson.MidiMapper.spotifyDiagnostics", DISPATCH_QUEUE_SERIAL);
        [self recordLifecycleEvent:@"diagnostics-started"];
    }
    return self;
}

- (void)dealloc {
    for (id token in _observers) {
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:token];
    }
}

- (void)recordLifecycleEvent:(NSString *)event {
    NSDictionary *record = @{@"event":event, @"wallTime":NSDate.date.description,
        @"processElapsedSeconds":@(self.clock() - self.launchedAt),
        @"systemUptimeSeconds":@(NSProcessInfo.processInfo.systemUptime)};
    @synchronized (self) {
        [self.lifecycleEvents addObject:record];
        if (self.lifecycleEvents.count > 20) [self.lifecycleEvents removeObjectAtIndex:0];
    }
    MMLogInfo(@"Spotify", @"LIFECYCLE %@", record);
}

- (MMSpotifyDiagnosticCall *)beginCall:(ActionContext *)context {
    MMSpotifyDiagnosticCall *call = [MMSpotifyDiagnosticCall new];
    call.context = context;
    call.start = self.clock();
    uint64_t threadID = 0;
    pthread_threadid_np(NULL, &threadID);
    call.record = [@{@"eventID":@(context.eventId), @"command":context.matchedActionName ?: @"Spotify:Unknown",
        @"startedAt":NSDate.date.description, @"callerThreadID":@(threadID),
        @"callerIsMainThread":@(NSThread.isMainThread),
        @"callerThreadName":NSThread.currentThread.name ?: @"",
        @"processElapsedSeconds":@(call.start - self.launchedAt),
        @"systemUptimeSeconds":@(NSProcessInfo.processInfo.systemUptime),
        @"sendMode":@"kAENoReply", @"appleEventTimeoutSeconds":@5,
        @"outcome":@"running", @"playbackVerified":@NO} mutableCopy];
    MMLogDebug(@"Spotify", @"%@ CALL_START thread=%llu main=%d processElapsed=%.1fs",
               context.logPrefix, threadID, NSThread.isMainThread, call.start - self.launchedAt);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.slowThreshold * NSEC_PER_SEC)),
                   self.watchdogQueue, ^{
        @autoreleasepool {
            if (![self claimSampleForCall:call]) return;
            [self captureCall:call];
        }
    });
    return call;
}

- (BOOL)claimSampleForCall:(MMSpotifyDiagnosticCall *)call {
    @synchronized (self) {
        // A healthy command ends an incident. A persistent fault produces only one sample.
        if (call.completed || call.sampleClaimed || self.incidentCaptured || self.captureCount >= 10) return NO;
        if (self.clock() - call.start < self.slowThreshold) return NO;
        call.sampleClaimed = YES;
        self.incidentCaptured = YES;
        self.captureCount++;
        call.record[@"sampleClaimedAtSeconds"] = @(self.clock() - call.start);
        return YES;
    }
}

- (NSDictionary *)finishCall:(MMSpotifyDiagnosticCall *)call {
    NSDictionary *record;
    BOOL sampled;
    @synchronized (self) {
        double elapsed = self.clock() - call.start;
        call.completed = YES;
        BOOL exceeded = elapsed >= 5.0;
        call.context.didTimeout = call.context.didTimeout || exceeded;
        call.record[@"durationMs"] = @(elapsed * 1000);
        call.record[@"deadlineExceeded"] = @(exceeded);
        call.record[@"returnedAt"] = NSDate.date.description;
        call.record[@"outcome"] = call.context.error ? @"error" : exceeded ? @"deadline-exceeded" : @"returned-unverified";
        record = [call.record copy];
        sampled = call.sampleClaimed;
        [self.recentCalls addObject:record];
        if (self.recentCalls.count > 20) [self.recentCalls removeObjectAtIndex:0];
        if (elapsed < self.slowThreshold && !call.context.error) self.incidentCaptured = NO;
    }
    MMLog(call.context.error || call.context.didTimeout ? DLogLevelError : DLogLevelDebug,
          @"Spotify", @"%@ CALL_RETURNED outcome=%@ duration=%.1fms playbackVerified=NO thread=%@",
          call.context.logPrefix, record[@"outcome"], [record[@"durationMs"] doubleValue], record[@"callerThreadID"]);
    // Preserve final outcome next to a sample even if it completes before the sampler does.
    if (sampled) dispatch_async(self.watchdogQueue, ^{ [self writeReport:call]; });
    return record;
}

- (void)recordError:(NSError *)error eventClass:(UInt32)eventClass eventID:(UInt32)eventID
               call:(MMSpotifyDiagnosticCall *)call {
    @synchronized (self) {
        call.context.error = error;
        call.record[@"error"] = @{@"domain":error.domain, @"code":@(error.code),
            @"description":error.localizedDescription, @"userInfo":error.userInfo.description,
            @"appleEventClass":@(eventClass), @"appleEventID":@(eventID)};
    }
    MMLogError(@"Spotify", @"%@ APPLE_EVENT_ERROR domain=%@ code=%ld details=%@",
               call.context.logPrefix, error.domain, (long)error.code, error.userInfo);
}

- (NSDictionary *)snapshotForCall:(MMSpotifyDiagnosticCall *)call {
    @synchronized (self) {
        return @{@"schemaVersion":@1, @"pid":@(getpid()),
            @"osVersion":NSProcessInfo.processInfo.operatingSystemVersionString,
            @"executable":NSProcessInfo.processInfo.arguments.firstObject ?: @"",
            @"call":[call.record copy], @"recentSpotifyCalls":[self.recentCalls copy],
            @"lifecycleEvents":[self.lifecycleEvents copy],
            @"observedElapsedSeconds":@(self.clock() - call.start),
            @"sampleLimitPerProcess":@10};
    }
}

- (void)writeReport:(MMSpotifyDiagnosticCall *)call {
    if (!call.reportURL) return;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self snapshotForCall:call]
                                                  options:NSJSONWritingPrettyPrinted error:&error];
    if (!data || ![data writeToURL:call.reportURL options:NSDataWritingAtomic error:&error]) {
        MMLogError(@"Spotify", @"%@ REPORT_WRITE_FAILED %@", call.context.logPrefix, error);
    }
}

- (void)captureCall:(MMSpotifyDiagnosticCall *)call {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
        rlim_t ceiling = MIN(limit.rlim_cur, (rlim_t)65536);
        NSUInteger openCount = 0;
        for (int fd = 0; fd < (int)ceiling; fd++) if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) openCount++;
        MMLogInfo(@"Spotify", @"%@ DESCRIPTORS open=%lu scanned=%llu softLimit=%llu", call.context.logPrefix,
                  (unsigned long)openCount, (unsigned long long)ceiling, (unsigned long long)limit.rlim_cur);
        @synchronized (self) {
            call.record[@"openDescriptors"] = @(openCount);
            call.record[@"descriptorScanLimit"] = @(ceiling);
            call.record[@"descriptorSoftLimit"] = @(limit.rlim_cur);
        }
    }
    NSError *error = nil;
    NSString *stem = [NSString stringWithFormat:@"pid-%d-event-%llu-%@", getpid(), call.context.eventId, NSUUID.UUID.UUIDString];
    NSURL *incident = [self.directory URLByAppendingPathComponent:stem isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:incident withIntermediateDirectories:YES
         attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        MMLogError(@"Spotify", @"%@ SAMPLE_DIRECTORY_FAILED %@", call.context.logPrefix, error);
        return;
    }
    call.reportURL = [incident URLByAppendingPathComponent:@"context.json"];
    NSURL *sampleURL = [incident URLByAppendingPathComponent:@"stacks.txt"];
    [self writeReport:call];
    MMLogWarn(@"Spotify", @"%@ SLOW_CALL_SAMPLE directory=%@ (slow does not imply failed)", call.context.logPrefix, incident.path);
    if (self.sampler) {
        self.sampler(call, sampleURL);
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sample"];
    task.arguments = @[[NSString stringWithFormat:@"%d", getpid()], @"1", @"1", @"-file", sampleURL.path];
    NSURL *outputURL = [incident URLByAppendingPathComponent:@"sampler.log"];
    [NSFileManager.defaultManager createFileAtPath:outputURL.path contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingAtPath:outputURL.path];
    if (!output) {
        MMLogError(@"Spotify", @"%@ SAMPLER_OUTPUT_FAILED", call.context.logPrefix);
        return;
    }
    task.standardOutput = output;
    task.standardError = output;
    if (![task launchAndReturnError:&error]) {
        @synchronized (self) { call.record[@"samplerError"] = error.description; }
        [output closeFile];
        [self writeReport:call];
        MMLogError(@"Spotify", @"%@ SAMPLE_LAUNCH_FAILED %@", call.context.logPrefix, error);
        return;
    }
    // Bound the diagnostic subprocess independently; never touch the Spotify worker.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try {
            if (task.running) [task terminate];
        } @catch (NSException *exception) {
            MMLogWarn(@"Spotify", @"Sampler termination raced with exit: %@", exception.reason);
        }
    });
    [task waitUntilExit];
    [output closeFile];
    @synchronized (self) { call.record[@"samplerExitStatus"] = @(task.terminationStatus); }
    [self writeReport:call];
    MMLogInfo(@"Spotify", @"%@ SAMPLE_FINISHED status=%d path=%@", call.context.logPrefix, task.terminationStatus, sampleURL.path);
}

@end
