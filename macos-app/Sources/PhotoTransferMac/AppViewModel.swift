import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sourceVolume: VolumeOption?
    @Published var sourceVolumes: [VolumeOption] = []
    @Published var destinationVolumes: [VolumeOption] = []
    @Published var selectedDestination: String = ""
    @Published var existingFolders: [String] = []
    @Published var dateGroups: [DateGroup] = []
    @Published var statusText: String = "Looking for SD cards and mounted drives..."
    @Published var isWorking = false
    @Published var isScanning = false
    @Published var hasScannedCurrentCard = false
    @Published var transferDetailText: String = ""
    @Published var transferProgressFraction: Double = 0
    @Published var lastTransferSummaryText: String = ""

    private let config: AppConfig
    private var filesByDate: [String: [PhotoFile]] = [:]
    private var scanTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    init() {
        self.config = AppConfigLoader.load()
        refresh()
    }

    func refresh() {
        scanTask?.cancel()

        let scanner = VolumeScanner(config: config)
        let volumes = scanner.loadVolumes()
        let previousSourcePath = sourceVolume?.path
        sourceVolumes = volumes.filter(\.isLikelySource)
        if sourceVolumes.isEmpty {
            sourceVolumes = volumes
        }

        if let current = sourceVolume,
           let refreshed = sourceVolumes.first(where: { $0.path == current.path }) {
            sourceVolume = refreshed
        } else {
            sourceVolume = sourceVolumes.first
        }

        destinationVolumes = volumes.filter { $0.path != sourceVolume?.path }
        if selectedDestination.isEmpty || selectedDestination == sourceVolume?.path || !destinationVolumes.contains(where: { $0.path == selectedDestination }) {
            selectedDestination = destinationVolumes.first?.path ?? ""
        }

        refreshFolderOptions()

        guard let sourceVolume else {
            filesByDate = [:]
            dateGroups = []
            isScanning = false
            hasScannedCurrentCard = false
            statusText = "No SD card detected."
            return
        }

        if previousSourcePath != sourceVolume.path {
            filesByDate = [:]
            dateGroups = []
            hasScannedCurrentCard = false
        }

        isScanning = false
        if hasScannedCurrentCard {
            statusText = "Card detected: \(sourceVolume.name). Review or rescan when ready."
        } else {
            statusText = "Card detected: \(sourceVolume.name). Click Scan SD Card when you're ready."
        }
    }

    func scanCurrentCard() {
        guard let sourceVolume else {
            statusText = "No SD card detected."
            return
        }

        scanTask?.cancel()
        let existingGroups = Dictionary(uniqueKeysWithValues: dateGroups.map { ($0.dateKey, $0) })
        let sourcePath = sourceVolume.path
        let sourceName = sourceVolume.name

        isScanning = true
        statusText = "Scanning \(sourceName)..."
        scanTask = Task.detached(priority: .userInitiated) { [config] in
            do {
                let result = try PhotoScanner(config: config).scan(sdCardPath: sourcePath)
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
                    guard self.sourceVolume?.path == sourcePath else {
                        return
                    }
                    self.filesByDate = result.filesByDate
                    self.dateGroups = mergedGroups
                    self.isScanning = false
                    self.hasScannedCurrentCard = true
                    self.statusText = "Loaded \(mergedGroups.count) shoot dates from \(sourceName)."
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                await MainActor.run {
                    guard self.sourceVolume?.path == sourcePath else {
                        return
                    }
                    self.filesByDate = [:]
                    self.dateGroups = []
                    self.isScanning = false
                    self.hasScannedCurrentCard = false
                    self.statusText = "Failed to scan SD card: \(error.localizedDescription)"
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

    func selectDestination(_ path: String) {
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
        destinationVolumes = VolumeScanner(config: config)
            .loadVolumes()
            .filter { $0.path != path }
        if selectedDestination.isEmpty || selectedDestination == path || !destinationVolumes.contains(where: { $0.path == selectedDestination }) {
            selectedDestination = destinationVolumes.first?.path ?? ""
        }
        refreshFolderOptions()

        filesByDate = [:]
        dateGroups = []
        hasScannedCurrentCard = false
        statusText = "Source selected: \(selected.name). Click Scan SD Card when you're ready."
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
        transferTask?.cancel()
        isWorking = true
        statusText = statusPrefix
        transferDetailText = ""
        transferProgressFraction = 0
        lastTransferSummaryText = ""

        let currentFilesByDate = filesByDate
        let currentGroups = groups
        let destinationRoot = selectedDestination
        transferTask = Task.detached(priority: .userInitiated) {
            do {
                let summary = try await TransferService().transfer(
                    filesByDate: currentFilesByDate,
                    dateGroups: currentGroups,
                    destinationRoot: destinationRoot,
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
                    self.statusText = "Transfer complete: \(summary.copiedRawCount) RAW, \(summary.copiedJPEGCount) JPEG, \(summary.skippedCount) skipped."
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
        let trimmed = group.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unlabeled"
        }
        return trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    func destinationPreviewPath(for group: DateGroup) -> String {
        guard !selectedDestination.isEmpty,
              let file = filesByDate[group.dateKey]?.first else {
            return "Choose a destination to preview the final path."
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyy"
        let year = formatter.string(from: file.photoDate)
        formatter.dateFormat = "MMMM"
        let month = formatter.string(from: file.photoDate)
        formatter.dateFormat = "dd"
        let day = formatter.string(from: file.photoDate)

        return URL(fileURLWithPath: selectedDestination, isDirectory: true)
            .appendingPathComponent(resolvedFolderName(for: group), isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .path
    }

    var selectedDateCount: Int {
        dateGroups.filter(\.isSelected).count
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
