import XCTest
@testable import CameraAccess

final class OpenClawMediaRepositoryTests: XCTestCase {
    private var tempRoot: URL!
    private var repository: OpenClawMediaRepository!

    private func snapshot(
        media: OpenClawCaptureModeMedia = .photo,
        prompt: String = "protected prompt"
    ) -> OpenClawCaptureModeExecutionSnapshot {
        OpenClawCaptureModeExecutionSnapshot(
            id: UUID(),
            name: "Repository Test",
            prompt: prompt,
            media: media
        )
    }

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClawMediaRepositoryTests-\(UUID().uuidString)")
        repository = OpenClawMediaRepository(rootURL: tempRoot)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        repository = nil
        try await super.tearDown()
    }

    func testAddItemPersistsOriginalThumbnailAndModeSnapshot() async throws {
        let item = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01, 0x02, 0x03]),
            originalExtension: "jpg",
            thumbnailData: Data([0xAA, 0xBB]),
            modeSnapshot: snapshot(prompt: "exact retry prompt"),
            requestID: UUID()
        )

        XCTAssertEqual(
            try await repository.originalData(for: item),
            Data([0x01, 0x02, 0x03])
        )
        XCTAssertEqual(
            try await repository.thumbnailData(for: item),
            Data([0xAA, 0xBB])
        )
        XCTAssertEqual(item.localStatus, .ready)
        XCTAssertEqual(item.modeSnapshot.prompt, "exact retry prompt")
    }

    func testAddItemRejectsEmptyData() async {
        do {
            _ = try await repository.addItem(
                kind: .photo,
                originalData: Data(),
                originalExtension: "jpg",
                thumbnailData: nil,
                modeSnapshot: snapshot(),
                requestID: UUID()
            )
            XCTFail("Expected emptyData error")
        } catch let error as OpenClawMediaRepositoryError {
            XCTAssertEqual(error, .emptyData)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDuplicateRequestIDReturnsExistingItem() async throws {
        let requestID = UUID()
        let first = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(prompt: "first prompt"),
            requestID: requestID
        )
        let second = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x99]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(prompt: "must be ignored"),
            requestID: requestID
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.modeSnapshot.prompt, "first prompt")
        let listed = try await repository.listItems()
        let storedData = try await repository.originalData(for: second)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(storedData, Data([0x01]))
    }

    func testIndexAndStatusUpdatesPersistAcrossInstances() async throws {
        let requestID = UUID()
        let item = try await repository.addItem(
            kind: .video,
            originalData: Data([0x01, 0x02]),
            originalExtension: "mp4",
            thumbnailData: nil,
            durationSeconds: 4.2,
            modeSnapshot: snapshot(media: .video),
            requestID: requestID
        )
        _ = try await repository.updatePhotosStatus(id: item.id, status: .failed)
        _ = try await repository.updateAnalysisStatus(id: item.id, status: .pending)
        _ = try await repository.updateDeliveryStatus(
            id: item.id,
            status: .ambiguous,
            retryAttempt: 2
        )
        let userID = UUID()
        let assistantID = UUID()
        _ = try await repository.linkMessages(
            id: item.id,
            userMessageID: userID,
            assistantMessageID: assistantID
        )

        let secondRepository = OpenClawMediaRepository(rootURL: tempRoot)
        let restoredCandidate = try await secondRepository.item(
            withRequestID: requestID
        )
        let restored = try XCTUnwrap(restoredCandidate)
        XCTAssertEqual(restored.photosStatus, .failed)
        XCTAssertEqual(restored.analysisStatus, .pending)
        XCTAssertEqual(restored.deliveryStatus, .ambiguous)
        XCTAssertEqual(restored.retryAttempt, 2)
        XCTAssertEqual(restored.linkedUserMessageID, userID)
        XCTAssertEqual(restored.linkedAssistantMessageID, assistantID)
        XCTAssertEqual(restored.modeSnapshot.prompt, "protected prompt")
    }

    func testRootIndexAndOriginalUseFileProtection() async throws {
        let item = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        let resourceValues = try tempRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        let indexAttributes = try FileManager.default.attributesOfItem(
            atPath: tempRoot.appendingPathComponent("index.json").path
        )
        XCTAssertEqual(
            indexAttributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
        let originalURL = await repository.originalURL(for: item)
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: originalURL.path
        )
        XCTAssertEqual(
            originalAttributes[.protectionKey] as? FileProtectionType,
            .completeUntilFirstUserAuthentication
        )
    }

    func testDeleteItemRemovesAppAssetsOnly() async throws {
        let item = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: Data([0x02]),
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        _ = try await repository.updatePhotosStatus(id: item.id, status: .saved)

        try await repository.deleteItem(id: item.id)

        let remainingItems = try await repository.listItems()
        XCTAssertTrue(remainingItems.isEmpty)
        do {
            _ = try await repository.originalData(for: item)
            XCTFail("Expected deleted original read to fail")
        } catch {
            // The app-owned original was removed as requested.
        }
    }

    func testCleanupOrphansPreservesIndexedAndInflightFiles() async throws {
        let item = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        let originalsURL = tempRoot.appendingPathComponent("originals", isDirectory: true)
        let orphanURL = originalsURL.appendingPathComponent("orphan.jpg")
        let stagingURL = originalsURL.appendingPathComponent(".tmp-inflight")
        try Data([0x99]).write(to: orphanURL)
        try Data([0x88]).write(to: stagingURL)

        let removedCount = try await repository.cleanupOrphans()
        let storedData = try await repository.originalData(for: item)
        XCTAssertEqual(removedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(storedData, Data([0x01]))
    }

    func testCorruptedIndexIsPreservedAndBlocksOrphanCleanup() async throws {
        try await repository.prepare()
        let indexURL = tempRoot.appendingPathComponent("index.json")
        try Data("not valid json".utf8).write(to: indexURL)

        let freshRepository = OpenClawMediaRepository(rootURL: tempRoot)
        let recoveredItems = try await freshRepository.listItems()
        XCTAssertTrue(recoveredItems.isEmpty)

        let files = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        XCTAssertEqual(
            files.filter {
                $0.hasPrefix("index.corrupted.") && $0.hasSuffix(".json")
            }.count,
            1
        )

        do {
            _ = try await freshRepository.cleanupOrphans()
            XCTFail("Expected cleanup to be refused")
        } catch let error as OpenClawMediaRepositoryError {
            XCTAssertEqual(error, .indexCorrupted)
        }

        do {
            _ = try await freshRepository.addItem(
                kind: .photo,
                originalData: Data([0x02]),
                originalExtension: "jpg",
                thumbnailData: nil,
                modeSnapshot: snapshot(),
                requestID: UUID()
            )
            XCTFail("Expected writes to be refused")
        } catch let error as OpenClawMediaRepositoryError {
            XCTAssertEqual(error, .indexCorrupted)
        }

        let thirdRepository = OpenClawMediaRepository(rootURL: tempRoot)
        do {
            _ = try await thirdRepository.cleanupOrphans()
            XCTFail("Expected corruption marker to survive restart")
        } catch let error as OpenClawMediaRepositoryError {
            XCTAssertEqual(error, .indexCorrupted)
        }

        try await thirdRepository.acknowledgeIndexRecovery()
        let recovered = try await thirdRepository.addItem(
            kind: .photo,
            originalData: Data([0x03]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        XCTAssertEqual(recovered.localStatus, .ready)
    }

    func testCapacityRefusesToEvictIntactOriginals() async throws {
        let boundedRepository = OpenClawMediaRepository(
            rootURL: tempRoot,
            indexCapacity: 1
        )
        let first = try await boundedRepository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        do {
            _ = try await boundedRepository.addItem(
                kind: .photo,
                originalData: Data([0x02]),
                originalExtension: "jpg",
                thumbnailData: nil,
                modeSnapshot: snapshot(),
                requestID: UUID()
            )
            XCTFail("Expected capacityReached")
        } catch let error as OpenClawMediaRepositoryError {
            XCTAssertEqual(error, .capacityReached)
        }

        let listed = try await boundedRepository.listItems()
        let storedData = try await boundedRepository.originalData(for: first)
        XCTAssertEqual(listed.map(\.id), [first.id])
        XCTAssertEqual(storedData, Data([0x01]))
    }

    func testCapacityPrunesMissingRecordsBeforeAdding() async throws {
        let boundedRepository = OpenClawMediaRepository(
            rootURL: tempRoot,
            indexCapacity: 1
        )
        let stale = try await boundedRepository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: Data([0xAA]),
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        let staleURL = await boundedRepository.originalURL(for: stale)
        try FileManager.default.removeItem(at: staleURL)

        let replacement = try await boundedRepository.addItem(
            kind: .photo,
            originalData: Data([0x02]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        let listed = try await boundedRepository.listItems()
        XCTAssertEqual(listed.map(\.id), [replacement.id])
        let staleThumbnailURL = await boundedRepository.thumbnailURL(for: stale)
        XCTAssertFalse(
            staleThumbnailURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        )
    }

    func testListItemsSortsMostRecentFirst() async throws {
        let first = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x01]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = try await repository.addItem(
            kind: .photo,
            originalData: Data([0x02]),
            originalExtension: "jpg",
            thumbnailData: nil,
            modeSnapshot: snapshot(),
            requestID: UUID()
        )

        let listed = try await repository.listItems()
        XCTAssertEqual(listed.first?.id, second.id)
        XCTAssertEqual(listed.last?.id, first.id)
    }
}
