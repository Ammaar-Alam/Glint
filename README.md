# Clipt

A native macOS app for screenshots, annotation, screen recording, and video editing. Captures and projects stay on your Mac.

## Build and run

Requires macOS 15 or later and Xcode with Swift 6.
Validated with Xcode 27 and Swift 6.4; earlier toolchains have not been checked.

```sh
scripts/build-app.sh
open build/Clipt.app
```

The build script creates an ad-hoc-signed app by default. Set `CLIPT_SIGNING_IDENTITY` to an existing signing certificate's SHA-1 hash to use a stable development identity between builds. The app is not notarized for distribution.

```sh
swift test
```

## Capture and edit

- Area, window, screen, previous area, timer, and all-in-one capture
- Frozen selection, magnifier, explicit dimensions and aspect ratios
- Vertical and horizontal scrolling capture, with manual and automatic scrolling
- On-device text and QR recognition
- Editable arrows, shapes, drawing, text, counters, highlighting, spotlight, blur, pixelation, and solid redaction
- Crop, resize, rotation, flipping, canvas expansion, image insertion, backgrounds, insets, presets, and printing
- Screen recording with independent system audio, microphone, camera, cursor, click, and optional key events
- Video trimming, cuts, cursor-following zooms, background composition, camera controls, cursor effects, and audio mixing
- MP4, GIF, and trim-only MOV export, with adjustable dimensions and quality
- Capture history, clipboard import, pinned images, file dragging, and configurable global shortcuts

PNG, JPEG, HEIC, and TIFF export use the system's image encoders. WebP export is available when the installed ImageIO framework provides its encoder.

Default shortcuts use Control–Option: **4** for area capture, **3** for screen capture, **5** for recording/stop, **T** for text, and **H** for history. Change them in Settings.

## Permissions

Screen capture needs Screen & System Audio Recording permission. Microphone and camera access are requested only when enabled for a recording. Automatic scrolling and recording key events need Accessibility permission.

Key recording is off by default. When enabled, the editable video project retains recorded key events so their presentation can be changed later. Keep it off for private input.

## Files and recovery

History is stored under `~/Library/Application Support/Clipt/Captures`. New captures are copied into a temporary directory, validated, and promoted into the library before appearing in quick access. Removing a history item moves it to Trash. Retention defaults to forever and does not affect exported files.

Image projects use `.clipt`; video projects use `.cliptvideo`. Projects preserve original media and editable instructions. **Share flattened images or exported videos when redacting information.** Image-project Copy, Save, and drag operations use a full-resolution flattened image. Video projects must be exported before sharing.

Recordings keep working files under `~/Library/Application Support/Clipt/Recordings` until the finished project is safely imported. Interrupted recordings are recovered when the media container is readable; unrecoverable originals are left in place.

## Automation

Enable **Allow capture URLs** in Settings to use these commands:

```text
clipt://capture?mode=area
clipt://capture?mode=window
clipt://capture?mode=fullScreen
clipt://capture?mode=previousArea
clipt://capture?mode=scrolling
clipt://capture?mode=text
clipt://capture?mode=allInOne
clipt://record
clipt://stop
clipt://history
```

Automation is disabled by default. These commands do not upload files or accept remote output paths.
