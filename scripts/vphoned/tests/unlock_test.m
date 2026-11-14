#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <unistd.h>
#include <assert.h>

static uint8_t locked, passcode;
static int presses, unlockAfter, statusError, failAfterPress;
static BOOL hidAvailable = YES;
static mach_port_t test_port(void) { return 1; }
static kern_return_t test_status(mach_port_t port, uint8_t *l, uint8_t *p) {
  if (statusError || (failAfterPress && presses)) return KERN_FAILURE;
  *l = locked; *p = passcode; return KERN_SUCCESS;
}
static void *test_dlopen(const char *path, int mode) { return (void *)1; }
static void *test_dlsym(void *handle, const char *name) {
  return strcmp(name, "SBSSpringBoardServerPort") == 0 ? (void *)test_port : (void *)test_status;
}
static int test_usleep(useconds_t delay) { return 0; }
#define dlopen test_dlopen
#define dlsym test_dlsym
#define usleep test_usleep
#import "../vphoned_unlock.m"
#undef dlopen
#undef dlsym
#undef usleep

BOOL vp_hid_load(void) { return hidAvailable; }
void vp_hid_press(uint32_t page, uint32_t usage) {
  assert(page == 0x0C && usage == 0x40);
  presses++;
  if (unlockAfter && presses >= unlockAfter) locked = 0;
}
NSMutableDictionary *vp_make_response(NSString *type, id reqId) {
  return [@{@"t":type, @"id":reqId} mutableCopy];
}
static NSDictionary *run(uint8_t l, uint8_t p, int after) {
  locked=l; passcode=p; unlockAfter=after; presses=0;
  return vp_handle_unlock_command(@{@"id":@"test"});
}
int main(void) {
  @autoreleasepool {
    NSDictionary *r=run(0,0,0);
    assert([r[@"ok"] boolValue] && [r[@"already_unlocked"] boolValue] && presses==0);
    // An unlocked device with a configured passcode is also a no-op.
    assert([run(0,1,0)[@"ok"] boolValue] && presses==0);
    assert(![run(1,1,0)[@"ok"] boolValue] && presses==0);
    assert([run(1,0,1)[@"ok"] boolValue] && presses==1);
    assert([run(1,0,2)[@"ok"] boolValue] && presses==2);
    assert(![run(1,0,0)[@"ok"] boolValue] && presses==2);
    statusError=1;
    assert(![run(1,0,1)[@"ok"] boolValue] && presses==0);
    statusError=0; failAfterPress=1;
    assert(![run(1,0,1)[@"ok"] boolValue] && presses==1);
    failAfterPress=0; hidAvailable=NO;
    assert(![run(1,0,1)[@"ok"] boolValue] && presses==0);
    puts("unlock: 9 state/error cases passed");
  }
}
