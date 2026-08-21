/*
 * OpenClaw Media Repository
 * 보호된 Application Support 미디어 저장소
 *
 * 원본, thumbnail, 실행 mode snapshot을 completeUntilFirstUserAuthentication
 * 보호 수준으로 저장하고 backup에서 제외한다. 저장소 로그에는 prompt,
 * mode name, 미디어 payload, 채팅 원문을 남기지 않는다.
 */

import Foundation
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "OpenClawMediaRepository")

// MARK: - Errors

enum OpenClawMediaRepositoryError: Error, Equatable {
    case emptyData
    case stagingFailed(String)
    case finalizeFailed(String)
    case itemNotFound
    /// The repository has reached its metadata capacity. Intact originals are never evicted
    /// automatically; the user must explicitly delete an item before another can be added.
    case capacityReached
    /// The on-disk index could not be decoded. The corrupted file has been preserved alongside
    /// the store (renamed, not deleted) for manual recovery. The in-memory index starts empty,
    /// but destructive operations that rely on the index being a complete picture of on-disk
    /// state (`cleanupOrphans`) are refused until this is resolved, so previously-stored assets
    /// are never mistaken for orphans and deleted.
    case indexCorrupted
}

// MARK: - Repository

/// Manages a protected, on-device media store for OpenClaw-captured photos and videos.
///
/// Layout:
/// ```
/// Application Support/
///   OpenClawMedia/
///     originals/    <uuid>.<ext>
///     thumbnails/   <uuid>.jpg
///     index.json
/// ```
///
/// All directories are marked excluded from iCloud/iTunes backup, and files are written with
/// `NSFileProtectionCompleteUntilFirstUserAuthentication` so their contents are inaccessible
/// before the device's first unlock after boot. Writes are staged to a temporary file in the
/// same directory and atomically finalized (move for a new path, replace for an existing one)
/// so a crash or termination mid-write can never leave a corrupt/partial asset visible to
/// readers.
actor OpenClawMediaRepository {
    static let shared = OpenClawMediaRepository()

    /// Hard metadata cap. Intact app-owned originals are never auto-evicted; callers must
    /// explicitly delete an item before adding another once this capacity is reached.
    static let maxIndexedItems = 500

    private let fileManager: FileManager
    private let indexCapacity: Int
    private let rootURL: URL
    private let originalsURL: URL
    private let thumbnailsURL: URL
    private let indexURL: URL
    private let integrityMarkerURL: URL

    private var indexLoaded = false
    private var items: [OpenClawMediaItem] = []

    /// Set when the on-disk index failed to decode. While `true`, all metadata writes and
    /// destructive cleanup are refused so files whose metadata was lost are never overwritten or
    /// misidentified as orphans. A protected marker persists this state across process restarts.
    private var indexIntegrityCompromised = false

    // MARK: - Init

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        indexCapacity: Int = OpenClawMediaRepository.maxIndexedItems
    ) {
        self.fileManager = fileManager
        self.indexCapacity = max(1, indexCapacity)

        let baseURL: URL
        if let rootURL {
            baseURL = rootURL
        } else {
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            baseURL = (appSupport ?? fileManager.temporaryDirectory)
                .appendingPathComponent("OpenClawMedia", isDirectory: true)
        }
        self.rootURL = baseURL
        self.originalsURL = baseURL.appendingPathComponent("originals", isDirectory: true)
        self.thumbnailsURL = baseURL.appendingPathComponent("thumbnails", isDirectory: true)
        self.indexURL = baseURL.appendingPathComponent("index.json", isDirectory: false)
        self.integrityMarkerURL = baseURL.appendingPathComponent(
            "index.integrity-compromised",
            isDirectory: false
        )
    }

    // MARK: - Public API

    /// Ensures the on-disk directory structure exists, is excluded from backups, and the
    /// in-memory index is loaded. Safe to call repeatedly.
    func prepare() throws {
        try ensureDirectoryStructure()
        try loadIndexIfNeeded()
    }

    /// Stages `originalData` and `thumbnailData` to temporary files, then atomically finalizes
    /// both into the protected store and appends a new index entry.
    ///
    /// If `requestID` is provided and an item with the same `requestID` already exists in the
    /// index, that existing item is returned unchanged and no new files are written — this
    /// makes retried invokes (e.g. a `camera.snap` retried after a dropped gateway response)
    /// idempotent instead of producing duplicate assets.
    ///
    /// - Returns: The newly created (or matching existing) `OpenClawMediaItem`.
    @discardableResult
    func addItem(
        kind: OpenClawMediaKind,
        originalData: Data,
        originalExtension: String,
        thumbnailData: Data?,
        thumbnailExtension: String = "jpg",
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        location: OpenClawCaptureLocationSnapshot? = nil,
        modeSnapshot: OpenClawCaptureModeExecutionSnapshot,
        requestID: UUID,
        linkedUserMessageID: UUID? = nil,
        linkedAssistantMessageID: UUID? = nil
    ) throws -> OpenClawMediaItem {
        guard !originalData.isEmpty else { throw OpenClawMediaRepositoryError.emptyData }

        try prepare()
        try requireHealthyIndexLocked()

        if let existing = items.first(where: { $0.requestID == requestID }) {
            return existing
        }
        try makeCapacityForNewItemLocked()

        let item = OpenClawMediaItem(
            kind: kind,
            originalExtension: originalExtension,
            thumbnailExtension: thumbnailExtension,
            byteSize: originalData.count,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            location: location,
            modeSnapshot: modeSnapshot,
            requestID: requestID,
            linkedUserMessageID: linkedUserMessageID,
            linkedAssistantMessageID: linkedAssistantMessageID,
            localStatus: .staged
        )

        let originalDest = originalsURL.appendingPathComponent(item.originalFilename)
        try atomicWrite(originalData, to: originalDest)

        var finalItem = item
        if let thumbnailData, !thumbnailData.isEmpty, let thumbFilename = item.thumbnailFilename {
            let thumbDest = thumbnailsURL.appendingPathComponent(thumbFilename)
            do {
                try atomicWrite(thumbnailData, to: thumbDest)
            } catch {
                // Thumbnail is best-effort; do not fail the whole add if only it fails.
                logger.error("Thumbnail write failed for item, continuing without thumbnail")
                try? fileManager.removeItem(at: thumbDest)
            }
        }
        finalItem = finalItem.withLocalStatus(.ready)

        items.append(finalItem)
        try persistIndexLocked()

        logger.info("Added media item kind=\(finalItem.kind.rawValue, privacy: .public) bytes=\(finalItem.byteSize, privacy: .public)")
        return finalItem
    }

    /// Stages original asset data directly from a source file URL (e.g. a video already written
    /// to disk by `AVAssetWriter`), avoiding a full in-memory copy for large files. Idempotent
    /// on `requestID` in the same way as the `Data`-based overload.
    @discardableResult
    func addItem(
        kind: OpenClawMediaKind,
        originalFileURL: URL,
        originalExtension: String,
        thumbnailData: Data?,
        thumbnailExtension: String = "jpg",
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        location: OpenClawCaptureLocationSnapshot? = nil,
        modeSnapshot: OpenClawCaptureModeExecutionSnapshot,
        requestID: UUID,
        linkedUserMessageID: UUID? = nil,
        linkedAssistantMessageID: UUID? = nil
    ) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()

        if let existing = items.first(where: { $0.requestID == requestID }) {
            try? fileManager.removeItem(at: originalFileURL)
            return existing
        }
        try makeCapacityForNewItemLocked()

        let attrs = try fileManager.attributesOfItem(atPath: originalFileURL.path)
        let byteSize = (attrs[.size] as? Int) ?? 0
        guard byteSize > 0 else { throw OpenClawMediaRepositoryError.emptyData }

        let item = OpenClawMediaItem(
            kind: kind,
            originalExtension: originalExtension,
            thumbnailExtension: thumbnailExtension,
            byteSize: byteSize,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            location: location,
            modeSnapshot: modeSnapshot,
            requestID: requestID,
            linkedUserMessageID: linkedUserMessageID,
            linkedAssistantMessageID: linkedAssistantMessageID,
            localStatus: .staged
        )

        let originalDest = originalsURL.appendingPathComponent(item.originalFilename)
        try atomicMove(from: originalFileURL, to: originalDest)

        var finalItem = item
        if let thumbnailData, !thumbnailData.isEmpty, let thumbFilename = item.thumbnailFilename {
            let thumbDest = thumbnailsURL.appendingPathComponent(thumbFilename)
            do {
                try atomicWrite(thumbnailData, to: thumbDest)
            } catch {
                logger.error("Thumbnail write failed for item, continuing without thumbnail")
                try? fileManager.removeItem(at: thumbDest)
            }
        }
        finalItem = finalItem.withLocalStatus(.ready)

        items.append(finalItem)
        try persistIndexLocked()

        logger.info("Added media item (file) kind=\(finalItem.kind.rawValue, privacy: .public) bytes=\(finalItem.byteSize, privacy: .public)")
        return finalItem
    }

    /// Returns all indexed items, most recently created first.
    func listItems() throws -> [OpenClawMediaItem] {
        try prepare()
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns a single item by id, if present in the index.
    func item(withID id: UUID) throws -> OpenClawMediaItem? {
        try prepare()
        return items.first { $0.id == id }
    }

    /// Returns a single item by its producing operation's `requestID`, if present.
    func item(withRequestID requestID: UUID) throws -> OpenClawMediaItem? {
        try prepare()
        return items.first { $0.requestID == requestID }
    }

    /// Reads the original asset bytes for the given item.
    func originalData(for item: OpenClawMediaItem) throws -> Data {
        try prepare()
        return try Data(contentsOf: originalURL(for: item), options: .mappedIfSafe)
    }

    /// File URL for the original asset (does not guarantee existence).
    func originalURL(for item: OpenClawMediaItem) -> URL {
        originalsURL.appendingPathComponent(item.originalFilename, isDirectory: false)
    }

    /// File URL for the thumbnail asset, if the item has one (does not guarantee existence).
    func thumbnailURL(for item: OpenClawMediaItem) -> URL? {
        guard let filename = item.thumbnailFilename else { return nil }
        return thumbnailsURL.appendingPathComponent(filename, isDirectory: false)
    }

    /// Reads the thumbnail asset bytes for the given item, if one was stored.
    func thumbnailData(for item: OpenClawMediaItem) throws -> Data? {
        try prepare()
        guard let url = thumbnailURL(for: item), fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Updates mutable dimension/duration metadata for an existing item, preserving its id,
    /// kind, timestamps, correlation identifiers, and on-disk assets. Returns the updated item.
    @discardableResult
    func updateItem(
        id: UUID,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil
    ) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        let updated = items[idx].withDimensions(width: width, height: height, durationSeconds: durationSeconds)
        items[idx] = updated
        try persistIndexLocked()
        return updated
    }

    /// Updates the Photos-export status for an item (e.g. after `PhotoLibrarySaver` succeeds or
    /// fails). Never stores the resulting `PHAsset` content — only the status transition.
    @discardableResult
    func updatePhotosStatus(id: UUID, status: OpenClawMediaPhotosStatus) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        let updated = items[idx].withPhotosStatus(status)
        items[idx] = updated
        try persistIndexLocked()
        return updated
    }

    /// Updates the downstream analysis status for an item. Never stores analysis prompts or
    /// results — only the status transition.
    @discardableResult
    func updateAnalysisStatus(id: UUID, status: OpenClawMediaAnalysisStatus) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        let updated = items[idx].withAnalysisStatus(status)
        items[idx] = updated
        try persistIndexLocked()
        return updated
    }

    /// Updates the gateway delivery status for an item, optionally bumping the retry attempt
    /// counter (e.g. after a `node.invoke.result` send failure is retried).
    @discardableResult
    func updateDeliveryStatus(id: UUID, status: OpenClawMediaDeliveryStatus, retryAttempt: Int? = nil) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        var updated = items[idx].withDeliveryStatus(status)
        if let retryAttempt {
            updated = updated.withRetryAttempt(retryAttempt)
        }
        items[idx] = updated
        try persistIndexLocked()
        return updated
    }

    /// Links an item to the OpenClaw chat message id(s) that requested it and/or referenced it
    /// in a response. Only opaque message identifiers are stored — never message content.
    @discardableResult
    func linkMessages(
        id: UUID,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil
    ) throws -> OpenClawMediaItem {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        let updated = items[idx].withLinkedMessages(userMessageID: userMessageID, assistantMessageID: assistantMessageID)
        items[idx] = updated
        try persistIndexLocked()
        return updated
    }

    /// Deletes an item's index entry and its on-disk original/thumbnail files, if present.
    func deleteItem(id: UUID) throws {
        try prepare()
        try requireHealthyIndexLocked()
        guard let idx = items.firstIndex(where: { $0.id == id }) else {
            throw OpenClawMediaRepositoryError.itemNotFound
        }
        let item = items.remove(at: idx)
        removeAssetsLocked(for: item)
        try persistIndexLocked()
        logger.info("Deleted media item")
    }

    /// Removes all indexed items and their on-disk assets, and clears the index file.
    func deleteAll() throws {
        try prepare()
        try requireHealthyIndexLocked()
        for item in items {
            removeAssetsLocked(for: item)
        }
        items = []
        try persistIndexLocked()
        logger.info("Deleted all media items")
    }

    /// Scans `originals/` and `thumbnails/` for files that are not referenced by any indexed
    /// item (e.g. left behind by a crash between staging and index persistence) and removes
    /// them. Returns the count of orphan files removed.
    ///
    /// Refuses to run (throws `.indexCorrupted`) if the index failed to decode on load — in
    /// that state the in-memory index is known-incomplete, so every on-disk file would look
    /// like an orphan even though it may still be a valid, previously-stored asset. Resolve the
    /// corruption (see the preserved `index.corrupted.*.json` file) before retrying.
    @discardableResult
    func cleanupOrphans() throws -> Int {
        try prepare()

        guard !indexIntegrityCompromised else {
            throw OpenClawMediaRepositoryError.indexCorrupted
        }

        let knownOriginals = Set(items.map { $0.originalFilename })
        let knownThumbnails = Set(items.compactMap { $0.thumbnailFilename })

        var removed = 0
        removed += try removeOrphans(in: originalsURL, keeping: knownOriginals)
        removed += try removeOrphans(in: thumbnailsURL, keeping: knownThumbnails)

        if removed > 0 {
            logger.info("Removed orphan media files")
        }
        return removed
    }

    /// Total on-disk byte size of all indexed originals + thumbnails (best effort).
    func totalStoredBytes() throws -> Int {
        try prepare()
        var total = 0
        for item in items {
            if let size = (try? fileManager.attributesOfItem(atPath: originalURL(for: item).path)[.size]) as? Int {
                total += size
            }
            if let thumbURL = thumbnailURL(for: item),
               let size = (try? fileManager.attributesOfItem(atPath: thumbURL.path)[.size]) as? Int {
                total += size
            }
        }
        return total
    }

    // MARK: - Directory / Backup Exclusion / Protection

    private func ensureDirectoryStructure() throws {
        for url in [rootURL, originalsURL, thumbnailsURL] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            applyProtection(toPath: url.path)
        }
        try excludeFromBackup(rootURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try mutableURL.setResourceValues(resourceValues)
    }

    /// Best-effort application of `NSFileProtectionCompleteUntilFirstUserAuthentication` to the
    /// item at `path`. Content protection is a per-file attribute; this is called for every
    /// directory at creation time and for every file immediately after it is finalized on disk.
    private func applyProtection(toPath path: String) {
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: path
        )
    }

    // MARK: - Index Persistence

    private func loadIndexIfNeeded() throws {
        guard !indexLoaded else { return }
        defer { indexLoaded = true }

        guard fileManager.fileExists(atPath: indexURL.path) else {
            items = []
            indexIntegrityCompromised = fileManager.fileExists(
                atPath: integrityMarkerURL.path
            )
            return
        }

        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([OpenClawMediaItem].self, from: data)
            indexIntegrityCompromised = fileManager.fileExists(
                atPath: integrityMarkerURL.path
            )
        } catch {
            // Corrupted index: the on-disk media files may still be perfectly valid, but we
            // have lost the metadata that maps them. Preserve the corrupted file (rename, don't
            // delete or overwrite it) for manual recovery, start the in-memory index empty, and
            // flag integrity as compromised so destructive orphan cleanup refuses to run and
            // mistakenly delete files that are still referenced by the lost metadata.
            logger.error("Index decode failed; preserving corrupted file and starting empty")
            items = []
            indexIntegrityCompromised = true
            preserveCorruptedIndexFile()
            persistIntegrityMarker()
        }
    }

    private func preserveCorruptedIndexFile() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = rootURL.appendingPathComponent("index.corrupted.\(timestamp).json")
        try? fileManager.removeItem(at: backupURL) // extremely unlikely collision, but stay safe
        try? fileManager.moveItem(at: indexURL, to: backupURL)
    }

    private func persistIntegrityMarker() {
        do {
            try atomicWrite(Data(), to: integrityMarkerURL)
        } catch {
            logger.error("Failed to persist media index integrity marker")
        }
    }

    private func requireHealthyIndexLocked() throws {
        guard !indexIntegrityCompromised else {
            throw OpenClawMediaRepositoryError.indexCorrupted
        }
    }

    private func persistIndexLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        try atomicWrite(data, to: indexURL)
    }

    /// Clears a repository write lock after the user has exported the preserved corrupted index
    /// and resolved any orphaned media. This does not delete originals or thumbnails; it only
    /// acknowledges that an empty/rebuilt index may safely become writable again.
    func acknowledgeIndexRecovery() throws {
        try prepare()
        guard indexIntegrityCompromised else { return }
        try fileManager.removeItem(at: integrityMarkerURL)
        indexIntegrityCompromised = false
        try persistIndexLocked()
        logger.info("Media index recovery acknowledged")
    }

    /// Removes metadata records whose originals are already missing before admitting a new item.
    /// If every indexed item still owns an intact original, capacity is reported to the caller
    /// rather than silently deleting user media or allowing an unbounded index.
    private func makeCapacityForNewItemLocked() throws {
        guard items.count >= indexCapacity else { return }

        let staleItems = items.filter {
            !fileManager.fileExists(atPath: originalURL(for: $0).path)
        }
        guard !staleItems.isEmpty else {
            throw OpenClawMediaRepositoryError.capacityReached
        }

        let staleIDs = Set(staleItems.map(\.id))
        for item in staleItems {
            if let thumbnailURL = thumbnailURL(for: item) {
                try? fileManager.removeItem(at: thumbnailURL)
            }
        }
        items.removeAll { staleIDs.contains($0.id) }
        try persistIndexLocked()

        guard items.count < indexCapacity else {
            throw OpenClawMediaRepositoryError.capacityReached
        }
    }

    private func removeAssetsLocked(for item: OpenClawMediaItem) {
        try? fileManager.removeItem(at: originalURL(for: item))
        if let thumbURL = thumbnailURL(for: item) {
            try? fileManager.removeItem(at: thumbURL)
        }
    }

    private func removeOrphans(in directory: URL, keeping known: Set<String>) throws -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in entries {
            // Never remove partially-staged temp files that are mid-write for another
            // operation; they use a distinct ".tmp-" prefix and are cleaned up by their
            // own atomic-write failure path, not by orphan scanning.
            guard !name.hasPrefix(".tmp-") else { continue }
            guard !known.contains(name) else { continue }
            let url = directory.appendingPathComponent(name)
            if (try? fileManager.removeItem(at: url)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Atomic Write Primitives

    /// Writes `data` to a temp file beside `destination`, then atomically finalizes it into
    /// place: `moveItem` if `destination` does not yet exist (the common case for new assets —
    /// `replaceItemAt` is not guaranteed to succeed when there is nothing to replace), or
    /// `replaceItemAt` if it does (e.g. rewriting `index.json`). Guarantees `destination` never
    /// observes partial content, and applies content protection to the finalized file.
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            applyProtection(toPath: tempURL.path)
            try finalizeStagedFile(from: tempURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw OpenClawMediaRepositoryError.stagingFailed(error.localizedDescription)
        }
    }

    /// Moves a file already on disk (e.g. an `AVAssetWriter` output) into the protected store
    /// via a staging copy + atomic finalize, so the source file's original location is left
    /// untouched until the destination is durably in place.
    private func atomicMove(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let tempURL = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: tempURL)
            applyProtection(toPath: tempURL.path)
            try finalizeStagedFile(from: tempURL, to: destination)
            try? fileManager.removeItem(at: source)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw OpenClawMediaRepositoryError.finalizeFailed(error.localizedDescription)
        }
    }

    /// Atomically finalizes a staged temp file into `destination`. `FileManager.replaceItemAt`
    /// is documented and tested against an *existing* destination; when nothing exists at
    /// `destination` yet (the common case for a brand-new original/thumbnail), a plain
    /// same-volume `moveItem` is the correct atomic-rename primitive and avoids relying on
    /// `replaceItemAt`'s undefined behavior for a missing target.
    private func finalizeStagedFile(from tempURL: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
        applyProtection(toPath: destination.path)
    }
}
