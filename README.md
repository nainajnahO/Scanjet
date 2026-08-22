# Scanjet

Native macOS (Apple silicon) app for the HP ScanJet G3010 — and any other scanner SANE supports.

The scanner is driven by SANE's `hp3900` backend; Scanjet is a SwiftUI front end that talks to
`libsane` directly through Swift's C interop (`CSane/module.modulemap`).

## Prerequisite

```sh
brew install sane-backends
```

`libsane` and its backends are loaded from `/opt/homebrew` at runtime; they are not bundled.
`scanimage -L` should list the scanner before you expect the app to.

Only one process can hold the scanner. While Scanjet is open, `scanimage` (or a second copy of
Scanjet) fails with "Access denied", and Scanjet fails the same way if something else has it —
quit the other one and press **Reconnect**. Reconnect is also the way back after the USB cable
has been pulled: `hp3900` reports that as a plain "Invalid argument" on the next scan, so the app
cannot tell it apart from a bad setting.

## Run

Open `Scanjet.xcodeproj` in Xcode and run the `Scanjet` scheme (⌘R).

- **Preview** (⌘P) scans the whole bed at the lowest resolution; drag on it to set the scan area — the geometry fields and status bar follow the drag in millimetres.
- **Scan** (⌘R) uses the sidebar settings and the selected area. A front-panel button on the scanner also starts a scan.
- **Cancel** (⌘.) takes effect at the next read; the backend's lamp warm-up and calibration inside `sane_start` cannot be interrupted, so the status bar shows "Cancelling…" until they finish.
- **Save…** (⌘S) writes PNG/TIFF (16-bit preserved) or JPEG via ImageIO.
- **Invert** flips the result — for negatives scanned on the flatbed, where the backend does not invert.
- **Balance** applies per-channel levels plus a grey-world gamma, which removes the orange-mask cast of negative film. Switched on automatically when the source was Negative or Slide. Invert runs first, then Balance; both apply to the canvas and to Save. The processing runs in the background — the status bar says "Processing scan…" until the canvas and Save are ready, which takes a while for a large 16-bit scan in a Debug build.
- The canvas shows a display-sized copy of the scan; Save writes the full-resolution frame.
- Presets set source/mode/resolution/depth; **Raw sensor** turns off gamma and white-shading correction. A preset only touches the options the connected backend has.
- Changing the source between flatbed and the film adapter changes the bed size, so the preview is discarded and the area has to be picked again.
- Quitting mid-scan cancels the scan and waits for the backend to park the carriage before the app exits.
- **Show advanced options** exposes everything the backend has (warm-up, shading, gamma, debug images, chip info).
- The **Log** inspector records every option change and scan with timings.

The sidebar is generated from the backend's option descriptors, so it reflects whatever scanner is connected.
Array-valued options (gamma tables) are not exposed.

## Build notes

- Not sandboxed: libusb needs raw USB access.
- Hardened runtime is on, with `com.apple.security.cs.disable-library-validation` because Homebrew's dylibs are only ad-hoc signed.
- Build settings that point at Homebrew: `SWIFT_INCLUDE_PATHS = $(SRCROOT)/CSane`, `LIBRARY_SEARCH_PATHS = /opt/homebrew/lib`.
- All SANE calls run on `SaneScanner`, an actor with its own serial `DispatchSerialQueue`, so a long `sane_read` loop never blocks the cooperative thread pool. `sane_cancel` is the one call made from outside the actor, as the SANE standard permits.
- `hp3900` quirks the app works around: `sane_cancel` only raises a flag that `sane_start` clears and `sane_read` acts on, so a cancel is remembered and re-issued after `sane_start`, and every scan ends with one extra `sane_read` so the backend parks the carriage and arms the lamp timer even when it gave up early. When the backend delivers fewer lines than it announced, the log says so. Reading a button option clears the press, so only the button poll reads buttons; everything else resolves options from their descriptors. The backend stores option values without checking them against their constraints, so the app clamps first, as `sanei_constrain_value` would.
- Geometry options are handled in whatever type the backend declares: `hp3900` uses whole-millimetre integers, most backends use fixed-point millimetres.
