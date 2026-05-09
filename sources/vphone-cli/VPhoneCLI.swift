import ArgumentParser
import Darwin
import FirmwarePatcher
import Foundation

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [
            VPhoneBootCLI.self,
            VPhoneScreenshotCLI.self,
            VPhoneRecordCLI.self,
            PatchFirmwareCLI.self,
            PatchComponentCLI.self,
        ],
        defaultSubcommand: VPhoneBootCLI.self
    )
}

struct VPhoneBootCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it from a manifest plist that describes all paths and hardware.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled
          - Signed with vphone entitlements (done automatically by wrapper script)

        Example:
          vphone-cli --config ./config.plist
        """
    )

    @Option(
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL

    @Flag(help: "Boot into DFU mode")
    var dfu: Bool = false

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"
    
    @Option(help: "Firmware variant to execute.")
    var variant: PatchFirmwareCLI.VariantOption = .regular

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:)
    )
    var installIPA: URL?
    
    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned usage (patchless-only).")
    var noVphoned: Bool = false

    /// DFU mode runs without a visible GUI.
    var noGraphics: Bool {
        dfu
    }

    var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    mutating func validate() throws {
        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)"
            )
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)"
            )
        }
    }

    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        return VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpBooter, in: vmDir) : nil,
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpSEPBooter, in: vmDir) : nil,
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
            variant: variant.virtualMachineVariant,
            noVphoned: self.noVphoned
        )
    }

    mutating func run() throws {}
}

struct VPhoneScreenshotCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Save a screenshot from a running vphone window"
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the running VM directory.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL = URL(fileURLWithPath: "vm")

    @Option(
        name: [.customLong("output"), .customShort("o")],
        help: "Output path. Defaults to Desktop when omitted.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL?

    mutating func run() throws {
        var command: [String: Any] = ["t": "screenshot", "screen": false]
        if let output {
            command["path"] = output.standardizedFileURL.path
        }
        let response = try VPhoneHostControlClient.send(command, vmDirectory: vmDirectory)
        if let path = response["path"] as? String {
            print("[screenshot] saved - \(path)")
        } else {
            print("[screenshot] saved")
        }
    }
}

struct VPhoneRecordCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start or stop screen recording on a running vphone window"
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the running VM directory.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL = URL(fileURLWithPath: "vm")

    @Option(
        name: [.customLong("output"), .customShort("o")],
        help: "Output .mov path. Defaults to Desktop when omitted.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL?

    @Option(help: "Seconds to record before automatically stopping.")
    var duration: Double?

    @Flag(help: "Stop an active recording.")
    var stop: Bool = false

    mutating func validate() throws {
        if let duration, duration <= 0 {
            throw ValidationError("`--duration` must be > 0.")
        }
        if stop, output != nil {
            throw ValidationError("`--output` is only valid when starting a recording.")
        }
        if stop, duration != nil {
            throw ValidationError("`--duration` is only valid when starting a recording.")
        }
    }

    mutating func run() throws {
        if stop {
            let response = try VPhoneHostControlClient.send(["t": "record_stop"], vmDirectory: vmDirectory)
            printRecordStop(response)
            return
        }

        var command: [String: Any] = ["t": "record_start"]
        if let output {
            command["path"] = output.standardizedFileURL.path
        }
        let response = try VPhoneHostControlClient.send(command, vmDirectory: vmDirectory)
        if let path = response["path"] as? String {
            print("[record] started - \(path)")
        } else {
            print("[record] started")
        }

        if let duration {
            Thread.sleep(forTimeInterval: duration)
            let stopResponse = try VPhoneHostControlClient.send(["t": "record_stop"], vmDirectory: vmDirectory)
            printRecordStop(stopResponse)
        }
    }

    private func printRecordStop(_ response: [String: Any]) {
        if let path = response["path"] as? String {
            print("[record] saved - \(path)")
        } else {
            print("[record] stopped")
        }
    }
}

enum VPhoneHostControlClient {
    private enum ClientError: LocalizedError {
        case socketUnavailable(String)
        case invalidResponse
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case let .socketUnavailable(path):
                "Host control socket is unavailable: \(path). Start the VM with `make boot` first."
            case .invalidResponse:
                "Host control returned an invalid response."
            case let .commandFailed(message):
                message
            }
        }
    }

    static func send(_ command: [String: Any], vmDirectory: URL) throws -> [String: Any] {
        let socketPath = vmDirectory.standardizedFileURL.appendingPathComponent("vphone.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError.socketUnavailable(socketPath)
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ClientError.socketUnavailable(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (index, byte) in pathBytes.enumerated() {
                    dst[index] = byte
                }
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw ClientError.socketUnavailable(socketPath)
        }

        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = data.count
            var offset = 0
            while remaining > 0 {
                let written = write(fd, baseAddress.advanced(by: offset), remaining)
                if written <= 0 {
                    throw ClientError.socketUnavailable(socketPath)
                }
                offset += written
                remaining -= written
            }
        }

        let responseData = readLine(fd: fd)
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        if json["ok"] as? Bool == true {
            return json
        }
        throw ClientError.commandFailed(json["error"] as? String ?? "host control command failed")
    }

    private static func readLine(fd: Int32) -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { break }
            data.append(byte)
        }
        return data
    }
}

struct PatchFirmwareCLI: ParsableCommand {
    enum VariantOption: String, CaseIterable, ExpressibleByArgument {
        case less
        case regular
        case dev
        case jb

        var pipelineVariant: FirmwarePipeline.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            }
        }
        
        var virtualMachineVariant: VPhoneVirtualMachine.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-firmware",
        abstract: "Patch boot-chain firmware in a VM directory using the Swift pipeline"
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the VM directory that contains the *Restore* folder.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL

    @Option(help: "Firmware variant to patch.")
    var variant: VariantOption = .regular

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON."
    )
    var recordsOut: String?

    @Flag(name: .customLong("quiet"), help: "Suppress per-component progress output.")
    var quiet: Bool = false
    
    @Flag(name: .customLong("no-binpack"), help: "Exclude the SSH, VNC, ... binaries from being installed (patchless-only).")
    var noBinpack: Bool = false

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned from being installed (patchless-only).")
    var noVphoned: Bool = false

    mutating func run() throws {
        let pipeline = FirmwarePipeline(
            vmDirectory: vmDirectory,
            variant: variant.pipelineVariant,
            verbose: !quiet,
            noBinpack: noBinpack,
            noVphoned: noVphoned
        )
        let records = try pipeline.patchAll()

        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            print("[patch-firmware] wrote \(records.count) patch records to \(url.path)")
        } else {
            print("[patch-firmware] applied \(records.count) patches for \(variant.rawValue)")
        }
    }
}

struct PatchComponentCLI: ParsableCommand {
    enum ComponentOption: String, CaseIterable, ExpressibleByArgument {
        case txm
        case kernelBase = "kernel-base"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes"
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: .customLong("input"),
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:)
    )
    var input: URL

    @Option(
        name: .customLong("output"),
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL

    @Flag(name: .customLong("quiet"), help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    mutating func run() throws {
        let payload = try IM4PHandler.load(contentsOf: input).payload
        let count: Int
        let patchedData: Data

        switch component {
        case .txm:
            let patcher = TXMPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.patchedData

        case .kernelBase:
            let patcher = KernelPatcher(data: payload, verbose: !quiet)
            count = try patcher.apply()
            patchedData = patcher.buffer.data
        }

        let outputDir = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try patchedData.write(to: output)

        if !quiet {
            print("[patch-component] applied \(count) patches for \(component.rawValue)")
            print("[patch-component] wrote patched payload to \(output.path)")
        }
    }
}
