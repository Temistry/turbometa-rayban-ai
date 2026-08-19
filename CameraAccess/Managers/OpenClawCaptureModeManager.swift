/*
 * OpenClaw Capture Mode Manager
 * 拍摄模式管理器 - 管理模式目录、默认/最近选择
 *
 * Owns the in-memory capture-mode catalog, backed by
 * OpenClawCaptureModeStorage (protected JSON file). Only mode ids for
 * default/last-used selections are kept in UserDefaults — prompt text and
 * mode names are never written there and are never logged, per OpenClaw
 * privacy rules (mirrors the token/keychain handling in
 * OpenClawNodeService, but for disk storage instead of Keychain since this
 * is not a secret, just sensitive user content).
 *
 * `isBuiltIn` on a mode is provenance only: built-in modes can be edited or
 * deleted exactly like custom ones, including deleting the very last mode
 * in the catalog — deletion is never refused. What IS guaranteed is that
 * the catalog never stays empty, or without any mode for a given media
 * type: `ensureFallbackIfNeeded()` runs after every delete and regenerates
 * just the General (both-media) mode in that case, without reseeding
 * Coding/Chess/Squat (a user who removed those intentionally should not
 * see them come back).
 */

import Foundation
import SwiftUI

@MainActor
final class OpenClawCaptureModeManager: ObservableObject {
    static let shared = OpenClawCaptureModeManager()

    // MARK: - Published State

    @Published private(set) var modes: [OpenClawCaptureMode] = []
    @Published private(set) var photoDefaultModeId: UUID
    @Published private(set) var videoDefaultModeId: UUID
    @Published private(set) var lastPhotoModeId: UUID
    @Published private(set) var lastVideoModeId: UUID

    // MARK: - Private

    private let storage: OpenClawCaptureModeStorage
    private let userDefaults: UserDefaults

    private let photoDefaultKey = "openclaw_capturemode_photo_default"
    private let videoDefaultKey = "openclaw_capturemode_video_default"
    private let lastPhotoKey = "openclaw_capturemode_last_photo"
    private let lastVideoKey = "openclaw_capturemode_last_video"

    // MARK: - Init

    init(
        storage: OpenClawCaptureModeStorage = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.storage = storage
        self.userDefaults = userDefaults

        let loaded = storage.loadModes()
        let safeModes = OpenClawCaptureModeManager.safeCatalog(from: loaded)
        self.modes = safeModes

        let fallbackId = safeModes.first?.id ?? OpenClawCaptureModeSeed.ID.general

        let storedPhotoDefault = userDefaults.string(forKey: photoDefaultKey).flatMap(UUID.init)
        let storedVideoDefault = userDefaults.string(forKey: videoDefaultKey).flatMap(UUID.init)
        let storedLastPhoto = userDefaults.string(forKey: lastPhotoKey).flatMap(UUID.init)
        let storedLastVideo = userDefaults.string(forKey: lastVideoKey).flatMap(UUID.init)

        let photoModeIds = Set(safeModes.filter { $0.supportedMedia.supportsPhoto }.map(\.id))
        let videoModeIds = Set(safeModes.filter { $0.supportedMedia.supportsVideo }.map(\.id))

        let photoFallback = safeModes.first { $0.supportedMedia.supportsPhoto }?.id ?? fallbackId
        let videoFallback = safeModes.first { $0.supportedMedia.supportsVideo }?.id ?? fallbackId

        self.photoDefaultModeId = storedPhotoDefault.flatMap { photoModeIds.contains($0) ? $0 : nil } ?? photoFallback
        self.videoDefaultModeId = storedVideoDefault.flatMap { videoModeIds.contains($0) ? $0 : nil } ?? videoFallback
        self.lastPhotoModeId = storedLastPhoto.flatMap { photoModeIds.contains($0) ? $0 : nil } ?? self.photoDefaultModeId
        self.lastVideoModeId = storedLastVideo.flatMap { videoModeIds.contains($0) ? $0 : nil } ?? self.videoDefaultModeId

        // Persist the seeded catalog on very first launch so the file exists
        // going forward, and repair the file if it failed to decode.
        if loaded == nil {
            storage.saveModes(safeModes)
        }

        persistSelections()
    }

    /// Produces the seeded built-in catalog if `loaded` is nil/empty, else
    /// returns `loaded` as-is. This is the "safe fallback" the rest of the
    /// app can rely on: the catalog is never empty at init time. (Runtime
    /// deletions are separately guarded by `ensureFallbackIfNeeded()`.)
    private static func safeCatalog(from loaded: [OpenClawCaptureMode]?) -> [OpenClawCaptureMode] {
        guard let loaded, !loaded.isEmpty else {
            return OpenClawCaptureModeSeed.makeAll()
        }
        return loaded.sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Snapshot

    /// Produces an immutable, self-consistent view of the catalog and
    /// current selections for browsing UI (pickers, settings) to consume in
    /// a single render pass. NOT for holding onto during an in-progress
    /// capture — use `makeExecutionSnapshot(for:)` for that.
    func makeSnapshot() -> OpenClawCaptureModeSnapshot {
        OpenClawCaptureModeSnapshot(
            modes: modes.sorted { $0.sortOrder < $1.sortOrder },
            photoDefaultModeId: photoDefaultModeId,
            videoDefaultModeId: videoDefaultModeId,
            lastPhotoModeId: lastPhotoModeId,
            lastVideoModeId: lastVideoModeId
        )
    }

    /// Freezes a single mode's capture-relevant fields at the moment
    /// capture starts. The catalog can keep changing after this point (the
    /// user could edit or delete the mode from Settings mid-capture); the
    /// caller should hold onto this value, not a live id lookup, so an
    /// in-flight capture always finishes with the prompt it started with.
    func makeExecutionSnapshot(for id: UUID) -> OpenClawCaptureModeExecutionSnapshot? {
        guard let mode = mode(for: id) else { return nil }
        return OpenClawCaptureModeExecutionSnapshot(mode: mode)
    }

    // MARK: - Lookup

    func mode(for id: UUID) -> OpenClawCaptureMode? {
        modes.first { $0.id == id }
    }

    var photoModes: [OpenClawCaptureMode] {
        modes.filter { $0.supportedMedia.supportsPhoto }.sorted { $0.sortOrder < $1.sortOrder }
    }

    var videoModes: [OpenClawCaptureMode] {
        modes.filter { $0.supportedMedia.supportsVideo }.sorted { $0.sortOrder < $1.sortOrder }
    }

    // MARK: - Create / Edit / Duplicate / Delete

    /// Creates a new mode from validated fields, appended to the end of the
    /// sort order. Returns the created mode on success.
    @discardableResult
    func createMode(
        name: String,
        summary: String,
        prompt: String,
        symbol: String,
        supportedMedia: OpenClawCaptureModeMedia
    ) throws -> OpenClawCaptureMode {
        try validate(name: name, summary: summary, prompt: prompt, symbol: symbol, media: supportedMedia, excluding: nil)

        let nextSortOrder = (modes.map(\.sortOrder).max() ?? -1) + 1
        let newMode = OpenClawCaptureMode(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines),
            supportedMedia: supportedMedia,
            isBuiltIn: false,
            sortOrder: nextSortOrder
        )

        modes.append(newMode)
        persistCatalog()
        return newMode
    }

    /// Edits an existing mode in place, built-in or custom — `isBuiltIn` is
    /// provenance only and does not block edits.
    func updateMode(
        id: UUID,
        name: String,
        summary: String,
        prompt: String,
        symbol: String,
        supportedMedia: OpenClawCaptureModeMedia
    ) throws {
        guard let index = modes.firstIndex(where: { $0.id == id }) else {
            throw OpenClawCaptureModeError.modeNotFound
        }

        try validate(name: name, summary: summary, prompt: prompt, symbol: symbol, media: supportedMedia, excluding: id)

        modes[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        modes[index].summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        modes[index].prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        modes[index].symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        modes[index].supportedMedia = supportedMedia

        persistCatalog()
        repairSelectionsIfNeeded()
    }

    /// Duplicates any mode into a new mode (provenance `isBuiltIn = false`
    /// regardless of the source), placed immediately after the source in
    /// sort order. Useful as a quick "start from an existing prompt"
    /// shortcut; not required for editing built-ins anymore since those are
    /// directly editable, but still convenient for branching a variant
    /// while keeping the original.
    @discardableResult
    func duplicateMode(id: UUID) throws -> OpenClawCaptureMode {
        guard let source = mode(for: id) else {
            throw OpenClawCaptureModeError.modeNotFound
        }

        let baseName = "\(source.name) \("openclaw.capturemode.duplicate.suffix".localized)"
        let uniqueName = uniqueName(basedOn: baseName)

        let nextSortOrder = source.sortOrder + 1
        // Shift everything at/after the insertion point down to make room.
        for i in modes.indices where modes[i].sortOrder >= nextSortOrder {
            modes[i].sortOrder += 1
        }

        let duplicate = OpenClawCaptureMode(
            name: uniqueName,
            summary: source.summary,
            prompt: source.prompt,
            symbol: source.symbol,
            supportedMedia: source.supportedMedia,
            isBuiltIn: false,
            sortOrder: nextSortOrder
        )

        modes.append(duplicate)
        persistCatalog()
        return duplicate
    }

    /// Deletes any mode, built-in or custom — including the very last
    /// remaining mode. Deletion is never blocked; instead
    /// `ensureFallbackIfNeeded()` runs after every delete and regenerates
    /// just the General (both-media) mode whenever the catalog would
    /// otherwise end up empty, or without any mode supporting photo, or
    /// without any mode supporting video. That keeps both capture flows
    /// always backed by at least one usable mode without ever refusing a
    /// user's delete action.
    func deleteMode(id: UUID) throws {
        guard mode(for: id) != nil else {
            throw OpenClawCaptureModeError.modeNotFound
        }

        modes.removeAll { $0.id == id }
        ensureFallbackIfNeeded()
        persistCatalog()
        repairSelectionsIfNeeded()
    }

    // MARK: - Fallback Regeneration

    /// If the catalog is empty, or has no mode supporting photo, or no mode
    /// supporting video, regenerates the General (both-media) mode so both
    /// capture flows always have at least one usable mode. Does not
    /// reseed the other built-ins — this is a minimal safety net, not a
    /// "reset to defaults" action.
    private func ensureFallbackIfNeeded() {
        let hasPhoto = modes.contains { $0.supportedMedia.supportsPhoto }
        let hasVideo = modes.contains { $0.supportedMedia.supportsVideo }

        guard modes.isEmpty || !hasPhoto || !hasVideo else { return }

        let nextSortOrder = (modes.map(\.sortOrder).min() ?? 0) - 1
        let fallback = OpenClawCaptureModeSeed.makeGeneralFallback(sortOrder: nextSortOrder)

        // Avoid a duplicate if a mode with the General id somehow survived
        // (shouldn't happen given the guards above, but keep this safe).
        modes.removeAll { $0.id == fallback.id }
        modes.append(fallback)

        print("[OpenClawCaptureModeManager] 일반 대체 모드를 다시 생성했습니다")
    }

    // MARK: - Reorder

    /// Reorders the full catalog to match `orderedIds`. Ids not present in
    /// `orderedIds` keep their relative order and are appended at the end,
    /// so a partial/stale list never silently drops modes.
    func reorderModes(orderedIds: [UUID]) {
        var order = [UUID: Int]()
        for (index, id) in orderedIds.enumerated() {
            order[id] = index
        }

        let knownCount = orderedIds.count
        var trailingIndex = knownCount

        let sorted = modes.sorted { lhs, rhs in
            let lhsRank = order[lhs.id] ?? Int.max
            let rhsRank = order[rhs.id] ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.sortOrder < rhs.sortOrder
        }

        for i in sorted.indices {
            let id = sorted[i].id
            if let rank = order[id] {
                if let modeIndex = modes.firstIndex(where: { $0.id == id }) {
                    modes[modeIndex].sortOrder = rank
                }
            } else if let modeIndex = modes.firstIndex(where: { $0.id == id }) {
                modes[modeIndex].sortOrder = trailingIndex
                trailingIndex += 1
            }
        }

        persistCatalog()
    }

    // MARK: - Selections

    func setPhotoDefault(_ id: UUID) {
        guard let mode = mode(for: id), mode.supportedMedia.supportsPhoto else { return }
        photoDefaultModeId = id
        persistSelections()
    }

    func setVideoDefault(_ id: UUID) {
        guard let mode = mode(for: id), mode.supportedMedia.supportsVideo else { return }
        videoDefaultModeId = id
        persistSelections()
    }

    func recordLastPhotoMode(_ id: UUID) {
        guard let mode = mode(for: id), mode.supportedMedia.supportsPhoto else { return }
        lastPhotoModeId = id
        persistSelections()
    }

    func recordLastVideoMode(_ id: UUID) {
        guard let mode = mode(for: id), mode.supportedMedia.supportsVideo else { return }
        lastVideoModeId = id
        persistSelections()
    }

    /// Effective mode to preselect when starting a photo capture: falls
    /// back through last-used -> default -> first available -> nil.
    func effectivePhotoModeId() -> UUID? {
        if let last = mode(for: lastPhotoModeId), last.supportedMedia.supportsPhoto {
            return last.id
        }
        if let def = mode(for: photoDefaultModeId), def.supportedMedia.supportsPhoto {
            return def.id
        }
        return photoModes.first?.id
    }

    /// Effective mode to preselect when starting a video capture: falls
    /// back through last-used -> default -> first available -> nil.
    func effectiveVideoModeId() -> UUID? {
        if let last = mode(for: lastVideoModeId), last.supportedMedia.supportsVideo {
            return last.id
        }
        if let def = mode(for: videoDefaultModeId), def.supportedMedia.supportsVideo {
            return def.id
        }
        return videoModes.first?.id
    }

    // MARK: - Validation Helpers

    private func validate(
        name: String,
        summary: String,
        prompt: String,
        symbol: String,
        media: OpenClawCaptureModeMedia,
        excluding excludedId: UUID?
    ) throws {
        if let fieldError = OpenClawCaptureModeValidation.validateFields(
            name: name, summary: summary, prompt: prompt, symbol: symbol, media: media
        ) {
            throw fieldError
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = modes.contains { mode in
            mode.id != excludedId && mode.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
        if isDuplicate {
            throw OpenClawCaptureModeError.duplicateName
        }
    }

    private func uniqueName(basedOn base: String) -> String {
        var candidate = base
        var suffix = 2
        let existingNames = Set(modes.map { $0.name.lowercased() })
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// After a delete/edit, make sure default/last-used selections still
    /// point at modes that exist and support the right media — otherwise
    /// re-derive them so the UI never ends up pointing at a dangling id.
    private func repairSelectionsIfNeeded() {
        let photoModeIds = Set(photoModes.map(\.id))
        let videoModeIds = Set(videoModes.map(\.id))

        if !photoModeIds.contains(photoDefaultModeId) {
            photoDefaultModeId = photoModes.first?.id ?? modes.first?.id ?? OpenClawCaptureModeSeed.ID.general
        }
        if !videoModeIds.contains(videoDefaultModeId) {
            videoDefaultModeId = videoModes.first?.id ?? modes.first?.id ?? OpenClawCaptureModeSeed.ID.general
        }
        if !photoModeIds.contains(lastPhotoModeId) {
            lastPhotoModeId = photoDefaultModeId
        }
        if !videoModeIds.contains(lastVideoModeId) {
            lastVideoModeId = videoDefaultModeId
        }

        persistSelections()
    }

    // MARK: - Persistence

    private func persistCatalog() {
        storage.saveModes(modes)
    }

    /// Only ids are written to UserDefaults — never prompt text, name, or
    /// summary — per the "no prompt text in logs/UserDefaults" requirement.
    private func persistSelections() {
        userDefaults.set(photoDefaultModeId.uuidString, forKey: photoDefaultKey)
        userDefaults.set(videoDefaultModeId.uuidString, forKey: videoDefaultKey)
        userDefaults.set(lastPhotoModeId.uuidString, forKey: lastPhotoKey)
        userDefaults.set(lastVideoModeId.uuidString, forKey: lastVideoKey)
    }
}
