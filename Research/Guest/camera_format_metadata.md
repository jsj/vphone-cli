# Synthetic camera format metadata

On iOS27.0.1(24A446), both virtual formats exposed ISO0...0, exposure0...0 and no highest-quality photo format. Device state still reported ISO100 at1/30s.

Halide3.3.1 build3263984 selected formats using `isHighestPhotoQualitySupported`. An empty selection led to zero FOV and infinite focal length; LLDB caught `HalideCamera+0x184d9c` (brk1) converting the result to Int. Process-local correction of that flag then exposed a CALayerInvalidGeometry exception in the duration scroll control from division by the zero duration interval. This is independent of the October29 weak-session teardown fix, whose installed libcamfix hash matched the successful repro.

## Native source correction

`VCamSourceBacking.m` publishes simulated ISO25...3200 (`ISOBase=25`, `DefaultAEMaxGain=32768` Q8) and integration100...1000000 microseconds (1/10000...1s). The source advertises high and highest available photo formats. Exact-build disassembly shows public highest-quality getter delegates to `FigCaptureSourceVideoFormat.isStillImageStabilizationSupported`, reading `SISSupported`, rather than `HighPhotoQualitySupported`. Both keys are included. Still output is the pre-rendered virtual frame; no physical sensor stabilization/fusion or actual sensor exposure/gain is implied.

## Verification

`make camera-format-probe` builds a read-only guest command-line test of actual AVFoundation exports. It fails without positive finite ranges/FOV and a highest-quality format. The baseline failed3checks; installed corrected library passed with0failures for both BGRA and420v formats. The test runs without foreground UI. Data-plane124checks, prewarm19checks and drive-gate116checks pass. Full bundle/archive and native shutter capture have not been tested in this change.

Halide camera-entry research still uses a process-local membership routing override, explicitly synthetic. Camera format overrides are removed for final verification. No VM reboot or firmware byte patch was needed; the camera daemon was restarted by environment.install. The old camera library is preserved for rollback.

Raw evidence and LLDB trace: `/Users/james/ios-studies/halide/runtime/retry-20261031/`.
