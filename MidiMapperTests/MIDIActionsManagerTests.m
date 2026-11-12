#import <XCTest/XCTest.h>
#import "MIDIActionsManager.h"
#import "SpotifyDiagnostics.h"
#import "HueBridgeDiscovery.h"
#import <dns_sd.h>
#import <fcntl.h>

@interface HueBridgeDiscovery (OwnershipTests)
- (BOOL)startService:(DNSServiceRef)ref;
- (void)finishService:(DNSServiceRef)ref;
@end


@interface MIDIActionsManagerTests : XCTestCase
@property (nonatomic) MIDIActionsManager *manager;
@end

@interface SpotifyDiagnosticsTests : XCTestCase
@property (nonatomic, strong) NSURL *directory;
@end

@implementation SpotifyDiagnosticsTests

- (void)setUp {
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
}

- (ActionContext *)context {
    ActionContext *context = [ActionContext contextWithStatus:176 data1:14 data2:68];
    context.matchedActionName = @"Spotify:Play";
    return context;
}

- (NSDictionary *)savedReport {
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:self.directory
        includingPropertiesForKeys:nil options:0 errorHandler:nil];
    for (NSURL *file in files) {
        if ([file.lastPathComponent isEqualToString:@"context.json"]) {
            NSData *data = [NSData dataWithContentsOfURL:file];
            if (data) return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
    }
    return nil;
}

- (void)testLateReturnIsClassifiedWithoutWatchdogCallback {
    __block double now = 100;
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return now; } slowThreshold:1000 sampler:nil];
    MMSpotifyDiagnosticCall *call = [diagnostics beginCall:self.context];
    now += 5.071;
    NSDictionary *record = [diagnostics finishCall:call];
    XCTAssertTrue([record[@"deadlineExceeded"] boolValue]);
    XCTAssertEqualObjects(record[@"outcome"], @"deadline-exceeded");
    XCTAssertTrue(call.context.didTimeout);
    XCTAssertFalse([record[@"playbackVerified"] boolValue]);
    XCTAssertFalse([diagnostics claimSampleForCall:call]);
}

- (void)testErrorIsCorrelatedAndPreserved {
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return 100; } slowThreshold:1000 sampler:nil];
    MMSpotifyDiagnosticCall *call = [diagnostics beginCall:self.context];
    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-1712
        userInfo:@{NSLocalizedDescriptionKey:@"Apple event timed out"}];
    [diagnostics recordError:error eventClass:123 eventID:456 call:call];
    NSDictionary *record = [diagnostics finishCall:call];
    XCTAssertEqualObjects(record[@"eventID"], @(call.context.eventId));
    XCTAssertEqualObjects(record[@"outcome"], @"error");
    XCTAssertEqualObjects(record[@"error"][@"code"], @(-1712));
    XCTAssertEqualObjects(record[@"error"][@"appleEventID"], @456);
    XCTAssertEqualObjects(call.context.error, error);
    XCTAssertNotNil(record[@"callerThreadID"]);
}

- (void)testDelegateCorrelatesErrorOnCallingThread {
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return 100; } slowThreshold:1000 sampler:nil];
    ActionContext *context = self.context;
    NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:-1743 userInfo:nil];
    [diagnostics observeAction:^{ [diagnostics eventDidFail:NULL withError:error]; } context:context];
    XCTAssertEqualObjects(context.error, error);
    XCTAssertEqualObjects(context.backend, @"Spotify");
}

- (void)testOneSamplePerIncidentUntilHealthyCommand {
    __block double now = 0;
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return now; } slowThreshold:1000 sampler:nil];
    MMSpotifyDiagnosticCall *first = [diagnostics beginCall:self.context];
    now += 1001;
    XCTAssertTrue([diagnostics claimSampleForCall:first]);
    XCTAssertFalse([diagnostics claimSampleForCall:first]);
    [diagnostics finishCall:first];
    MMSpotifyDiagnosticCall *second = [diagnostics beginCall:self.context];
    now += 1001;
    XCTAssertFalse([diagnostics claimSampleForCall:second]);
    [diagnostics finishCall:second];
    [diagnostics finishCall:[diagnostics beginCall:self.context]];
    MMSpotifyDiagnosticCall *third = [diagnostics beginCall:self.context];
    now += 1001;
    XCTAssertTrue([diagnostics claimSampleForCall:third]);
    [diagnostics finishCall:third];
}

- (void)testCaptureBudgetAndRecentHistoryAreBounded {
    __block double now = 0;
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return now; } slowThreshold:1000 sampler:nil];
    MMSpotifyDiagnosticCall *last;
    for (NSUInteger i = 0; i < 12; i++) {
        last = [diagnostics beginCall:self.context];
        now += 1001;
        XCTAssertEqual([diagnostics claimSampleForCall:last], i < 10);
        [diagnostics finishCall:last];
        [diagnostics finishCall:[diagnostics beginCall:self.context]];
    }
    NSDictionary *snapshot = [diagnostics snapshotForCall:last];
    XCTAssertEqual([snapshot[@"recentSpotifyCalls"] count], 20u);
    XCTAssertTrue([NSJSONSerialization isValidJSONObject:snapshot]);
}

- (void)testWatchdogSamplesWhileCommandIsStillRunning {
    XCTestExpectation *sampled = [self expectationWithDescription:@"independent watchdog sampled running call"];
    XCTestExpectation *returned = [self expectationWithDescription:@"command returned"];
    __block __weak SpotifyDiagnostics *weakDiagnostics;
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return MMMonotonicSeconds(); } slowThreshold:0.02
        sampler:^(MMSpotifyDiagnosticCall *call, NSURL *path) {
            XCTAssertEqualObjects([weakDiagnostics snapshotForCall:call][@"call"][@"outcome"], @"running");
            XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:
                [[path URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"context.json"].path]);
            [sampled fulfill];
        }];
    weakDiagnostics = diagnostics;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [diagnostics observeAction:^{ [NSThread sleepForTimeInterval:0.12]; } context:self.context];
        [returned fulfill];
    });
    [self waitForExpectations:@[sampled, returned] timeout:2.0];
    XCTestExpectation *persisted = [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [[[self savedReport][@"call"] objectForKey:@"outcome"] isEqualToString:@"returned-unverified"];
    }] evaluatedWithObject:self handler:nil];
    [self waitForExpectations:@[persisted] timeout:2.0];
}

- (void)testNativeSamplerWritesStacksAndExitStatus {
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return MMMonotonicSeconds(); } slowThreshold:0.02 sampler:nil];
    MMSpotifyDiagnosticCall *call = [diagnostics beginCall:self.context];
    XCTestExpectation *persisted = [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return [self savedReport][@"call"][@"samplerExitStatus"] != nil;
    }] evaluatedWithObject:self handler:nil];
    [self waitForExpectations:@[persisted] timeout:8.0];
    XCTAssertEqualObjects([self savedReport][@"call"][@"samplerExitStatus"], @0);
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:self.directory
        includingPropertiesForKeys:nil options:0 errorHandler:nil];
    NSString *stacks = nil;
    for (NSURL *file in files) {
        if ([file.lastPathComponent isEqualToString:@"stacks.txt"])
            stacks = [NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:nil];
    }
    XCTAssertTrue(stacks.length > 0);
    XCTAssertTrue([stacks containsString:@"Call graph:"]);
    [diagnostics finishCall:call];
    XCTestExpectation *returned = [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return ![[self savedReport][@"call"][@"outcome"] isEqualToString:@"running"];
    }] evaluatedWithObject:self handler:nil];
    [self waitForExpectations:@[returned] timeout:2.0];
}

- (void)testQuickCommandDoesNotTriggerSampler {
    XCTestExpectation *sampled = [self expectationWithDescription:@"sampler must not run"];
    sampled.inverted = YES;
    SpotifyDiagnostics *diagnostics = [[SpotifyDiagnostics alloc] initWithDirectory:self.directory
        clock:^double{ return MMMonotonicSeconds(); } slowThreshold:0.02
        sampler:^(MMSpotifyDiagnosticCall *call, NSURL *path) { [sampled fulfill]; }];
    [diagnostics observeAction:^{} context:self.context];
    [self waitForExpectations:@[sampled] timeout:0.08];
}

@end

@interface HueDiscoveryOwnershipTests : XCTestCase
@end
@implementation HueDiscoveryOwnershipTests
- (void)testCompletedAndOutstandingServicesReleaseDescriptors {
    int baseline = 0;
    for (int fd = 0; fd < 1024; fd++) if (fcntl(fd, F_GETFD) != -1) baseline++;
    @autoreleasepool {
        HueBridgeDiscovery *discovery = [HueBridgeDiscovery new];
        for (int i = 0; i < 100; i++) {
            DNSServiceRef ref = NULL;
            XCTAssertEqual(DNSServiceCreateConnection(&ref), kDNSServiceErr_NoError);
            if (!ref) return;
            XCTAssertTrue([discovery startService:ref]);
            [discovery finishService:ref];
        }
        DNSServiceRef outstanding = NULL;
        XCTAssertEqual(DNSServiceCreateConnection(&outstanding), kDNSServiceErr_NoError);
        if (!outstanding) return;
        XCTAssertTrue([discovery startService:outstanding]);
        discovery = nil;
    }
    // DNS-SD closes dispatch-managed sockets asynchronously on the main queue.
    XCTestExpectation *closed = [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        int count = 0;
        for (int fd = 0; fd < 1024; fd++) if (fcntl(fd, F_GETFD) != -1) count++;
        return count <= baseline + 5;
    }] evaluatedWithObject:self handler:nil];
    [self waitForExpectations:@[closed] timeout:3.0];
}
@end

@implementation MIDIActionsManagerTests

- (void)setUp {
    [super setUp];
    self.manager = [[MIDIActionsManager alloc] initForTesting];
}

- (void)testSupportedButtonMappingsHaveStableNames {
    XCTAssertEqualObjects([self.manager actionNameForControl:@"14" actionID:@"67"], @"Spotify:Pause");
    XCTAssertEqualObjects([self.manager actionNameForControl:@"14" actionID:@"68"], @"Spotify:Play");
    XCTAssertEqualObjects([self.manager actionNameForControl:@"10" actionID:@"65"], @"Spotify:PrevTrack");
    XCTAssertEqualObjects([self.manager actionNameForControl:@"10" actionID:@"67"], @"Spotify:NextTrack");
    XCTAssertEqualObjects([self.manager actionNameForControl:@"0" actionID:@"66"], @"System:Mute");
    XCTAssertEqualObjects([self.manager actionNameForControl:@"0" actionID:@"2"], @"System:Unmute");
    XCTAssertNil([self.manager actionNameForControl:@"14" actionID:@"0"]);
}

- (void)testSpotifyAndCoreAudioActionsUseTheirBlockingGroups {
    XCTAssertEqualObjects([self.manager actionGroupForControl:@"14" actionID:@"67"], @"spotify");
    XCTAssertEqualObjects([self.manager actionGroupForControl:@"10" actionID:@"67"], @"spotify");
    XCTAssertEqualObjects([self.manager actionGroupForControl:@"0" actionID:@"66"], @"coreaudio");
    XCTAssertEqualObjects([self.manager actionGroupForControl:@"64" actionID:@"65"], nil);
}

- (void)testSliderMappingsHaveExpectedNamesAndGroups {
    XCTAssertEqualObjects([self.manager sliderActionNameForControl:@"0"], @"System:Volume");
    XCTAssertEqualObjects([self.manager sliderActionGroupForControl:@"0"], @"coreaudio");
    XCTAssertEqualObjects([self.manager sliderActionNameForControl:@"1"], @"Spotify:Volume");
    XCTAssertEqualObjects([self.manager sliderActionGroupForControl:@"1"], @"spotify");
    XCTAssertEqualObjects([self.manager sliderActionNameForControl:@"2"], @"Hue:GroupedLight");
    XCTAssertNil([self.manager sliderActionGroupForControl:@"2"]);
}

- (void)testSliderDispatchCoalescesToTheLatestValue {
    XCTestExpectation *delivered = [self expectationWithDescription:@"latest slider value delivered"];
    __block NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    [self.manager setSliderActionForTesting:^(UInt8 value) {
        [values addObject:@(value)];
        [delivered fulfill];
    } forControl:@"2"];

    [self.manager handleSliderValueForTesting:12 control:@"2"];
    [self.manager handleSliderValueForTesting:96 control:@"2"];
    [self waitForExpectations:@[delivered] timeout:1.0];

    XCTAssertEqualObjects(values, (@[@96]));
}

@end
