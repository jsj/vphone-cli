/*
 * vphoned_auth_broker — Guest-to-host Apple auth capability broker.
 */

#pragma once
#import <Foundation/Foundation.h>

NSDictionary *vp_handle_auth_broker_command(NSDictionary *msg);
void vp_auth_broker_start_local_relay(void);
