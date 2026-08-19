/*
 * OpenClaw Media Item
 * 보호된 앱 Gallery의 사진·동영상 메타데이터 모델
 *
 * 원본 미디어와 thumbnail은 별도 보호 파일에 저장한다. 사용자가 선택한
 * 모드의 실행 snapshot은 명시적 분석 재시도가 최초 촬영과 동일한 prompt를
 * 사용하도록 보호된 index에 함께 저장한다. 이 prompt와 mode name은
 * UserDefaults나 진단 로그에 기록하지 않는다.
 */

import Foundation

enum OpenClawMediaKind: String, Codable, Equatable, Sendable {
    case photo
    case video
}

enum OpenClawMediaLocalStatus: String, Codable, Equatable, Sendable {
    case staged
    case ready
    case failed
}

enum OpenClawMediaPhotosStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case pending
    case saved
    case failed
    case permissionDenied
}

enum OpenClawMediaAnalysisStatus: String, Codable, Equatable, Sendable {
    case notRequested
    case pending
    case completed
    case failed
}

/// Tracks transport delivery separately from analysis completion. `ambiguous`
/// means the socket outcome did not prove whether Gateway accepted the request;
/// it must never be retried automatically.
enum OpenClawMediaDeliveryStatus: String, Codable, Equatable, Sendable {
    case notAttempted
    case sending
    case delivered
    case ambiguous
    case failed
}

struct OpenClawMediaItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let kind: OpenClawMediaKind
    let createdAt: Date

    let originalExtension: String
    let thumbnailExtension: String
    let originalRelativePath: String
    let thumbnailRelativePath: String?
    let byteSize: Int
    let width: Int?
    let height: Int?
    let durationSeconds: Double?

    /// Frozen at capture start. This intentionally contains sensitive prompt
    /// text, so the enclosing index must retain file protection and backup
    /// exclusion. UI should normally display only `name`.
    let modeSnapshot: OpenClawCaptureModeExecutionSnapshot

    /// Stable identity for the capture and its first outbound analysis attempt.
    /// Reconnect never implicitly sends it again.
    let requestID: UUID
    let linkedUserMessageID: UUID?
    let linkedAssistantMessageID: UUID?

    let localStatus: OpenClawMediaLocalStatus
    let photosStatus: OpenClawMediaPhotosStatus
    let analysisStatus: OpenClawMediaAnalysisStatus
    let deliveryStatus: OpenClawMediaDeliveryStatus

    /// Explicit retry count. Zero is the first attempt; each user-approved
    /// retry creates a new outbound attempt while preserving the capture ID.
    let retryAttempt: Int

    init(
        id: UUID = UUID(),
        kind: OpenClawMediaKind,
        createdAt: Date = Date(),
        originalExtension: String,
        thumbnailExtension: String = "jpg",
        originalRelativePath: String? = nil,
        thumbnailRelativePath: String? = nil,
        byteSize: Int,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        modeSnapshot: OpenClawCaptureModeExecutionSnapshot,
        requestID: UUID,
        linkedUserMessageID: UUID? = nil,
        linkedAssistantMessageID: UUID? = nil,
        localStatus: OpenClawMediaLocalStatus = .staged,
        photosStatus: OpenClawMediaPhotosStatus = .notRequested,
        analysisStatus: OpenClawMediaAnalysisStatus = .notRequested,
        deliveryStatus: OpenClawMediaDeliveryStatus = .notAttempted,
        retryAttempt: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.originalExtension = originalExtension
        self.thumbnailExtension = thumbnailExtension
        self.originalRelativePath = Self.safeFilename(
            originalRelativePath ?? "\(id.uuidString).\(originalExtension)"
        )
        self.thumbnailRelativePath = thumbnailRelativePath.map(Self.safeFilename)
            ?? "\(id.uuidString).\(thumbnailExtension)"
        self.byteSize = byteSize
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.modeSnapshot = modeSnapshot
        self.requestID = requestID
        self.linkedUserMessageID = linkedUserMessageID
        self.linkedAssistantMessageID = linkedAssistantMessageID
        self.localStatus = localStatus
        self.photosStatus = photosStatus
        self.analysisStatus = analysisStatus
        self.deliveryStatus = deliveryStatus
        self.retryAttempt = max(0, retryAttempt)
    }

    var originalFilename: String {
        (originalRelativePath as NSString).lastPathComponent
    }

    var thumbnailFilename: String? {
        thumbnailRelativePath.map { ($0 as NSString).lastPathComponent }
    }

    func withLocalStatus(_ status: OpenClawMediaLocalStatus) -> OpenClawMediaItem {
        copying(localStatus: status)
    }

    func withPhotosStatus(_ status: OpenClawMediaPhotosStatus) -> OpenClawMediaItem {
        copying(photosStatus: status)
    }

    func withAnalysisStatus(_ status: OpenClawMediaAnalysisStatus) -> OpenClawMediaItem {
        copying(analysisStatus: status)
    }

    func withDeliveryStatus(_ status: OpenClawMediaDeliveryStatus) -> OpenClawMediaItem {
        copying(deliveryStatus: status)
    }

    func withRetryAttempt(_ attempt: Int) -> OpenClawMediaItem {
        copying(retryAttempt: max(0, attempt))
    }

    func withLinkedMessages(
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil
    ) -> OpenClawMediaItem {
        copying(
            linkedUserMessageID: userMessageID ?? linkedUserMessageID,
            linkedAssistantMessageID: assistantMessageID ?? linkedAssistantMessageID
        )
    }

    func withDimensions(
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil
    ) -> OpenClawMediaItem {
        copying(
            width: width ?? self.width,
            height: height ?? self.height,
            durationSeconds: durationSeconds ?? self.durationSeconds
        )
    }

    private func copying(
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        linkedUserMessageID: UUID? = nil,
        linkedAssistantMessageID: UUID? = nil,
        localStatus: OpenClawMediaLocalStatus? = nil,
        photosStatus: OpenClawMediaPhotosStatus? = nil,
        analysisStatus: OpenClawMediaAnalysisStatus? = nil,
        deliveryStatus: OpenClawMediaDeliveryStatus? = nil,
        retryAttempt: Int? = nil
    ) -> OpenClawMediaItem {
        OpenClawMediaItem(
            id: id,
            kind: kind,
            createdAt: createdAt,
            originalExtension: originalExtension,
            thumbnailExtension: thumbnailExtension,
            originalRelativePath: originalRelativePath,
            thumbnailRelativePath: thumbnailRelativePath,
            byteSize: byteSize,
            width: width ?? self.width,
            height: height ?? self.height,
            durationSeconds: durationSeconds ?? self.durationSeconds,
            modeSnapshot: modeSnapshot,
            requestID: requestID,
            linkedUserMessageID: linkedUserMessageID ?? self.linkedUserMessageID,
            linkedAssistantMessageID: linkedAssistantMessageID ?? self.linkedAssistantMessageID,
            localStatus: localStatus ?? self.localStatus,
            photosStatus: photosStatus ?? self.photosStatus,
            analysisStatus: analysisStatus ?? self.analysisStatus,
            deliveryStatus: deliveryStatus ?? self.deliveryStatus,
            retryAttempt: retryAttempt ?? self.retryAttempt
        )
    }

    private static func safeFilename(_ candidate: String) -> String {
        let filename = (candidate as NSString).lastPathComponent
        return filename.isEmpty ? UUID().uuidString : filename
    }
}
