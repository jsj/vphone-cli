#import "CamFixSessionLifetime.h"
#include <assert.h>

static BOOL checkedDealloc;
@interface SessionProbe : NSObject
@end
@implementation SessionProbe
- (void)dealloc {
  // Mirrors isRunning -> tracking during AVCaptureSession teardown.
  assert(cfx_live_session(self) == nil);
  checkedDealloc = YES;
}
@end

int main(void) {
  @autoreleasepool {
    assert(cfx_live_session(nil) == nil);
    SessionProbe *session = [SessionProbe new];
    assert(cfx_live_session(session) == session);
    session = nil;
    assert(checkedDealloc);
  }
  puts("CamFix session lifetime: passed");
}
