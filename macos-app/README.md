# PhotoTransferMac

Native macOS SwiftUI app for the photo-transfer workflow.

## Features

- SD card detection
- scan on demand
- per-day folder mapping
- transfer one day or selected days
- destination preview path
- `Open in Finder` and `Open First JPEG`
- live transfer progress
- eject SD card from the app

## Open in Xcode

1. Install full Xcode from the App Store if it is not already installed.
2. Switch the active developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

3. Open the package in Xcode:

```bash
open Package.swift
```

4. Run the `PhotoTransferMac` target from Xcode.

## Command-line build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --scratch-path .build/swiftpm-cache
open ./.build/swiftpm-cache/arm64-apple-macosx/debug/PhotoTransferMac
```

## Build a shareable app

Create an unsigned `.app` bundle:

```bash
./scripts/build-app.sh
```

Create a shareable zip:

```bash
./scripts/package-share.sh
```

You can stamp a specific version into the app bundle and zip name:

```bash
VERSION=0.2.0 BUILD_NUMBER=12 ./scripts/package-share.sh
```

## Unsigned app note

This package flow creates an unsigned app for easy friend-to-friend sharing. macOS may warn on first launch; recipients can right-click the app and choose `Open`.

If macOS reports that the app is damaged, clear quarantine once:

```bash
xattr -dr com.apple.quarantine "/Applications/Photo Transfer Manager.app"
```
