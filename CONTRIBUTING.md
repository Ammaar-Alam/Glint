# Contributing

Glint is Swift, AppKit and SwiftUI with no third-party dependencies.

## Setup

macOS 15 and Xcode 16.4 or later.

```sh
swift test
scripts/build-app.sh debug
open build/Glint.app
```

Set `GLINT_SIGNING_IDENTITY` to a certificate's SHA-1 hash to keep permissions between builds. Otherwise the app is ad-hoc signed.

Tests use generated media and need no permissions. Check capture, recording and window behavior in the running app too.

## Guidelines

- Keep changes focused, and put them in the file that owns the behavior.
- Add a regression test when a bug can be reproduced deterministically.
- Keep image, video and file work off the main thread.
- Never lose original media or overwrite good output when work fails or is canceled.
- Treat project files as untrusted input.
- Migrate persisted formats with a test when changing them.

Use conventional commit titles, for example `fix(recording): keep audio across pauses`.

## Bug reports

Include the Glint and macOS versions, steps to reproduce, and expected and actual behavior. Don't attach private screenshots or recordings.

## License

Contributions are licensed under [GPLv3](LICENSE).
