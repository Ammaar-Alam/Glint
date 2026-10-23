# Contributing to Clipt

Clipt is a native macOS application built with Swift, AppKit, SwiftUI, ScreenCaptureKit, and AVFoundation. It has no third-party runtime dependencies.

## Development

Use macOS 15 or later with Xcode and Swift 6. The minimum-platform CI job uses Xcode 16.4; local development is also tested with Xcode 27.

```sh
swift test
scripts/build-app.sh debug
open build/Clipt.app
```

Tests use generated media and do not need access to your screen, microphone, or camera. Live capture tests require the corresponding macOS permissions. Automatic scrolling and optional key recording also require Accessibility access.

## Changes

- Keep changes focused and reuse the module that owns the behavior.
- Include a regression test for a bug when the failure can be reproduced deterministically.
- Keep image processing, media encoding, and file I/O off the interaction path.
- Preserve original media and existing output files when work fails or is canceled.
- Treat project files as untrusted input. Keep path, size, and format validation intact.
- Preserve existing project formats or provide a tested migration when changing persisted data.
- Check relevant native interactions as well as unit tests. Passing media tests alone does not prove window focus, permissions, or hardware behavior.

Use conventional commit titles such as `fix(recording): preserve audio across pauses` or `feat(editor): add a crop preset`. Describe the resulting behavior and the checks performed in the pull request.

## Bug reports

Include the Clipt version, macOS version, reproducible steps, expected behavior, and actual behavior. For capture bugs, mention display scaling and whether multiple displays are connected. Use generated or sanitized media; do not attach private screenshots, recordings, credentials, or personal key-event data.

## Distribution

Before distributing an app build, publish the matching source revision and include the GPLv3 license. Developer ID signing and notarization are separate from the local ad-hoc build script. Check the final bundle on a clean Mac after signing.

Contributions are provided under the repository’s GPL-3.0-only license. Be respectful, and explain feedback with concrete behavior or evidence.
