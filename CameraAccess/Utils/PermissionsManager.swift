/*
 * 권한 관리자
 * 앱에 필요한 마이크와 사진 보관함 권한을 한곳에서 관리한다.
 */

import Foundation
import UIKit
import AVFoundation
import Photos

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published var allPermissionsGranted = false

    private init() {}

    // MARK: - 모든 권한 요청

    func requestAllPermissions(completion: @escaping (Bool) -> Void) {
        print("[Permissions][INFO] 필수 권한 요청 시작")

        let group = DispatchGroup()
        var microphoneGranted = false
        var photoLibraryGranted = false

        group.enter()
        requestMicrophonePermission { granted in
            microphoneGranted = granted
            group.leave()
        }

        group.enter()
        requestPhotoLibraryPermission { granted in
            photoLibraryGranted = granted
            group.leave()
        }

        group.notify(queue: .main) {
            let allGranted = microphoneGranted && photoLibraryGranted
            self.allPermissionsGranted = allGranted

            if allGranted {
                print("[Permissions][INFO] 모든 필수 권한이 허용되었습니다")
            } else {
                print("[Permissions][WARN] 일부 권한이 허용되지 않았습니다 microphone=\(microphoneGranted) photoLibrary=\(photoLibraryGranted)")
            }

            completion(allGranted)
        }
    }

    // MARK: - 권한 상태 확인

    func checkAllPermissions() -> Bool {
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        let microphoneGranted = microphoneStatus == .authorized
        let photoGranted = photoStatus == .authorized || photoStatus == .limited

        allPermissionsGranted = microphoneGranted && photoGranted
        print("[Permissions][INFO] 권한 상태 확인 microphone=\(microphoneStatus.rawValue) photoLibrary=\(photoStatus.rawValue) allGranted=\(allPermissionsGranted)")
        return allPermissionsGranted
    }

    // MARK: - 마이크 권한

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            print("[Permissions][INFO] 마이크 권한이 이미 허용되어 있습니다")
            completion(true)

        case .notDetermined:
            print("[Permissions][INFO] 마이크 권한 요청 표시")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    print("[Permissions][\(granted ? "INFO" : "WARN")] 마이크 권한 요청 결과 granted=\(granted)")
                    completion(granted)
                }
            }

        case .denied, .restricted:
            print("[Permissions][WARN] 마이크 권한이 거부되었거나 제한되어 있습니다 status=\(status.rawValue)")
            completion(false)

        @unknown default:
            print("[Permissions][WARN] 알 수 없는 마이크 권한 상태 status=\(status.rawValue)")
            completion(false)
        }
    }

    // MARK: - 사진 보관함 권한

    private func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch status {
        case .authorized, .limited:
            print("[Permissions][INFO] 사진 보관함 추가 권한이 이미 허용되어 있습니다 status=\(status.rawValue)")
            completion(true)

        case .notDetermined:
            print("[Permissions][INFO] 사진 보관함 추가 권한 요청 표시")
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    let granted = newStatus == .authorized || newStatus == .limited
                    print("[Permissions][\(granted ? "INFO" : "WARN")] 사진 보관함 권한 요청 결과 status=\(newStatus.rawValue) granted=\(granted)")
                    completion(granted)
                }
            }

        case .denied, .restricted:
            print("[Permissions][WARN] 사진 보관함 권한이 거부되었거나 제한되어 있습니다 status=\(status.rawValue)")
            completion(false)

        @unknown default:
            print("[Permissions][WARN] 알 수 없는 사진 보관함 권한 상태 status=\(status.rawValue)")
            completion(false)
        }
    }

    // MARK: - iOS 설정 열기

    func openSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            print("[Permissions][ERROR] 앱 설정 URL을 만들 수 없습니다")
            return
        }

        guard UIApplication.shared.canOpenURL(settingsURL) else {
            print("[Permissions][ERROR] 앱 설정 URL을 열 수 없습니다 url=\(settingsURL.absoluteString)")
            return
        }

        UIApplication.shared.open(settingsURL)
        print("[Permissions][INFO] iOS 앱 설정 화면 열기 요청 완료")
    }
}
