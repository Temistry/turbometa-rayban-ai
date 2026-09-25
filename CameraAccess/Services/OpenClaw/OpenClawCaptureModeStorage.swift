/*
 * OpenClaw Capture Mode Storage
 * 拍摄模式持久化服务 - 受保护的 JSON 文件存储
 *
 * Capture mode prompts can contain sensitive or personal task context
 * (custom coding notes, health/fitness cues, etc.), so unlike
 * QuickVisionStorage / ConversationStorage this does NOT use UserDefaults
 * for the catalog itself. Modes are written as a JSON file under
 * Application Support, protected with
 * NSFileProtectionCompleteUntilFirstUserAuthentication (readable only after
 * the device has been unlocked at least once since boot — appropriate for
 * background-refresh-safe app data, stronger than the default protection
 * level) and excluded from backup. Only non-sensitive
 * selection state (which mode id is default/last-used) lives in
 * UserDefaults, and only as UUID strings — prompt text and mode names never
 * do. Log lines here only ever mention ids/counts, never mode names or
 * prompt content.
 */

import Foundation

final class OpenClawCaptureModeStorage {
    static let shared = OpenClawCaptureModeStorage()

    private let fileManager: FileManager
    private let fileName = "openclaw_capture_modes.json"
    private let directoryName = "OpenClaw"
    /// Injectable so tests can point storage at an isolated scratch
    /// directory instead of sharing the app's real Application Support
    /// folder (avoids cross-test leakage and touching real user data).
    private let directoryOverride: URL?

    private static let protectionType = FileProtectionType.completeUntilFirstUserAuthentication

    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        self.fileManager = fileManager
        self.directoryOverride = directoryOverride
    }

    // MARK: - Load

    /// Loads the stored catalog. Returns `nil` if there is no file yet or it
    /// failed to decode (corrupt/old-format), so the caller can fall back to
    /// the safe seeded catalog rather than crash or silently show nothing.
    func loadModes() -> [OpenClawCaptureMode]? {
        guard let url = existingFileURL() else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            print("[OpenClawCaptureModeStorage] 모드 파일을 읽지 못했습니다")
            return nil
        }

        guard let modes = try? JSONDecoder().decode([OpenClawCaptureMode].self, from: data) else {
            print("[OpenClawCaptureModeStorage] 모드 디코딩에 실패해 안전한 기본값을 사용합니다")
            return nil
        }

        return modes
    }

    // MARK: - Save

    /// Persists the full catalog, replacing any prior file. Writes
    /// atomically so a crash or termination mid-write can never leave a
    /// half-written/corrupt file behind. Errors are logged without content
    /// and surfaced to the caller so the in-memory state and on-disk state
    /// don't silently diverge.
    @discardableResult
    func saveModes(_ modes: [OpenClawCaptureMode]) -> Bool {
        guard let directoryURL = ensureDirectory() else { return false }
        let fileURL = directoryURL.appendingPathComponent(fileName)

        guard let data = try? JSONEncoder().encode(modes) else {
            print("[OpenClawCaptureModeStorage] 모드 인코딩에 실패했습니다")
            return false
        }

        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // Re-assert protection + exclude-from-backup in case the file
            // already existed with weaker attributes from an earlier app
            // version, or NSData's write options didn't cover them.
            try? fileManager.setAttributes(
                [.protectionKey: Self.protectionType],
                ofItemAtPath: fileURL.path
            )
            var excludedURL = fileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? excludedURL.setResourceValues(resourceValues)

            print("[OpenClawCaptureModeStorage] 모드 \(modes.count)개를 저장했습니다")
            return true
        } catch {
            print("[OpenClawCaptureModeStorage] 모드 저장에 실패했습니다")
            return false
        }
    }

    /// Removes the stored catalog file entirely (used by tests / reset flows).
    func deleteAll() {
        guard let url = existingFileURL() else { return }
        try? fileManager.removeItem(at: url)
        print("[OpenClawCaptureModeStorage] 모드 파일을 삭제했습니다")
    }

    // MARK: - Paths

    private func existingFileURL() -> URL? {
        guard let directoryURL = directoryURL() else { return nil }
        let fileURL = directoryURL.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func directoryURL() -> URL? {
        if let directoryOverride {
            return directoryOverride
        }
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    @discardableResult
    private func ensureDirectory() -> URL? {
        guard let directoryURL = directoryURL() else { return nil }

        if !fileManager.fileExists(atPath: directoryURL.path) {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: Self.protectionType]
                )
            } catch {
                print("[OpenClawCaptureModeStorage] 저장 디렉터리를 만들지 못했습니다")
                return nil
            }
        }

        // Best-effort: ensure the directory itself is excluded from backup
        // too, not just the file inside it.
        var directoryToExclude = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directoryToExclude.setResourceValues(resourceValues)

        return directoryURL
    }
}
