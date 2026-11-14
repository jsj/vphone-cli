#pragma once
#import <Foundation/Foundation.h>

/// Unlock a passcode-free device, reporting success only after checking state.
NSDictionary *vp_handle_unlock_command(NSDictionary *msg);
