# PaperCat

USB scanning app for HP LaserJet Pro MFP M125a, with protocol reverse-engineered from scratch.

## Known Working Status

- End-to-end scan works in both:
  - Swift app (`Services/ScannerManager.swift` path)
  - C reference test (`Tests/scan_interactive.c`)
- Current stable profile in app is parity mode:
  - `RGB24`
  - `300 DPI`
  - Letter scan region (`2550x3300` at 300 DPI)
- Retrieve flow is automated in app (no manual ENTER step).

## Requirements

- macOS 15+
- Xcode Command Line Tools
- Homebrew `libusb`

Install dependency:

```bash
brew install libusb
```

## Quick Start (Swift App)

From project root:

```bash
swift build
open .build/debug/PaperCat
```

Alternative:

```bash
swift run PaperCat
```

## Quick Start (C Reference Test)

Build and run the protocol reference test:

```bash
cd Tests
cc -Wall -Wextra -o scan_interactive scan_interactive.c -I/opt/homebrew/include/libusb-1.0 -L/opt/homebrew/lib -lusb-1.0
./scan_interactive
```

## Developer Checklist (Smoke Test)

Use this when verifying a fresh environment or after protocol changes.

1. Build and launch app:

   ```bash
   swift build
   open .build/debug/PaperCat
   ```

2. In the app, run one scan.

3. Confirm output artifacts exist:

   ```bash
   ls -lh ~/papercat_scan_raw.bin ~/papercat_scan_raw_jpeg.bin ~/papercat_scan_test.jpg
   file ~/papercat_scan_raw_jpeg.bin ~/papercat_scan_test.jpg
   ```

4. Check log for expected success markers:

   ```bash
   grep -E "CreateScanJob immediate JobId|RetrieveImage attempt|Extracted image/|Scan failed" ~/PaperCat.log
   ```

Expected successful pattern:
- `CreateScanJob immediate JobId: <N>`
- `RetrieveImage attempt <N>: <bytes> bytes`
- `Extracted image/jfif: payload=<bytes> jpeg=<bytes>`
- No final `Scan failed` for that run

## Scan Artifacts

The app writes debug/output artifacts to your home directory:

- `~/papercat_scan_raw.bin` - raw RetrieveImage response (HTTP + chunked + DIME)
- `~/papercat_scan_raw_jpeg.bin` - extracted DIME image payload
- `~/papercat_scan_test.jpg` - compatibility re-encoded output used by app
- `~/PaperCat.log` - scan/USB log

The C test writes artifacts in the project root (`papercat_scan_raw.bin`, `papercat_scan_raw_jpeg.bin`, `papercat_scan_output.jpg`).

## Notes

- The app currently favors protocol parity/stability over UI-driven scan parameter selection.
- UI settings are present, but scan request parameters are intentionally pinned to the known good profile for now.
- See `PROTOCOL_FINDINGS.md` for full protocol history, dead ends, and current implementation status.
