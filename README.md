# Photo Transfer Manager

A native macOS app for importing and organizing photos from SD cards — built with SwiftUI.

---

## What it does

- Detects SD cards and mounted drives automatically
- Scans and groups photos by shoot date
- Lets you name each shoot and preview photos before transferring
- Copies files into an organized folder structure: `Shoot Name / Year / Month / Day / raw` or `jpeg`
- Supports reorganizing an existing folder of photos into the same structure
- Eject your SD card directly from the app when done

---

## Download

Grab the latest release from the [Releases page](../../releases). Unzip and move the app to your Applications folder.

> Because the app is unsigned, macOS may warn you on first launch. Right-click the app and choose **Open** to proceed. If macOS says it's damaged, run:
> ```bash
> xattr -dr com.apple.quarantine "/Applications/Photo Transfer Manager.app"
> ```

---

## Contributing

Contributions are welcome! Here's how to get involved:

### Reporting bugs or requesting features

Open an issue on the [Issues page](../../issues). Please include:
- What you were trying to do
- What happened instead
- Your macOS version

### Submitting a pull request

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Open a pull request with a clear description of what you changed and why

---

## Development

### Requirements

- macOS 13 or later
- Xcode 15 or later (for the Swift toolchain)

### Run locally

```bash
cd macos-app
swift build
.build/debug/PhotoTransferMac
```

### Run tests

```bash
cd macos-app
swift test
```

### Project structure

```
macos-app/
  Sources/PhotoTransferMac/
    PhotoTransferApp.swift   # App entry point
    ContentView.swift        # Main UI
    AppViewModel.swift       # State and business logic
    Services.swift           # Scanning, transfer, volume detection
    Models.swift             # Data types
    PhotoReviewSheet.swift   # Per-photo review UI
  Tests/
config.json                  # Optional: override scan settings
```

### Configuration

A `config.json` file in the project root lets you override defaults like the supported RAW extensions or SD card names. If absent, the app uses sensible defaults.

### Releasing

Tag a version to trigger a GitHub Actions build and release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This builds an unsigned `.app` bundle, zips it, and publishes it to GitHub Releases automatically.

---

## License

Source-available for personal and educational use. You may copy and modify the code, but you may not sell it or use it commercially without prior written permission.
