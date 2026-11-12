#import <Foundation/Foundation.h>
#import <ScriptingBridge/ScriptingBridge.h>
#import "ActionContext.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT double MMMonotonicSeconds(void);

@interface MMSpotifyDiagnosticCall : NSObject
@property (nonatomic, strong, readonly) ActionContext *context;
@end

/// Observes calls without querying Spotify, retrying, or altering execution queues.
@interface SpotifyDiagnostics : NSObject <SBApplicationDelegate>
- (instancetype)init;
// Injected sampler and clock allow tests to run without sampling or external apps.
- (instancetype)initWithDirectory:(NSURL *)directory
                           clock:(double (^)(void))clock
                   slowThreshold:(NSTimeInterval)threshold
                         sampler:(nullable void (^)(MMSpotifyDiagnosticCall *, NSURL *))sampler;
- (void)observeAction:(void (^)(void))action context:(ActionContext *)context;
- (MMSpotifyDiagnosticCall *)beginCall:(ActionContext *)context;
- (NSDictionary *)finishCall:(MMSpotifyDiagnosticCall *)call;
- (void)recordError:(NSError *)error eventClass:(UInt32)eventClass eventID:(UInt32)eventID
               call:(MMSpotifyDiagnosticCall *)call;
- (void)recordLifecycleEvent:(NSString *)event;
- (BOOL)claimSampleForCall:(MMSpotifyDiagnosticCall *)call;
- (NSDictionary *)snapshotForCall:(MMSpotifyDiagnosticCall *)call;
@end

NS_ASSUME_NONNULL_END
