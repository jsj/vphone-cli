#import "vphoned_unlock.h"
#import "vphoned_hid.h"
#import "vphoned_protocol.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <unistd.h>

// SBGetScreenLockStatus is a MIG call returning kern_return_t and two bytes.
// Verified against SpringBoardServices in iOS 27 build 24A5430a.
typedef mach_port_t (*ServerPortFn)(void);
typedef kern_return_t (*LockStatusFn)(mach_port_t, uint8_t *, uint8_t *);

NSDictionary *vp_handle_unlock_command(NSDictionary *msg) {
  NSMutableDictionary *r = vp_make_response(@"unlock", msg[@"id"]);
  r[@"ok"] = @NO;
  static ServerPortFn serverPort;
  static LockStatusFn lockStatus;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    void *framework = dlopen("/System/Library/PrivateFrameworks/"
                            "SpringBoardServices.framework/SpringBoardServices",
                            RTLD_NOW | RTLD_GLOBAL);
    serverPort = framework ? dlsym(framework, "SBSSpringBoardServerPort") : NULL;
    lockStatus = framework ? dlsym(framework, "SBGetScreenLockStatus") : NULL;
  });
  if (!serverPort || !lockStatus) {
    r[@"msg"] = @"screen lock status is unavailable on this iOS build";
    return r;
  }
  uint8_t locked = 0, passcode = 0;
  kern_return_t status = lockStatus(serverPort(), &locked, &passcode);
  if (status != KERN_SUCCESS) {
    r[@"msg"] = [NSString stringWithFormat:@"cannot read screen lock status (%d)", status];
    return r;
  }
  if (!locked) {
    r[@"ok"] = @YES;
    r[@"already_unlocked"] = @YES;
    return r;
  }
  if (passcode) {
    r[@"msg"] = @"device requires a passcode; unlock it manually";
    return r;
  }
  if (!vp_hid_load()) {
    r[@"msg"] = @"HID event injection is unavailable";
    return r;
  }

  // Home wakes the display. A second press dismisses the passcode-free lock
  // screen if needed. Never toggle Power or open a URL to unlock the device.
  for (int attempt = 0; attempt < 2; attempt++) {
    vp_hid_press(0x0C, 0x40);
    for (int poll = 0; poll < 10; poll++) {
      usleep(200000);
      status = lockStatus(serverPort(), &locked, &passcode);
      if (status != KERN_SUCCESS) {
        r[@"msg"] = [NSString stringWithFormat:@"cannot verify screen lock status (%d)", status];
        return r;
      }
      if (!locked) {
        r[@"ok"] = @YES;
        r[@"already_unlocked"] = @NO;
        return r;
      }
      if (passcode) {
        r[@"msg"] = @"device requires a passcode; unlock it manually";
        return r;
      }
    }
  }
  r[@"msg"] = @"device remained locked after Home events";
  return r;
}
