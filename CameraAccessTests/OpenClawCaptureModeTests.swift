/*
 * OpenClaw Capture Mode Tests
 * 拍摄模式子系统单元测试：模型校验、受保护存储、管理器行为
 */

import Foundation
import XCTest

@testable import CameraAccess

@MainActor
final class OpenClawCaptureModeTests: XCTestCase {

    // MARK: - Fixtures

    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var storage: OpenClawCaptureModeStorage!
    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "OpenClawCaptureModeTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClawCaptureModeTests-\(UUID().uuidString)", isDirectory: true)
        // Injectable directory keeps every test isolated from the app's
        // real Application Support folder and from other tests.
        storage = OpenClawCaptureModeStorage(directoryOverride: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        storage = nil
        scratchDirectory = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeManager() -> OpenClawCaptureModeManager {
        OpenClawCaptureModeManager(storage: storage, userDefaults: userDefaults)
    }

    // MARK: - Seeding

    func testSeedsBuiltInModesOnFirstLaunch() {
        let manager = makeManager()

        XCTAssertEqual(manager.modes.count, 4)
        XCTAssertTrue(manager.modes.allSatisfy { $0.isBuiltIn })

        let ids = Set(manager.modes.map(\.id))
        XCTAssertEqual(
            ids,
            [
                OpenClawCaptureModeSeed.ID.general,
                OpenClawCaptureModeSeed.ID.coding,
                OpenClawCaptureModeSeed.ID.chess,
                OpenClawCaptureModeSeed.ID.squat
            ]
        )
    }

    func testSeededCatalogIsPersistedToStorage() {
        _ = makeManager()

        let loaded = storage.loadModes()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 4)
    }

    func testChessIsPhotoOnlyAndSquatIsVideoOnly() {
        let manager = makeManager()

        let chess = manager.mode(for: OpenClawCaptureModeSeed.ID.chess)
        let squat = manager.mode(for: OpenClawCaptureModeSeed.ID.squat)

        XCTAssertEqual(chess?.supportedMedia, .photo)
        XCTAssertEqual(squat?.supportedMedia, .video)

        XCTAssertTrue(manager.photoModes.contains { $0.id == OpenClawCaptureModeSeed.ID.chess })
        XCTAssertFalse(manager.videoModes.contains { $0.id == OpenClawCaptureModeSeed.ID.chess })

        XCTAssertTrue(manager.videoModes.contains { $0.id == OpenClawCaptureModeSeed.ID.squat })
        XCTAssertFalse(manager.photoModes.contains { $0.id == OpenClawCaptureModeSeed.ID.squat })
    }

    // MARK: - Safe Fallback (decode failure)

    func testFallsBackToSeedCatalogWhenStoredFileIsCorrupt() throws {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let fileURL = scratchDirectory.appendingPathComponent("openclaw_capture_modes.json")
        try Data("not valid json".utf8).write(to: fileURL)

        let manager = makeManager()

        // Should not crash and should fall back to the safe seeded catalog.
        XCTAssertEqual(manager.modes.count, 4)
        XCTAssertTrue(manager.modes.allSatisfy { $0.isBuiltIn })
    }

    // MARK: - Create

    func testCreateModeAppendsMode() throws {
        let manager = makeManager()

        let created = try manager.createMode(
            name: "Wine Label",
            summary: "Read a wine label",
            prompt: "Read the wine label in view and summarize the vintage, region, and grape.",
            symbol: "wineglass",
            supportedMedia: .photo
        )

        XCTAssertFalse(created.isBuiltIn)
        XCTAssertEqual(manager.modes.count, 5)
        XCTAssertNotNil(manager.mode(for: created.id))
    }

    func testCreateModeRejectsEmptyName() {
        let manager = makeManager()

        XCTAssertThrowsError(
            try manager.createMode(name: "   ", summary: "", prompt: "prompt", symbol: "eye", supportedMedia: .both)
        ) { error in
            XCTAssertEqual(error as? OpenClawCaptureModeError, .nameRequired)
        }
    }

    func testCreateModeRejectsEmptyPrompt() {
        let manager = makeManager()

        XCTAssertThrowsError(
            try manager.createMode(name: "Name", summary: "", prompt: "   ", symbol: "eye", supportedMedia: .both)
        ) { error in
            XCTAssertEqual(error as? OpenClawCaptureModeError, .promptRequired)
        }
    }

    func testCreateModeRejectsEmptyMediaSelection() {
        let manager = makeManager()

        XCTAssertThrowsError(
            try manager.createMode(name: "Name", summary: "", prompt: "p", symbol: "eye", supportedMedia: [])
        ) { error in
            XCTAssertEqual(error as? OpenClawCaptureModeError, .mediaRequired)
        }
    }

    func testCreateModeRejectsDuplicateNameCaseInsensitive() throws {
        let manager = makeManager()

        _ = try manager.createMode(name: "My Mode", summary: "", prompt: "p", symbol: "eye", supportedMedia: .both)

        XCTAssertThrowsError(
            try manager.createMode(name: "my mode", summary: "", prompt: "p2", symbol: "eye", supportedMedia: .both)
        ) { error in
            XCTAssertEqual(error as? OpenClawCaptureModeError, .duplicateName)
        }
    }

    func testCreateModeRejectsNameCollisionWithBuiltIn() {
        let manager = makeManager()

        XCTAssertThrowsError(
            try manager.createMode(name: manager.modes[0].name, summary: "", prompt: "p", symbol: "eye", supportedMedia: .both)
        ) { error in
            XCTAssertEqual(error as? OpenClawCaptureModeError, .duplicateName)
        }
    }

    // MARK: - Edit (built-in modes are editable — provenance only)

    func testUpdateModeEditsCustomMode() throws {
        let manager = makeManager()
        let created = try manager.createMode(name: "Draft", summary: "s", prompt: "p", symbol: "eye", supportedMedia: .photo)

        try manager.updateMode(
            id: created.id,
            name: "Final",
            summary: "s2",
            prompt: "p2",
            symbol: "star",
            supportedMedia: .both
        )

        let updated = manager.mode(for: created.id)
        XCTAssertEqual(updated?.name, "Final")
        XCTAssertEqual(updated?.supportedMedia, .both)
    }

    func testUpdateModeAllowsEditingBuiltInMode() throws {
        let manager = makeManager()
        let builtIn = manager.mode(for: OpenClawCaptureModeSeed.ID.general)!

        try manager.updateMode(
            id: builtIn.id,
            name: "General (Edited)",
            summary: builtIn.summary,
            prompt: "A customized general-purpose prompt.",
            symbol: builtIn.symbol,
            supportedMedia: builtIn.supportedMedia
        )

        let updated = manager.mode(for: builtIn.id)
        XCTAssertEqual(updated?.name, "General (Edited)")
        // isBuiltIn is provenance only and does not change on edit.
        XCTAssertEqual(updated?.isBuiltIn, true)
    }

    // MARK: - Duplicate

    func testDuplicateModeCreatesCopyWithProvenanceFalse() throws {
        let manager = makeManager()
        let builtIn = manager.mode(for: OpenClawCaptureModeSeed.ID.coding)!

        let duplicate = try manager.duplicateMode(id: builtIn.id)

        XCTAssertFalse(duplicate.isBuiltIn)
        XCTAssertEqual(duplicate.prompt, builtIn.prompt)
        XCTAssertNotEqual(duplicate.name, builtIn.name)
        XCTAssertEqual(manager.modes.count, 5)
    }

    func testDuplicateGeneratesUniqueNameOnRepeatedDuplication() throws {
        let manager = makeManager()
        let builtIn = manager.mode(for: OpenClawCaptureModeSeed.ID.general)!

        let first = try manager.duplicateMode(id: builtIn.id)
        let second = try manager.duplicateMode(id: builtIn.id)

        XCTAssertNotEqual(first.name, second.name)
    }

    // MARK: - Delete (built-in modes are deletable — provenance only)

    func testDeleteCustomModeRemovesIt() throws {
        let manager = makeManager()
        let created = try manager.createMode(name: "Temp", summary: "", prompt: "p", symbol: "eye", supportedMedia: .both)

        try manager.deleteMode(id: created.id)

        XCTAssertNil(manager.mode(for: created.id))
        XCTAssertEqual(manager.modes.count, 4)
    }

    func testDeleteBuiltInModeSucceeds() throws {
        let manager = makeManager()
        let builtIn = manager.mode(for: OpenClawCaptureModeSeed.ID.chess)!

        try manager.deleteMode(id: builtIn.id)

        XCTAssertNil(manager.mode(for: builtIn.id))
        XCTAssertEqual(manager.modes.count, 3)
    }

    func testDeletingTheFinalModeRegeneratesGeneralFallbackInstead() throws {
        let manager = makeManager()

        // Delete every mode, including the very last one — deletion must
        // never be refused. After each delete, ensureFallbackIfNeeded()
        // should keep photo/video coverage alive, and after everything is
        // gone the catalog should never actually reach zero modes.
        let allIds = manager.modes.map(\.id)
        for id in allIds {
            try manager.deleteMode(id: id)
        }

        XCTAssertFalse(manager.modes.isEmpty, "Catalog must never be left empty")
        XCTAssertEqual(manager.modes.count, 1)

        let remaining = manager.modes[0]
        XCTAssertEqual(remaining.id, OpenClawCaptureModeSeed.ID.general)
        XCTAssertEqual(remaining.supportedMedia, .both)

        // Deleting that final regenerated mode must also succeed (not
        // throw) and immediately regenerate it again.
        try manager.deleteMode(id: remaining.id)
        XCTAssertEqual(manager.modes.count, 1)
        XCTAssertEqual(manager.modes[0].id, OpenClawCaptureModeSeed.ID.general)
    }

    // MARK: - Fallback Regeneration

    func testDeletingAllPhotoModesRegeneratesGeneralFallback() throws {
        let manager = makeManager()

        // Remove every mode that supports photo (General, Coding, Chess).
        let photoModeIds = manager.modes.filter { $0.supportedMedia.supportsPhoto }.map(\.id)
        for id in photoModeIds {
            try manager.deleteMode(id: id)
        }

        // Squat Form (video-only) should remain, plus a regenerated
        // General fallback covering both media again.
        XCTAssertTrue(manager.modes.contains { $0.supportedMedia.supportsPhoto })
        XCTAssertNotNil(manager.mode(for: OpenClawCaptureModeSeed.ID.squat))

        let regeneratedGeneral = manager.modes.first { $0.id == OpenClawCaptureModeSeed.ID.general }
        XCTAssertNotNil(regeneratedGeneral)
        XCTAssertEqual(regeneratedGeneral?.supportedMedia, .both)
    }

    func testDeletingAllVideoModesRegeneratesGeneralFallback() throws {
        let manager = makeManager()

        let videoModeIds = manager.modes.filter { $0.supportedMedia.supportsVideo }.map(\.id)
        for id in videoModeIds {
            try manager.deleteMode(id: id)
        }

        XCTAssertTrue(manager.modes.contains { $0.supportedMedia.supportsVideo })
        let regeneratedGeneral = manager.modes.first { $0.id == OpenClawCaptureModeSeed.ID.general }
        XCTAssertNotNil(regeneratedGeneral)
    }

    func testFallbackRegenerationDoesNotReseedOtherBuiltIns() throws {
        let manager = makeManager()

        let photoModeIds = manager.modes.filter { $0.supportedMedia.supportsPhoto }.map(\.id)
        for id in photoModeIds {
            try manager.deleteMode(id: id)
        }

        // Coding and Chess were intentionally removed and must not reappear.
        XCTAssertNil(manager.mode(for: OpenClawCaptureModeSeed.ID.coding))
        XCTAssertNil(manager.mode(for: OpenClawCaptureModeSeed.ID.chess))
    }

    // MARK: - Reorder

    func testReorderModesUpdatesSortOrder() {
        let manager = makeManager()
        let originalIds = manager.modes.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        let reversedIds = Array(originalIds.reversed())

        manager.reorderModes(orderedIds: reversedIds)

        let newOrder = manager.modes.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
        XCTAssertEqual(newOrder, reversedIds)
    }

    // MARK: - Defaults & Last Used

    func testSetPhotoDefaultOnlyAcceptsPhotoCapableMode() {
        let manager = makeManager()
        let squat = manager.mode(for: OpenClawCaptureModeSeed.ID.squat)! // video-only

        let before = manager.photoDefaultModeId
        manager.setPhotoDefault(squat.id)

        // Video-only mode must be rejected for the photo default.
        XCTAssertEqual(manager.photoDefaultModeId, before)
    }

    func testSetVideoDefaultOnlyAcceptsVideoCapableMode() {
        let manager = makeManager()
        let chess = manager.mode(for: OpenClawCaptureModeSeed.ID.chess)! // photo-only

        let before = manager.videoDefaultModeId
        manager.setVideoDefault(chess.id)

        XCTAssertEqual(manager.videoDefaultModeId, before)
    }

    func testRecordLastPhotoModeUpdatesEffectivePhotoMode() {
        let manager = makeManager()
        let coding = manager.mode(for: OpenClawCaptureModeSeed.ID.coding)!

        manager.recordLastPhotoMode(coding.id)

        XCTAssertEqual(manager.effectivePhotoModeId(), coding.id)
    }

    func testEffectiveModeFallsBackWhenLastUsedDeleted() throws {
        let manager = makeManager()
        let custom = try manager.createMode(name: "Custom Photo", summary: "", prompt: "p", symbol: "eye", supportedMedia: .photo)
        manager.recordLastPhotoMode(custom.id)
        XCTAssertEqual(manager.effectivePhotoModeId(), custom.id)

        try manager.deleteMode(id: custom.id)

        // After deletion, effective mode should fall back safely rather
        // than pointing at a dangling id.
        let fallback = manager.effectivePhotoModeId()
        XCTAssertNotNil(fallback)
        XCTAssertNotEqual(fallback, custom.id)
    }

    // MARK: - Selection persistence excludes prompt text and names

    func testSelectionPersistenceOnlyStoresIdsNotPromptTextOrNames() {
        let manager = makeManager()
        let coding = manager.mode(for: OpenClawCaptureModeSeed.ID.coding)!
        manager.recordLastPhotoMode(coding.id)

        let domain = userDefaults.dictionaryRepresentation()
        for (_, value) in domain {
            if let stringValue = value as? String {
                XCTAssertFalse(
                    stringValue.contains(coding.prompt),
                    "UserDefaults must never contain capture mode prompt text"
                )
                XCTAssertFalse(
                    stringValue == coding.name,
                    "UserDefaults must never contain capture mode names"
                )
            }
        }
    }

    func testNewManagerInstanceReloadsPersistedCatalogAndSelections() throws {
        let first = makeManager()
        let created = try first.createMode(name: "Persisted", summary: "s", prompt: "p", symbol: "eye", supportedMedia: .photo)
        first.setPhotoDefault(created.id)

        let second = OpenClawCaptureModeManager(storage: storage, userDefaults: userDefaults)

        XCTAssertNotNil(second.mode(for: created.id))
        XCTAssertEqual(second.photoDefaultModeId, created.id)
    }

    // MARK: - Snapshot (catalog browsing)

    func testSnapshotIsSelfConsistent() {
        let manager = makeManager()
        let snapshot = manager.makeSnapshot()

        XCTAssertEqual(snapshot.modes.count, manager.modes.count)
        XCTAssertEqual(snapshot.photoDefaultModeId, manager.photoDefaultModeId)
        XCTAssertEqual(snapshot.videoDefaultModeId, manager.videoDefaultModeId)
        XCTAssertNotNil(snapshot.mode(for: snapshot.photoDefaultModeId))
    }

    // MARK: - Execution Snapshot (immutable, single mode)

    func testExecutionSnapshotCapturesFieldsAtCreationTime() throws {
        let manager = makeManager()
        let mode = try manager.createMode(
            name: "Freeze Me",
            summary: "s",
            prompt: "original prompt",
            symbol: "eye",
            supportedMedia: .photo
        )

        guard let snapshot = manager.makeExecutionSnapshot(for: mode.id) else {
            XCTFail("Expected an execution snapshot")
            return
        }

        XCTAssertEqual(snapshot.id, mode.id)
        XCTAssertEqual(snapshot.name, "Freeze Me")
        XCTAssertEqual(snapshot.prompt, "original prompt")
        XCTAssertEqual(snapshot.media, .photo)

        // Mutating the catalog afterward must not affect the snapshot
        // already taken — it is a frozen value type, not a live reference.
        try manager.updateMode(
            id: mode.id,
            name: "Changed Name",
            summary: "s",
            prompt: "changed prompt",
            symbol: "eye",
            supportedMedia: .both
        )

        XCTAssertEqual(snapshot.name, "Freeze Me")
        XCTAssertEqual(snapshot.prompt, "original prompt")
        XCTAssertEqual(snapshot.media, .photo)
    }

    func testExecutionSnapshotSurvivesModeDeletion() throws {
        let manager = makeManager()
        let mode = try manager.createMode(name: "Temp Mode", summary: "", prompt: "p", symbol: "eye", supportedMedia: .video)
        guard let snapshot = manager.makeExecutionSnapshot(for: mode.id) else {
            XCTFail("Expected an execution snapshot")
            return
        }

        try manager.deleteMode(id: mode.id)

        // The snapshot is a value type independent of the catalog, so it
        // remains valid even after the source mode is deleted.
        XCTAssertEqual(snapshot.prompt, "p")
        XCTAssertNil(manager.mode(for: mode.id))
    }

    func testExecutionSnapshotReturnsNilForUnknownId() {
        let manager = makeManager()
        XCTAssertNil(manager.makeExecutionSnapshot(for: UUID()))
    }

    // MARK: - Model Validation

    func testValidationCatchesOverlongName() {
        let longName = String(repeating: "a", count: OpenClawCaptureModeValidation.nameLimit + 1)
        let error = OpenClawCaptureModeValidation.validateFields(
            name: longName, summary: "", prompt: "p", symbol: "eye", media: .both
        )
        XCTAssertEqual(error, .nameTooLong(limit: OpenClawCaptureModeValidation.nameLimit))
    }

    func testValidationCatchesOverlongPrompt() {
        let longPrompt = String(repeating: "a", count: OpenClawCaptureModeValidation.promptLimit + 1)
        let error = OpenClawCaptureModeValidation.validateFields(
            name: "ok", summary: "", prompt: longPrompt, symbol: "eye", media: .both
        )
        XCTAssertEqual(error, .promptTooLong(limit: OpenClawCaptureModeValidation.promptLimit))
    }

    func testValidationCatchesEmptyMedia() {
        let error = OpenClawCaptureModeValidation.validateFields(
            name: "ok", summary: "", prompt: "p", symbol: "eye", media: []
        )
        XCTAssertEqual(error, .mediaRequired)
    }

    func testValidationPassesForWellFormedFields() {
        let error = OpenClawCaptureModeValidation.validateFields(
            name: "Valid Mode", summary: "short summary", prompt: "A valid prompt.", symbol: "eye.circle", media: .photo
        )
        XCTAssertNil(error)
    }

    // MARK: - OptionSet Media

    func testMediaOptionSetCombinations() {
        let photoOnly: OpenClawCaptureModeMedia = .photo
        let videoOnly: OpenClawCaptureModeMedia = .video
        let both: OpenClawCaptureModeMedia = [.photo, .video]

        XCTAssertTrue(photoOnly.supportsPhoto)
        XCTAssertFalse(photoOnly.supportsVideo)

        XCTAssertFalse(videoOnly.supportsPhoto)
        XCTAssertTrue(videoOnly.supportsVideo)

        XCTAssertTrue(both.supportsPhoto)
        XCTAssertTrue(both.supportsVideo)
        XCTAssertEqual(both, OpenClawCaptureModeMedia.both)
    }

    // MARK: - Storage

    func testStorageSaveAndLoadRoundTrips() {
        let modes = OpenClawCaptureModeSeed.makeAll()
        XCTAssertTrue(storage.saveModes(modes))

        let loaded = storage.loadModes()
        XCTAssertEqual(loaded?.count, modes.count)
        XCTAssertEqual(loaded?.map(\.id).sorted { $0.uuidString < $1.uuidString },
                        modes.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    func testStorageLoadReturnsNilWhenNoFileExists() {
        XCTAssertNil(storage.loadModes())
    }

    func testStorageFileIsWrittenUnderInjectedDirectoryNotUserDefaults() {
        let modes = OpenClawCaptureModeSeed.makeAll()
        storage.saveModes(modes)

        let fileURL = scratchDirectory.appendingPathComponent("openclaw_capture_modes.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Prompt text must not appear in standard UserDefaults.
        let standardDump = UserDefaults.standard.dictionaryRepresentation()
        for (_, value) in standardDump {
            if let stringValue = value as? String {
                for mode in modes {
                    XCTAssertFalse(stringValue.contains(mode.prompt))
                }
            }
        }
    }

    func testStorageFileHasCompleteUntilFirstAuthProtection() throws {
        let modes = OpenClawCaptureModeSeed.makeAll()
        storage.saveModes(modes)

        let fileURL = scratchDirectory.appendingPathComponent("openclaw_capture_modes.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let protection = attributes[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
    }
}
