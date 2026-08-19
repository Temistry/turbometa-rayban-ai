/*
 * Photo Library Saver
 * OpenClaw에서 촬영한 JPEG/MP4를 Photos에 복사한다.
 *
 * `.addOnly` 권한만 요청하며 기존 사진 보관함을 읽거나 열거하지 않는다.
 * 저장 실패는 보호된 앱 원본과 독립적으로 처리한다.
 */

import Foundation
import Photos
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "PhotoLibrarySaver")

// MARK: - Errors

enum PhotoLibrarySaverError: LocalizedError, Equatable {
    case permissionDenied
    case permissionRestricted
    case invalidData
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "사진 보관함 추가 권한이 거부되었습니다."
        case .permissionRestricted:
            return "이 기기에서는 사진 보관함 추가가 제한되어 있습니다."
        case .invalidData:
            return "저장할 미디어를 읽을 수 없습니다."
        case .saveFailed:
            return "사진 보관함에 저장하지 못했습니다."
        }
    }
}

// MARK: - Saver

/// Saves photos and videos captured via OpenClaw into the user's system photo library using
/// the add-only Photos authorization scope (`PHAccessLevel.addOnly`). This scope allows writing
/// new assets without ever being granted read access to the existing library.
@MainActor
final class PhotoLibrarySaver {
    static let shared = PhotoLibrarySaver()

    private init() {}

    // MARK: - Public API

    /// Current add-only authorization status without prompting the user.
    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Requests add-only Photos authorization if not already determined, then resolves with the
    /// resulting status.
    func requestAuthorization() async -> PHAuthorizationStatus {
        let current = authorizationStatus
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Saves JPEG image data as a new asset in the system photo library.
    /// - Parameter jpegData: Raw JPEG bytes.
    /// - Returns: A non-sensitive success marker. Add-only access does not require retaining an asset identifier.
    @discardableResult
    func saveJPEG(_ jpegData: Data) async throws -> String {
        guard !jpegData.isEmpty else { throw PhotoLibrarySaverError.invalidData }
        try await ensureAddOnlyAuthorization()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.jpeg"
                request.addResource(with: .photo, data: jpegData, options: options)
            }
        } catch {
            logger.error("Photo save failed")
            throw PhotoLibrarySaverError.saveFailed
        }

        logger.info("Saved photo asset to library")
        return "saved"
    }

    /// Saves an MP4 video file (already on disk) as a new asset in the system photo library.
    /// - Parameter fileURL: File URL of a finalized, readable MP4 file.
    /// - Returns: A non-sensitive success marker. Add-only access does not require retaining an asset identifier.
    @discardableResult
    func saveMP4(fileURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoLibrarySaverError.invalidData
        }
        try await ensureAddOnlyAuthorization()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
            }
        } catch {
            logger.error("Video save failed")
            throw PhotoLibrarySaverError.saveFailed
        }

        logger.info("Saved video asset to library")
        return "saved"
    }

    // MARK: - Private

    private func ensureAddOnlyAuthorization() async throws {
        let status = await requestAuthorization()
        switch status {
        case .authorized, .limited:
            return
        case .denied:
            throw PhotoLibrarySaverError.permissionDenied
        case .restricted:
            throw PhotoLibrarySaverError.permissionRestricted
        case .notDetermined:
            throw PhotoLibrarySaverError.permissionDenied
        @unknown default:
            throw PhotoLibrarySaverError.permissionDenied
        }
    }
}
