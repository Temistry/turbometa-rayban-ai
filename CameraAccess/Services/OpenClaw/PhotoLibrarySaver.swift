/*
 * Photo Library Saver
 * OpenClaw에서 촬영한 JPEG/MP4를 Photos에 복사한다.
 *
 * `.addOnly` 권한만 요청하며 기존 사진 보관함을 읽거나 열거하지 않는다.
 * 저장 실패는 보호된 앱 원본과 독립적으로 처리한다.
 */

import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "PhotoLibrarySaver")

// MARK: - Capture location

struct OpenClawCaptureLocationSnapshot: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double
    let capturedAt: Date

    var coreLocation: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: latitude,
                longitude: longitude
            ),
            altitude: altitude ?? 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: altitude == nil ? -1 : horizontalAccuracy,
            timestamp: capturedAt
        )
    }

    var openClawContext: String {
        let format = "openclaw.capture.location.context".localized
        return String(
            format: format,
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude,
            horizontalAccuracy
        )
    }

    var iso6709: String {
        let locale = Locale(identifier: "en_US_POSIX")
        let altitudeComponent = altitude.map {
            String(format: "%+.1f", locale: locale, $0)
        } ?? ""
        return String(
            format: "%+.6f%+.6f%@/",
            locale: locale,
            latitude,
            longitude,
            altitudeComponent
        )
    }
}

@MainActor
final class OpenClawCaptureLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = OpenClawCaptureLocationService()
    static let enabledDefaultsKey = "openclaw_capture_location_enabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled {
                requestAuthorizationIfNeeded()
            } else {
                finish(with: nil)
            }
        }
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<OpenClawCaptureLocationSnapshot?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isLocationRequestStarted = false

    override init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestAuthorizationIfNeeded() {
        guard isEnabled,
              manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func captureSnapshot(timeout: TimeInterval = 3) async -> OpenClawCaptureLocationSnapshot? {
        guard isEnabled, continuation == nil else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            isLocationRequestStarted = false
            timeoutTask?.cancel()
            timeoutTask = Task { @MainActor [weak self] in
                let bounded = timeout.isFinite ? min(max(timeout, 0.5), 10) : 3
                try? await Task.sleep(
                    nanoseconds: UInt64(bounded * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                self?.finish(with: nil)
            }
            beginLocationRequestIfAuthorized()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        beginLocationRequestIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let now = Date()
        let location = locations
            .filter {
                $0.horizontalAccuracy >= 0
                    && $0.horizontalAccuracy <= 500
                    && abs($0.timestamp.timeIntervalSince(now)) <= 60
            }
            .min { $0.horizontalAccuracy < $1.horizontalAccuracy }
        guard let location else {
            finish(with: nil)
            return
        }
        finish(
            with: OpenClawCaptureLocationSnapshot(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                horizontalAccuracy: location.horizontalAccuracy,
                capturedAt: location.timestamp
            )
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(with: nil)
    }

    private func beginLocationRequestIfAuthorized() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard !isLocationRequestStarted else { return }
            isLocationRequestStarted = true
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(with: nil)
        @unknown default:
            finish(with: nil)
        }
    }

    private func finish(with snapshot: OpenClawCaptureLocationSnapshot?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        isLocationRequestStarted = false
        let pending = continuation
        continuation = nil
        pending?.resume(returning: snapshot)
    }
}

enum OpenClawMediaMetadataWriter {
    static func jpegData(
        _ originalData: Data,
        adding location: OpenClawCaptureLocationSnapshot?
    ) -> Data? {
        guard let location else { return originalData }
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              let type = CGImageSourceGetType(source),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                type,
                1,
                nil
              ) else {
            return nil
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var gps = (properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
        gps[kCGImagePropertyGPSLatitude] = abs(location.latitude)
        gps[kCGImagePropertyGPSLatitudeRef] = location.latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(location.longitude)
        gps[kCGImagePropertyGPSLongitudeRef] = location.longitude >= 0 ? "E" : "W"
        if let altitude = location.altitude {
            gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss.SSSSSS"
        gps[kCGImagePropertyGPSTimeStamp] = formatter.string(from: location.capturedAt)
        formatter.dateFormat = "yyyy:MM:dd"
        gps[kCGImagePropertyGPSDateStamp] = formatter.string(from: location.capturedAt)
        properties[kCGImagePropertyGPSDictionary] = gps

        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }
}

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
    func saveJPEG(
        _ jpegData: Data,
        location: OpenClawCaptureLocationSnapshot? = nil
    ) async throws -> String {
        guard !jpegData.isEmpty else { throw PhotoLibrarySaverError.invalidData }
        try await ensureAddOnlyAuthorization()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.location = location?.coreLocation
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.jpeg.identifier
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
    func saveMP4(
        fileURL: URL,
        location: OpenClawCaptureLocationSnapshot? = nil
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PhotoLibrarySaverError.invalidData
        }
        try await ensureAddOnlyAuthorization()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.location = location?.coreLocation
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
