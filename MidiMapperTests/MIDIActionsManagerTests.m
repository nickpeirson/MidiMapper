#import <XCTest/XCTest.h>
#import "MIDIActionsManager.h"

@interface MIDIActionsManagerTests : XCTestCase
@property (nonatomic) MIDIActionsManager *manager;
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
