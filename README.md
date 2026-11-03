# Fanon

A native Apple Silicon replacement for Canon's **IJScanner5** driver and IJ Scan Utility, for the
**Canon PIXMA MX920 series** (MX922 / MX923 / MX924 / MX925).

*Fanon* is what fans call the version of a story that the community made rather than the official canon.
This is an unofficial, fan-made scanner driver. It isn't affiliated with or endorsed by Canon Inc.; Canon,
PIXMA and IJ Scan Utility are Canon's trademarks, used here only to say which hardware Fanon works with.

Canon's 2014 driver is an Intel-only Image Capture plug-in (`/Library/Image Capture/Devices/Canon IJScanner5.app`).
It's a thin shim around closed-source x86_64 frameworks in `/Library/Printers/Canon/IJScanner`, so it can't be
recompiled. It only runs under Rosetta, which is going away.

Fanon Bridge doesn't port that code. It replaces it:

```
Image Capture / Preview / Printers & Scanners
        │  (Apple's built-in AirScan driver)
        ▼
  eSCL over HTTP + Bonjour (_uscan._tcp)        ← Fanon Bridge (this project, native arm64)
        │  Canon BJNP over TCP/UDP 8612
        ▼
  Canon MX922 on your network
```

* **PixmaKit**: a pure-Swift implementation of Canon's BJNP network transport and the PIXMA "generation 5"
  scan protocol used by the MX920 series. It supports flatbed, ADF, and duplex ADF, in color and grayscale,
  at 75–1200 dpi (75–600 dpi from the feeder).
* **ESCLKit**: an eSCL (AirScan) server. It presents the MX922 to macOS as a standard network scanner, so the
  scanner keeps working through Apple's own, maintained scanner stack. No vendor driver, kernel extension,
  or deprecated plug-in API is involved.
* **Fanon Bridge.app**: a small menu-bar agent that runs the bridge.
* **Fanon.app**: a companion scanning app, in the same spirit as Canon's current IJ Scan Utility Lite.
  It has a preview with a drag-to-select scan area, and rebuilds the image options of Canon's old driver
  with Core Image and Vision (see below).
* **ScanProcessing**: the correction library shared by Fanon.app and `fanon`.
* **fanon**: a command-line tool for discovering, scanning to a file, and running the bridge in the foreground.

It has no third-party dependencies. It is built on Foundation, Network.framework, CoreGraphics, ImageIO,
Core Image, Vision and SwiftUI.

## Build

Requires Xcode (or the Command Line Tools) with Swift 5.10+. The app targets macOS 13 and later.

```bash
./scripts/build-app.sh            # Apple Silicon (arm64) → dist/Fanon.app + dist/Fanon Bridge.app
./scripts/build-app.sh --universal  # arm64 + x86_64
swift test                         # unit tests
```

Local builds are ad-hoc signed, which is fine on the Mac that built them.

### Releasing

`scripts/release.sh 1.2.0` builds both apps, signs them with your Developer ID (hardened runtime, secure
timestamp), packs them into `dist/Fanon-1.2.0.dmg`, has Apple notarize it, staples the ticket, checks it
with Gatekeeper and writes the SHA-256 next to it. It needs a "Developer ID Application" certificate and a
notarytool keychain profile named `fanon`, created once with:

```bash
xcrun notarytool store-credentials fanon --apple-id <apple id> --team-id <team id>
```

`SIGN_IDENTITY` and `NOTARY_PROFILE` override the certificate and profile names.

## Install

1. Download `Fanon-<version>.dmg` from the latest GitHub release (it's signed and notarized by Apple), open it,
   and drag **Fanon** and **Fanon Bridge** to Applications. If you built it yourself, copy them from `dist/`
   instead. Open Fanon Bridge. A scanner icon appears in the menu bar.
2. Allow **Local Network** access when macOS asks. The bridge needs it to reach the printer.
3. In the menu, turn on **Open at Login**.
4. Open **Image Capture**, or Preview → File → Import from Scanner. Choose
   **Canon MX920 series (Fanon)**.

The scanner is found automatically through Bonjour. If that doesn't work on your network (for example, the
printer is on another subnet), use **Scanner Address…** in the menu to enter its IP address.

### Removing the old Intel driver (optional)

Once the bridge works for you, you can remove Canon's driver so the old, Rosetta-only "Canon MX920 series"
entry disappears from Image Capture:

```bash
sudo rm -rf "/Library/Image Capture/Devices/Canon IJScanner5.app" /Library/Printers/Canon/IJScanner
```

Printing is unaffected. The printer queue uses AirPrint/IPP.

## Fanon.app (companion app)

Image Capture shows only the controls Apple's AirScan driver knows about. Canon's extra options live in
Fanon instead:

| Canon driver option | Fanon |
| --- | --- |
| Image Adjustment | Auto tone and colour (Core Image auto-adjust) |
| Reduce Dust (and Scratches) | Low / Medium / High: replaces isolated specks with their median-filtered neighbourhood |
| Fading Correction | Low / Medium / High: per-channel range stretch plus vibrance |
| Grain Correction | Low / Medium / High: noise reduction |
| Gutter Correction | Divides out the shadow along a book spine or page edge |
| Unsharp Mask | Unsharp mask scaled to the resolution |
| Descreen | Removes halftone/moiré patterns from printed material |
| Reduce Show-through | Turns the paper colour to white and lifts faint reverse-side text away |
| Calibrate before each scan | Asks the scanner to recalibrate on every scan |
| Auto Selection | Straighten, straighten & crop a document, or detect separate photos |

Beyond Canon's options, it borrows the most useful ideas from ScanSnap Home, Epson ScanSmart, VueScan and
NAPS2:

* **Detect Document** (⌘D, above the preview): finds the page on the glass and selects its four corners.
  Drag a corner to adjust it, or drag inside to move the selection. The scan is cropped and straightened to
  exactly those corners. With Auto Selection set to Straighten & Crop, this happens after every preview.
  Detection works from what differs from the white lid (colour, the faint shadow along a page edge, and
  print), so it copes with pages that run off the edge of the glass. A white page whose edges can't be seen
  is taken to be Letter or A4, placed against the corner mark.
* **Straightening by text**: the angle of the text lines is measured (projection profiles), and a cropped
  page is levelled to its text, which is what the eye judges.
* **Flatten curved pages**: straightens text lines that bend toward a book's spine. Neighbouring strips of
  the page are cross-correlated to map how far each line has drifted, and the page is resampled to undo it.
* **Split facing pages**: saves a two-page book spread as two pages, cut at the spine.
* **Automatic rotation**: turns pages upright from their text, including upside-down feeder pages.
* **Skip blank pages**, for two-sided feeder scans.
* **Automatic colour**: pages with only black or grey print are saved in grayscale, for smaller files.
* **Presets**: Document, Book Pages, Magazine, Photo, Several Photos and Old or Faded Photo, each setting
  everything for that job in one click.
* **Collect pages, then save**: pages go into a tray below the preview, where you can rotate, reorder or
  delete them before saving one document. This is the way to make a multi-page PDF on the flatbed.
* **File names with {date} and {time}**, and a quality setting for PDF and JPEG size.

It also has black-and-white output, rotation, duplex back-side rotation and searchable PDFs (Vision OCR,
with an invisible text layer). The first OCR after launch takes 20–30 seconds while macOS loads its
text-recognition model.

## Command line

```bash
fanon discover
fanon status --host 192.168.1.50
fanon scan -o page.pdf --dpi 300 --mode color --source flatbed
fanon scan -o stack.pdf --source duplex --dpi 300      # every page from the feeder, both sides
fanon scan -o letter.pdf --fix crop,rotate=auto,autocolor,showthrough,ocr
fanon scan -o book.pdf --fix straighten,gutter,flatten,split,showthrough,ocr
fanon scan -o stack.pdf --source duplex --fix skipblank,rotate=auto,quality=0.6
fanon process -i old-photo.jpg -o fixed.jpg --fix fading=high,dust=medium,grain=low
fanon detect -i glass.png --dpi 75                     # where is the page? (inches, tilt)
fanon serve --port 8090 -v                             # run the bridge in the foreground
```

The `fanon` binary is also bundled inside both apps, for example at `Fanon Bridge.app/Contents/MacOS/fanon`.

Fanon was called IJScan / IJScanBridge before. The new apps pick up the old scanner address and scan
settings on first launch. If you turned on Open at Login in IJScanBridge, delete the old app and turn it on
again in Fanon Bridge.

## Security and privacy

* Fanon Bridge shares the scanner on your local network the way an AirScan printer does. Once it has found
  your printer, any computer on the same network can see the scanner and start a scan, with no password.
  That is no more than the printer already allows, since its own scan service is open to the network too.
  Quit the bridge if you take your Mac onto a network you don't trust.
* Scans travel only between the printer, your Mac and the computer that asked for them. Nothing is sent to
  the internet, and text recognition runs on your Mac with Apple's Vision framework.
* As Canon's driver does, each scan job tells the printer your Mac's name and your macOS user name.
* Please report security problems privately through GitHub's **Report a vulnerability** button on the
  repository's Security tab rather than in a public issue.

## Notes and limits

* Only one job runs at a time; the MX922 accepts one scan or copy job at a time anyway. If the printer is busy,
  the bridge waits up to 30 seconds for it.
* 2400 dpi isn't offered: a full page at that resolution needs about 1.7 GB of memory.
* The protocol logic is derived from the SANE project's `pixma` backend (GPL-2.0-or-later), so this project is
  distributed under the same licence (see [License](#license)).
* Debug builds of Fanon can render their window to a PNG without a scanner, for checking the UI:
  `FANON_SNAPSHOT=out.png FANON_PREVIEW=glass-75dpi.png [FANON_PRESET=book] [FANON_TRAY=3] .build/debug/FanonApp`.
* `scripts/ica-scan-test.swift` drives a scan through ImageCaptureCore. It's the same path Image Capture
  uses, so it can check the whole chain from a terminal.

## License

Copyright © 2026 Eric Cirone.

Fanon is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, either version 2 of the License or (at your option) any
later version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the
full text.

The PIXMA scan protocol in PixmaKit is based on the `pixma` backend of the
[SANE project](http://www.sane-project.org/), copyright its authors and also licensed under the GPL.
