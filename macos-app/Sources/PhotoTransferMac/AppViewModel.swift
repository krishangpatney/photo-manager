import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var workflowMode: WorkflowMode = .sdImport
    @Published var sourceVolume: VolumeOption?
    @Published var sourceVolumes: [VolumeOption] = []
    @Published var reorganizeSource: FolderSource?
    @Published var destinationVolumes: [VolumeOption] = []
    @Published var selectedDestination: String = ""
    @Published var existingFolders: [String] = []
    @Published var dateGroups: [DateGroup] = []
    @Published var statusText: String = "Looking for SD cards and mounted drives..."
    @Published var isWorking = false
    @Published var isScanning = false
    @Published var hasScannedCurrentCard = false
    @Published var scanDetailText: String = ""
    @Published var transferDetailText: String = ""
    @Published var transferProgressFraction: Double = 0
    @Published var lastTransferSummaryText: String = ""
    @Published var ignoredScanFileCount = 0
    @Published var folderStructure: FolderStructure = .yearMonthDay
    @Published var blurThreshold: Double = BlurDetection.threshold {
        didSet { BlurDetection.threshold = blurThreshold }
    }

    private let config: AppConfig
    private var filesByDate: [String: [PhotoFile]] = [:]
    private var scanTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    init(config: AppConfig = AppConfigLoader.load(), autoRefresh: Bool = true) {
        self.config = config
        if autoRefresh {
            refresh()
        }
    }

    func refresh() {
        scanTask?.cancel()

        let scanner = VolumeScanner(config: config)
        let volumes = scanner.loadVolumes()
        let previousSDSourcePath = sourceVolume?.path
        sourceVolumes = volumes.filter(\.isLikelySource)
        if sourceVolumes.isEmpty {
            sourceVolumes = volumes
        }

        if workflowMode == .sdImport {
            if let current = sourceVolume,
               let refreshed = sourceVolumes.first(where: { $0.path == current.path }) {
                sourceVolume = refreshed
            } else {
                sourceVolume = sourceVolumes.first
            }
        }

        refreshDestinationVolumes(using: volumes)
        refreshFolderOptions()

        if workflowMode == .sdImport {
            guard let sourceVolume else {
                clearLoadedSourceData()
                isScanning = false
                statusText = "No SD card detected."
                return
            }

            if previousSDSourcePath != sourceVolume.path {
                clearLoadedSourceData()
            }

            isScanning = false
            if hasScannedCurrentCard {
                statusText = "Card detected: \(sourceVolume.name). Review or rescan when ready."
            } else {
                statusText = "Card detected: \(sourceVolume.name). Click Scan SD Card when you're ready."
            }
        } else {
            isScanning = false
            if let reorganizeSource {
                if hasScannedCurrentCard {
                    statusText = "Folder selected: \(reorganizeSource.name). Review or rescan when ready."
                } else {
                    statusText = "Folder selected: \(reorganizeSource.name). Click Scan Folder when you're ready."
                }
            } else {
                clearLoadedSourceData()
                statusText = "Choose a source folder to reorganize."
            }
        }
    }

    func scanCurrentSource() {
        scanTask?.cancel()
        let existingGroups = Dictionary(uniqueKeysWithValues: dateGroups.map { ($0.dateKey, $0) })
        let sourcePath: String
        let sourceName: String
        switch workflowMode {
        case .sdImport:
            guard let sourceVolume else {
                statusText = "No SD card detected."
                return
            }
            sourcePath = sourceVolume.path
            sourceName = sourceVolume.name
            statusText = "Scanning \(sourceName)..."
        case .reorganizeFolder:
            guard let reorganizeSource else {
                statusText = "Choose a source folder before scanning."
                return
            }
            sourcePath = reorganizeSource.path
            sourceName = reorganizeSource.name
            statusText = "Scanning selected folder \(sourceName)..."
        }

        isScanning = true
        scanDetailText = ""
        scanTask = Task.detached(priority: .userInitiated) { [config] in
            do {
                let result = try await PhotoScanner(config: config).scan(
                    sourcePath: sourcePath,
                    onProgress: { progress in
                        Task { @MainActor in
                            self.scanDetailText = "Scanned \(progress.scannedCount) file(s) • grouped \(progress.groupedFileCount) • ignored \(progress.ignoredAlreadyOrganizedCount)"
                        }
                    }
                )
                if Task.isCancelled {
                    return
                }
                let mergedGroups = result.dateGroups.map { group -> DateGroup in
                    guard let existing = existingGroups[group.dateKey] else {
                        return group
                    }
                    var updated = group
                    updated.folderName = existing.folderName
                    updated.isExpanded = existing.isExpanded
                    updated.isSelected = existing.isSelected
                    return updated
                }
                await MainActor.run {
                    guard self.currentSourcePath == sourcePath else {
                        return
                    }
                    self.filesByDate = result.filesByDate
                    self.dateGroups = mergedGroups
                    self.isScanning = false
                    self.hasScannedCurrentCard = true
                    self.ignoredScanFileCount = result.ignoredAlreadyOrganizedCount
                    if result.ignoredAlreadyOrganizedCount > 0 {
                        self.statusText = "Loaded \(mergedGroups.count) shoot dates from \(sourceName). Ignored \(result.ignoredAlreadyOrganizedCount) file(s) already in organized folders."
                    } else {
                        self.statusText = "Loaded \(mergedGroups.count) shoot dates from \(sourceName)."
                    }
                    self.scanDetailText = "Scanned \(result.ignoredAlreadyOrganizedCount + result.filesByDate.values.reduce(0) { $0 + $1.count }) file(s) total."
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    guard self.currentSourcePath == sourcePath else {
                        return
                    }
                    self.clearLoadedSourceData()
                    self.isScanning = false
                    self.ignoredScanFileCount = 0
                    self.scanDetailText = ""
                    self.statusText = "Failed to scan source folder: \(error.localizedDescription)"
                }
            }
        }
    }

    func chooseDestinationFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Destination"
        panel.directoryURL = URL(fileURLWithPath: selectedDestination.isEmpty ? "/Volumes" : selectedDestination)

        if panel.runModal() == .OK, let url = panel.url {
            selectDestination(url.path)
        }
    }

    func chooseReorganizeSourceFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Source Folder"
        panel.directoryURL = reorganizeSource.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            selectReorganizeSourceFolder(url.path)
        }
    }

    func selectDestination(_ path: String) {
        if workflowMode == .reorganizeFolder, path == reorganizeSource?.path {
            statusText = "Choose a destination folder other than the reorganize source folder."
            return
        }
        selectedDestination = path
        refreshFolderOptions()
    }

    func promptForFolderName(for dateGroupID: DateGroup.ID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == dateGroupID }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Set Folder Name"
        panel.message = "Choose or create the folder for \(dateGroups[index].displayDate)."
        panel.prompt = "Use Folder"
        panel.nameFieldLabel = "Folder Name:"
        panel.nameFieldStringValue = dateGroups[index].folderName.isEmpty ? "New Folder" : dateGroups[index].folderName
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = true
        if !selectedDestination.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: selectedDestination, isDirectory: true)
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let chosenFolderName: String
        let parentDirectory = url.deletingLastPathComponent().path
        if !selectedDestination.isEmpty, parentDirectory == selectedDestination {
            chosenFolderName = url.lastPathComponent
        } else if !selectedDestination.isEmpty, url.path.hasPrefix(selectedDestination + "/") {
            chosenFolderName = String(url.path.dropFirst(selectedDestination.count + 1))
        } else {
            chosenFolderName = url.lastPathComponent
        }

        dateGroups[index].folderName = chosenFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func selectSource(_ path: String) {
        guard let selected = sourceVolumes.first(where: { $0.path == path }) else { return }
        sourceVolume = selected
        refreshDestinationVolumes(using: VolumeScanner(config: config).loadVolumes())
        refreshFolderOptions()

        clearLoadedSourceData()
        statusText = "Source selected: \(selected.name). Click Scan SD Card when you're ready."
    }

    func selectReorganizeSourceFolder(_ path: String) {
        reorganizeSource = FolderSource(path: path)
        if selectedDestination == path {
            selectedDestination = ""
        }
        refreshDestinationVolumes(using: VolumeScanner(config: config).loadVolumes())
        refreshFolderOptions()

        clearLoadedSourceData()
        statusText = "Source folder selected: \(reorganizeSource?.name ?? "folder"). Click Scan Folder when you're ready."
    }

    func setWorkflowMode(_ mode: WorkflowMode) {
        guard workflowMode != mode else { return }
        workflowMode = mode
        clearLoadedSourceData()
        if mode == .reorganizeFolder {
            sourceVolume = nil
        }
        refresh()
    }

    func setFolderName(_ folder: String, for dateGroupID: DateGroup.ID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == dateGroupID }) else { return }
        dateGroups[index].folderName = folder
    }

    func toggleExpanded(_ dateGroupID: DateGroup.ID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == dateGroupID }) else { return }
        dateGroups[index].isExpanded.toggle()
    }

    func addExistingFolder(_ folder: String, to dateGroupID: DateGroup.ID) {
        setFolderName(folder, for: dateGroupID)
    }

    func toggleSelected(_ dateGroupID: DateGroup.ID) {
        guard let index = dateGroups.firstIndex(where: { $0.id == dateGroupID }) else { return }
        dateGroups[index].isSelected.toggle()
    }

    // Toggle a single JPEG preview's inclusion. If it has a paired RAW, the RAW is toggled too.
    func togglePhotoIncluded(dateGroupID: DateGroup.ID, photoID: PhotoPreview.ID) {
        guard let groupIndex = dateGroups.firstIndex(where: { $0.id == dateGroupID }),
              let previewIndex = dateGroups[groupIndex].previews.firstIndex(where: { $0.id == photoID }) else { return }

        let newValue = !dateGroups[groupIndex].previews[previewIndex].isIncluded
        dateGroups[groupIndex].previews[previewIndex].isIncluded = newValue

        let dateKey = dateGroups[groupIndex].dateKey
        let preview = dateGroups[groupIndex].previews[previewIndex]

        // sync into filesByDate so TransferService sees the change
        if var files = filesByDate[dateKey] {
            for i in files.indices {
                // match the JPEG itself
                if files[i].sourcePath == preview.path {
                    files[i].isIncluded = newValue
                }
                // match its paired RAW (same base name, isRaw == true)
                if let pairedKey = preview.pairedKey,
                   files[i].isRaw,
                   baseName(of: files[i].filename) == pairedKey {
                    files[i].isIncluded = newValue
                }
            }
            filesByDate[dateKey] = files
        }
    }

    private func availableFreeBytes(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(available)
    }

    private func baseName(of filename: String) -> String {
        URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    }

    private func sendNotification(title: String, body: String) {
        let safe = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
        let script = "display notification \"\(safe(body))\" with title \"\(safe(title))\" sound name \"default\""
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    func revealInFinder(for dateKey: String) {
        guard let files = filesByDate[dateKey], let firstFile = files.first else {
            statusText = "No files found for that shoot date."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: firstFile.sourcePath)])
    }

    func openFirstJPEG(for dateKey: String) {
        guard let preview = dateGroups.first(where: { $0.dateKey == dateKey })?.previews.first,
              let path = preview.path else {
            statusText = "No JPEG preview is available for that shoot date."
            return
        }

        let url = URL(fileURLWithPath: path)
        if !NSWorkspace.shared.open(url) {
            statusText = "Couldn't open the preview file."
        }
    }

    func ejectSourceCard() {
        guard let sourceVolume else {
            statusText = "No SD card detected."
            return
        }
        guard !isScanning && !isWorking else {
            statusText = "Wait for the current scan or transfer to finish before ejecting."
            return
        }

        statusText = "Ejecting \(sourceVolume.name)..."
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["eject", sourceVolume.path]

            do {
                try process.run()
                process.waitUntilExit()
                await MainActor.run {
                    if process.terminationStatus == 0 {
                        self.refresh()
                        self.statusText = "Ejected \(sourceVolume.name)."
                    } else {
                        self.statusText = "Couldn't eject \(sourceVolume.name)."
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusText = "Couldn't eject \(sourceVolume.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func startTransfer() {
        guard !selectedDestination.isEmpty else {
            statusText = "Choose a destination folder before starting the transfer."
            return
        }
        guard !dateGroups.isEmpty else {
            statusText = "No grouped photos are loaded."
            return
        }

        let selectedGroups = dateGroups.filter(\.isSelected)
        guard !selectedGroups.isEmpty else {
            statusText = "Select one or more days before starting the transfer."
            return
        }

        let selectedFiles: [String: [PhotoFile]] = Dictionary(uniqueKeysWithValues: selectedGroups.compactMap { group in
                guard let files = filesByDate[group.dateKey] else { return nil }
                return (group.dateKey, files)
        })
        runTransfer(
            filesByDate: selectedFiles,
            groups: selectedGroups,
            statusPrefix: "Transferring \(selectedGroups.count) selected day(s)..."
        )
    }

    func transferDateGroup(_ dateGroupID: DateGroup.ID) {
        guard !selectedDestination.isEmpty else {
            statusText = "Choose a destination folder before transferring a day."
            return
        }
        guard let group = dateGroups.first(where: { $0.id == dateGroupID }) else {
            statusText = "Couldn't find that shoot date."
            return
        }
        guard let files = filesByDate[group.dateKey], !files.isEmpty else {
            statusText = "No files found for \(group.displayDate)."
            return
        }

        runTransfer(
            filesByDate: [group.dateKey: files],
            groups: [group],
            statusPrefix: "Transferring \(group.displayDate)..."
        )
    }

    private func runTransfer(filesByDate: [String: [PhotoFile]], groups: [DateGroup], statusPrefix: String) {
        // Free space check
        let totalBytes = filesByDate.values.flatMap { $0 }.filter(\.isIncluded).reduce(0) { $0 + $1.fileSize }
        if let available = availableFreeBytes(at: selectedDestination), totalBytes > 0, available < totalBytes {
            statusText = "Not enough space on destination. Need \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)), only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available."
            return
        }

        transferTask?.cancel()
        isWorking = true
        statusText = statusPrefix
        transferDetailText = ""
        transferProgressFraction = 0
        lastTransferSummaryText = ""

        let currentFilesByDate = filesByDate
        let currentGroups = groups
        let destinationRoot = selectedDestination
        let currentFolderStructure = folderStructure
        transferTask = Task.detached(priority: .userInitiated) {
            do {
                let summary = try await TransferService().transfer(
                    filesByDate: currentFilesByDate,
                    dateGroups: currentGroups,
                    destinationRoot: destinationRoot,
                    folderStructure: currentFolderStructure,
                    onProgress: { progress in
                        Task { @MainActor in
                            self.transferProgressFraction = progress.fractionComplete
                            self.transferDetailText = "Processing \(progress.currentFilename) • \(progress.completedCount)/\(progress.totalCount) • \(progress.copiedJPEGCount) JPEG • \(progress.copiedRawCount) RAW • \(progress.skippedCount) skipped"
                        }
                    }
                )
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    self.refreshFolderOptions()
                    let summaryText = "Transfer complete: \(summary.copiedRawCount) RAW, \(summary.copiedJPEGCount) JPEG, \(summary.skippedCount) skipped."
                    self.statusText = summaryText
                    self.sendNotification(title: "Transfer Complete", body: "\(currentGroups.count) day(s) transferred. \(summary.copiedRawCount) RAW, \(summary.copiedJPEGCount) JPEG.")
                    self.transferDetailText = "Done."
                    self.transferProgressFraction = 1
                    self.lastTransferSummaryText = "\(currentGroups.count) day(s) transferred to \(destinationRoot)"
                    let transferredKeys = Set(currentGroups.map(\.dateKey))
                    self.dateGroups = self.dateGroups.map { group in
                        var updated = group
                        if transferredKeys.contains(group.dateKey) {
                            updated.isSelected = false
                        }
                        return updated
                    }
                    self.isWorking = false
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    self.statusText = "Transfer failed: \(error.localizedDescription)"
                    self.transferDetailText = ""
                    self.transferProgressFraction = 0
                    self.isWorking = false
                }
            }
        }
    }

    private func refreshFolderOptions() {
        existingFolders = folderNames(at: selectedDestination)
    }

    func resolvedFolderName(for group: DateGroup) -> String {
        sanitizeFolderInput(group.folderName)
    }

    private func sanitizeFolderInput(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Unlabeled" }
        return trimmed
            .replacingOccurrences(of: ">", with: "/")  // allow > as subfolder separator
            .replacingOccurrences(of: "\\", with: "/") // normalize backslash
            .replacingOccurrences(of: ":", with: "-")  // colons are invalid on macOS
    }

    func destinationPreviewPath(for group: DateGroup) -> String {
        guard !selectedDestination.isEmpty,
              let file = filesByDate[group.dateKey]?.first else {
            return "Choose a destination to preview the final path."
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var path = URL(fileURLWithPath: selectedDestination, isDirectory: true)
            .appendingPathComponent(resolvedFolderName(for: group), isDirectory: true)

        switch folderStructure {
        case .yearMonthDay:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: file.photoDate)
            formatter.dateFormat = "MMMM"
            let month = formatter.string(from: file.photoDate)
            formatter.dateFormat = "dd"
            let day = formatter.string(from: file.photoDate)
            path = path.appendingPathComponent(year).appendingPathComponent(month).appendingPathComponent(day)
        case .yearMonth:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: file.photoDate)
            formatter.dateFormat = "MMMM"
            let month = formatter.string(from: file.photoDate)
            path = path.appendingPathComponent(year).appendingPathComponent(month)
        case .year:
            formatter.dateFormat = "yyyy"
            let year = formatter.string(from: file.photoDate)
            path = path.appendingPathComponent(year)
        case .flat:
            break
        }

        return path.path
    }

    var selectedDateCount: Int {
        dateGroups.filter(\.isSelected).count
    }

    var currentSourcePath: String? {
        switch workflowMode {
        case .sdImport:
            return sourceVolume?.path
        case .reorganizeFolder:
            return reorganizeSource?.path
        }
    }

    var scanButtonTitle: String {
        workflowMode == .sdImport ? "Scan SD Card" : "Scan Folder"
    }

    var hasActiveSource: Bool {
        currentSourcePath != nil
    }

    var activeSourceTitle: String {
        switch workflowMode {
        case .sdImport:
            return "Source (SD Card)"
        case .reorganizeFolder:
            return "Source Folder"
        }
    }

    private func clearLoadedSourceData() {
        filesByDate = [:]
        dateGroups = []
        hasScannedCurrentCard = false
        ignoredScanFileCount = 0
        scanDetailText = ""
    }

    private func refreshDestinationVolumes(using volumes: [VolumeOption]) {
        let excludedPath = workflowMode == .sdImport ? sourceVolume?.path : nil
        destinationVolumes = volumes.filter { volume in
            guard let excludedPath else { return true }
            return volume.path != excludedPath
        }

        if workflowMode == .reorganizeFolder, selectedDestination == reorganizeSource?.path {
            selectedDestination = ""
        }

        if !selectedDestination.isEmpty {
            if workflowMode == .sdImport,
               !destinationVolumes.contains(where: { $0.path == selectedDestination }) {
                selectedDestination = destinationVolumes.first?.path ?? ""
            }
        } else if workflowMode == .sdImport {
            selectedDestination = destinationVolumes.first?.path ?? ""
        }
    }

    private func folderNames(at path: String) -> [String] {
        guard !path.isEmpty, let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return entries
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                var isDirectory: ObjCBool = false
                let fullPath = (path as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory)
                return isDirectory.boolValue
            }
            .sorted()
    }
}
