# Unlocking a research vPhone

Use **Keys → Unlock** in the host app, or send this request to the running VM's host-control socket:

```json
{"t":"unlock","screen":false}
```

The command requires a connected vphoned with the `unlock` capability. It checks SpringBoard lock state, returns success immediately if already unlocked, and rejects a locked device that requires a passcode. For a passcode-free lock screen it sends Home events (at most two), polling state before reporting success. It does not toggle Power, open a URL, change Auto-Lock, enter a passcode, or alter security settings.

The socket replies with `ok: true` only after the guest reports it is unlocked. Missing SpringBoard APIs, failed status reads, unavailable HID, and a device that remains locked produce `ok: false` with an error. A successful unlock need not preserve the foreground app; explicitly launch the target and verify its bundle ID before capture.

## Build and test

Use the repository's normal signed builds:

```sh
make build
make vphoned VM_DIR=/absolute/path/to/VM
```

For the modern `vm launch` resource layout, stage the signed daemon at `.build/vphoned.signed` (or the packaged resource location). Relaunch the host so it runs the rebuilt executable and lets the existing daemon update handshake install the matching guest.

Focused tests run the production handler with simulated lock/HID boundaries:

```sh
xcrun --sdk macosx clang -fobjc-arc -fblocks \
  scripts/vphoned/tests/unlock_test.m -framework Foundation -o /tmp/vphone-unlock-test
/tmp/vphone-unlock-test
```

Cases: already unlocked, already unlocked with a configured passcode, locked with passcode, one/two Home events required, still locked, initial status error, verification error, unavailable HID.

## Exact-build validation

September 7, 2026: iPhone99,11 / iOS 27 beta 8 / 24A5430a. `SBGetScreenLockStatus` was checked in SpringBoardServices: the MIG result is returned in w0, and the two output flags are written with byte stores. Resolve it and `SBSSpringBoardServerPort` dynamically after loading the framework.

A signed smoke executable linked against the production unlock/HID code successfully changed a live locked VM to unlocked; an independent RPC status read confirmed both states. A repeat call returned `already_unlocked: true`. Passcode/error cases are simulated tests; no passcode was set on the research VM.

Host socket integration validation is recorded in Kahlo's `artifacts/safari/resume-20260907/`.

The rebuilt host socket passed the same locked-to-unlocked check and a repeat no-op on September 7. Independent RPC checks bracketed the host request; result: `unlock-integration.json` in the Kahlo evidence directory. The host and updated daemon are running on the research VM.
