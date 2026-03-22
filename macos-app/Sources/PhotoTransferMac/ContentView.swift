import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                storageSection
                groupsSection
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Photo Manager")
                    .font(.system(size: 32, weight: .bold))
                Spacer()
                Button(viewModel.isScanning ? "Scanning..." : "Refresh") {
                    viewModel.refresh()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isWorking)

                Button(viewModel.isScanning ? "Scanning..." : "Scan SD Card") {
                    viewModel.scanCurrentCard()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScanning || viewModel.isWorking || viewModel.sourceVolume == nil)

                Button("Eject SD Card") {
                    viewModel.ejectSourceCard()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.sourceVolume == nil || viewModel.isScanning || viewModel.isWorking)

                Button(viewModel.isWorking ? "Transferring..." : transferButtonTitle) {
                    viewModel.startTransfer()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isWorking || viewModel.isScanning || viewModel.selectedDateCount == 0 || viewModel.selectedDestination.isEmpty)
            }
            Text("Transfer and organize your photos from SD card to SSD")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(viewModel.statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
            if viewModel.isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: viewModel.transferProgressFraction)
                        .tint(.blue)
                    if !viewModel.transferDetailText.isEmpty {
                        Text(viewModel.transferDetailText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 520)
            }
            if !viewModel.lastTransferSummaryText.isEmpty && !viewModel.isWorking {
                Text(viewModel.lastTransferSummaryText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !viewModel.hasScannedCurrentCard, viewModel.sourceVolume != nil {
                Text("We only detect the card at insert time now. Click Scan SD Card when you actually want to load the shoot dates.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transferButtonTitle: String {
        switch viewModel.selectedDateCount {
        case 0:
            return "Transfer Selected Days"
        case 1:
            return "Transfer Selected Day"
        default:
            return "Transfer Selected Days (\(viewModel.selectedDateCount))"
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Select Storage Devices")
                .font(.system(size: 18, weight: .semibold))

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Source")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !viewModel.sourceVolumes.isEmpty {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.sourceVolumes) { volume in
                                    StorageCard(
                                        volume: volume,
                                        isSelected: viewModel.sourceVolume?.path == volume.path,
                                        actionTitle: "Use This Card"
                                    ) {
                                        viewModel.selectSource(volume.path)
                                    }
                                }
                            }
                        }
                        .frame(height: 250)
                    } else {
                        EmptyStorageCard(message: "No likely source card detected yet")
                    }
                }

                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 52)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Destination")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose Folder") {
                            viewModel.chooseDestinationFolder()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.destinationVolumes) { volume in
                                StorageCard(
                                    volume: volume,
                                    isSelected: viewModel.selectedDestination == volume.path,
                                    actionTitle: "Use This Drive"
                                ) {
                                    viewModel.selectDestination(volume.path)
                                }
                            }
                        }
                    }
                    .frame(height: 250)
                }
            }
        }
        .padding(22)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shoot Dates")
                .font(.system(size: 18, weight: .semibold))

            LazyVStack(spacing: 18) {
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
                        onToggleSelect: { viewModel.toggleSelected(group.id) }
                    )
                }
            }
        }
    }
}

private struct StorageCard: View {
    let volume: VolumeOption
    let isSelected: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(volume.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text(volume.path)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(volume.freeText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: volume.usageFraction)
                .tint(isSelected ? .blue : .blue.opacity(0.7))

            Text(volume.usageText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .background(isSelected ? Color.blue.opacity(0.08) : .white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Color.blue : Color.black.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
    }
}

private struct EmptyStorageCard: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
    }
}

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onToggle) {
                    Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayDate)
                        .font(.system(size: 18, weight: .semibold))
                    Text(group.subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                FolderInputControl(
                    folderName: $group.folderName,
                    folderOptions: folderOptions,
                    onUseExistingFolder: onUseExistingFolder
                )
                    .frame(width: 280)

                Button("Open in Finder", action: onRevealInFinder)
                    .buttonStyle(.bordered)

                if !group.previews.isEmpty {
                    Button("Open First JPEG", action: onOpenFirstJPEG)
                        .buttonStyle(.bordered)
                }

                Button("Transfer This Day", action: onTransferThisDay)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || !hasDestination)

                if group.isSelected {
                    Button("Selected", action: onToggleSelect)
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                } else {
                    Button("Select Day", action: onToggleSelect)
                        .buttonStyle(.bordered)
                        .disabled(isWorking)
                }

                Text(group.jpegCount > 0 ? "\(group.jpegCount) previewable JPEGs" : "RAW-only date")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(18)

            if group.isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Folder")
                            .font(.system(size: 14, weight: .semibold))
                        Text(resolvedFolderName)
                            .font(.system(size: 13, weight: .medium))
                        Text(destinationPreviewPath)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if !group.previews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Representative JPEG")
                                .font(.system(size: 14, weight: .semibold))
                            Text(group.previews[0].filename)
                                .font(.system(size: 13, weight: .medium))
                            Text("Use Open First JPEG or Open in Finder to inspect the files without slowing down the import screen.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    Text("Use the folder control in the top row to type a new folder name or pick an existing one.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(18)
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(group.isSelected ? Color.blue.opacity(0.55) : Color.black.opacity(0.06), lineWidth: group.isSelected ? 2 : 1)
        )
    }
}

private struct FolderInputControl: View {
    @Binding var folderName: String
    let folderOptions: [String]
    let onUseExistingFolder: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            TextField("New Folder", text: $folderName)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1)

            Menu {
                if folderOptions.isEmpty {
                    Text("No existing folders yet")
                } else {
                    ForEach(folderOptions, id: \.self) { folder in
                        Button(folder) {
                            onUseExistingFolder(folder)
                        }
                    }
                }
            } label: {
                Color.clear
                    .frame(width: 14, height: 14)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}
