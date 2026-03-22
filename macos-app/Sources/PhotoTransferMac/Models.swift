import Foundation

enum WorkflowMode: String, CaseIterable, Identifiable, Sendable {
    case sdImport
    case reorganizeFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sdImport:
            return "SD Import"
        case .reorganizeFolder:
            return "Reorganize Folder"
        }
    }
}

struct AppConfig: Decodable, Sendable {
    let photographyPath: String
    let sdCardNames: [String]
    let checkIntervalSeconds: Int
    let supportedRawExtensions: [String]
    let supportedJpegExtensions: [String]
    let logFile: String

    enum CodingKeys: String, CodingKey {
        case photographyPath = "photography_path"
        case sdCardNames = "sd_card_names"
        case checkIntervalSeconds = "check_interval_seconds"
        case supportedRawExtensions = "supported_raw_extensions"
        case supportedJpegExtensions = "supported_jpeg_extensions"
        case logFile = "log_file"
    }

    static let fallback = AppConfig(
        photographyPath: "\(NSHomeDirectory())/Documents/Photography",
        sdCardNames: ["SD Card", "Untitled", "NO NAME", "EOS_DIGITAL"],
        checkIntervalSeconds: 5,
        supportedRawExtensions: [".cr2", ".nef", ".arw", ".dng", ".raw", ".orf", ".rw2", ".tiff", ".tif", ".raf"],
        supportedJpegExtensions: [".jpg", ".jpeg"],
        logFile: "\(NSHomeDirectory())/Library/Logs/photo-transfer.log"
    )
}

struct FolderSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String

    init(path: String) {
        self.id = path
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
    }
}

struct VolumeOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let totalBytes: Int64?
    let freeBytes: Int64?
    let usedBytes: Int64?
    let sourceScore: Int

    init(name: String, path: String, totalBytes: Int64?, freeBytes: Int64?, usedBytes: Int64?, sourceScore: Int) {
        self.id = path
        self.name = name
        self.path = path
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
        self.sourceScore = sourceScore
    }

    var usageFraction: Double {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    var freeText: String {
        guard let freeBytes else { return "Storage info unavailable" }
        return "\(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) free"
    }

    var usageText: String {
        guard let totalBytes, let usedBytes else { return "Storage info unavailable" }
        return "\(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)) used / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)) total"
    }

    var isLikelySource: Bool {
        sourceScore > 0
    }
}

struct PhotoFile: Hashable, Sendable {
    let sourcePath: String
    let filename: String
    let photoDate: Date
    let fileSize: Int64
    let isRaw: Bool
}

struct PhotoPreview: Identifiable, Hashable, Sendable {
    let id: String
    let path: String?
    let filename: String
    let bytes: Int64

    init(path: String?, filename: String, bytes: Int64) {
        self.id = path ?? filename
        self.path = path
        self.filename = filename
        self.bytes = bytes
    }
}

struct DateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let dateKey: String
    let displayDate: String
    let photoCount: Int
    let rawCount: Int
    let jpegCount: Int
    let totalBytes: Int64
    var folderName: String
    let previews: [PhotoPreview]
    var isExpanded: Bool
    var isSelected: Bool

    init(dateKey: String, displayDate: String, photoCount: Int, rawCount: Int, jpegCount: Int, totalBytes: Int64, folderName: String, previews: [PhotoPreview], isExpanded: Bool, isSelected: Bool = false) {
        self.id = dateKey
        self.dateKey = dateKey
        self.displayDate = displayDate
        self.photoCount = photoCount
        self.rawCount = rawCount
        self.jpegCount = jpegCount
        self.totalBytes = totalBytes
        self.folderName = folderName
        self.previews = previews
        self.isExpanded = isExpanded
        self.isSelected = isSelected
    }

    var subtitle: String {
        "\(photoCount) photos • \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
    }
}

struct TransferSummary: Sendable {
    let copiedRawCount: Int
    let copiedJPEGCount: Int
    let skippedCount: Int
}

struct TransferProgress: Sendable {
    let completedCount: Int
    let totalCount: Int
    let copiedRawCount: Int
    let copiedJPEGCount: Int
    let skippedCount: Int
    let currentFilename: String

    var fractionComplete: Double {
        guard totalCount > 0 else { return 0 }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }
}

struct ScanProgress: Sendable {
    let scannedCount: Int
    let groupedFileCount: Int
    let ignoredAlreadyOrganizedCount: Int
}
