# Photo Transfer Manager

Native macOS photo import app built with SwiftUI.

## What is here

- `macos-app/` - the active macOS app
- `config.json` - shared scan/import configuration
- `LICENSE` - non-commercial source-available license for this project

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

If macOS says the app is damaged, remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/Photo Transfer Manager.app"
```

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

## Add a custom app icon

If you want the app to have a proper macOS icon in Finder and Launchpad:

1. Create a square source image, ideally at least `1024x1024`
2. Convert it into a macOS `.icns` file named:

```bash
macos-app/Resources/AppIcon.icns
```

3. Rebuild the shareable package:

```bash
cd macos-app
./scripts/package-share.sh
```

The packaging script already checks for `macos-app/Resources/AppIcon.icns` and automatically bundles it into the app.

If you start from a PNG, one common macOS flow is:

```bash
mkdir AppIcon.iconset
sips -z 16 16 icon.png --out AppIcon.iconset/icon_16x16.png
sips -z 32 32 icon.png --out AppIcon.iconset/icon_16x16@2x.png
sips -z 32 32 icon.png --out AppIcon.iconset/icon_32x32.png
sips -z 64 64 icon.png --out AppIcon.iconset/icon_32x32@2x.png
sips -z 128 128 icon.png --out AppIcon.iconset/icon_128x128.png
sips -z 256 256 icon.png --out AppIcon.iconset/icon_128x128@2x.png
sips -z 256 256 icon.png --out AppIcon.iconset/icon_256x256.png
sips -z 512 512 icon.png --out AppIcon.iconset/icon_256x256@2x.png
sips -z 512 512 icon.png --out AppIcon.iconset/icon_512x512.png
cp icon.png AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns AppIcon.iconset -o macos-app/Resources/AppIcon.icns
```

After that, tag a new release and GitHub will publish the app with the new icon.

## Current workflow

- detect SD card
- scan on demand
- map each shoot date to a folder
- transfer one day or selected days
- eject the SD card from the app when done

## License

This project is source-available for personal, educational, and other
non-commercial use only.

You may copy and modify it, but you may not sell it or use it commercially
without prior written permission.
