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

    func scan(sourcePath: String, onProgress: ((ScanProgress) -> Void)? = nil) throws -> PhotoScanResult {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: sourcePath, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return PhotoScanResult(filesByDate: [:], dateGroups: [], ignoredAlreadyOrganizedCount: 0)
        }

        var grouped: [String: [PhotoFile]] = [:]
        var ignoredAlreadyOrganizedCount = 0
        var scannedCount = 0
        var groupedFileCount = 0
        var lastReportedCount = 0
        for case let url as URL in enumerator {
            autoreleasepool {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if [".Trashes", ".Spotlight-V100", ".fseventsd"].contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    if isOrganizedMediaDirectory(url: url, sourceRoot: sourcePath) {
                        ignoredAlreadyOrganizedCount += countSupportedPhotos(in: url)
                        enumerator.skipDescendants()
                    }
                    return
                }

                let ext = "." + url.pathExtension.lowercased()
                let isRaw = config.supportedRawExtensions.contains(ext)
                let isJPEG = config.supportedJpegExtensions.contains(ext)
                if !isRaw && !isJPEG {
                    return
                }

                if isAlreadyOrganizedPhoto(url: url, sourceRoot: sourcePath) {
                    ignoredAlreadyOrganizedCount += 1
                    scannedCount += 1
                    reportProgressIfNeeded(
                        onProgress: onProgress,
                        scannedCount: scannedCount,
                        groupedFileCount: groupedFileCount,
                        ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount,
                        lastReportedCount: &lastReportedCount
                    )
                    return
                }

                let photoDate = readPhotoDate(from: url) ?? values?.contentModificationDate ?? Date()
                let file = PhotoFile(
                    sourcePath: url.path,
                    filename: url.lastPathComponent,
                    photoDate: photoDate,
                    fileSize: Int64(values?.fileSize ?? 0),
                    isRaw: isRaw
                )
                grouped[dateKey(for: photoDate), default: []].append(file)
                scannedCount += 1
                groupedFileCount += 1
                reportProgressIfNeeded(
                    onProgress: onProgress,
                    scannedCount: scannedCount,
                    groupedFileCount: groupedFileCount,
                    ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount,
                    lastReportedCount: &lastReportedCount
                )
            }
        }

        onProgress?(ScanProgress(
            scannedCount: scannedCount,
            groupedFileCount: groupedFileCount,
            ignoredAlreadyOrganizedCount: ignoredAlreadyOrganizedCount
        ))

        let keys = grouped.keys.sorted()
        let groups = keys.enumerated().map { offset, key in
            let files = grouped[key, default: []]
            let rawCount = files.filter(\.isRaw).count
            let jpegFiles = files.filter { !$0.isRaw }
            return DateGroup(
                dateKey: key,
                displayDate: displayDate(for: files.first?.photoDate ?? Date()),
                photoCount: files.count,
                rawCount: rawCount,
                jpegCount: jpegFiles.count,
                totalBytes: files.reduce(0) { $0 + $1.fileSize },
                folderName: "",
                previews: jpegFiles.prefix(1).map {
                    PhotoPreview(path: $0.sourcePath, filename: $0.filename, bytes: $0.fileSize)
                },
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

    private func readPhotoDate(from url: URL) -> Date? {
        let options: CFDictionary = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let parsed = parseExifDate(value) {
            return parsed
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let value = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let parsed = parseExifDate(value) {
            return parsed
        }

        return nil
    }

    private func parseExifDate(_ value: String) -> Date? {
        Self.exifDateFormatter.date(from: value)
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

    private func isOrganizedMediaDirectory(url: URL, sourceRoot: String) -> Bool {
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

    private func countSupportedPhotos(in directory: URL) -> Int {
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
            if values?.isDirectory == true {
                continue
            }

            let ext = "." + url.pathExtension.lowercased()
            if config.supportedRawExtensions.contains(ext) || config.supportedJpegExtensions.contains(ext) {
                count += 1
            }
        }
        return count
    }

    private func isAlreadyOrganizedPhoto(url: URL, sourceRoot: String) -> Bool {
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
        onProgress: ((TransferProgress) -> Void)? = nil
    ) async throws -> TransferSummary {
        var copiedRaw = 0
        var copiedJPEG = 0
        var skipped = 0
        let jobs = buildJobs(filesByDate: filesByDate, dateGroups: dateGroups, destinationRoot: destinationRoot)
        let totalFiles = jobs.count
        var completed = 0
        let workerCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 4), max(totalFiles, 1), 8)

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

    private func buildJobs(filesByDate: [String: [PhotoFile]], dateGroups: [DateGroup], destinationRoot: String) -> [TransferJob] {
        let folders = Dictionary(uniqueKeysWithValues: dateGroups.map { ($0.dateKey, sanitizeFolderName($0.folderName)) })
        var jobs: [TransferJob] = []

        for (dateKey, files) in filesByDate {
            let folderName = folders[dateKey] ?? "Unlabeled"
            for file in files {
                let baseFolder = destinationFolder(root: destinationRoot, folderName: folderName, photoDate: file.photoDate)
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

        if fileManager.fileExists(atPath: job.destinationFile.path) {
            return TransferJobResult(
                filename: job.file.filename,
                copiedRawCount: 0,
                copiedJPEGCount: 0,
                skippedCount: 1
            )
        }

        do {
            try fileManager.copyItem(at: URL(fileURLWithPath: job.file.sourcePath), to: job.destinationFile)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                return TransferJobResult(
                    filename: job.file.filename,
                    copiedRawCount: 0,
                    copiedJPEGCount: 0,
                    skippedCount: 1
                )
            }
            throw error
        }

        return TransferJobResult(
            filename: job.file.filename,
            copiedRawCount: job.file.isRaw ? 1 : 0,
            copiedJPEGCount: job.file.isRaw ? 0 : 1,
            skippedCount: 0
        )
    }

    private func destinationFolder(root: String, folderName: String, photoDate: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: photoDate)
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: photoDate)
        formatter.dateFormat = "dd"
        let day = formatter.string(from: photoDate)

        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
    }

    private func sanitizeFolderName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unlabeled"
        }
        return trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
