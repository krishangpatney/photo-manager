import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

// MARK: - Image caches

private actor ImageCache {
    private var cache: [String: CGImage] = [:]
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    func image(for path: String, maxPixelSize: Int?) async -> CGImage? {
        if let cached = cache[path] { return cached }
        if let existing = inFlight[path] { return await existing.value }

        let task = Task<CGImage?, Never> { await Self.load(path: path, maxPixelSize: maxPixelSize) }
        inFlight[path] = task
        let result = await task.value
        inFlight.removeValue(forKey: path)
        if let result { cache[path] = result }
        return result
    }

    private static func load(path: String, maxPixelSize: Int?) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil as CGImage? }

            if let maxPixelSize {
                // small thumbnail for film strip
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                    kCGImageSourceShouldCache: false,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            } else {
                // full resolution — decode the actual image
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCacheImmediately: false,
                    kCGImageSourceShouldCache: false,
                ]
                return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
            }
        }.value
    }
}

// MARK: - Sheet

struct PhotoReviewSheet: View {
    let group: DateGroup
    let onToggle: (PhotoPreview.ID) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int = 0
    // small thumbnails used in the film strip
    @State private var stripThumbnails: [String: CGImage] = [:]
    // full-resolution images for the main viewer
    @State private var fullResImages: [String: CGImage] = [:]
    // rotation per photo path, in 90° steps
    @State private var rotations: [String: Int] = [:]

    private let stripCache = ImageCache()
    private let fullResCache = ImageCache()

    private func currentRotationAngle(for path: String) -> Angle {
        .degrees(Double((rotations[path] ?? 0) * 90))
    }

    private func rotateLeft() {
        guard let path = current?.path else { return }
        rotations[path] = ((rotations[path] ?? 0) - 1 + 4) % 4
    }

    private func rotateRight() {
        guard let path = current?.path else { return }
        rotations[path] = ((rotations[path] ?? 0) + 1) % 4
    }

    private var previews: [PhotoPreview] { group.previews }
    private var current: PhotoPreview? { previews.indices.contains(currentIndex) ? previews[currentIndex] : nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if previews.isEmpty {
                emptyState
            } else {
                HSplitView {
                    filmStrip
                    mainViewer
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .task { await prefetchStrip() }
        .onChange(of: currentIndex) { _, _ in
            Task { await loadFullRes(around: currentIndex) }
        }
        .task { await loadFullRes(around: 0) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text("Review Photos — \(group.displayDate)")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            let includedCount = previews.filter(\.isIncluded).count
            Text("\(includedCount) of \(previews.count) JPEG(s) selected for transfer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if group.rawOnlyCount > 0 {
                Text("\(group.rawOnlyCount) RAW-only (always included)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Film strip (left column)

    private var filmStrip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(previews.enumerated()), id: \.element.id) { index, preview in
                        FilmStripCell(
                            preview: preview,
                            isActive: index == currentIndex,
                            thumbnail: stripThumbnails[preview.path ?? ""],
                            rotation: currentRotationAngle(for: preview.path ?? "")
                        )
                        .id(index)
                        .onTapGesture { currentIndex = index }
                    }
                }
                .padding(8)
            }
            .frame(width: 130)
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
            }
        }
    }

    // MARK: Main viewer (right panel)

    private var mainViewer: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black

                if let preview = current {
                    let path = preview.path ?? ""
                    // show full-res if ready, otherwise fall back to the strip thumbnail as placeholder
                    let displayImage = fullResImages[path] ?? stripThumbnails[path]

                    if let cgImage = displayImage {
                        let angle = currentRotationAngle(for: path)
                        let isSideways = (rotations[path] ?? 0) % 2 != 0
                        GeometryReader { geo in
                            // When sideways, pre-swap the frame so the rotated image fills the container
                            let fitW = isSideways ? geo.size.height : geo.size.width
                            let fitH = isSideways ? geo.size.width : geo.size.height
                            Image(cgImage, scale: 1, label: Text(preview.filename))
                                .resizable()
                                .scaledToFit()
                                .frame(width: fitW, height: fitH)
                                .rotationEffect(angle)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .opacity(preview.isIncluded ? 1 : 0.35)
                                .overlay(alignment: .bottomTrailing) {
                                    if fullResImages[path] == nil {
                                        ProgressView()
                                            .tint(.white)
                                            .scaleEffect(0.7)
                                            .padding(10)
                                    }
                                }
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                    }

                    if let preview = current, !preview.isIncluded {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            if let preview = current {
                HStack(spacing: 20) {
                    Button(action: prev) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentIndex == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])

                    Spacer()

                    VStack(spacing: 2) {
                        Text(preview.filename)
                            .font(.system(size: 13, weight: .medium))
                        HStack(spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            if preview.pairedKey != nil {
                                Text("RAW+JPEG pair")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            Text("\(currentIndex + 1) / \(previews.count)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button(action: rotateLeft) {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("[", modifiers: [])
                    .help("Rotate left  [")

                    Button(action: rotateRight) {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("]", modifiers: [])
                    .help("Rotate right  ]")

                    Spacer()

                    if preview.isIncluded {
                        Button(action: { onToggle(preview.id) }) {
                            Label("Exclude", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.space, modifiers: [])
                    } else {
                        Button(action: { onToggle(preview.id) }) {
                            Label("Include", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.space, modifiers: [])
                    }

                    Button(action: next) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentIndex >= previews.count - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No JPEG files in this group.")
                .foregroundStyle(.secondary)
            if group.rawOnlyCount > 0 {
                Text("\(group.rawOnlyCount) RAW-only file(s) will always be included.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Navigation

    private func next() {
        guard currentIndex < previews.count - 1 else { return }
        currentIndex += 1
    }

    private func prev() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    // MARK: Loading

    // Prefetch all strip thumbnails (small, fast) when the sheet opens
    private func prefetchStrip() async {
        await withTaskGroup(of: Void.self) { group in
            for preview in previews {
                guard let path = preview.path else { continue }
                group.addTask {
                    if let image = await stripCache.image(for: path, maxPixelSize: 300) {
                        await MainActor.run { stripThumbnails[path] = image }
                    }
                }
            }
        }
    }

    // Load full-res for current photo and prefetch ±2 neighbours
    private func loadFullRes(around index: Int) async {
        let indices = [index, index + 1, index - 1, index + 2, index - 2]
            .filter { previews.indices.contains($0) }

        await withTaskGroup(of: Void.self) { group in
            for i in indices {
                guard let path = previews[i].path else { continue }
                guard fullResImages[path] == nil else { continue }
                group.addTask {
                    if let image = await fullResCache.image(for: path, maxPixelSize: nil) {
                        await MainActor.run { fullResImages[path] = image }
                    }
                }
            }
        }
    }
}

// MARK: - Film strip cell

private struct FilmStripCell: View {
    let preview: PhotoPreview
    let isActive: Bool
    let thumbnail: CGImage?
    let rotation: Angle

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(thumbnail, scale: 1, label: Text(preview.filename))
                    .resizable()
                    .scaledToFill()
                    .rotationEffect(rotation)
                    .opacity(preview.isIncluded ? 1 : 0.3)
            } else {
                Color.gray.opacity(0.2)
            }

            if !preview.isIncluded {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .frame(width: 110, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isActive ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}
