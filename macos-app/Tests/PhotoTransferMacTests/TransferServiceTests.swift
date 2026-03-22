import Foundation
import XCTest
@testable import PhotoTransferMac

final class TransferServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testTransferCopiesRawAndJPEGIntoExpectedFolders() async throws {
        let date = makeDate(year: 2026, month: 2, day: 7)
        let rawSource = try makeSourceFile(named: "DSCF0001.RAF", contents: "raw-data")
        let jpegSource = try makeSourceFile(named: "DSCF0001.JPG", contents: "jpeg-data")
        let destinationRoot = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let filesByDate = [
            "2026-02-07": [
                PhotoFile(sourcePath: rawSource.path, filename: "DSCF0001.RAF", photoDate: date, fileSize: 8, isRaw: true),
                PhotoFile(sourcePath: jpegSource.path, filename: "DSCF0001.JPG", photoDate: date, fileSize: 9, isRaw: false)
            ]
        ]
        let dateGroups = [
            DateGroup(
                dateKey: "2026-02-07",
                displayDate: "Saturday, February 07, 2026",
                photoCount: 2,
                rawCount: 1,
                jpegCount: 1,
                totalBytes: 17,
                folderName: "Mom/UK:Trip",
                previews: [],
                isExpanded: false
            )
        ]

        let summary = try await TransferService().transfer(
            filesByDate: filesByDate,
            dateGroups: dateGroups,
            destinationRoot: destinationRoot.path
        )

        XCTAssertEqual(summary.copiedRawCount, 1)
        XCTAssertEqual(summary.copiedJPEGCount, 1)
        XCTAssertEqual(summary.skippedCount, 0)

        let rawDestination = destinationRoot
            .appendingPathComponent("Mom-UK-Trip/2026/February/07/raw/DSCF0001.RAF")
        let jpegDestination = destinationRoot
            .appendingPathComponent("Mom-UK-Trip/2026/February/07/jpeg/DSCF0001.JPG")

        XCTAssertTrue(FileManager.default.fileExists(atPath: rawDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpegDestination.path))
    }

    func testTransferSkipsExistingFilesAndReportsProgress() async throws {
        let date = makeDate(year: 2026, month: 3, day: 21)
        let rawSource = try makeSourceFile(named: "DSCF0255.RAF", contents: "raw-data")
        let jpegSource = try makeSourceFile(named: "DSCF0255.JPG", contents: "jpeg-data")
        let destinationRoot = tempRoot.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let files = [
            PhotoFile(sourcePath: rawSource.path, filename: "DSCF0255.RAF", photoDate: date, fileSize: 8, isRaw: true),
            PhotoFile(sourcePath: jpegSource.path, filename: "DSCF0255.JPG", photoDate: date, fileSize: 9, isRaw: false)
        ]
        let filesByDate = ["2026-03-21": files]
        let dateGroups = [
            DateGroup(
                dateKey: "2026-03-21",
                displayDate: "Saturday, March 21, 2026",
                photoCount: 2,
                rawCount: 1,
                jpegCount: 1,
                totalBytes: 17,
                folderName: "Birthday",
                previews: [],
                isExpanded: false
            )
        ]

        _ = try await TransferService().transfer(
            filesByDate: filesByDate,
            dateGroups: dateGroups,
            destinationRoot: destinationRoot.path
        )

        var progressEvents: [TransferProgress] = []
        let summary = try await TransferService().transfer(
            filesByDate: filesByDate,
            dateGroups: dateGroups,
            destinationRoot: destinationRoot.path,
            onProgress: { progress in
                progressEvents.append(progress)
            }
        )

        XCTAssertEqual(summary.copiedRawCount, 0)
        XCTAssertEqual(summary.copiedJPEGCount, 0)
        XCTAssertEqual(summary.skippedCount, 2)
        XCTAssertEqual(progressEvents.count, 2)
        XCTAssertEqual(progressEvents.last?.completedCount, 2)
        XCTAssertEqual(progressEvents.last?.totalCount, 2)
        XCTAssertEqual(progressEvents.last?.skippedCount, 2)
    }

    func testScannerCanGroupPhotosFromGenericFolderSource() throws {
        let sourceRoot = tempRoot.appendingPathComponent("LibrarySource", isDirectory: true)
        let nested = sourceRoot.appendingPathComponent("Trips/Day1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let photoDate = makeDate(year: 2026, month: 3, day: 19)
        let jpegURL = nested.appendingPathComponent("IMG_1001.JPG")
        try Data("jpeg-data".utf8).write(to: jpegURL)
        try FileManager.default.setAttributes([.modificationDate: photoDate], ofItemAtPath: jpegURL.path)

        let ignoredURL = nested.appendingPathComponent("notes.txt")
        try Data("ignore".utf8).write(to: ignoredURL)

        let result = try PhotoScanner(config: .fallback).scan(sourcePath: sourceRoot.path)

        XCTAssertEqual(result.dateGroups.count, 1)
        XCTAssertEqual(result.dateGroups.first?.photoCount, 1)
        XCTAssertEqual(result.dateGroups.first?.jpegCount, 1)
        XCTAssertEqual(result.dateGroups.first?.rawCount, 0)
        XCTAssertEqual(result.filesByDate["2026-03-19"]?.count, 1)
        XCTAssertEqual(result.filesByDate["2026-03-19"]?.first?.filename, "IMG_1001.JPG")
    }

    func testScannerSkipsFilesAlreadyInsideOrganizedDateStructure() throws {
        let sourceRoot = tempRoot.appendingPathComponent("LibrarySource", isDirectory: true)
        let organizedFolder = sourceRoot.appendingPathComponent("Mom/2026/March/19/jpeg", isDirectory: true)
        let unsortedFolder = sourceRoot.appendingPathComponent("Dump", isDirectory: true)
        try FileManager.default.createDirectory(at: organizedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unsortedFolder, withIntermediateDirectories: true)

        let date = makeDate(year: 2026, month: 3, day: 19)
        let organizedJPEG = organizedFolder.appendingPathComponent("IMG_2000.JPG")
        let unsortedJPEG = unsortedFolder.appendingPathComponent("IMG_2001.JPG")
        try Data("organized".utf8).write(to: organizedJPEG)
        try Data("unsorted".utf8).write(to: unsortedJPEG)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: organizedJPEG.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: unsortedJPEG.path)

        let result = try PhotoScanner(config: .fallback).scan(sourcePath: sourceRoot.path)

        XCTAssertEqual(result.dateGroups.count, 1)
        XCTAssertEqual(result.dateGroups.first?.photoCount, 1)
        XCTAssertEqual(result.filesByDate["2026-03-19"]?.first?.filename, "IMG_2001.JPG")
        XCTAssertEqual(result.ignoredAlreadyOrganizedCount, 1)
    }

    @MainActor
    func testSwitchingToReorganizeModeClearsLoadedDates() {
        let viewModel = AppViewModel(config: .fallback, autoRefresh: false)
        viewModel.dateGroups = [
            DateGroup(
                dateKey: "2026-02-07",
                displayDate: "Saturday, February 07, 2026",
                photoCount: 2,
                rawCount: 1,
                jpegCount: 1,
                totalBytes: 17,
                folderName: "Birthday",
                previews: [],
                isExpanded: false,
                isSelected: true
            )
        ]
        viewModel.hasScannedCurrentCard = true

        viewModel.setWorkflowMode(.reorganizeFolder)

        XCTAssertEqual(viewModel.workflowMode, .reorganizeFolder)
        XCTAssertTrue(viewModel.dateGroups.isEmpty)
        XCTAssertFalse(viewModel.hasScannedCurrentCard)
    }

    private func makeSourceFile(named name: String, contents: String) throws -> URL {
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let url = sourceDir.appendingPathComponent(name)
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        components.second = 0
        components.calendar = Calendar(identifier: .gregorian)
        return components.date!
    }
}
