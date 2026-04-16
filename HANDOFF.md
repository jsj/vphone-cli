# Handoff

## Goal
Continue debugging the `make restore` / restore-entry flow in `vphone-cli`. This session made real progress on manifest parity and TSS instrumentation, but the current live blocker regressed back to the first recovery `firmware` command for `Ap,RestoreSecurePageTableMonitor`.

## Current repo state
Modified files already present in working tree before/during this session:
- `scripts/fw_manifest.py`
- `scripts/pymobiledevice3_bridge.py`
- `scripts/ramdisk_build.py`
- `scripts/setup_venv.sh`
- `sources/FirmwarePatcher/Manifest/FirmwareManifest.swift`
- `HANDOFF.md`

No commit was created.

## Identity / VM context
Current VM identity from `vm/udid-prediction.txt`:

```text
UDID=0000FE01-6232A8AD4848D25B
CPID=0x0000FE01
ECID=0x6232A8AD4848D25B
MACHINE_IDENTIFIER=config.plist
```

Manual restore commands used repeatedly:

```bash
make restore_get_shsh RESTORE_UDID=0000FE01-6232A8AD4848D25B RESTORE_ECID=0x6232A8AD4848D25B
make restore RESTORE_UDID=0000FE01-6232A8AD4848D25B RESTORE_ECID=0x6232A8AD4848D25B
```

`make boot_dfu` must already be running. There was once a stale auxiliary-storage lock from old `vphone-cli` processes; killing those fixed startup.

Repeated operational gotchas from this session:
- stale `vphone-cli --dfu` processes can hold the auxiliary-storage lock; kill them before restarting `make boot_dfu`
- many failed restore attempts leave no DFU/recovery endpoint visible, so `make boot_dfu` must usually be restarted before each new `make restore`

## What was learned

### 1. The original crash suspicion
The earlier failure pattern strongly matched upstream macOS `libusb` Darwin re-enumeration/use-after-free issues:
- `IRecv.send_buffer()` in DFU mode ends by calling `reset()`
- that maps into risky Darwin `libusb` re-enumeration paths
- upstream `libusb` issue family around reset/attach/detach/hotplug looked like the same class of bug

### 2. Local mitigation added
In `scripts/pymobiledevice3_bridge.py`:
- DFU uploads now avoid `IRecv.send_buffer()`’s automatic `reset()` path
- a local DFU sender was added that performs the transfer without calling reset
- recovery-mode uploads still use the normal upstream path

### 3. Restore flow state-machine fixes added
Also in `scripts/pymobiledevice3_bridge.py`:
- restore entry now accepts either:
  - stable DFU, or
  - already-in-recovery state
- `cmd_restore_update()` now continues when the device is already in recovery
- `cmd_ramdisk_send()` now also accepts already-in-recovery and skips redundant iBSS/iBEC work
- `require_ecid()` was fixed to accept both `str` and `int`

### 4. Custom handoff theories that were tested and did not solve it
These were useful because they ruled out broad classes of failure:

- sending locally built `vm/Ramdisk/*.img4` vs TSS-personalized restore components
- explicit post-`ramdisk` reconnect / USB interface reacquire
- manual restore boot-args staging
- explicit `ApImg4Ticket` upload + `ticket` command
- swapping restore-stage payloads from `vphone600ap` to `vresearch101ap`
- hand-driving the full custom recovery chain instead of upstream restore entry

### 5. Manifest generation change that remains important
The hybrid manifest generators were updated so that:

- installed/runtime payloads still use `vphone600ap` / `vphone600`:
  - `DeviceTree`
  - `SEP`
  - `KernelCache`
- restore-stage payloads now use `vresearch101ap` consistently:
  - `RestoreDeviceTree`
  - `RestoreSEP`
  - `RestoreKernelCache`

Files changed:

- `scripts/fw_manifest.py`
- `sources/FirmwarePatcher/Manifest/FirmwareManifest.swift`

Additional Swift manifest parity completed in this session:
- Swift now also copies iPhone erase-identity cryptex manifest entries:
  - `Cryptex1,AppOS`
  - `Cryptex1,AppTrustCache`
  - `Cryptex1,AppVolume`
  - `Cryptex1,SystemOS`
  - `Cryptex1,SystemTrustCache`
  - `Cryptex1,SystemVolume`
- Swift now also copies iPhone erase-identity `Info` keys:
  - `Cryptex1,AppOSSize`
  - `Cryptex1,SystemOSSize`
  - `MinimumSystemPartition`
  - `OSDiskImageSize`
  - `OSVarContentSize`
  - `RecoveryVariant`
  - `RequiresNonceSlot`
  - `RequiresUIDMode`
- Swift erase-identity selection now also requires `RestoreBehavior == "Erase"`
- Swift explicitly sets `Info.DeviceClass = "vresearch101ap"`

The VM restore tree manifest was regenerated with:

```bash
"/Users/james/Developer/zrepos/zmirror/vphone-cli/.venv/bin/python3" \
  "/Users/james/Developer/zrepos/zmirror/vphone-cli/scripts/fw_manifest.py" \
  "/Users/james/Developer/zrepos/zmirror/vphone-cli/vm/iPhone17,3_26.1_23B85_Restore" \
  "/Users/james/Developer/zrepos/zmirror/vphone-cli/ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432"
```

This materially changed restore-stage personalization sizes:

- `RestoreDeviceTree`: `74244` -> `12449`
- `RestoreKernelCache`: `14056094` -> `12360905`

So the new manifest is definitely being used.

## Latest observed behavior
This session had two distinct phases:

1. a later-stage `FirmwareUpdaterData` / TSS investigation, and
2. a regression back to an earlier recovery `firmware` pipe-error on `Ap,RestoreSecurePageTableMonitor`.

### Upstream restore entry result
Current `cmd_restore_update()` now falls back to upstream `Restore.update()` / `Recovery.enter_restore()` when already in recovery, rather than continuing the big custom handoff.

### Earlier recovery handoff breakthrough
At one point, instrumentation proved that the whole pre-restore chain could succeed:

- `Ap,RestoreSecurePageTableMonitor -> firmware`
- `Ap,RestoreTrustedExecutionMonitor -> firmware`
- `RestoreTrustCache -> firmware`
- `RestoreRamDisk`
- `RestoreDeviceTree -> devicetree`
- `RestoreSEP -> rsepfirmware`
- `RestoreKernelCache -> bootx`

So the old recovery-side blocker is effectively solved.

### Later-stage TSS work completed in this session
`scripts/pymobiledevice3_bridge.py` now contains additional runtime instrumentation:

- `LoggingRestore.send_firmware_updater_data()` prints:
  - `updater_name`
  - `message_arg_type`
  - `response_tags`
  - `build_identity_tags`
  - `message_arg_info`
  - `device_generated_request`
- `LoggingRestore.get_device_generated_firmware_data()` now:
  - logs the synthesized request keys and full request body
  - uses a custom raw-TSS sender to print the raw TSS response body on failure
  - applies special request pruning for `Cryptex1LocalPolicy`

The `Cryptex1LocalPolicy` pruning currently removes:
- `RequiresUIDMode`
- `UniqueBuildID`
- `@BBTicket`
- `Manifest`
- `NeRDEpoch`
- unrelated `BMU,*`, baseband, `SE,*`, `Savage,*`, `Yonkers,*`, `Rap,*`, `Baobab,*`, `eUICC,*`, and `Timer,*` keys

This direction is supported by public idevicerestore history:
- `Cryptex1LocalPolicy` `status=94` failures were historically fixed by stripping `UniqueBuildID` and unrelated manifest tags from the device-generated TSS request
- public reference: libimobiledevice/idevicerestore issue `#518`

### Current live blocker
The latest reproducible failure is no longer the late `FirmwareUpdaterData` TSS error. It now fails earlier during the first recovery `firmware` command:

```text
[*] upstream send_component_and_command: Ap,RestoreSecurePageTableMonitor -> firmware
  [*] send_command failed for Ap,RestoreSecurePageTableMonitor attempt=1 mode=Mode.RECOVERY_MODE_2 exc=USBError(32, 'Pipe error')
  [*] Reopening recovery irecv endpoint and retrying command once
  [*] Connected to recovery endpoint mode=Mode.RECOVERY_MODE_2 serial=None
  [*] Connected to recovery endpoint mode=Mode.RECOVERY_MODE_2 serial=None
  [*] send_command failed for Ap,RestoreSecurePageTableMonitor attempt=2 mode=Mode.RECOVERY_MODE_2 exc=USBError(32, 'Pipe error')
```

Important details:
- recovery reconnection logic was added and works
- the device remains in `RECOVERY_MODE_2`
- the retried handle is valid enough to reconnect, but `send_command("firmware")` still gets a pipe error
- therefore this no longer looks like only a stale-handle issue; it may be a payload/command acceptance problem at iBoot

### Recovery instrumentation added for this blocker
`LoggingRecovery` now:
- retries `send_command(command)` once on `USBError`
- reopens the recovery `IRecv` handle before retry
- logs recovery payload metadata in `send_component()`:
  - manifest path
  - `Trusted`
  - digest length
  - `Info` keys
  - raw component length
  - personalized IMG4 length

However, the user interrupted the next run before that new metadata could be captured in a full failing log.

### Historical later-stage failure (still relevant)
Before the regression back to recovery pipe errors, restore could progress into restore mode and fail later during `FirmwareUpdaterData` handling:

```text
TSSError: server replied: This device isn't eligible for the requested build.
```

The traceback lands in:

```python
Restore.send_firmware_updater_data()
  -> Restore.get_device_generated_firmware_data(updater_name, info, arguments)
  -> TSSRequest.send_receive()
```

## Critical serial log evidence
Historical serial log evidence from the active `boot_dfu` session still matters:

```text
Ramdisk image not valid
Device Tree image not valid
```

But the live, most refined blocker is now earlier and more specific than that old symptom.

## Current conclusion
There are now two credible blockers in play:

1. a likely valid late-stage device-generated TSS mismatch (`Cryptex1LocalPolicy` remains the top suspect), and
2. a newly reappeared earlier recovery pipe error on the first `firmware` command for `Ap,RestoreSecurePageTableMonitor`.

Right now the *live* blocker is the recovery pipe error because it prevents reaching the later TSS stage on current runs.

The current best framing is:
- DFU reset/libusb was a real concern and mitigation exists
- manifest parity work is more complete now
- `Cryptex1LocalPolicy` pruning is implemented and still worth testing
- but the immediate issue to unblock is why iBoot/recovery rejects or aborts on `Ap,RestoreSecurePageTableMonitor -> firmware`

## Key file to continue in
Primary runtime file:

```text
scripts/pymobiledevice3_bridge.py
```

Primary manifest files:

```text
scripts/fw_manifest.py
sources/FirmwarePatcher/Manifest/FirmwareManifest.swift
```

## Most likely next debugging steps
1. Re-run `make boot_dfu` then `make restore` and capture the new `LoggingRecovery.send_component()` metadata for `Ap,RestoreSecurePageTableMonitor`:
   - manifest path
   - `Trusted`
   - digest length
   - `Info` keys
   - raw component length
   - personalized IMG4 length
2. Compare that metadata against a known-good earlier run and/or the source cloudOS manifest entry for `Ap,RestoreSecurePageTableMonitor`.
3. Verify whether the personalized SPTM payload path / ticket / digest pairing changed when the hybrid manifest was regenerated.
4. If recovery starts succeeding again and the restore reaches `FirmwareUpdaterData`, immediately capture:
   - `updater_name`
   - `final_request`
   - raw TSS response body
5. If the updater is `Cryptex1LocalPolicy` and it still fails, compare the emitted request against the historical idevicerestore fixes from issue `#518`.

Do not restart from the older “generic devicetree failure” framing.

## Validation already run
- `"/Users/james/Developer/zrepos/zmirror/vphone-cli/.venv/bin/python3" -m py_compile scripts/pymobiledevice3_bridge.py`
- `"/Users/james/Developer/zrepos/zmirror/vphone-cli/.venv/bin/python3" -m py_compile scripts/fw_manifest.py scripts/pymobiledevice3_bridge.py`
- `python3 -m py_compile scripts/pymobiledevice3_bridge.py` after each bridge change
- `swift build`
- `make build`
- multiple `make restore` runs

Observed `make restore` outcomes in this session:
- some runs timed out immediately because no DFU/recovery endpoint was present
- one run reached restore mode and reproduced the later `TSSError: This device isn't eligible for the requested build`
- later runs consistently failed earlier on `Ap,RestoreSecurePageTableMonitor -> firmware` with `USBError(32, 'Pipe error')`

`pytest` was not installed in the project venv.

## Important note for next session
Do not restart from:

- “libusb crash”
- “generic devicetree failure”

Do restart from:

- the current `LoggingRecovery` / `LoggingRestore` instrumentation already in `scripts/pymobiledevice3_bridge.py`
- the fact that the first current failing recovery component is `Ap,RestoreSecurePageTableMonitor`
- the fact that `Cryptex1LocalPolicy` request-pruning logic has already been implemented but not fully re-exercised due the recovery regression
- the need to restart `make boot_dfu` frequently because failed runs often leave no visible DFU/recovery endpoint

Historical evidence still worth remembering:

```text
Ramdisk image not valid
Device Tree image not valid
```
