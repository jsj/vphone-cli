import asyncio
import binascii
import hashlib
import inspect
import plistlib
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from collections.abc import Awaitable
from pathlib import Path
from typing import Optional

import requests
from ipsw_parser.build_manifest import BuildManifest
from ipsw_parser.ipsw import IPSW
from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import (
    ConnectionFailedError,
    ConnectionFailedToUsbmuxdError,
    ConnectionTerminatedError,
    TSSError,
    IRecvNoDeviceConnectedError,
    IncorrectModeError,
)
from pymobiledevice3.restore.asr import ASRClient, DEFAULT_ASR_SYNC_PORT
from pymobiledevice3.irecv import IRecv
from pymobiledevice3.irecv import Mode as IRecvMode
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.restore.device import Device
from pymobiledevice3.restore.recovery import Behavior, Recovery
from pymobiledevice3.restore.restore import Restore
from pymobiledevice3.restore.tss import TSSRequest, TSSResponse
from pymobiledevice3.restore.recovery import lpol_file
from pymobiledevice3.restore.img4 import stitch_component
from usb import util as usb_util
from usb.core import USBError
import typer


def parse_ecid(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    raw = value.strip().lower()
    if raw.startswith("0x"):
        raw = raw[2:]
    if not raw:
        raise ValueError("ECID is empty")
    if any(c not in "0123456789abcdef" for c in raw):
        raise ValueError(f"Invalid ECID: {value}")
    return int(raw, 16)


def normalize_udid(value: Optional[str]) -> Optional[str]:
    return None if value is None else value.strip().upper()


RETRYABLE_IRECV_ERRORS = (IRecvNoDeviceConnectedError, ValueError, USBError)
EAN_IMAGE_FLAGS = ("IsEarlyAccessFirmware", "IsiBootEANFirmware", "IsiBootNonEssentialFirmware")
RECOVERY_TSS_EXCLUDED_COMPONENTS = {
    "Ap,AudioBootChime",
    "Ap,LowPowerMode",
    "AppleLogo",
    "DCP",
    "Liquid",
    "WCHFirmwareUpdater",
}
RESTORE_FIRMWARE_COMPONENTS = {
    "iBSS",
    "iBEC",
    "Ap,RestoreSecurePageTableMonitor",
    "Ap,RestoreTrustedExecutionMonitor",
    "RestoreDeviceTree",
    "RestoreKernelCache",
    "RestoreRamDisk",
    "RestoreSEP",
    "RestoreTrustCache",
}
RESTORE_FIRMWARE_SOURCE_COMPONENTS = {
    "Ap,RestoreSecurePageTableMonitor": "Ap,SecurePageTableMonitor",
    "Ap,RestoreTrustedExecutionMonitor": "Ap,TrustedExecutionMonitor",
}


def find_iphone_erase_identity(identities) -> dict:
    for bi in identities:
        info = bi.get("Info", {})
        variant = info.get("Variant", "").lower()
        if (
            "research" not in variant
            and "upgrade" not in variant
            and "recovery" not in variant
            and info.get("RestoreBehavior") == "Erase"
        ):
            return bi
    raise KeyError("No erase identity found in iPhone manifest")


def find_restore_dir(vm_dir: Path) -> Path:
    candidates = sorted(p for p in vm_dir.glob("iPhone*_Restore") if p.is_dir())
    if not candidates:
        raise FileNotFoundError(f"No iPhone*_Restore directory found in {vm_dir}")
    if len(candidates) > 1:
        raise RuntimeError(
            "Multiple iPhone*_Restore directories found; keep only one active restore tree"
        )
    return candidates[0]


async def resolve_device(ecid: Optional[int], udid: Optional[str]) -> Device:
    print(f"[*] resolve_device: start ecid={ecid} udid={udid}")
    udid_normalized = normalize_udid(udid)

    try:
        devices = [d for d in await usbmux.list_devices() if d.connection_type == "USB"]
    except ConnectionFailedToUsbmuxdError:
        devices = []

    print(f"[*] resolve_device: usbmux usb devices={len(devices)}")

    for usb_device in devices:
        serial = normalize_udid(getattr(usb_device, "serial", None))
        if udid_normalized and serial != udid_normalized:
            continue

        try:
            lockdown = await create_using_usbmux(serial=usb_device.serial, connection_type="USB")
        except (ConnectionFailedError, IncorrectModeError):
            continue

        lockdown_ecid = int(str(lockdown.ecid), 0)
        if ecid is not None and lockdown_ecid != ecid:
            continue

        return Device(lockdown=lockdown)

    if ecid is None and udid_normalized is not None:
        raise RuntimeError(
            "Target UDID not available over usbmux in lockdownd mode and ECID is unset; "
            "set RESTORE_ECID for DFU/Recovery targeting"
        )

    print("[*] resolve_device: falling back to irecv")
    return Device(irecv=wait_for_irecv(ecid, timeout=5))


async def resolve_device_preferring_irecv(ecid: Optional[int], udid: Optional[str]) -> Device:
    print("[*] resolve_device_preferring_irecv: probing irecv first")
    try:
        irecv = wait_for_irecv(ecid, timeout=3)
        print(f"[*] resolve_device_preferring_irecv: using irecv mode={irecv.mode}")
        return Device(irecv=irecv)
    except Exception as exc:
        print(f"[*] resolve_device_preferring_irecv: no irecv endpoint yet ({exc!r})")
    return await resolve_device(ecid, udid)


def wait_for_restore_start_dfu(ecid: Optional[int], timeout: int) -> IRecv:
    print("[*] Waiting for a fresh DFU endpoint before starting restore-update")
    deadline = time.monotonic() + timeout
    stable_dfu_hits = 0
    last_mode = None
    saw_recovery = False
    while time.monotonic() < deadline:
        for recovery_hint in (False, None, True):
            try:
                irecv = IRecv(ecid=ecid, timeout=2, is_recovery=recovery_hint)
                mode = getattr(irecv, "mode", None)
                if mode != last_mode:
                    print(f"  [*] restore-start probe hint={recovery_hint} mode={mode}")
                    last_mode = mode
                if mode == IRecvMode.DFU_MODE:
                    stable_dfu_hits += 1
                    if stable_dfu_hits >= 2:
                        print("  [*] Stable DFU endpoint confirmed twice")
                        return irecv
                else:
                    if mode and getattr(mode, "is_recovery", False):
                        saw_recovery = True
                    stable_dfu_hits = 0
            except RETRYABLE_IRECV_ERRORS:
                continue
        time.sleep(1)
    if saw_recovery:
        raise RuntimeError(
            "Device is already in recovery mode; restart `make boot_dfu` before running `make restore`."
        )
    raise TimeoutError(f"Timed out waiting for fresh DFU endpoint; last mode={last_mode}")


async def cmd_usbmux_list(usb_only: bool) -> None:
    devices = await usbmux.list_devices()
    for device in devices:
        if usb_only and getattr(device, "connection_type", None) != "USB":
            continue
        serial = getattr(device, "serial", None)
        if serial:
            print(serial)


def wait_for_irecv(ecid: Optional[int], timeout: int, is_recovery: Optional[bool] = None) -> IRecv:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            irecv = IRecv(ecid=ecid, timeout=2, is_recovery=is_recovery)
            mode = getattr(irecv, "mode", None)
            try:
                serial = irecv.serial_number
            except Exception:
                serial = None
            print(
                f"  [*] Connected to {'recovery' if is_recovery else 'dfu/recovery'} endpoint"
                f" mode={mode} serial={serial}"
            )
            return irecv
        except RETRYABLE_IRECV_ERRORS as exc:
            print(
                f"  [*] wait_for_irecv attempt={attempt} target="
                f"{'recovery' if is_recovery else 'dfu/recovery'}: no device yet ({exc!r})"
            )
            time.sleep(1)
    mode_label = "recovery" if is_recovery else "dfu/recovery"
    raise TimeoutError(f"Timed out waiting for {mode_label} endpoint")


def wait_for_transition_to_recovery(ecid: Optional[int], timeout: int) -> IRecv:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        for recovery_hint in (True, None, False):
            try:
                irecv = IRecv(ecid=ecid, timeout=2, is_recovery=recovery_hint)
                mode = getattr(irecv, "mode", None)
                print(
                    f"  [*] transition probe attempt={attempt} hint={recovery_hint} mode={mode}"
                )
                if mode and getattr(mode, "is_recovery", False):
                    return irecv
            except RETRYABLE_IRECV_ERRORS:
                continue
        time.sleep(1)
    raise TimeoutError("Timed out waiting for device to transition into recovery mode")


def wait_for_reconnect(ecid: Optional[int], timeout: int) -> IRecv:
    deadline = time.monotonic() + timeout
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        for recovery_hint in (None, False, True):
            try:
                irecv = IRecv(ecid=ecid, timeout=2, is_recovery=recovery_hint)
                mode = getattr(irecv, "mode", None)
                try:
                    serial = irecv.serial_number
                except Exception:
                    serial = None
                print(
                    f"  [*] reconnect attempt={attempt} hint={recovery_hint} mode={mode} serial={serial}"
                )
                return irecv
            except RETRYABLE_IRECV_ERRORS:
                continue
        time.sleep(1)
    raise TimeoutError("Timed out waiting for device reconnect")


def reopen_irecv(ecid: Optional[int], timeout: int, is_recovery: Optional[bool] = None) -> IRecv:
    irecv = wait_for_irecv(ecid, timeout=timeout, is_recovery=is_recovery)
    try:
        usb_util.dispose_resources(irecv._device)
    except Exception as exc:
        print(f"  [*] dispose_resources raised {exc!r}")
    time.sleep(1)
    return wait_for_irecv(ecid, timeout=timeout, is_recovery=is_recovery)


def wait_after_ibss(ecid: Optional[int], timeout: int) -> IRecv:
    print("  [*] Allowing USB stack to settle after iBSS...")
    time.sleep(2)

    deadline = time.monotonic() + timeout
    attempt = 0
    last_mode = None
    while time.monotonic() < deadline:
        attempt += 1
        for recovery_hint in (None, False, True):
            try:
                irecv = IRecv(ecid=ecid, timeout=2, is_recovery=recovery_hint)
                mode = getattr(irecv, "mode", None)
                if mode != last_mode:
                    print(f"  [*] post-iBSS mode observation: hint={recovery_hint} mode={mode}")
                    last_mode = mode
                try:
                    serial = irecv.serial_number
                except Exception:
                    serial = None
                print(
                    f"  [*] post-iBSS reconnect attempt={attempt} hint={recovery_hint} mode={mode} serial={serial}"
                )
                return irecv
            except RETRYABLE_IRECV_ERRORS as exc:
                if attempt <= 3:
                    print(
                        f"  [*] post-iBSS attempt={attempt} hint={recovery_hint} waiting ({exc!r})"
                    )
                continue
        time.sleep(1)
    raise TimeoutError("Timed out waiting for post-iBSS reconnect")


def irecv_send_file(irecv: IRecv, image_path: Path) -> None:
    started = time.monotonic()
    data = image_path.read_bytes()
    print(f"  [*] Read {image_path.name} ({len(data)} bytes)")
    if irecv.mode.is_recovery:
        irecv.send_buffer(data)
    else:
        irecv_send_file_dfu_without_reset(irecv, data)
    elapsed = time.monotonic() - started
    print(f"  [*] Sent {image_path.name} in {elapsed:.2f}s")


def irecv_send_file_dfu_without_reset(irecv: IRecv, data: bytes) -> None:
    packet_size = 0x800
    response = irecv.ctrl_transfer(0xA1, 5, data_or_wLength=1)
    state = response[0]
    print(f"  [*] DFU state before send_buffer: {state}")
    if state == 10:
        irecv.ctrl_transfer(0x21, 4)
        raise RuntimeError("DFU ERROR, issued CLRSTATUS")
    if state != 2:
        irecv.ctrl_transfer(0x21, 6)
        raise RuntimeError(f"Unexpected DFU state {state}, issued ABORT")

    crc = -1
    num_packets = (len(data) + packet_size - 1) // packet_size
    for offset in range(0, len(data), packet_size):
        chunk = data[offset : offset + packet_size]
        packet_index = offset // packet_size
        is_last_packet = offset + packet_size >= len(data)
        if is_last_packet:
            crc = binascii.crc32(data, crc)
            dfu_xbuf = bytearray([0xFF, 0xFF, 0xFF, 0xFF, 0xAC, 0x05, 0x00, 0x01, 0x55, 0x46, 0x44, 0x10])
            crc = binascii.crc32(dfu_xbuf, crc)
            crc_chunk = dfu_xbuf + struct.pack("<I", crc)
            if len(chunk) + 16 > packet_size:
                irecv.ctrl_transfer(0x21, 1, wValue=packet_index, wIndex=0, data_or_wLength=chunk)
                irecv.ctrl_transfer(0x21, 1, wValue=packet_index, wIndex=0, data_or_wLength=crc_chunk)
            else:
                irecv.ctrl_transfer(
                    0x21, 1, wValue=packet_index, wIndex=0, data_or_wLength=chunk + crc_chunk
                )
        else:
            irecv.ctrl_transfer(0x21, 1, wValue=packet_index, wIndex=0, data_or_wLength=chunk)

    while irecv.status != 5:
        time.sleep(1)

    irecv.ctrl_transfer(0x21, 1, wValue=num_packets, wIndex=0)
    for _ in range(2):
        _ = irecv.status


def resolve_kernel_image(ramdisk_dir: Path) -> Path:
    ramdisk_variant = ramdisk_dir / "krnl.ramdisk.img4"
    if ramdisk_variant.exists():
        return ramdisk_variant
    default_kernel = ramdisk_dir / "krnl.img4"
    if default_kernel.exists():
        return default_kernel
    raise FileNotFoundError(f"Kernel image not found in {ramdisk_dir}")


class LoggingRecovery(Recovery):
    async def get_tss_response(self):
        parameters = {}

        parameters["ApECID"] = await self.device.get_ecid()
        ap_nonce = await self.device.get_ap_nonce()
        if ap_nonce is not None:
            parameters["ApNonce"] = ap_nonce

        sep_nonce = await self.device.get_sep_nonce()
        if sep_nonce is not None:
            parameters["ApSepNonce"] = sep_nonce

        parameters["ApProductionMode"] = True

        if await self.device.get_is_image4_supported():
            parameters["ApSecurityMode"] = True
            parameters["ApSupportsImg4"] = True
        else:
            parameters["ApSupportsImg4"] = False

        self.populate_tss_request_from_manifest(parameters)

        request = TSSRequest()
        request.add_common_tags(parameters)
        request.add_ap_tags(parameters)

        if await self.device.get_is_image4_supported():
            request.add_ap_img4_tags(parameters)
        else:
            request.add_ap_img3_tags(parameters)

        for key in RECOVERY_TSS_EXCLUDED_COMPONENTS:
            request.remove_key(key)

        print(f"[*] recovery_tss_request_keys={sorted(request._request.keys())}")
        print(f"[*] recovery_tss_request={request._request}")
        response = await send_tss_with_logging(request._request, "Recovery")
        return TSSResponse(response)

    def get_component_identity(self, name: str):
        if name in RESTORE_FIRMWARE_COMPONENTS:
            return self.build_identity, "restore-build"

        stock_build_identity = self.get_stock_iphone_build_identity()
        if stock_build_identity is not None and stock_build_identity.has_component(name):
            return stock_build_identity, "stock-iphone"

        return self.build_identity, "restore-build"

    def get_stock_iphone_build_identity(self):
        root = getattr(self.ipsw.archive, "_root", None)
        if root is None:
            return None

        manifest_path = Path(root) / "iPhone-BuildManifest.plist"
        if not manifest_path.exists():
            return None

        build_manifest = BuildManifest(self.ipsw, manifest_path.read_bytes())
        for identity in build_manifest.build_identities:
            info = identity.get("Info", {})
            variant = info.get("Variant", "").lower()
            if (
                "research" not in variant
                and "upgrade" not in variant
                and "recovery" not in variant
                and info.get("RestoreBehavior") == "Erase"
            ):
                return identity
        return None

    async def send_component(self, name: str):
        data = None
        tss = self.tss
        if name == "Ap,LocalPolicy":
            tss = self.tss_localpolicy
            data = lpol_file

        component_identity, component_source = self.get_component_identity(name)
        source_name = RESTORE_FIRMWARE_SOURCE_COMPONENTS.get(name, name)
        component = component_identity.get_component(source_name, tss=tss, data=data)

        manifest_entry = component_identity["Manifest"].get(source_name, {})
        info = manifest_entry.get("Info", {})
        path = info.get("Path")
        print(f"[*] send_component metadata: name={name}")
        print(f"  [*] component_source={component_source}")
        print(f"  [*] source_name={source_name}")
        print(f"  [*] manifest_path={path}")
        print(f"  [*] trusted={manifest_entry.get('Trusted')}")
        print(f"  [*] digest_len={len(manifest_entry.get('Digest', b'')) if manifest_entry.get('Digest') is not None else None}")
        print(f"  [*] info_keys={sorted(info.keys())}")
        raw_data = component.data
        print(f"  [*] component_data_len={len(raw_data)}")
        stitched = stitch_component(
            name,
            raw_data,
            tss,
            component_identity,
            await self.device.get_ap_parameters(),
        )
        print(f"  [*] personalized_data_len={len(stitched)}")
        self.device.irecv.send_buffer(stitched)

    async def send_component_and_command(self, name, command):
        print(f"[*] upstream send_component_and_command: {name} -> {command}")
        await self.send_component(name)
        for attempt in (1, 2):
            try:
                self.device.irecv.send_command(command)
                return
            except USBError as exc:
                print(
                    f"  [*] send_command failed for {name} attempt={attempt} "
                    f"mode={getattr(self.device.irecv, 'mode', None)} exc={exc!r}"
                )
                if attempt == 2:
                    raise
                print("  [*] Reopening recovery irecv endpoint and retrying command once")
                self.device.irecv = reopen_irecv(
                    self.device.get_ecid_value(),
                    timeout=10,
                    is_recovery=True,
                )

    async def send_loaded_by_iboot(self):
        manifest = self.build_identity["Manifest"]
        for key, node in manifest.items():
            info = node.get("Info", {})
            iboot = info.get("IsLoadedByiBoot", False)
            iboot_stg1 = info.get("IsLoadedByiBootStage1", False)

            assert isinstance(iboot, bool)
            assert isinstance(iboot_stg1, bool)

            if key == "WCHFirmwareUpdater":
                print("[*] skipping early recovery firmware send for WCHFirmwareUpdater")
                continue

            if iboot and not iboot_stg1:
                await self.send_component_and_command(key, "firmware")


def normalize_tss_value(value):
    if isinstance(value, str):
        raw = value.strip().lower()
        if raw.startswith("0x"):
            try:
                return int(raw, 16)
            except ValueError:
                return value
        return value
    if isinstance(value, dict):
        return {key: normalize_tss_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize_tss_value(item) for item in value]
    return value


def build_cryptex_tss_request(updater_name: str, parameters: dict) -> TSSRequest:
    request = TSSRequest()
    request.add_common_tags(parameters)

    if updater_name == "Cryptex1LocalPolicy" or "Ap,LocalPolicy" in parameters:
        request._request["@ApImg4Ticket"] = True
        for key in (
            "Ap,LocalBoot",
            "Ap,LocalPolicy",
            "Ap,NextStageIM4MHash",
            "Ap,NextStageCryptex1IM4MHash",
            "Ap,RecoveryOSPolicyNonceHash",
            "Ap,VolumeUUID",
            "ApECID",
            "ApChipID",
            "ApBoardID",
            "ApSecurityDomain",
            "ApNonce",
            "ApSecurityMode",
            "ApProductionMode",
        ):
            if key in parameters:
                request._request[key] = parameters[key]
        return request

    request._request["@Cryptex1,Ticket"] = True
    for key in ("ApSecurityMode", "ApProductionMode"):
        if key in parameters:
            request._request[key] = parameters[key]

    for key, value in parameters.items():
        if key.startswith("Cryptex1"):
            request._request[key] = value

    return request


class LoggingRestore(Restore):
    def __init__(self, ipsw: IPSW, device: Device, behavior: Behavior):
        super().__init__(ipsw, device, behavior=behavior, ignore_fdr=False)
        self.verify_restore_complete = False
        self.final_status: Optional[int] = None
        self.final_status_log: Optional[str] = None
        self.restore_error: Optional[str] = None

    def get_stock_iphone_build_identity(self):
        cached = getattr(self, "_stock_iphone_build_identity", None)
        if cached is not None:
            return cached

        root = getattr(self.ipsw.archive, "_root", None)
        if root is None:
            return None

        manifest_path = Path(root) / "iPhone-BuildManifest.plist"
        if not manifest_path.exists():
            return None

        build_manifest = BuildManifest(self.ipsw, manifest_path.read_bytes())
        for identity in build_manifest.build_identities:
            info = identity.get("Info", {})
            variant = info.get("Variant", "").lower()
            if (
                "research" not in variant
                and "upgrade" not in variant
                and "recovery" not in variant
                and info.get("RestoreBehavior") == "Erase"
            ):
                self._stock_iphone_build_identity = identity
                return identity
        return None

    async def get_personalized_data(self, component_name: str, data=None, tss=None, path=None) -> bytes:
        if component_name in RESTORE_FIRMWARE_COMPONENTS:
            return await super().get_personalized_data(component_name, data=data, tss=tss, path=path)

        try:
            return await super().get_personalized_data(component_name, data=data, tss=tss, path=path)
        except KeyError:
            stock_build_identity = self.get_stock_iphone_build_identity()
            if stock_build_identity is None or not stock_build_identity.has_component(component_name):
                raise

            print(f"[*] personalized_data fallback: component={component_name} source=stock-iphone")
            active_tss = tss if tss is not None else self.recovery.tss
            return stitch_component(
                component_name,
                stock_build_identity.get_component(component_name, tss=active_tss, data=data, path=path).data,
                active_tss,
                stock_build_identity,
                await self.device.get_ap_parameters(),
            )

    def load_source_component(self, manifest_entry: dict) -> bytes:
        path = manifest_entry.get("Info", {}).get("Path")
        if path is None:
            raise FileNotFoundError("Manifest entry is missing Info.Path")
        with self.ipsw.open_path(path) as handle:
            return handle.read()

    async def handle_data_request_msg(self, message: dict):
        print(f"[*] data_request: type={message.get('DataType')} args={message.get('Arguments')}")
        await super().handle_data_request_msg(message)

    async def handle_progress_msg(self, message: dict) -> None:
        await super().handle_progress_msg(message)
        if message.get("Operation") == "VERIFY_RESTORE" and message.get("Progress") == 100:
            self.verify_restore_complete = True
            print("[*] verify_restore reached 100%")

    async def handle_status_msg(self, message: dict):
        status = int(message["Status"])
        log = message.get("Log")
        self.final_status = status
        self.final_status_log = log
        print(f"[*] status_msg: status={status} log={log!r}")

        if status == 0:
            await super().handle_status_msg(message)
            return

        self.restore_error = f"restore failed with status={status} log={log!r}"
        self._restore_finished = True

    async def send_image_data(
        self, message: dict, image_list_k: Optional[str], image_type_k: Optional[str], image_data_k: Optional[str]
    ) -> None:
        arguments = message["Arguments"]
        want_image_list = arguments.get(image_list_k)
        image_name = arguments.get("ImageName")
        build_id_manifest = self.build_identity["Manifest"]
        source_manifest = build_id_manifest
        use_source_data = False

        if image_type_k is None:
            image_type_k = arguments["ImageType"]

        accepted_image_types = (image_type_k,)
        if image_type_k == "IsEarlyAccessFirmware":
            accepted_image_types = EAN_IMAGE_FLAGS
            stock_build_identity = self.get_stock_iphone_build_identity()
            if stock_build_identity is not None:
                source_manifest = stock_build_identity["Manifest"]
                use_source_data = True

        if (
            (not want_image_list)
            and (image_name is not None)
            and (image_name not in source_manifest)
            and image_name.startswith("Ap")
        ):
            image_name = image_name.replace("Ap", "Ap,", 1)

        print(
            f"[*] send_image_data: reply_key={image_data_k} "
            f"requested_type={image_type_k} accepted_types={accepted_image_types} "
            f"want_list={want_image_list} image_name={image_name} "
            f"source={'stock-iphone' if use_source_data else 'hybrid-build'}"
        )

        matched_images = []
        data_dict = {}

        for component, manifest_entry in source_manifest.items():
            if not isinstance(manifest_entry, dict):
                continue

            info = manifest_entry.get("Info", {})
            is_image_type = any(info.get(flag) for flag in accepted_image_types)
            if not is_image_type:
                continue

            if want_image_list:
                if image_type_k == "IsiBootEANFirmware" and component == "WCHFirmwareUpdater":
                    print("  [*] skipping WCHFirmwareUpdater from IsiBootEANFirmware image list")
                    continue
                matched_images.append(component)
            elif image_name is None or image_name == component:
                if use_source_data:
                    data_dict[component] = self.load_source_component(manifest_entry)
                else:
                    data_dict[component] = await self.get_personalized_data(component, tss=self.recovery.tss)

        if image_name and not data_dict and image_name in source_manifest:
            print(f"  [*] direct component fallback for {image_name}")
            if use_source_data:
                data_dict[image_name] = self.load_source_component(source_manifest[image_name])
            else:
                data_dict[image_name] = await self.get_personalized_data(image_name, tss=self.recovery.tss)

        req = {}
        if want_image_list:
            req[image_list_k] = matched_images
            preview = matched_images[:12]
            print(f"  [*] matched_image_list_count={len(matched_images)} preview={preview}")
        else:
            if image_name:
                if image_name in data_dict:
                    req[image_data_k] = data_dict[image_name]
                req["ImageName"] = image_name
                print(
                    f"  [*] single_image_present={image_name in data_dict} "
                    f"payload_len={len(data_dict[image_name]) if image_name in data_dict else None}"
                )
            else:
                req[image_data_k] = data_dict
                print(f"  [*] bulk_image_count={len(data_dict)}")

        await self._restored.send(req)

    async def send_filesystem(self, message: dict) -> None:
        print("[*] send_filesystem: start")
        print(f"  [*] message={message}")

        asr_port = message.get("DataPort", DEFAULT_ASR_SYNC_PORT)
        print(f"  [*] ASR port={asr_port}")
        asr = LoggingASRClient(self._restored.udid)
        attempt = 0
        while True:
            attempt += 1
            try:
                print(f"  [*] ASR connect attempt={attempt}")
                await asr.connect(asr_port)
                break
            except ConnectionFailedError as exc:
                print(f"  [*] ASR connect failed attempt={attempt}: {exc!r}")
                await asyncio.sleep(1)

        print("  [*] ASR connected")

        os_component = self.build_identity.get_component("OS")
        print(f"  [*] filesystem path={os_component.path}")
        print(f"  [*] filesystem size={len(os_component.data)}")

        with self.ipsw.open_path(os_component.path) as filesystem:
            await asr.perform_validation(filesystem)
            print("  [*] filesystem validated")

            try:
                await asr.send_payload(filesystem)
                print("  [*] filesystem payload send complete")
            except (BrokenPipeError, ConnectionTerminatedError) as exc:
                print(f"  [*] filesystem payload send failed: {exc!r}")
                raise
            finally:
                await asr.close()

    async def send_firmware_updater_data(self, message: dict):
        arguments = message.get("Arguments", {})
        print("[*] FirmwareUpdaterData request received")
        print(f"  [*] updater_name={arguments.get('MessageArgUpdaterName')}")
        print(f"  [*] message_arg_type={arguments.get('MessageArgType')}")
        print(f"  [*] response_tags={arguments.get('DeviceGeneratedTags', {}).get('ResponseTags')}")
        print(
            "  [*] build_identity_tags="
            f"{arguments.get('DeviceGeneratedTags', {}).get('BuildIdentityTags')}"
        )
        print(f"  [*] message_arg_info={arguments.get('MessageArgInfo')}")
        print(f"  [*] device_generated_request={arguments.get('DeviceGeneratedRequest')}")
        await super().send_firmware_updater_data(message)

    async def get_device_generated_firmware_data(self, updater_name: str, info: dict, arguments: dict) -> dict:
        print(f"[*] get_device_generated_firmware_data updater={updater_name}")
        print(
            "  [*] build_identity_tags="
            f"{arguments.get('DeviceGeneratedTags', {}).get('BuildIdentityTags')}"
        )
        print(
            "  [*] response_tags="
            f"{arguments.get('DeviceGeneratedTags', {}).get('ResponseTags')}"
        )
        print(f"  [*] info={info}")
        print(f"  [*] device_generated_request={arguments.get('DeviceGeneratedRequest')}")
        build_identity_tags = arguments.get("DeviceGeneratedTags", {}).get("BuildIdentityTags")
        response_tags = arguments.get("DeviceGeneratedTags", {}).get("ResponseTags") or []
        device_generated_request = normalize_tss_value(arguments.get("DeviceGeneratedRequest") or {})

        if updater_name in ("Cryptex1", "Cryptex1LocalPolicy"):
            parameters = normalize_tss_value(arguments.get("MessageArgInfo") or {})
            self.populate_tss_request_from_manifest(parameters, build_identity_tags)
            parameters.setdefault("ApProductionMode", True)
            parameters.setdefault("ApSecurityMode", True)
            parameters.setdefault("ApChipID", normalize_tss_value(self.build_identity["ApChipID"]))
            parameters.setdefault("ApBoardID", normalize_tss_value(self.build_identity["ApBoardID"]))
            parameters.update(device_generated_request)
            request = build_cryptex_tss_request(updater_name, parameters)
            print(f"  [*] cryptex_request_keys={sorted(request._request.keys())}")
        else:
            request = TSSRequest()
            parameters = {}
            self.populate_tss_request_from_manifest(parameters, build_identity_tags)
            parameters["@BBTicket"] = True
            parameters["ApSecurityMode"] = True
            parameters["ApProductionMode"] = True

            for key, value in arguments.get("MessageArgInfo", {}).items():
                if key.endswith("ProductionMode"):
                    parameters["ApProductionMode"] = bool(value)

            parameters.update(device_generated_request)
            request.add_common_tags(info)
            request.update(parameters)

            print(f"  [*] provisional_request_keys={sorted(request._request.keys())}")
            if updater_name == "Cryptex1LocalPolicy":
                print("  [*] Cryptex1LocalPolicy detected; pruning generic TSS keys")
                for redacted_field in (
                    "BMU,BoardID",
                    "BMU,ChipID",
                    "BbChipID",
                    "BbProvisioningManifestKeyHash",
                    "BbActivationManifestKeyHash",
                    "BbCalibrationManifestKeyHash",
                    "BbFactoryActivationManifestKeyHash",
                    "BbFDRSecurityKeyHash",
                    "BbSkeyId",
                    "SE,ChipID",
                    "Savage,ChipID",
                    "Savage,PatchEpoch",
                    "Yonkers,BoardID",
                    "Yonkers,ChipID",
                    "Yonkers,PatchEpoch",
                    "Rap,BoardID",
                    "Rap,ChipID",
                    "Rap,SecurityDomain",
                    "Baobab,BoardID",
                    "Baobab,ChipID",
                    "Baobab,ManifestEpoch",
                    "Baobab,SecurityDomain",
                    "eUICC,ChipID",
                    "Timer,BoardID,1",
                    "Timer,BoardID,2",
                    "Timer,ChipID,1",
                    "Timer,ChipID,2",
                    "Timer,SecurityDomain,1",
                    "Timer,SecurityDomain,2",
                    "Manifest",
                    "NeRDEpoch",
                ):
                    request.remove_key(redacted_field)
            else:
                for redacted_field in ("RequiresUIDMode",):
                    request.remove_key(redacted_field)

        response_tags = arguments.get("DeviceGeneratedTags", {}).get("ResponseTags") or []
        print(f"  [*] final_request_keys={sorted(request._request.keys())}")
        print(f"  [*] expected_response_tags={response_tags}")
        print(f"  [*] final_request={request._request}")
        print(f"  [*] Sending {updater_name} TSS request...")
        response = await send_tss_with_logging(request._request, updater_name)
        print(f"  [*] TSS response keys={sorted(response.keys())}")
        return response


def build_logging_restore(ipsw: IPSW, device: Device, behavior: Behavior) -> LoggingRestore:
    restore = LoggingRestore(ipsw, device, behavior)
    restore.recovery = LoggingRecovery(ipsw, device, behavior=behavior)
    return restore


async def send_tss_with_logging(payload: dict, label: str):
    headers = {
        "Cache-Control": "no-cache",
        "Content-type": 'text/xml; charset="utf-8"',
        "User-Agent": "InetURL/1.0",
        "Expect": "",
    }

    loop = asyncio.get_event_loop()

    def post() -> bytes:
        return requests.post(
            "https://gs.apple.com/TSS/controller?action=2",
            headers=headers,
            data=plistlib.dumps(payload),
            verify=False,
        ).content

    with ThreadPoolExecutor() as executor:
        content = await loop.run_in_executor(executor, post)

    message = content.split(b"MESSAGE=", 1)[1].split(b"&", 1)[0].decode()
    if message != "SUCCESS":
        print(f"  [*] {label} TSS raw response={content[:2000]!r}")
        raise TSSError(f"server replied: {message}")

    return plistlib.loads(content.split(b"REQUEST_STRING=", 1)[1])


class LoggingASRClient(ASRClient):
    async def connect(self, port: int = DEFAULT_ASR_SYNC_PORT) -> None:
        print(f"[*] ASR connect: port={port}")
        await super().connect(port)
        print(f"  [*] ASR checksum_chunks={self.checksum_chunks}")

    async def perform_validation(self, filesystem) -> None:
        filesystem.seek(0, 2)
        length = filesystem.tell()
        filesystem.seek(0, 0)
        print(f"[*] ASR validation start size={length}")
        await super().perform_validation(filesystem)
        print("[*] ASR validation complete")

    async def send_payload(self, filesystem) -> None:
        filesystem.seek(0, 2)
        length = filesystem.tell()
        filesystem.seek(0, 0)
        print(f"[*] ASR payload start size={length}")
        sent = 0
        chunk_index = 0
        while True:
            chunk = filesystem.read(0x20000)
            if not chunk:
                break

            chunk_index += 1
            original_chunk_len = len(chunk)
            payload = chunk
            if self.checksum_chunks:
                payload += hashlib.sha1(chunk).digest()

            try:
                await self.send_buffer(payload)
            except (BrokenPipeError, ConnectionTerminatedError) as exc:
                print(
                    "  [*] ASR payload write failed "
                    f"chunk={chunk_index} offset={sent} raw_len={original_chunk_len} "
                    f"wire_len={len(payload)} exc={exc!r}"
                )
                raise

            sent += original_chunk_len
            if chunk_index <= 3 or sent == length or chunk_index % 32 == 0:
                print(
                    f"  [*] ASR payload progress chunk={chunk_index} "
                    f"sent={sent}/{length}"
                )

        print(f"[*] ASR payload complete chunks={chunk_index} bytes={sent}")


def derive_shsh_output(vm_dir: Path, ecid: Optional[int]) -> Path:
    tag = f"{ecid:016X}" if ecid is not None else "auto"
    return vm_dir / f"{tag}.shsh"


async def cmd_restore_get_shsh(
    vm_dir: Path, ecid: Optional[int], udid: Optional[str], out: Optional[Path]
) -> None:
    restore_dir = find_restore_dir(vm_dir)
    ipsw = IPSW.create_from_path(str(restore_dir))
    device = await resolve_device(ecid, udid)
    tss = await Recovery(ipsw, device, behavior=Behavior.Erase).fetch_tss_record()

    out_path = out or derive_shsh_output(vm_dir, device.get_ecid_value())
    with out_path.open("wb") as handle:
        plistlib.dump(tss, handle)

    print(f"[+] SHSH saved: {out_path}")


async def cmd_restore_update(vm_dir: Path, ecid: Optional[int], udid: Optional[str], erase: bool) -> None:
    print("[*] restore-update: starting")
    stable_irecv = wait_for_restore_start_dfu(ecid, timeout=20)
    restore_dir = find_restore_dir(vm_dir)
    print(f"[*] restore-update: restore dir = {restore_dir}")
    ipsw = IPSW.create_from_path(str(restore_dir))
    behavior = Behavior.Erase if erase else Behavior.Update
    print(f"[*] restore-update: behavior = {behavior}")
    device = Device(irecv=stable_irecv)
    print(f"[*] restore-update: device lockdown={device.lockdown is not None} irecv={device.irecv is not None}")
    restore = build_logging_restore(ipsw, device, behavior)
    try:
        await restore.update()
    except ConnectionTerminatedError:
        if restore.verify_restore_complete and restore.restore_error is None and restore.final_status is None:
            print("[*] restored connection closed after verify-restore 100%; treating as success")
        else:
            raise

    if restore.restore_error is not None:
        raise RuntimeError(restore.restore_error)

    print("[+] restore-update completed")


def require_ecid(value: Optional[str | int]) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    try:
        return parse_ecid(value)
    except ValueError as exc:
        raise typer.BadParameter(str(exc)) from exc


app = typer.Typer(help="pymobiledevice3 bridge for vphone", pretty_exceptions_enable=False)


@app.command("usbmux-list", help="List usbmux UDIDs")
def usbmux_list_command(
    usb_only: bool = typer.Option(
        True,
        "--usb-only/--no-usb-only",
        help="Include network devices with --no-usb-only.",
    ),
) -> Awaitable[None]:
    return cmd_usbmux_list(usb_only=usb_only)


@app.command("recovery-probe", help="Probe for DFU/recovery endpoint")
def recovery_probe_command(
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    timeout: int = typer.Option(2, help="Probe timeout in seconds"),
) -> None:
    parsed_ecid = require_ecid(ecid)
    wait_for_irecv(parsed_ecid, timeout=timeout)


@app.command("ramdisk-send", help="Send ramdisk chain over irecv")
def ramdisk_send_command(
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    timeout: int = typer.Option(90, help="Send timeout in seconds"),
    ramdisk_dir: Path = typer.Option(
        Path("Ramdisk"),
        help="Ramdisk directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
) -> None:
    cmd_ramdisk_send(require_ecid(ecid), ramdisk_dir, timeout)


@app.command("restore-get-shsh", help="Fetch SHSH from prepared restore dir")
def restore_get_shsh_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    out: Optional[Path] = typer.Option(
        None,
        help="Output SHSH path",
        exists=False,
        file_okay=True,
        dir_okay=False,
    ),
) -> Awaitable[None]:
    return cmd_restore_get_shsh(vm_dir, require_ecid(ecid), udid, out)


@app.command("restore-update", help="Run erase/update restore from prepared dir")
def restore_update_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    erase: bool = typer.Option(True, "--erase/--no-erase", help="Run update-in-place with --no-erase."),
) -> Awaitable[None]:
    return cmd_restore_update(vm_dir, require_ecid(ecid), udid, erase=erase)


async def main(argv: list[str]) -> None:
    result = app(args=argv, prog_name="pymobiledevice3_bridge.py", standalone_mode=False)
    if inspect.isawaitable(result):
        await result


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
