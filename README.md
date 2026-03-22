# Photo Transfer Manager

Native macOS photo import app built with SwiftUI.

## What is here

- `macos-app/` - the active macOS app
- `config.json` - shared scan/import configuration

## Run the app

```bash
cd macos-app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=.build/clang-module-cache swift build --scratch-path .build/swiftpm-cache
open ./.build/swiftpm-cache/arm64-apple-macosx/debug/PhotoTransferMac
```

## Build a shareable app

To make an unsigned `.app` bundle for friends:

```bash
cd macos-app
./scripts/build-app.sh
```

That creates:

```bash
macos-app/.build/share/Photo Transfer Manager.app
```

To package it as a shareable zip:

```bash
cd macos-app
./scripts/package-share.sh
```

That creates:

```bash
macos-app/dist/photo-transfer-manager-0.1.0-macos.zip
```

You can also override the version:

```bash
cd macos-app
VERSION=0.2.0 BUILD_NUMBER=12 ./scripts/package-share.sh
```

## Sharing with friends

Because this build is unsigned, macOS may warn when your friends open it. They can still launch it by:

1. moving the app to `Applications`
2. right-clicking the app
3. choosing `Open`
4. confirming the prompt

## GitHub Releases

This repo can publish the shareable zip to GitHub Releases automatically.

Push a version tag like this:

```bash
git tag v0.1.0
git push origin v0.1.0
```

That triggers the GitHub Actions workflow in `.github/workflows/release.yml`, which:

- builds the macOS app
- packages the unsigned zip
- uploads it to GitHub Releases

## Current workflow

- detect SD card
- scan on demand
- map each shoot date to a folder
- transfer one day or selected days
- eject the SD card from the app when done
