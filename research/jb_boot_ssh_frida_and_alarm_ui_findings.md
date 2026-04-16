# JB Boot, SSH, Frida, and Alarm UI Findings

## Scope

This note captures the validated jailbreak bring-up flow on the current repo state, the SSH and Frida setup that was proven working against the booted phone, and runtime findings from Frida inspection of the Clock app's Alarms screen.

## Environment

- Host: macOS 26.5 (`darwin 25.5.0`)
- Repo: `vphone-cli`
- Variant used: Jailbreak (`JB=1`)
- Device observed over usbmux: `0000FE01-65C5A83B187CAFA6`
- Clock app process: `MobileTimer.app/MobileTimer` (`pid 852` during inspection)

## Proven JB Flow

### Full setup

The following end-to-end jailbreak flow completed successfully:

```bash
SUDO_PASSWORD=... make setup_machine JB=1 NONE_INTERACTIVE=1
```

This completed:

- project setup
- boot-chain patching
- restore
- ramdisk build/send
- `cfw_install_jb`
- first boot
- jailbreak finalization handoff

The setup script reported successful boot analysis.

### Boot existing JB VM

Validated boot command:

```bash
make boot
```

## SSH Findings

### Port forward

Working usbmux forward:

```bash
./.venv/bin/python3 -m pymobiledevice3 usbmux forward 2222 22
```

### SSH login

Working login:

```bash
ssh -p 2222 mobile@127.0.0.1
```

Password:

```text
alpine
```

### Important note

After installing `openssh-server` inside the jailbreak environment, SSH on port `22` did not work until the phone was rebooted once. After reboot, SSH worked normally.

### Verified SSH output

The following was successfully executed over SSH:

```bash
whoami && uname -a
```

Observed output:

```text
mobile
Darwin iPhone 25.1.0 Darwin Kernel Version 25.1.0: Thu Oct 23 11:11:48 PDT 2025; root:xnu-12377.42.6~55/RELEASE_ARM64_VRESEARCH1 iPhone99,11 arm Darwin
```

## Frida Findings

### Device-side install

Installed package:

```text
re.frida.server 17.9.1
```

Installed binary:

```text
/var/jb/usr/sbin/frida-server
```

The package was installed from:

```text
frida_17.9.1_iphoneos-arm64.deb
```

### Device-side runtime

`frida-server` was started successfully and verified listening on:

```text
127.0.0.1:27042
```

### Host-side tooling

Local Frida client tools were installed into a project-local virtualenv:

```bash
python3 -m venv .frida-venv
./.frida-venv/bin/python -m pip install frida-tools
```

Installed locally:

- `frida 17.9.1`
- `frida-tools 14.8.1`

### Frida port forward

Working forward:

```bash
./.venv/bin/python3 -m pymobiledevice3 usbmux forward 27042 27042
```

### Verified Frida connectivity

Working process listing:

```bash
./.frida-venv/bin/frida-ps -H 127.0.0.1:27042
```

Working attach sanity check:

```bash
./.frida-venv/bin/frida -H 127.0.0.1:27042 -n SpringBoard -q -e 'console.log(Process.id); console.log(Process.arch);'
```

Observed output:

```text
40
arm64
```

This proves:

- host Frida client works
- usbmux Frida forward works
- device `frida-server` works
- attach + script execution works

## Clock / Alarm UI Runtime Findings

### Target app

Clock on the device was identified as:

```text
/var/containers/Bundle/Application/.../MobileTimer.app/MobileTimer
```

### Live alarm screen controller

When the app was on the Alarms tab, Frida inspection showed:

```text
selected=UINavigationController
visible=MTAAlarmTableViewController
tableView=UITableView
```

This is the strongest live finding for the current question.

## Conclusion: UIKit vs SwiftUI

The Alarms screen is not a pure SwiftUI list. The visible alarm list is a UIKit table-based screen.

The most accurate model from runtime inspection is:

- Swift / support layer for models and state
- UIKit controller for the list UI
- UIKit table cells for edit/swipe/delete behavior

So this appears to be:

```text
Swift model layer + UIKit table UI
```

not:

```text
SwiftUI native List + .swipeActions
```

## Alarm-related classes observed

### UIKit alarm list/controller classes

- `MTAAlarmTableViewController`
- `MTAAlarmTableViewCell`
- `MTAAlarmCollectionViewController`
- `MTAAlarmCollectionViewCell`

### Alarm model / data / support classes

- `MobileTimerSupport.AlarmsViewModel`
- `MTAlarm`
- `MTMutableAlarm`
- `MTAlarmManager`
- `MTAlarmDataSource`
- `MTAlarmStorage`

## Swipe / Delete Implementation Evidence

### On `MTAAlarmTableViewController`

Frida selector inspection found:

- `tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:`
- `tableView:commitEditingStyle:forRowAtIndexPath:`
- `deleteRowAtIndexPath:`
- `setEditing:animated:`
- `editingInteractionConfiguration`
- `editButtonItem`

These are classic UIKit table editing / swipe-delete hooks.

### On `MTAAlarmTableViewCell`

Frida selector inspection found:

- `setShowingDeleteConfirmation:`
- `showingDeleteConfirmation`
- `setWasSwiped:`
- `wasSwiped`
- `setEditing:`
- `setEditing:animated:`

These also match UIKit-managed cell swipe/edit state rather than a SwiftUI-native row action system.

## Best Current Mental Model

```text
MobileTimerSupport.AlarmsViewModel
            ↓
MTAAlarmTableViewController
            ↓
UITableView
            ↓
MTAAlarmTableViewCell
            ↓
UIKit swipe / edit / delete confirmation flow
```

## Notes on Live Hooking

Temporary Frida hooks were successfully armed for:

- `MTAAlarmTableViewController - tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:`
- `MTAAlarmTableViewController - tableView:commitEditingStyle:forRowAtIndexPath:`
- `MTAAlarmTableViewController - deleteRowAtIndexPath:`
- `MTAAlarmTableViewController - setEditing:animated:`
- `MTAAlarmTableViewCell - setShowingDeleteConfirmation:`
- `MTAAlarmTableViewCell - setWasSwiped:`

The session environment did not capture a clean live interaction callback chain in the CLI logs during user interaction, but the controller identity, backing `UITableView`, and method inventory are already enough to conclude the delete behavior is driven by UIKit table view editing/swipe APIs.

## Reusable Commands

### Boot

```bash
make boot
```

### SSH

```bash
./.venv/bin/python3 -m pymobiledevice3 usbmux forward 2222 22
ssh -p 2222 mobile@127.0.0.1
```

### Frida

```bash
./.venv/bin/python3 -m pymobiledevice3 usbmux forward 27042 27042
./.frida-venv/bin/frida-ps -H 127.0.0.1:27042
./.frida-venv/bin/frida -H 127.0.0.1:27042 -n SpringBoard
```
