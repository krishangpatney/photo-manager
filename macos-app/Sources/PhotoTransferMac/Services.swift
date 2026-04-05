import Darwin
import Foundation
import ImageIO

enum AppConfigLoader {
    static func load() -> AppConfig {
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        let candidates = [
            URL(fileURLWithPath: cwd).appendingPathComponent("../config.json").standardizedFileURL,
            URL(fileURLWithPath: cwd).appendingPathComponent("config.json").standardizedFileURL,
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".photo-transfer-config.json")
        ]

        let decoder = JSONDecoder()
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let config = try? decoder.decode(AppConfig.self, from: data) {
                return AppConfig(
                    photographyPath: NSString(string: config.photographyPath).expandingTildeInPath,
                    sdCardNames: config.sdCardNames,
                    checkIntervalSeconds: config.checkIntervalSeconds,
                    supportedRawExtensions: config.supportedRawExtensions.map { $0.lowercased() },
                    supportedJpegExtensions: config.supportedJpegExtensions.map { $0.lowercased() },
                    logFile: NSString(string: config.logFile).expandingTildeInPath
                )
            }
        }

        return AppConfig.fallback
    }
}

struct VolumeScanner {
    let config: AppConfig

    func loadVolumes() -> [VolumeOption] {
        let root = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            let total = Int64(values?.volumeTotalCapacity ?? 0)
            let free = Int64(values?.volumeAvailableCapacity ?? 0)
            let used = total > 0 ? total - free : nil
            let sourceScore = sourceLikelihood(for: url)

            return VolumeOption(
                name: name,
                path: url.path,
                totalBytes: total > 0 ? total : nil,
                freeBytes: free > 0 ? free : nil,
                usedBytes: used,
                sourceScore: sourceScore
            )
        }
        .sorted {
            if $0.sourceScore == $1.sourceScore {
                return $0.name < $1.name
            }
            return $0.sourceScore > $1.sourceScore
        }
    }

    private func sourceLikelihood(for url: URL) -> Int {
        let fileManager = FileManager.default
        var score = 0

        let dcimURL = url.appendingPathComponent("DCIM", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dcimURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            score += 5
        }

        if containsSupportedPhotoFiles(in: dcimURL) {
            score += 4
        } else if containsSupportedPhotoFiles(in: url) {
            score += 2
        }

        let lowercasedName = url.lastPathComponent.lowercased()
        if ["untitled", "no name", "sd card", "eos_digital", "dcim"].contains(where: { lowercasedName.contains($0) }) {
            score += 1
        }

        return score
    }

    private func containsSupportedPhotoFiles(in root: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        var checked = 0
        for case let url as URL in enumerator {
            checked += 1
            if checked > 200 {
                break
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }

            let ext = "." + url.pathExtension.lowercased()
            if config.supportedRawExtensions.contains(ext) || config.supportedJpegExtensions.contains(ext) {
                return true
            }
        }

        return false
    }
}

struct PhotoScanResult {
    let filesByDate: [String: [PhotoFile]]
    let dateGroups: [DateGroup]
    let ignoredAlreadyOrganizedCount: Int
}

struct PhotoScanner {
    let config: AppConfig
    private let progressUpdateInterval = 100

    private static let fullMonthNames: Set<String> = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return Set(formatter.monthSymbols.map { $0.lowercased() })
    }()

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dateKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM dd, yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // Intermediate type used between enumeration and EXIF phases
    private struct CandidateFile {
        let url: URL
        let fileSize: Int64
        let modDate: Date?
        let isRaw: Bool
    }

    func scan(sourcePath: String, onProgress: ((ScanProgress) -> Void)? = nil) async throws -> PhotoScanResult {
        // ── Phase 1: enumerate the directory tree (sequential, fast — just stat calls) ──
        // Run on a detached task so the synchronous NSDirectoryEnumerator doesn't block the cooperative pool.
        let (candidates, ignoredAlreadyOrganizedCount): ([CandidateFile], Int) = await Task.detached(priority: .userInitiated) { [config] in
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: sourcePath, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                return ([], 0)
            }

            var candidates: [CandidateFile] = []
            var ignoredCount = 0

            for case let url as URL in enumerator {
                autoreleasepool {
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                    if values?.isDirectory == true {
                        if [".Trashes", ".Spotlight-V100", ".fseventsd"].contains(url.lastPathComponent) {
                            enumerator.skipDescendants()
                        }
                        if Self.isOrganizedMediaDirectoryStatic(url: url, sourceRoot: sourcePath) {
                            ignoredCount += Self.countSupportedPhotosStatic(in: url, config: config)
                            enumerator.skipDescendants()
                        }
                        return
                    }

                    let ext = "." + url.pathExtension.lowercased()
                    let isRaw = config.supportedRawExtensions.contains(ext)
                    let isJPEG = config.supportedJpegExtensions.contains(ext)
                    guard isRaw || isJPEG else { return }

                    if Self.isAlreadyOrganizedPhotoStatic(url: url, sourceRoot: sourcePath) {
                        ignoredCount += 1
                        return
                    }

                    candidates.append(CandidateFile(
                        url: url,
                        fileSize: Int64(values?.fileSize ?? 0),
                        modDate: values?.contentModificationDate,
                        isRaw: isRaw
                    ))
                }
            }
            return (candidates, ignoredCount)
        }.value

        // ── Phase 2: read EXIF dates in parallel (the slow part) ──
        // Each task gets its own formatter — DateFormatter is not thread-safe.
        let exifWorkerCount = min(candidates.count, max(ProcessInfo.processInfo.activeProcessorCount * 2, 8))
        var resolved: [PhotoFile] = Array(repeating: PhotoFile(sourcePath: "", filename: "", photoDate: Date(), fileSize: 0, isRaw: false), count: candidates.count)
        var completed = 0
        let reportInterval = max(progressUpdateInterval, candidates.count / 20)

        await withTaskGroup(of: (Int, PhotoFile).self) { group in
            var nextIndex = 0

            func scheduleNext() {
                guard nextIndex < candidates.count else { return }
                let i = nextIndex
                let c = candidates[i]
                nextIndex += 1
                group.addTask {
                    let (photoDate, coordinate) = Self.readExifDataStatic(from: c.url)
                    let blurScore = c.isRaw ? nil : Self.computeBlurScoreStatic(from: c.url)
                    let file = PhotoFile(
                        sourcePath: c.url.path,
                        filename: c.url.lastPathComponent,
                        photoDate: photoDate ?? c.modDate ?? Date(),
                        fileSize: c.fileSize,
                        isRaw: c.isRaw,
                        coordinate: coordinate,
                        blurScore: blurScore
                    )
                    return (i, file)
                }
            }

            for _ in 0..<exifWorkerCount { scheduleNext() }

            while let (i, file) = await group.next() {
                resolved[i] = file
                completed += 1
                if completed % reportInterval == 0 || completed == candidates.count {
                    onProgress?(ScanProgress(
                        scannedCount: completed + ignoredAlreadyOrganizedCount,
                        groupedFileCount: completed,
                        ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount
                    ))
                }
                scheduleNext()
            }
        }

        // ── Phase 3: group by date (sequential, trivial) ──
        var grouped: [String: [PhotoFile]] = [:]
        for file in resolved where !file.sourcePath.isEmpty {
            grouped[dateKey(for: file.photoDate), default: []].append(file)
        }

        onProgress?(ScanProgress(
            scannedCount: candidates.count + ignoredAlreadyOrganizedCount,
            groupedFileCount: candidates.count,
            ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount
        ))

        let keys = grouped.keys.sorted()
        let groups = keys.enumerated().map { offset, key in
            let files = grouped[key, default: []]
            let rawFiles = files.filter(\.isRaw)
            let jpegFiles = files.filter { !$0.isRaw }

            // build a set of base names that have a JPEG so we can detect RAW-only files
            let jpegBaseNames = Set(jpegFiles.map { baseName(of: $0.filename) })
            let rawOnlyCount = rawFiles.filter { !jpegBaseNames.contains(baseName(of: $0.filename)) }.count

            // full JPEG preview list for review, sorted by filename
            // pairedKey links each JPEG to its RAW counterpart (same base name)
            let rawBaseNames = Set(rawFiles.map { baseName(of: $0.filename) })
            let allPreviews: [PhotoPreview] = jpegFiles
                .sorted { $0.filename < $1.filename }
                .map { jpeg in
                    let base = baseName(of: jpeg.filename)
                    return PhotoPreview(
                        path: jpeg.sourcePath,
                        filename: jpeg.filename,
                        bytes: jpeg.fileSize,
                        pairedKey: rawBaseNames.contains(base) ? base : nil,
                        blurScore: jpeg.blurScore
                    )
                }

            let representativeCoordinate = files.first(where: { $0.coordinate != nil })?.coordinate

            return DateGroup(
                dateKey: key,
                displayDate: displayDate(for: files.first?.photoDate ?? Date()),
                photoCount: files.count,
                rawCount: rawFiles.count,
                jpegCount: jpegFiles.count,
                totalBytes: files.reduce(0) { $0 + $1.fileSize },
                folderName: "",
                previews: allPreviews,
                rawOnlyCount: rawOnlyCount,
                representativeCoordinate: representativeCoordinate,
                isExpanded: false,
                isSelected: false
            )
        }

        return PhotoScanResult(
            filesByDate: grouped,
            dateGroups: groups,
            ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount
        )
    }

    // Static + creates its own formatter so it's safe to call from concurrent tasks.
    // Returns the EXIF date (if present) and GPS coordinate (if present).
    private static func readExifDataStatic(from url: URL) -> (date: Date?, coordinate: Coordinate?) {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }

        let formatter = makeDateFormatter()
        var date: Date? = nil

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let parsed = formatter.date(from: value) {
            date = parsed
        }

        if date == nil,
           let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let parsed = formatter.date(from: value) {
            date = parsed
        }

        var coordinate: Coordinate? = nil
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            coordinate = Coordinate(
                latitude: latRef == "S" ? -lat : lat,
                longitude: lonRef == "W" ? -lon : lon
            )
        }

        return (date, coordinate)
    }

    // Tenengrad blur score for a JPEG. Higher = sharper. Returns nil if the image can't be read.
    // Only call for non-RAW files — RAW requires demosaicing before analysis.
    //
    // Method: render a 512px thumbnail to an 8-bit grayscale bitmap, compute Sobel gradients
    // over the central 60% of the image (ignores intentional background bokeh at the edges),
    // and return the mean squared gradient normalised to 0–1.
    private static func computeBlurScoreStatic(from url: URL) -> Double? {
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }

        let w = cgThumb.width
        let h = cgThumb.height
        guard w > 4, h > 4 else { return nil }

        // Render to 8-bit grayscale bitmap
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cgThumb, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Analyse only the central 60% — excludes intentional background blur at the edges
        let xStart = w / 5
        let xEnd   = w - w / 5
        let yStart = h / 5
        let yEnd   = h - h / 5
        guard xEnd - xStart > 1, yEnd - yStart > 1 else { return nil }

        // Sobel Tenengrad: T(x,y) = Gx² + Gy²
        // Gx kernel: [-1,0,1 / -2,0,2 / -1,0,1]
        // Gy kernel: [-1,-2,-1 / 0,0,0 / 1,2,1]
        var sumT = 0.0
        var n = 0

        for y in max(1, yStart)..<min(h - 1, yEnd) {
            for x in max(1, xStart)..<min(w - 1, xEnd) {
                let tl = Int(pixels[(y - 1) * w + (x - 1)])
                let tc = Int(pixels[(y - 1) * w +  x     ])
                let tr = Int(pixels[(y - 1) * w + (x + 1)])
                let ml = Int(pixels[ y      * w + (x - 1)])
                let mr = Int(pixels[ y      * w + (x + 1)])
                let bl = Int(pixels[(y + 1) * w + (x - 1)])
                let bc = Int(pixels[(y + 1) * w +  x     ])
                let br = Int(pixels[(y + 1) * w + (x + 1)])

                let gx = Double(-tl + tr - 2 * ml + 2 * mr - bl + br)
                let gy = Double(-tl - 2 * tc - tr + bl + 2 * bc + br)
                sumT += gx * gx + gy * gy
                n += 1
            }
        }

        guard n > 0 else { return nil }
        let meanT = sumT / Double(n)
        // Normalise: max Gx or Gy for 8-bit = 4*255 = 1020, so max Gx²+Gy² = 2*1020² ≈ 2_080_800
        return min(1, meanT / 2_080_800)
    }

    private static func makeDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private func baseName(of filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    private func dateKey(for date: Date) -> String {
        Self.dateKeyFormatter.string(from: date)
    }

    private func displayDate(for date: Date) -> String {
        Self.displayDateFormatter.string(from: date)
    }

    private func reportProgressIfNeeded(
        onProgress: ((ScanProgress) -> Void)?,
        scannedCount: Int,
        groupedFileCount: Int,
        ignoredAlreadyOrganizedCount: Int,
        lastReportedCount: inout Int
    ) {
        guard let onProgress else { return }
        guard scannedCount - lastReportedCount >= progressUpdateInterval else { return }
        lastReportedCount = scannedCount
        onProgress(ScanProgress(
            scannedCount: scannedCount,
            groupedFileCount: groupedFileCount,
            ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount
        ))
    }

    private static func isOrganizedMediaDirectoryStatic(url: URL, sourceRoot: String) -> Bool {
        let rootURL = URL(fileURLWithPath: sourceRoot, isDirectory: true)
        let standardizedRoot = rootURL.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else {
            return false
        }

        let relativePath = String(standardizedPath.dropFirst(standardizedRoot.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 5 else {
            return false
        }

        let suffix = Array(components.suffix(4))
        let year = suffix[0]
        let month = suffix[1].lowercased()
        let day = suffix[2]
        let mediaFolder = suffix[3].lowercased()

        let isYear = year.count == 4 && year.allSatisfy(\.isNumber)
        let isMonth = Self.fullMonthNames.contains(month)
        let isDay = day.count == 2 && day.allSatisfy(\.isNumber)
        let isMediaFolder = mediaFolder == "raw" || mediaFolder == "jpeg"

        return isYear && isMonth && isDay && isMediaFolder
    }

    private static func countSupportedPhotosStatic(in directory: URL, config: AppConfig) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            let ext = "." + url.pathExtension.lowercased()
            if config.supportedRawExtensions.contains(ext) || config.supportedJpegExtensions.contains(ext) {
                count += 1
            }
        }
        return count
    }

    private static func isAlreadyOrganizedPhotoStatic(url: URL, sourceRoot: String) -> Bool {
        let rootURL = URL(fileURLWithPath: sourceRoot, isDirectory: true)
        let standardizedRoot = rootURL.standardizedFileURL.path
        let standardizedPath = url.standardizedFileURL.path
        guard standardizedPath.hasPrefix(standardizedRoot + "/") else {
            return false
        }

        let relativePath = String(standardizedPath.dropFirst(standardizedRoot.count + 1))
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count >= 6 else {
            return false
        }

        let suffix = Array(components.suffix(5))
        let year = suffix[0]
        let month = suffix[1].lowercased()
        let day = suffix[2]
        let mediaFolder = suffix[3].lowercased()

        let isYear = year.count == 4 && year.allSatisfy(\.isNumber)
        let isMonth = Self.fullMonthNames.contains(month)
        let isDay = day.count == 2 && day.allSatisfy(\.isNumber)
        let isMediaFolder = mediaFolder == "raw" || mediaFolder == "jpeg"

        return isYear && isMonth && isDay && isMediaFolder
    }
}

private struct TransferJob: Sendable {
    let file: PhotoFile
    let destinationDirectory: URL
    let destinationFile: URL
}

private struct TransferJobResult: Sendable {
    let filename: String
    let copiedRawCount: Int
    let copiedJPEGCount: Int
    let skippedCount: Int
}

struct TransferService {
    private let progressUpdateInterval = 25

    func transfer(
        filesByDate: [String: [PhotoFile]],
        dateGroups: [DateGroup],
        destinationRoot: String,
        folderStructure: FolderStructure = .yearMonthDay,
        onProgress: ((TransferProgress) -> Void)? = nil
    ) async throws -> TransferSummary {
        var copiedRaw = 0
        var copiedJPEG = 0
        var skipped = 0
        let jobs = buildJobs(filesByDate: filesByDate, dateGroups: dateGroups, destinationRoot: destinationRoot, folderStructure: folderStructure)
        let totalFiles = jobs.count
        var completed = 0

        // Same-volume copies use clonefile (near-instant), so more workers is fine.
        // Cross-volume from an SD card: SD cards read best with few concurrent readers.
        let sourceRoot = filesByDate.values.first?.first?.sourcePath ?? destinationRoot
        let sameVolume = onSameVolume(sourceRoot, destinationRoot)
        let workerCount = min(
            max(totalFiles, 1),
            sameVolume ? 32 : min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 6)
        )

        try precreateDestinationDirectories(for: jobs)

        try await withThrowingTaskGroup(of: TransferJobResult.self) { group in
            var nextIndex = 0
            var lastProgressUpdate = 0

            func scheduleNext() {
                guard nextIndex < jobs.count else { return }
                let job = jobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Self.process(job: job)
                }
            }

            for _ in 0..<workerCount {
                scheduleNext()
            }

            while let result = try await group.next() {
                copiedRaw += result.copiedRawCount
                copiedJPEG += result.copiedJPEGCount
                skipped += result.skippedCount
                completed += 1
                let shouldReportEveryFile = totalFiles <= progressUpdateInterval
                if shouldReportEveryFile || completed - lastProgressUpdate >= progressUpdateInterval || completed == totalFiles {
                    lastProgressUpdate = completed
                    onProgress?(TransferProgress(
                        completedCount: completed,
                        totalCount: totalFiles,
                        copiedRawCount: copiedRaw,
                        copiedJPEGCount: copiedJPEG,
                        skippedCount: skipped,
                        currentFilename: result.filename
                    ))
                }
                scheduleNext()
            }
        }

        return TransferSummary(copiedRawCount: copiedRaw, copiedJPEGCount: copiedJPEG, skippedCount: skipped)
    }

    private func buildJobs(filesByDate: [String: [PhotoFile]], dateGroups: [DateGroup], destinationRoot: String, folderStructure: FolderStructure) -> [TransferJob] {
        let folders = Dictionary(uniqueKeysWithValues: dateGroups.map { ($0.dateKey, sanitizeFolderName($0.folderName)) })
        var jobs: [TransferJob] = []

        for (dateKey, files) in filesByDate {
            let folderName = folders[dateKey] ?? "Unlabeled"
            for file in files where file.isIncluded {
                let baseFolder = destinationFolder(root: destinationRoot, folderName: folderName, photoDate: file.photoDate, structure: folderStructure)
                let leaf = baseFolder.appendingPathComponent(file.isRaw ? "raw" : "jpeg", isDirectory: true)
                let destination = leaf.appendingPathComponent(file.filename)
                jobs.append(TransferJob(file: file, destinationDirectory: leaf, destinationFile: destination))
            }
        }

        return jobs
    }

    private func precreateDestinationDirectories(for jobs: [TransferJob]) throws {
        let fileManager = FileManager.default
        let directories = Set(jobs.map(\.destinationDirectory))
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func process(job: TransferJob) throws -> TransferJobResult {
        let fileManager = FileManager.default
        let src = URL(fileURLWithPath: job.file.sourcePath)
        let dst = job.destinationFile

        if fileManager.fileExists(atPath: dst.path) {
            return TransferJobResult(filename: job.file.filename, copiedRawCount: 0, copiedJPEGCount: 0, skippedCount: 1)
        }

        // Try clonefile first — on APFS same-volume this is copy-on-write (near-instant).
        // Falls back to a regular copy for cross-volume or non-APFS.
        var cloned = false
        var cloneErrno: Int32 = 0
        src.withUnsafeFileSystemRepresentation { srcPtr in
            guard let srcPtr else { return }
            dst.withUnsafeFileSystemRepresentation { dstPtr in
                guard let dstPtr else { return }
                if Darwin.clonefile(srcPtr, dstPtr, 0) == 0 {
                    cloned = true
                } else {
                    cloneErrno = errno
                }
            }
        }

        if cloneErrno == EEXIST {
            return TransferJobResult(filename: job.file.filename, copiedRawCount: 0, copiedJPEGCount: 0, skippedCount: 1)
        }

        if !cloned {
            // clonefile can leave a partial file on failure — clean up before falling back
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }
            do {
                try fileManager.copyItem(at: src, to: dst)
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                    return TransferJobResult(filename: job.file.filename, copiedRawCount: 0, copiedJPEGCount: 0, skippedCount: 1)
                }
                throw error
            }
        }

        return TransferJobResult(
            filename: job.file.filename,
            copiedRawCount: job.file.isRaw ? 1 : 0,
            copiedJPEGCount: job.file.isRaw ? 0 : 1,
            skippedCount: 0
        )
    }

    private func onSameVolume(_ path1: String, _ path2: String) -> Bool {
        var fs1 = statfs(), fs2 = statfs()
        guard statfs(path1, &fs1) == 0, statfs(path2, &fs2) == 0 else { return false }
        return fs1.f_fsid.val.0 == fs2.f_fsid.val.0 && fs1.f_fsid.val.1 == fs2.f_fsid.val.1
    }

    private func destinationFolder(root: String, folderName: String, photoDate: Date, structure: FolderStructure) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var base = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        switch structure {
        case .yearMonthDay:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: photoDate)
            formatter.dateFormat = "MMMM"
            let month = formatter.string(from: photoDate)
            formatter.dateFormat = "dd"
            let day = formatter.string(from: photoDate)
            base = base.appendingPathComponent(year).appendingPathComponent(month).appendingPathComponent(day)
        case .yearMonth:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: photoDate)
            formatter.dateFormat = "MMMM"
            let month = formatter.string(from: photoDate)
            base = base.appendingPathComponent(year).appendingPathComponent(month)
        case .year:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: photoDate)
            base = base.appendingPathComponent(year)
        case .flat:
            break
        }

        return base
    }

    private func sanitizeFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unlabeled" }
        return trimmed
            .replacingOccurrences(of: ">", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: ":", with: "-")
    }
}
