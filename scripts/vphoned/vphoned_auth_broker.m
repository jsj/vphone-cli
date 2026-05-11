/*
 * vphoned_auth_broker — Guest-to-host Apple auth capability broker.
 *
 * This is the reusable control plane for host donation: guest code asks the host
 * for a narrow Apple-authenticated capability, and the host returns only the
 * requested result. It deliberately does not copy Apple ID credentials into the
 * guest.
 */

#import "vphoned_auth_broker.h"
#import "vphoned_protocol.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/vsock.h>
#include <unistd.h>

#define VPHONE_AUTH_BROKER_PORT 1338
#define VPHONE_AUTH_BROKER_LOCAL_PORT 17338

static NSDictionary *broker_error(id reqId, NSString *message) {
  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = message;
  return r;
}

static NSDictionary *forward_to_host_broker(id reqId, NSString *kind,
                                            NSDictionary *payload) {
  if (kind.length == 0) {
    return broker_error(reqId, @"auth_broker_request: missing kind");
  }
  if (payload && ![payload isKindOfClass:[NSDictionary class]]) {
    return broker_error(reqId, @"auth_broker_request: payload must be a dictionary");
  }

  int sock = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (sock < 0) {
    return broker_error(reqId, [NSString stringWithFormat:@"auth broker socket failed: %s", strerror(errno)]);
  }

  struct sockaddr_vm addr = {
      .svm_len = sizeof(struct sockaddr_vm),
      .svm_family = AF_VSOCK,
      .svm_port = VPHONE_AUTH_BROKER_PORT,
      .svm_cid = VMADDR_CID_HOST,
  };

  if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    NSString *message = [NSString stringWithFormat:@"auth broker connect failed: %s", strerror(errno)];
    close(sock);
    return broker_error(reqId, message);
  }

  NSDictionary *brokerRequest = @{
    @"v" : @PROTOCOL_VERSION,
    @"t" : @"auth_broker_request",
    @"kind" : kind,
    @"payload" : payload ?: @{},
  };

  if (!vp_write_message(sock, brokerRequest)) {
    close(sock);
    return broker_error(reqId, @"auth broker write failed");
  }

  NSDictionary *brokerResponse = vp_read_message(sock);
  close(sock);

  if (!brokerResponse) {
    return broker_error(reqId, @"auth broker returned no response");
  }

  NSMutableDictionary *response = [brokerResponse mutableCopy];
  response[@"id"] = reqId;
  if (!response[@"v"])
    response[@"v"] = @PROTOCOL_VERSION;
  if (!response[@"t"])
    response[@"t"] = @"auth_broker_response";
  return response;
}

NSDictionary *vp_handle_auth_broker_command(NSDictionary *msg) {
  return forward_to_host_broker(msg[@"id"], msg[@"kind"], msg[@"payload"]);
}

static void handle_local_relay_client(int fd) {
  @autoreleasepool {
    NSDictionary *msg = vp_read_message(fd);
    if (!msg) {
      close(fd);
      return;
    }
    NSDictionary *resp =
        forward_to_host_broker(msg[@"id"], msg[@"kind"], msg[@"payload"]);
    vp_write_message(fd, resp);
    close(fd);
  }
}

static void *local_relay_thread(void *arg) {
  (void)arg;
  @autoreleasepool {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
      NSLog(@"vphoned: auth broker local relay socket failed: %s", strerror(errno));
      return NULL;
    }

    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(VPHONE_AUTH_BROKER_LOCAL_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
      NSLog(@"vphoned: auth broker local relay bind failed: %s", strerror(errno));
      close(sock);
      return NULL;
    }

    if (listen(sock, 8) < 0) {
      NSLog(@"vphoned: auth broker local relay listen failed: %s", strerror(errno));
      close(sock);
      return NULL;
    }

    NSLog(@"vphoned: auth broker local relay listening on 127.0.0.1:%d",
          VPHONE_AUTH_BROKER_LOCAL_PORT);

    for (;;) {
      int client = accept(sock, NULL, NULL);
      if (client < 0)
        continue;
      handle_local_relay_client(client);
    }
  }
  return NULL;
}

void vp_auth_broker_start_local_relay(void) {
  pthread_t thread;
  int ret = pthread_create(&thread, NULL, local_relay_thread, NULL);
  if (ret != 0) {
    NSLog(@"vphoned: auth broker local relay pthread_create failed: %s",
          strerror(ret));
    return;
  }
  pthread_detach(thread);
}
