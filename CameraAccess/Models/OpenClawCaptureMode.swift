/*
 * OpenClaw Capture Mode Models
 * 定义 OpenClaw 拍摄模式（通用/编程/象棋/深蹲等）的数据结构
 *
 * A capture mode bundles a system prompt with a symbol and supported media
 * types so the OpenClaw camera flow can be repointed at different tasks
 * (general description, coding help, chess analysis, squat form check, ...)
 * without changing code. Modes are shared across the photo and video
 * library — a single catalog, filtered per-flow by `supportedMedia`.
 */

import Foundation

// MARK: - Supported Media

/// Which capture flows a mode is valid for. Backed by an `OptionSet` (not a
/// three-case enum) because the editor exposes independent Photo/Video
/// toggles — a mode can support either, or both, but must support at least
/// one (enforced by `OpenClawCaptureModeValidation`).
struct OpenClawCaptureModeMedia: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let photo = OpenClawCaptureModeMedia(rawValue: 1 << 0)
    static let video = OpenClawCaptureModeMedia(rawValue: 1 << 1)

    /// Convenience for the common "works for both flows" case.
    static let both: OpenClawCaptureModeMedia = [.photo, .video]

    var supportsPhoto: Bool { contains(.photo) }
    var supportsVideo: Bool { contains(.video) }

    var displayName: String {
        switch (supportsPhoto, supportsVideo) {
        case (true, true): return "openclaw.capturemode.media.both".localized
        case (true, false): return "openclaw.capturemode.media.photo".localized
        case (false, true): return "openclaw.capturemode.media.video".localized
        case (false, false): return "openclaw.capturemode.media.none".localized
        }
    }
}

// MARK: - Capture Mode

/// A single OpenClaw capture mode: a named prompt preset with an icon and
/// media applicability. `isBuiltIn` is a provenance marker only — it
/// records that a mode shipped with the app, but does not lock it: built-in
/// modes can be freely edited or deleted like any custom mode. The catalog
/// still guarantees a safe fallback exists (see
/// `OpenClawCaptureModeManager.ensureFallbackIfNeeded`), so deleting
/// everything never leaves capture without a usable mode.
struct OpenClawCaptureMode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var summary: String
    var prompt: String
    /// SF Symbol name used to represent the mode in pickers.
    var symbol: String
    var supportedMedia: OpenClawCaptureModeMedia
    /// Provenance only: true if this mode was seeded by the app rather than
    /// created by the user. Does not restrict editing or deletion.
    let isBuiltIn: Bool
    /// Lower sorts first. Reordering rewrites this for every mode.
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        prompt: String,
        symbol: String,
        supportedMedia: OpenClawCaptureModeMedia,
        isBuiltIn: Bool = false,
        sortOrder: Int
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.prompt = prompt
        self.symbol = symbol
        self.supportedMedia = supportedMedia
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }
}

// MARK: - Validation

enum OpenClawCaptureModeError: LocalizedError, Equatable {
    case nameRequired
    case nameTooLong(limit: Int)
    case duplicateName
    case summaryTooLong(limit: Int)
    case promptRequired
    case promptTooLong(limit: Int)
    case symbolRequired
    case mediaRequired
    case modeNotFound

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "openclaw.capturemode.error.namerequired".localized
        case .nameTooLong(let limit):
            return "openclaw.capturemode.error.nametoolong".localized("\(limit)")
        case .duplicateName:
            return "openclaw.capturemode.error.duplicatename".localized
        case .summaryTooLong(let limit):
            return "openclaw.capturemode.error.summarytoolong".localized("\(limit)")
        case .promptRequired:
            return "openclaw.capturemode.error.promptrequired".localized
        case .promptTooLong(let limit):
            return "openclaw.capturemode.error.prompttoolong".localized("\(limit)")
        case .symbolRequired:
            return "openclaw.capturemode.error.symbolrequired".localized
        case .mediaRequired:
            return "openclaw.capturemode.error.mediarequired".localized
        case .modeNotFound:
            return "openclaw.capturemode.error.notfound".localized
        }
    }
}

enum OpenClawCaptureModeValidation {
    static let nameLimit = 60
    static let summaryLimit = 160
    static let promptLimit = 4000

    /// Validates the editable fields of a mode draft. Does not check name
    /// uniqueness (callers must do that against the live catalog, since it
    /// needs to exclude the mode's own previous value when editing).
    static func validateFields(
        name: String,
        summary: String,
        prompt: String,
        symbol: String,
        media: OpenClawCaptureModeMedia
    ) -> OpenClawCaptureModeError? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedName.isEmpty {
            return .nameRequired
        }
        if trimmedName.count > nameLimit {
            return .nameTooLong(limit: nameLimit)
        }
        if summary.count > summaryLimit {
            return .summaryTooLong(limit: summaryLimit)
        }
        if trimmedPrompt.isEmpty {
            return .promptRequired
        }
        if trimmedPrompt.count > promptLimit {
            return .promptTooLong(limit: promptLimit)
        }
        if trimmedSymbol.isEmpty {
            return .symbolRequired
        }
        if media.isEmpty {
            return .mediaRequired
        }
        return nil
    }
}

// MARK: - Catalog Snapshot

/// Read-only, value-type view of the full capture-mode catalog plus current
/// default/last-used selections. Intended for browsing UI (pickers,
/// settings) where a single render pass should see a self-consistent set of
/// modes and selections. This is NOT what capture should hold onto for the
/// duration of a shot — use `OpenClawCaptureModeExecutionSnapshot` for that,
/// since the catalog here can still change while a capture is in flight.
struct OpenClawCaptureModeSnapshot: Equatable {
    let modes: [OpenClawCaptureMode]
    let photoDefaultModeId: UUID
    let videoDefaultModeId: UUID
    let lastPhotoModeId: UUID
    let lastVideoModeId: UUID

    func mode(for id: UUID) -> OpenClawCaptureMode? {
        modes.first { $0.id == id }
    }

    /// Modes valid for photo capture, in sort order.
    var photoModes: [OpenClawCaptureMode] {
        modes.filter { $0.supportedMedia.supportsPhoto }
    }

    /// Modes valid for video capture, in sort order.
    var videoModes: [OpenClawCaptureMode] {
        modes.filter { $0.supportedMedia.supportsVideo }
    }
}

// MARK: - Execution Snapshot

/// A frozen copy of exactly one mode's capture-relevant fields (id, name,
/// prompt, media), taken at the moment capture starts. The catalog is
/// mutable (the user can edit/delete/reorder modes at any time from
/// Settings), but a capture already in flight must keep using the prompt it
/// started with — so the capture flow should hold onto this snapshot, not a
/// live reference into the catalog or a full `OpenClawCaptureModeSnapshot`.
struct OpenClawCaptureModeExecutionSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let prompt: String
    let media: OpenClawCaptureModeMedia

    init(
        id: UUID,
        name: String,
        prompt: String,
        media: OpenClawCaptureModeMedia
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.media = media
    }

    init(mode: OpenClawCaptureMode) {
        self.init(
            id: mode.id,
            name: mode.name,
            prompt: mode.prompt,
            media: mode.supportedMedia
        )
    }
}

// MARK: - Seed Modes

enum OpenClawCaptureModeSeed {
    /// Stable, well-known identifiers for the built-in modes so migrations
    /// and "reset to default" flows can recognize them across app versions.
    /// `ID.general` also doubles as the id of the auto-regenerated fallback
    /// mode (see `makeGeneralFallback`), so "the general mode" is always a
    /// recognizable, stable concept even after a full catalog wipe.
    enum ID {
        static let general = UUID(uuidString: "8B27A2B0-6C0A-4C6E-9C7E-000000000001")!
        static let coding = UUID(uuidString: "8B27A2B0-6C0A-4C6E-9C7E-000000000002")!
        static let chess = UUID(uuidString: "8B27A2B0-6C0A-4C6E-9C7E-000000000003")!
        static let squat = UUID(uuidString: "8B27A2B0-6C0A-4C6E-9C7E-000000000004")!
    }

    /// Seeds the four built-in modes in a fixed sort order, using the
    /// device's current app-language bundle at seed time. Called on first
    /// launch and used as the safe fallback catalog if stored data is
    /// missing or fails to decode. Name/summary/prompt come from
    /// Localizable.strings (mirrors `QuickVisionMode`'s convention) so the
    /// seeded content is captured in the user's language rather than
    /// hardcoded to English.
    static func makeAll() -> [OpenClawCaptureMode] {
        [
            OpenClawCaptureMode(
                id: ID.general,
                name: "openclaw.capturemode.seed.general.name".localized,
                summary: "openclaw.capturemode.seed.general.summary".localized,
                prompt: "openclaw.capturemode.seed.general.prompt".localized,
                symbol: "eye.circle",
                supportedMedia: .both,
                isBuiltIn: true,
                sortOrder: 0
            ),
            OpenClawCaptureMode(
                id: ID.coding,
                name: "openclaw.capturemode.seed.coding.name".localized,
                summary: "openclaw.capturemode.seed.coding.summary".localized,
                prompt: "openclaw.capturemode.seed.coding.prompt".localized,
                symbol: "chevron.left.forwardslash.chevron.right",
                supportedMedia: .both,
                isBuiltIn: true,
                sortOrder: 1
            ),
            OpenClawCaptureMode(
                id: ID.chess,
                name: "openclaw.capturemode.seed.chess.name".localized,
                summary: "openclaw.capturemode.seed.chess.summary".localized,
                prompt: "openclaw.capturemode.seed.chess.prompt".localized,
                symbol: "checkerboard.rectangle",
                supportedMedia: .photo,
                isBuiltIn: true,
                sortOrder: 2
            ),
            OpenClawCaptureMode(
                id: ID.squat,
                name: "openclaw.capturemode.seed.squat.name".localized,
                summary: "openclaw.capturemode.seed.squat.summary".localized,
                prompt: "openclaw.capturemode.seed.squat.prompt".localized,
                symbol: "figure.strengthtraining.traditional",
                supportedMedia: .video,
                isBuiltIn: true,
                sortOrder: 3
            )
        ]
    }

    /// Regenerates just the General mode (both media), used to restore a
    /// safe fallback after a deletion leaves the catalog empty or without
    /// photo/video coverage. Deliberately does NOT reseed the other three
    /// built-ins — a user who intentionally removed them should not see
    /// them reappear.
    static func makeGeneralFallback(sortOrder: Int) -> OpenClawCaptureMode {
        OpenClawCaptureMode(
            id: ID.general,
            name: "openclaw.capturemode.seed.general.name".localized,
            summary: "openclaw.capturemode.seed.general.summary".localized,
            prompt: "openclaw.capturemode.seed.general.prompt".localized,
            symbol: "eye.circle",
            supportedMedia: .both,
            isBuiltIn: true,
            sortOrder: sortOrder
        )
    }
}
