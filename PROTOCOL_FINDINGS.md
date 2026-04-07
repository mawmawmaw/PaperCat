# HP LaserJet Pro MFP M125a — USB Protocol Findings

## Device Identity
- **Model**: HP LaserJet Pro MFP M125a (CZ172A)
- **USB**: Vendor 0x03f0, Product 0x222a
- **Serial**: CNB6GDCLGR
- **Internal codename**: Stars3_01 (from PJL INFO ID)
- **Firmware**: Mrvl-R2_0 (Marvell chip), gSOAP/2.7
- **Memory**: 128MB (from PJL INFO MEMORY)
- **1284 Device ID**: `MFG:Hewlett-Packard;MDL:HP LaserJet Pro MFP M125a;CMD:ACL,CMD,ZJS,URF,PCLm,PJL;CLS:PRINTER;LEDMDIS:USB#ff#04#01`

---

## Current Working Status (2026-04-07)

### End-to-end scan is now working in both C and Swift
- **C reference flow**: `Tests/scan_interactive.c`
- **Swift app flow**: `Services/ScannerManager.swift` + `Services/USBTransport.swift`
- **Decode pipeline**: `Services/DIMEImageExtractor.swift`

### Verified output (from app run)
- `~/papercat_scan_raw.bin`: raw SOAP/HTTP response (~537 KB)
- `~/papercat_scan_raw_jpeg.bin`: extracted DIME image payload, valid JPEG (`2550x3300`, `300 DPI`, RGB)
- `~/papercat_scan_test.jpg`: compatibility re-encoded JPEG used by app preview/export

### Working sequence (parity mode)
1. Prepare Interface 0 session: release/reclaim + DOT4 wake
2. `GetScannerElements` (optional state probe)
3. `CreateScanJobRequest` with known-good parameters (`RGB24`, `300 DPI`, Letter region)
4. Capture `JobId` from immediate or delayed response
5. Send `RetrieveImageRequest` with `JobId` and `JobToken` on the **same SOAP connection**
6. Read DIME/chunked payload and decode to JPEG

### Important behavior
- The app currently runs in **parity mode** for reliability: scan parameters are fixed to the known-good profile (`RGB24`, `300 DPI`, Letter).
- Retrieve is automated in-app (retry/poll loop), so no manual ENTER trigger is required.
- The decode issue was formatting/framing (chunked + DIME continuation), not missing image data.

---

## USB Interfaces

### Interface 0 — SOAP/WSD Scan Command Channel
- **Class**: 0xFF (Vendor), **Subclass**: 0x02, **Protocol**: 0x01
- **Endpoints**: Bulk OUT 0x02, Bulk IN 0x82, Interrupt 0x83
- **Server**: gSOAP/2.7, SOAP 1.2
- **Namespace**: `wscn` = `http://tempuri.org/wscn.xsd`
- **Purpose**: WSD (Web Services for Devices) scan operations
- **Quirk**: Requires DOT4 Init packet (`00 00 00 08 01 00 00 20`) as "wake-up" before bulk reads work
- **Quirk (updated)**: Best reliability comes from release/reclaim + DOT4 at session start, then keeping `CreateScanJobRequest` + `RetrieveImageRequest` on the same connection.

### Interface 1 — Standard Printer (PJL)
- **Class**: 0x07 (Printer), **Subclass**: 0x01, **Protocol**: 0x02
- **Endpoints**: Bulk OUT 0x01, Bulk IN 0x81
- **Supports**: PJL commands (INFO STATUS, INFO ID, INFO CONFIG, INFO VARIABLES, INFO MEMORY)
- **Does NOT support**: PML DMINFO, SCL escape sequences
- **PJL STATUS**: CODE=10001 (ready)

### Interface 2 — LEDM HTTP Document Server (Read-Only)
- **Class**: 0xFF (Vendor), **Subclass**: 0x04, **Protocol**: 0x01
- **Endpoints**: Bulk OUT 0x04, Bulk IN 0x84, Interrupt 0x85
- **Server**: Mrvl-R2_0
- **Allowed methods**: GET, HEAD only (PUT → 405, POST → 404)
- **Quirk**: Returns 0-byte reads between responses; must retry up to 5 times

---

## Working HTTP Endpoints (Interface 2)

All properly routed by URL path:

| URL | Status | Content | Size |
|-----|--------|---------|------|
| `/eSCL/ScannerCapabilities` | 200 | eSCL scanner capabilities XML | 2762 |
| `/eSCL/ScannerStatus` | 200 | Scanner state (Idle) | ~300 |
| `/DevMgmt/ProductStatusDyn.xml` | 200 | Printer status | 2461 |
| `/DevMgmt/ProductConfigDyn.xml` | 200 | Device configuration | 3818 |
| `/DevMgmt/ProductUsageDyn.xml` | 200 | Usage counters | 2593 |
| `/DevMgmt/DiscoveryTree.xml` | 200 | All available LEDM endpoints | 7806 |
| `/DevMgmt/CopyConfigDyn.xml` | 200 | Copy settings | 994 |
| `/DevMgmt/CopyConfigCap.xml` | 200 | Copy capabilities | 2592 |

### eSCL Scanner Capabilities (from `/eSCL/ScannerCapabilities`)
```
Schema: http://schemas.hp.com/imaging/escl/2011/02/08 (v0.98)
Resolutions: 100, 300, 600 DPI
Color Profiles:
  - RGB24 (Color, 8-bit) → image/jpeg, application/pdf
  - Grayscale8 (8-bit) → application/octet-stream, application/pdf
  - BlackAndWhite1 (1-bit) → application/octet-stream, application/pdf
Platen: MaxWidth=2550, MaxHeight=3600 (1/300" units = 8.5" x 12")
Max Optical Resolution: 1200x1200
```

### eSCL Scanner Status (from `/eSCL/ScannerStatus`)
```
Schema: http://schemas.hp.com/imaging/escl/2011/05/03 (v1.93)
State: Idle
```

### DiscoveryTree Endpoints (from `/DevMgmt/DiscoveryTree.xml`)
No scan-related URIs. Only DevMgmt, EventMgmt, and Copy endpoints listed.

---

## SOAP/WSD Operations (Interface 0)

### Session sequence (required at scan start):
```
1. libusb_release_interface(h, 0)
2. usleep(500000)  // 500ms delay
3. libusb_claim_interface(h, 0)
4. Send DOT4 Init: bulk_write(EP 0x02, [00 00 00 08 01 00 00 20])
5. usleep(100000)  // 100ms delay
6. Send GetScannerElements/CreateScanJob/RetrieveImage HTTP POSTs to "/"
7. Read responses from EP 0x82
```

For the working flow, `CreateScanJobRequest` and `RetrieveImageRequest` must be sent on the same session without re-priming in between.

### Recognized SOAP Operations

Tested in `scan_test3.c` (the definitive method probe):

| Operation | Response | Notes |
|-----------|----------|-------|
| `CreateScanJobRequest` (empty) | **7 bytes (accepted)** | Triggers scanner motor! |
| `RetrieveImageRequest` | **7 bytes (accepted)** | Returns DIME with image/bmp |
| `ValidateScanTicketRequest` | **202 ACCEPTED** | Accepts but doesn't set params |
| `GetJobElementsRequest` | **1690 bytes — CreateScanJobResponseType** | Returns job details |
| `CancelJobRequest` | 7 bytes | Accepted |
| `GetScannerElementsRequest` | **400 or CreateScanJobResponseType** | Intermittent — sometimes triggers scan |
| `CreateScanJobType` | 400 Error 13 (SOAP_NO_METHOD) | Not recognized |
| `ScanAvailableEvent` | 400 | Not recognized |
| Empty SOAP body | 400 Error 13 | Expected |

### gSOAP Error Codes
- **Error 4**: Invalid job state / wrong JobId
- **Error 13**: SOAP_NO_METHOD — operation not recognized
- **Error 32**: SOAP_TAG_MISMATCH — XML elements don't match expected schema

---

## Early Behavior: Scan Job Creation Without Image (Historical)

### What works (scan_test3.c — definitive test):
```xml
POST / HTTP/1.1
Host: localhost
Content-Type: text/xml; charset=utf-8

<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
                   xmlns:wscn="http://tempuri.org/wscn.xsd">
<SOAP-ENV:Body>
<wscn:CreateScanJobRequest/>
</SOAP-ENV:Body>
</SOAP-ENV:Envelope>
```
→ Returns 7 bytes (empty chunked success), scanner motor activates.

### CreateScanJobResponseType (from GetJobElementsRequest after job creation):
```xml
<wscn:CreateScanJobResponseType>
  <JobId>N</JobId>
  <JobToken>wscn:job:N</JobToken>
  <ImageInformation>
    <MediaFrontImageInfo>
      <PixelsPerLine>0</PixelsPerLine>         ← ALWAYS 0
      <NumberOfLines>0</NumberOfLines>          ← ALWAYS 0
      <BytesPerLine>0</BytesPerLine>            ← ALWAYS 0
    </MediaFrontImageInfo>
  </ImageInformation>
  <DocumentFinalParameters>
    <Format>201</Format>                        ← garbage (uninitialized)
    <CompressionQualityFactor>-367929647</CompressionQualityFactor>  ← garbage
    <ImagesToTransfer>1</ImagesToTransfer>
    <InputSource>219</InputSource>              ← garbage
    <ContentType>214</ContentType>              ← garbage
    <Resolution><Width>0</Width><Height>0</Height></Resolution>     ← ALWAYS 0
    <ColorProcessing>BlackandWhite1</ColorProcessing>
  </DocumentFinalParameters>
</wscn:CreateScanJobResponseType>
```

**Key finding**: ALL scan parameters are 0 or uninitialized garbage. The server does NOT populate the scan settings struct from any input.

### RetrieveImageRequest Response:
```
HTTP/1.1 200 OK
Content-Type: application/dime
Transfer-Encoding: chunked

DIME Part 1: SOAP envelope with RetrieveImageRequestResponse (href="cid:id1")
DIME Part 2: id=id1, type="image/bmp", data_length=0  ← ALWAYS 0 BYTES
```

The image is always 0 bytes because Resolution=0, PixelsPerLine=0.

---

## Parameter Attempts (Historical)

### Formats that were ACCEPTED (0 bytes back = success):
From `scan_exact.c`:
- `<DocumentFinalParameters>` with full settings → accepted
- `<DocumentParameters>` with settings → accepted
- `<ScanTicket><DocumentParameters>` → accepted
- Direct children (Format, Resolution, etc.) → accepted
- Empty `<CreateScanJobRequest/>` → accepted

**ALL formats are accepted but ALL produce the same garbage parameters.** The server's CreateScanJobRequest handler ignores ALL input XML — it always creates a job with uninitialized defaults.

### Formats that FAILED:
- `wscn:` prefixed elements inside CreateScanJobRequest → Error 32
- LEDM namespace XML → 500 (gSOAP doesn't understand non-SOAP)
- eSCL XML → 404 on Interface 2, 500 on Interface 0

---

## What Triggers the Scanner Motor (Historical)

The scanner motor activates when `CreateScanJobRequest` is accepted. This happens:
- ~70% of the time with the empty `<wscn:CreateScanJobRequest/>`
- Sometimes with parameterized versions
- Requires the full release/reclaim/DOT4 sequence

The motor runs a brief calibration/scan pass but produces 0-byte image output.

---

## Dead Ends Confirmed
- **DOT4 protocol**: Returns 0 bytes on both Interface 0 and Interface 2
- **SCL escape sequences**: No response on Interface 1
- **PML via DMINFO**: No response on Interface 1
- **WalkupScanToComp registration**: 404 (not supported)
- **Physical copy button interception**: Scan data flows internally, never reaches USB
- **Interface 2 POST/PUT**: 404/405 — strictly read-only

---

## Critical Insight from scan_test9 (Historical)

In scan_test9, we ran ValidateScanTicket → CreateScanJob WITH parameters → empty CreateScanJob. The results:

1. **ValidateScanTicket** (with full scan params) → 400 Bad Request (SOAP fault)
2. **CreateScanJob WITH parameters** → **7 bytes (ACCEPTED!)** — this was after the failed ValidateScanTicket
3. **Empty CreateScanJob** → 400 (because a job already existed from #2)

**Key observation**: The parameterized CreateScanJob was accepted (7 bytes = empty chunked success) when sent on the SAME connection immediately after a ValidateScanTicket 400 error. This suggests:
- The ValidateScanTicket may "prime" the gSOAP server's internal state
- OR the gSOAP server processes the second request differently after handling a fault
- OR the chunked encoding terminator from ValidateScanTicket's 400 response was misread as the CreateScanJob response

**This needs further investigation**: If the parameterized CreateScanJob truly was accepted with parameters, the image data should be non-zero. The sequence ValidateScanTicket → CreateScanJob (same connection, no reclaim) should be retested with RetrieveImage.

---

## Session 2 Findings (2026-04-07)

### Plugin binary analysis (`bb_soapht-arm64.so`)
- Channel: `HP-SOAP-SCAN` via `hpmud_open_channel` in RAW_MODE
- Content-Type: `application/soap+xml; charset=utf-8`
- User-Agent: `gSOAP/2.7`
- Full namespace declarations: SOAP-ENC, xsi, xsd, wscn
- Exact CreateScanJobRequest XML extracted (see Tests/scan_plugin_iface0.c)
- Plugin requires DOT4/MLC which returns 0 bytes on all interfaces from macOS

### Model config (models.dat)
- `scan-type=5` (SOAPHT — proprietary plugin)
- `io-mode=1` (RAW_MODE — direct bulk I/O on Interface 1)
- `plugin=1`, `plugin-reason=65` (0x41 = PRINTING_SUPPORT | SCANNING_SUPPORT)
- RAW_MODE means: claim Interface 1, bulk write/read directly (no DOT4/MLC)

### HPLIP transport analysis
- RAW mode (`io-mode=1`): `musb_raw_channel_open` just claims FD_7_1_2 (Interface 1)
- MLC/DOT4 mode: requires `write_ecp_channel(value=77)` vendor control transfer first
- ECP channel-77 returns `LIBUSB_ERROR_PIPE` (-9) — device doesn't support it
- MLC Init (rev=3) returns 0 bytes on all interfaces
- DOT4 Init (rev=0x20) returns 0 bytes on all interfaces
- Direct SOAP on Interface 1: write succeeds, 0 bytes read back

### Parameter acceptance testing
Using `application/soap+xml` Content-Type with full namespace declarations:

| Parameter combo | Result |
|---|---|
| Empty CreateScanJobRequest | ACCEPTED (motor runs ~70%) |
| +ScanIdentifier, +ScanTicket, +JobDescription | ACCEPTED |
| +DocumentParameters(empty) | ACCEPTED |
| +Format=jfif | ACCEPTED |
| +InputSource=Platen | ACCEPTED |
| **+Resolution=300x300** | **ACCEPTED** |
| **+ColorProcessing=RGB24** | **ACCEPTED** |
| **+ColorProcessing=BlackandWhite1** | **ACCEPTED** |
| +ColorProcessing=Grayscale8 | **Error 4 (type mismatch)** |
| +ColorProcessing=Color | Error 4 |
| +InputSize | Error 4 |
| Full plugin format | Error 4 |

Valid ColorProcessing values: `RGB24`, `BlackandWhite1`
Invalid: `Grayscale8`, `Color`, `Gray`, `Grayscale`, `BlackAndWhite`

### "Service temporarily blocked" discovery
When trying to create a second job while one is running:
```
SOAP-ENV:Receiver — "The service is temporarily blocked and can't accept new scan job requests."
```
This PROVES the parameterized scan job (with RGB24, 300 DPI) was accepted AND running.

### Scan execution timing
- Jobs queue and execute asynchronously — not immediately
- A scan executed ~60 seconds after job creation during idle time
- The scan motor ran for a full scan cycle (not just calibration)
- Passive listening on EP 0x82 and EP 0x84 during scan: **0 bytes**

### SCANNING WORKS! (Session 2 — final breakthrough)

**Working sequence (in `Tests/scan_interactive.c`):**
1. Claim Interface 0 + release/reclaim + DOT4 wake
2. `GetScannerElements` → confirms `ScannerState=Idle`, `ScanToAvailable`
3. `CreateScanJobRequest` with params (same connection) → 202 ACCEPTED + `CreateScanJobResponseType` with real JobId
4. Wait for user signal (scanner runs, "HP" blinks on display)
5. `RetrieveImageRequest` with correct JobId (SAME connection, NO reclaim!) → `HTTP/1.1 200 OK` with `Content-Type: application/dime`
6. Read chunked DIME data → decode chunks → extract JPEG from DIME payload

**Result:** `JPEG image data, JFIF standard 1.01, resolution 300x300 DPI, 2550x3300 pixels, 3 components (RGB)`

**Key discoveries:**
- RetrieveImage MUST be on the SAME connection as CreateScanJob (no release/reclaim)
- The CreateScanJobResponseType arrives as a delayed response (~13-82s after creation)
- The scan executes after a variable delay (13s-160s depending on device state)
- Valid `ColorProcessing` values: `RGB24`, `BlackandWhite1` (NOT Grayscale8)
- HTTP headers: `Content-Type: application/soap+xml; charset=utf-8`, `User-Agent: gSOAP/2.7`
- All SOAP-ENC, xsi, xsd namespace declarations required
- DIME response contains SOAP envelope (Part 1) + JPEG image (Part 2)
- Image data is chunked (4096-byte chunks with `\r\n1000\r\n` headers)

**Accepted scan parameters:**
- `<Format>jfif</Format>` ✓
- `<InputSource>Platen</InputSource>` ✓
- `<InputSize><InputMediaSize><Width>8500</Width><Height>11000</Height></InputMediaSize>` ✓
- `<ScanRegion>` with offsets and dimensions ✓
- `<Resolution><Width>300</Width><Height>300</Height></Resolution>` ✓
- `<ColorProcessing>RGB24</ColorProcessing>` ✓

### Swift app implementation status (parity mode)

Implemented and verified in:
- `Services/USBTransport.swift`
  - `prepareInteractiveSOAPSession()` for release/reclaim + DOT4 wake
  - `sendSOAPEnvelope(...)` with gSOAP-compatible headers
  - `readSOAPResponseBuffer(...)`, `readSOAPForDuration(...)`, `readSOAPImageData(...)` for C-style response handling
- `Services/ScannerManager.swift`
  - End-to-end parity sequence (`GetScannerElements` -> `CreateScanJobRequest` -> delayed `JobId` capture -> automated `RetrieveImageRequest` retries)
  - Same-connection enforcement for create/retrieve
  - Artifact logging/saving to home directory for debugging
- `Services/DIMEImageExtractor.swift`
  - Robust HTTP body extraction (handles leading junk before `HTTP/1.1`)
  - Chunked transfer decode
  - DIME record parse with 4-byte padding + continuation handling
  - JPEG trimming from SOI (`FFD8FF`) to EOI (`FFD9`)

Automation note:
- The old manual ENTER step from `Tests/scan_interactive.c` is still useful for protocol experiments.
- The app path now automates retrieve timing with retries and timeout windows.

## Historical Notes (Superseded)

The sections below reflect earlier hypotheses and dead ends from before the parity/session fixes. They are intentionally preserved for cross-model troubleshooting and future reverse-engineering work.

### Previous core conclusion (NOW OUTDATED)
The WSD/gSOAP server on Interface 0:
- Creates scan jobs (with or without parameters)
- The scan engine executes them (motor runs, full scan cycle)
- **The image data is NEVER transmitted over USB**
- RetrieveImage returns DIME with `image/bmp` but data_length=0 always
- The firmware's image-to-USB data path is not implemented
- HPLIP on Linux uses a proprietary plugin that likely uses a different data path (DOT4/MLC channel) which doesn't respond on this device from macOS

### Remaining hope
- The proprietary `bb_soapht.so` plugin must get image data somehow on Linux
- If DOT4/MLC doesn't work from macOS libusb, it might work from Linux libusb (different USB stack behavior)
- A USB Wireshark capture from a working HPLIP scan on Linux would reveal the missing piece
- The image data might flow through Interface 1 in a format we haven't tried reading

---

## Open Questions / Next Steps (Current)

1. **Replace retrieve retry loop with status polling**
   - The app currently automates retrieve with timed retries (works), but a status-driven flow should reduce latency and improve predictability.

2. **Map UI settings back to protocol parameters**
   - Current app path intentionally hardcodes parity profile (`RGB24`, `300 DPI`, Letter) for stability.
   - Next step is safe mapping for UI-selected color mode/resolution/paper size.

3. **Validate full scan matrix**
   - Test `RGB24` and `BlackandWhite1` at `100/300/600 DPI`.
   - Record payload sizes, timing, and decode success/failure per mode.

4. **Handle "service temporarily blocked" with backoff/recovery**
   - Add explicit detection and user-facing retry guidance.

5. **Cross-model portability**
   - Re-run this same parity process on other HP models and document which assumptions hold.

### Historical Questions (Superseded but kept for reference)

These were useful during reverse-engineering and may still help with other printers/scanners:

1. Why did early runs return 0-byte image payloads?
2. Is there a scan-default endpoint outside current WSD path?
3. Could HPLIP DOT4/MLC behavior reveal additional paths on Linux USB stack?
4. Would USB capture from a working Linux/HPLIP session expose hidden prerequisites?
5. Could `sane-airscan` patterns over USB apply to non-M125a devices?

---

## Files Reference
- **App entry**: `PaperCatApp.swift`
- **Scanner manager (parity flow + automation)**: `Services/ScannerManager.swift`
- **USB transport (SOAP session helpers)**: `Services/USBTransport.swift`
- **Image decode (HTTP chunked + DIME + JPEG)**: `Services/DIMEImageExtractor.swift`
- **Reference C implementation**: `Tests/scan_interactive.c`
- **Protocol history and findings**: `PROTOCOL_FINDINGS.md`
- **Runtime artifacts (app run, in home folder)**: `~/papercat_scan_raw.bin`, `~/papercat_scan_raw_jpeg.bin`, `~/papercat_scan_test.jpg`, `~/PaperCat.log`
