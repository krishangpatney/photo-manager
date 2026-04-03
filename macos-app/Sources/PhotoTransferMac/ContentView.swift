import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    storageSection
                    if !viewModel.dateGroups.isEmpty || viewModel.isScanning {
                        groupsSection
                    }
                }
                .padding(24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo Manager")
                        .font(.system(size: 22, weight: .bold))
                    Text(viewModel.workflowMode == .sdImport
                         ? "Transfer and organize your photos from SD card to SSD"
                         : "Pick a folder, group photos by date, and reorganize into your destination")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }

                Spacer()

                Picker("", selection: $viewModel.workflowMode) {
                    ForEach(WorkflowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .onChange(of: viewModel.workflowMode) { _, newMode in
                    viewModel.setWorkflowMode(newMode)
                }

                Button(action: viewModel.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isWorking)
                .help("Refresh volumes")

                Button(viewModel.isWorking ? "Transferring…" : transferButtonTitle) {
                    viewModel.startTransfer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking || viewModel.isScanning || viewModel.selectedDateCount == 0 || viewModel.selectedDestination.isEmpty)
            }

            statusPill
        }
        .padding(.leading, 80)
        .padding(.trailing, 60)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var statusPill: some View {
        if viewModel.isWorking {
            HStack(spacing: 8) {
                ProgressView(value: viewModel.transferProgressFraction)
                    .frame(width: 100)
                Text(viewModel.transferDetailText.isEmpty ? "Transferring…" : viewModel.transferDetailText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        } else if viewModel.isScanning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(viewModel.scanDetailText.isEmpty ? "Scanning…" : viewModel.scanDetailText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        } else if !viewModel.statusText.isEmpty {
            Text(viewModel.statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var transferButtonTitle: String {
        switch viewModel.selectedDateCount {
        case 0: return "Transfer"
        case 1: return "Transfer 1 Day"
        default: return "Transfer \(viewModel.selectedDateCount) Days"
        }
    }

    // MARK: Storage section

    private var storageSection: some View {
        HStack(alignment: .top, spacing: 16) {
            sourceColumn
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .padding(.top, 46)
            destinationColumn
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(viewModel.activeSourceTitle, systemImage: viewModel.workflowMode == .sdImport ? "sdcard" : "folder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(viewModel.isScanning ? "Scanning…" : viewModel.scanButtonTitle) {
                    viewModel.scanCurrentSource()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isScanning || viewModel.isWorking || !viewModel.hasActiveSource)

                if viewModel.workflowMode == .sdImport {
                    Button("Eject") { viewModel.ejectSourceCard() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.sourceVolume == nil || viewModel.isScanning || viewModel.isWorking)
                }
            }

            if viewModel.workflowMode == .sdImport {
                if viewModel.sourceVolumes.isEmpty {
                    emptyVolumeCard(message: "No SD card detected")
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(viewModel.sourceVolumes) { volume in
                                CompactVolumeCard(
                                    volume: volume,
                                    isSelected: viewModel.sourceVolume?.path == volume.path
                                ) { viewModel.selectSource(volume.path) }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                FolderSourceCard(source: viewModel.reorganizeSource, action: viewModel.chooseReorganizeSourceFolder)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var destinationColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Destination", systemImage: "externaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder") { viewModel.chooseDestinationFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(viewModel.destinationVolumes) { volume in
                        CompactVolumeCard(
                            volume: volume,
                            isSelected: viewModel.selectedDestination == volume.path
                        ) { viewModel.selectDestination(volume.path) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func emptyVolumeCard(message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Groups section

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shoot Dates")
                    .font(.system(size: 15, weight: .semibold))
                if viewModel.ignoredScanFileCount > 0 {
                    Text("\(viewModel.ignoredScanFileCount) already organized, skipped")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }

            LazyVStack(spacing: 10) {
                ForEach($viewModel.dateGroups) { $group in
                    DateGroupCard(
                        group: $group,
                        isWorking: viewModel.isWorking || viewModel.isScanning,
                        hasDestination: !viewModel.selectedDestination.isEmpty,
                        resolvedFolderName: viewModel.resolvedFolderName(for: group),
                        destinationPreviewPath: viewModel.destinationPreviewPath(for: group),
                        folderOptions: viewModel.existingFolders,
                        onToggle: { viewModel.toggleExpanded(group.id) },
                        onUseExistingFolder: { viewModel.addExistingFolder($0, to: group.id) },
                        onRevealInFinder: { viewModel.revealInFinder(for: group.dateKey) },
                        onOpenFirstJPEG: { viewModel.openFirstJPEG(for: group.dateKey) },
                        onTransferThisDay: { viewModel.transferDateGroup(group.id) },
                        onToggleSelect: { viewModel.toggleSelected(group.id) },
                        onTogglePhotoIncluded: { viewModel.togglePhotoIncluded(dateGroupID: group.id, photoID: $0) }
                    )
                }
            }
        }
    }
}

// MARK: - Compact volume card

private struct CompactVolumeCard: View {
    let volume: VolumeOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.system(size: 13))
                        }
                        Text(volume.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(nsColor: .labelColor))
                    }
                    Text(volume.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(1)
                    ProgressView(value: volume.usageFraction)
                        .tint(isSelected ? .blue : Color(nsColor: .quaternaryLabelColor))
                        .padding(.top, 2)
                    Text(volume.freeText)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isSelected ? Color.blue.opacity(0.07) : Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.4) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder source card

private struct FolderSourceCard: View {
    let source: FolderSource?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(source != nil ? .blue : Color(nsColor: .tertiaryLabelColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source?.name ?? "Choose source folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    if let path = source?.path {
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Date group card

private struct DateGroupCard: View {
    @Binding var group: DateGroup
    let isWorking: Bool
    let hasDestination: Bool
    let resolvedFolderName: String
    let destinationPreviewPath: String
    let folderOptions: [String]
    let onToggle: () -> Void
    let onUseExistingFolder: (String) -> Void
    let onRevealInFinder: () -> Void
    let onOpenFirstJPEG: () -> Void
    let onTransferThisDay: () -> Void
    let onToggleSelect: () -> Void
    let onTogglePhotoIncluded: (PhotoPreview.ID) -> Void

    @State private var isReviewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .center, spacing: 12) {
                Button(action: onToggle) {
                    Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                // Date + stats
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayDate)
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(group.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        if group.excludedCount > 0 {
                            Text("\(group.excludedCount) excluded")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Spacer()

                // Folder input
                FolderInputControl(
                    folderName: $group.folderName,
                    folderOptions: folderOptions,
                    onUseExistingFolder: onUseExistingFolder
                )
                .frame(width: 200)

                // Actions
                if !group.previews.isEmpty {
                    Button(action: { isReviewing = true }) {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .help("Review photos")
                    .sheet(isPresented: $isReviewing) {
                        PhotoReviewSheet(group: group, onToggle: onTogglePhotoIncluded)
                    }
                }

                Button(action: onToggleSelect) {
                    Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(group.isSelected ? .blue : Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(group.isSelected ? "Deselect" : "Select for batch transfer")

                Button("Transfer", action: onTransferThisDay)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isWorking || !hasDestination)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Expanded details
            if group.isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button("Open in Finder", action: onRevealInFinder)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        if !group.previews.isEmpty {
                            Button("Open First JPEG", action: onOpenFirstJPEG)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    if !destinationPreviewPath.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Destination path")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                            Text(destinationPreviewPath)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .background(group.isSelected ? Color.blue.opacity(0.04) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(group.isSelected ? Color.blue.opacity(0.35) : Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Folder input control

private struct FolderInputControl: View {
    @Binding var folderName: String
    let folderOptions: [String]
    let onUseExistingFolder: (String) -> Void

    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 0) {
            // Text field area
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))

                TextField("Folder or Folder/Subfolder", text: $folderName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // Dropdown button — only when there are existing folders
            if !folderOptions.isEmpty {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .padding(.vertical, 6)

                Button(action: { showPopover.toggle() }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(folderOptions, id: \.self) { folder in
                            Button(action: {
                                onUseExistingFolder(folder)
                                showPopover = false
                            }) {
                                Text(folder)
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(minWidth: 200)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}
