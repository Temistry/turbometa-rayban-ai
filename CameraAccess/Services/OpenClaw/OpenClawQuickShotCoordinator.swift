/*
 * OpenClaw Quick Shot Coordinator
 *
 * 사진·동영상 촬영, 보호 저장, Photos 복사, OpenClaw 분석을 한 작업으로
 * 직렬화한다. prompt와 미디어 payload는 진단 로그에 기록하지 않는다.
 */

import Foundation
import UIKit

@MainActor
final class OpenClawQuickShotCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case capturing
        case recording(elapsed: TimeInterval)
        case saving
        case exportingToPhotos
        case sending
        case awaitingResponse
        case completed(mediaID: UUID, assistantMessageID: UUID)
        case failed(message: String, mediaID: UUID?, deliveryAmbiguous: Bool)
        case cancelled

        var isActive: Bool {
            switch self {
            case .preparing, .capturing, .recording, .saving,
                 .exportingToPhotos, .sending, .awaitingResponse:
                return true
            case .idle, .completed, .failed, .cancelled:
                return false
            }
        }
    }

    enum Flow: Equatable {
        case photo
        case video
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var selectedSnapshot: OpenClawCaptureModeExecutionSnapshot?
    @Published private(set) var recordedDuration: TimeInterval = 0
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var currentMediaItem: OpenClawMediaItem?

    private let streamViewModel: StreamSessionViewModel
    private let repository: OpenClawMediaRepository
    private let photoLibrarySaver: PhotoLibrarySaver
    private let openClawService: OpenClawNodeService

    private var operationTask: Task<Void, Never>?
    private var recordingTimerTask: Task<Void, Never>?
    private var recorder: OpenClawVideoRecorder?
    private var recordingStartUptime: TimeInterval?
    private var sampledFrames: [(time: TimeInterval, image: UIImage)] = []
    private var isVideoFinalizationStarted = false
    private var videoRequestID: UUID?
    private var videoUserMessageID: UUID?
    private var streamStartedByQuickShot = false

    init(
        streamViewModel: StreamSessionViewModel,
        repository: OpenClawMediaRepository = .shared,
        photoLibrarySaver: PhotoLibrarySaver? = nil,
        openClawService: OpenClawNodeService = .shared
    ) {
        self.streamViewModel = streamViewModel
        self.repository = repository
        self.photoLibrarySaver = photoLibrarySaver ?? .shared
        self.openClawService = openClawService
    }

    func startPhoto(snapshot: OpenClawCaptureModeExecutionSnapshot) {
        guard !state.isActive else { return }
        selectedSnapshot = snapshot
        resetOperationState()
        operationTask = Task { [weak self] in
            await self?.runPhoto(snapshot: snapshot)
        }
    }

    func startVideo(snapshot: OpenClawCaptureModeExecutionSnapshot) {
        guard !state.isActive else { return }
        selectedSnapshot = snapshot
        resetOperationState()
        videoRequestID = UUID()
        videoUserMessageID = UUID()
        operationTask = Task { [weak self] in
            await self?.beginVideo(snapshot: snapshot)
        }
    }

    func stopVideo() {
        guard case .recording = state,
              beginVideoFinalizationIfNeeded() else { return }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        streamViewModel.stopRecordingFrames(owner: .openClawQuickShot)
        operationTask = Task { [weak self] in
            await self?.finishVideo()
        }
    }

    func cancel() {
        operationTask?.cancel()
        operationTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        streamViewModel.cancelCapture(owner: .openClawQuickShot)
        recorder?.cancel()
        recorder = nil
        isVideoFinalizationStarted = false
        videoRequestID = nil
        videoUserMessageID = nil
        sampledFrames.removeAll(keepingCapacity: false)
        Task { await stopOwnedStreamIfNeeded() }
        state = .cancelled
    }

    func reset() {
        guard !state.isActive else { return }
        selectedSnapshot = nil
        currentMediaItem = nil
        recordedDuration = 0
        droppedFrameCount = 0
        state = .idle
    }

    private func runPhoto(snapshot: OpenClawCaptureModeExecutionSnapshot) async {
        let requestID = UUID()
        let userMessageID = UUID()
        do {
            state = .preparing
            try await prepareStream()
            try Task.checkCancellation()

            state = .capturing
            let captured = try await streamViewModel.capturePhotoResult(
                owner: .openClawQuickShot
            )
            print("[OpenClawQuickShot][INFO] 사진 수신 bytes=\(captured.jpegData.count)")
            try Task.checkCancellation()

            state = .saving
            let thumbnailData = makeThumbnailJPEG(from: captured.image)
            var item = try await repository.addItem(
                kind: .photo,
                originalData: captured.jpegData,
                originalExtension: "jpg",
                thumbnailData: thumbnailData,
                width: captured.image.cgImage?.width,
                height: captured.image.cgImage?.height,
                modeSnapshot: snapshot,
                requestID: requestID,
                linkedUserMessageID: userMessageID
            )
            currentMediaItem = item
            print("[OpenClawQuickShot][INFO] 사진 보호 저장 완료 bytes=\(captured.jpegData.count)")

            item = await exportPhoto(captured.jpegData, item: item)
            try Task.checkCancellation()
            await analyze(
                jpegData: captured.jpegData,
                prompt: snapshot.prompt,
                requestID: requestID,
                userMessageID: userMessageID,
                item: item
            )
        } catch is CancellationError {
            state = .cancelled
        } catch {
            await fail(error, mediaID: currentMediaItem?.id)
        }
        await stopOwnedStreamIfNeeded()
    }

    private func beginVideo(snapshot: OpenClawCaptureModeExecutionSnapshot) async {
        do {
            state = .preparing
            try await prepareStream()
            try Task.checkCancellation()

            let recorder = OpenClawVideoRecorder()
            recorder.onFrameDropped = { [weak self] in
                Task { @MainActor in self?.droppedFrameCount += 1 }
            }
            recorder.onLimitReached = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.streamViewModel.stopRecordingFrames(owner: .openClawQuickShot)
                    self.recordingTimerTask?.cancel()
                    self.recordingTimerTask = nil
                }
            }
            recorder.onAutoFinalized = { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.beginVideoFinalizationIfNeeded() else { return }
                    self.operationTask = Task { [weak self] in
                        await self?.finishVideo()
                    }
                }
            }
            try recorder.start()
            self.recorder = recorder
            recordingStartUptime = ProcessInfo.processInfo.systemUptime
            recordedDuration = 0
            sampledFrames = []

            try streamViewModel.startRecordingFrames(
                owner: .openClawQuickShot,
                maximumFrameRate: OpenClawVideoRecorder.maxInputFPS
            ) { [weak self, weak recorder] image, uptime in
                recorder?.appendFrame(image, hostTime: uptime)
                Task { @MainActor in
                    self?.sampleFrame(image, uptime: uptime)
                }
            }

            state = .recording(elapsed: 0)
            startRecordingTimer()
        } catch is CancellationError {
            state = .cancelled
            await stopOwnedStreamIfNeeded()
        } catch {
            await fail(error, mediaID: nil)
            await stopOwnedStreamIfNeeded()
        }
    }

    private func finishVideo() async {
        guard let snapshot = selectedSnapshot,
              let requestID = videoRequestID,
              let userMessageID = videoUserMessageID else {
            await fail(OpenClawVideoRecorderError.notRecording, mediaID: nil)
            return
        }
        let finalizedResult: Result<URL, OpenClawVideoRecorderError>
        if let recorder {
            do {
                finalizedResult = .success(try await recorder.finalize())
            } catch let error as OpenClawVideoRecorderError {
                finalizedResult = .failure(error)
            } catch {
                finalizedResult = .failure(.writerFailed(error.localizedDescription))
            }
        } else {
            finalizedResult = .failure(.notRecording)
        }

        do {
            recordedDuration = min(
                recordingStartUptime.map {
                    ProcessInfo.processInfo.systemUptime - $0
                } ?? recordedDuration,
                OpenClawVideoRecorder.maxDuration
            )
            state = .saving
            let fileURL = try finalizedResult.get()

            let orderedFrames = sampledFrames
                .sorted { $0.time < $1.time }
                .map(\.image)
            let contactSheetData = try await OpenClawVideoContactSheetBuilder
                .buildJPEGDataOffMain(from: orderedFrames)
            guard let contactSheetImage = UIImage(data: contactSheetData) else {
                throw OpenClawConversationError.invalidImage
            }
            let duration = min(
                recordedDuration,
                OpenClawVideoRecorder.maxDuration
            )
            var item = try await repository.addItem(
                kind: .video,
                originalFileURL: fileURL,
                originalExtension: "mp4",
                thumbnailData: makeThumbnailJPEG(from: contactSheetImage),
                width: sampledFrames.first?.image.cgImage?.width,
                height: sampledFrames.first?.image.cgImage?.height,
                durationSeconds: duration,
                modeSnapshot: snapshot,
                requestID: requestID,
                linkedUserMessageID: userMessageID
            )
            currentMediaItem = item

            item = await exportVideo(item: item)
            try Task.checkCancellation()
            let prompt = videoAnalysisPrompt(
                basePrompt: snapshot.prompt,
                duration: duration,
                frameCount: orderedFrames.count
            )
            await analyze(
                jpegData: contactSheetData,
                prompt: prompt,
                requestID: requestID,
                userMessageID: userMessageID,
                item: item
            )
        } catch is CancellationError {
            state = .cancelled
        } catch {
            await fail(error, mediaID: currentMediaItem?.id)
        }

        if Task.isCancelled,
           case .success(let temporaryURL) = finalizedResult,
           currentMediaItem == nil {
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        recorder = nil
        videoRequestID = nil
        videoUserMessageID = nil
        sampledFrames.removeAll(keepingCapacity: false)
        await stopOwnedStreamIfNeeded()
    }

    private func prepareStream() async throws {
        guard streamViewModel.hasActiveDevice else {
            throw StreamCaptureError.captureInterrupted
        }
        streamStartedByQuickShot = !streamViewModel.isStreaming
        if streamStartedByQuickShot {
            await streamViewModel.handleStartStreaming()
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            try Task.checkCancellation()
            if streamViewModel.streamingStatus == .streaming,
               streamViewModel.currentVideoFrame != nil {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StreamCaptureError.captureInterrupted
    }

    private func exportPhoto(
        _ jpegData: Data,
        item: OpenClawMediaItem
    ) async -> OpenClawMediaItem {
        state = .exportingToPhotos
        _ = try? await repository.updatePhotosStatus(id: item.id, status: .pending)
        do {
            _ = try await photoLibrarySaver.saveJPEG(jpegData)
            return (try? await repository.updatePhotosStatus(id: item.id, status: .saved)) ?? item
        } catch PhotoLibrarySaverError.permissionDenied,
                PhotoLibrarySaverError.permissionRestricted {
            return (try? await repository.updatePhotosStatus(id: item.id, status: .permissionDenied)) ?? item
        } catch {
            return (try? await repository.updatePhotosStatus(id: item.id, status: .failed)) ?? item
        }
    }

    private func exportVideo(item: OpenClawMediaItem) async -> OpenClawMediaItem {
        state = .exportingToPhotos
        _ = try? await repository.updatePhotosStatus(id: item.id, status: .pending)
        do {
            let url = await repository.originalURL(for: item)
            _ = try await photoLibrarySaver.saveMP4(fileURL: url)
            return (try? await repository.updatePhotosStatus(id: item.id, status: .saved)) ?? item
        } catch PhotoLibrarySaverError.permissionDenied,
                PhotoLibrarySaverError.permissionRestricted {
            return (try? await repository.updatePhotosStatus(id: item.id, status: .permissionDenied)) ?? item
        } catch {
            return (try? await repository.updatePhotosStatus(id: item.id, status: .failed)) ?? item
        }
    }

    private func analyze(
        jpegData: Data,
        prompt: String,
        requestID: UUID,
        userMessageID: UUID,
        item: OpenClawMediaItem
    ) async {
        do {
            state = .sending
            _ = try await repository.updateAnalysisStatus(id: item.id, status: .pending)
            _ = try await repository.updateDeliveryStatus(id: item.id, status: .sending)
            state = .awaitingResponse
            let result = try await openClawService.sendConversation(
                prompt,
                imageJPEGData: jpegData,
                owner: .quickShot,
                requestID: requestID,
                idempotencyKey: requestID,
                userMessageID: userMessageID
            )
            _ = try await repository.updateDeliveryStatus(id: item.id, status: .delivered)
            _ = try await repository.updateAnalysisStatus(id: item.id, status: .completed)
            let linked = try await repository.linkMessages(
                id: item.id,
                userMessageID: result.receipt.userMessageID,
                assistantMessageID: result.assistantMessageID
            )
            currentMediaItem = linked
            state = .completed(
                mediaID: item.id,
                assistantMessageID: result.assistantMessageID
            )
        } catch OpenClawConversationError.deliveryAmbiguous {
            _ = try? await repository.updateDeliveryStatus(id: item.id, status: .ambiguous)
            _ = try? await repository.updateAnalysisStatus(id: item.id, status: .failed)
            state = .failed(
                message: OpenClawConversationError.deliveryAmbiguous.localizedDescription,
                mediaID: item.id,
                deliveryAmbiguous: true
            )
        } catch {
            _ = try? await repository.updateDeliveryStatus(id: item.id, status: .failed)
            _ = try? await repository.updateAnalysisStatus(id: item.id, status: .failed)
            state = .failed(
                message: error.localizedDescription,
                mediaID: item.id,
                deliveryAmbiguous: false
            )
        }
    }

    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let start = self.recordingStartUptime ?? ProcessInfo.processInfo.systemUptime
                let elapsed = min(
                    ProcessInfo.processInfo.systemUptime - start,
                    OpenClawVideoRecorder.maxDuration
                )
                self.recordedDuration = elapsed
                if case .recording = self.state {
                    self.state = .recording(elapsed: elapsed)
                }
                if elapsed >= OpenClawVideoRecorder.maxDuration { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func sampleFrame(_ image: UIImage, uptime: TimeInterval) {
        guard case .recording = state else { return }
        let start = recordingStartUptime ?? uptime
        let elapsed = max(0, uptime - start)
        recordedDuration = min(elapsed, OpenClawVideoRecorder.maxDuration)

        sampledFrames.append((elapsed, image))
        guard sampledFrames.count > 6 else { return }

        // Keep the first and latest observations, then remove the interior frame whose
        // neighboring time span is smallest. Repeating this online compaction keeps six
        // bounded frames distributed across the actual clip length without buffering the
        // full video or assuming the user records for the full ten-second limit.
        var removalIndex = 1
        var smallestMergedSpan = TimeInterval.greatestFiniteMagnitude
        for index in 1..<(sampledFrames.count - 1) {
            let mergedSpan = sampledFrames[index + 1].time
                - sampledFrames[index - 1].time
            if mergedSpan < smallestMergedSpan {
                smallestMergedSpan = mergedSpan
                removalIndex = index
            }
        }
        sampledFrames.remove(at: removalIndex)
    }

    private func stopOwnedStreamIfNeeded() async {
        guard streamStartedByQuickShot else { return }
        streamStartedByQuickShot = false
        await streamViewModel.stopSession()
    }

    private func resetOperationState() {
        operationTask?.cancel()
        operationTask = nil
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        currentMediaItem = nil
        recordedDuration = 0
        droppedFrameCount = 0
        sampledFrames.removeAll(keepingCapacity: false)
        isVideoFinalizationStarted = false
        videoRequestID = nil
        videoUserMessageID = nil
        streamStartedByQuickShot = false
    }

    private func beginVideoFinalizationIfNeeded() -> Bool {
        guard !isVideoFinalizationStarted else { return false }
        isVideoFinalizationStarted = true
        return true
    }

    private func fail(_ error: Error, mediaID: UUID?) async {
        state = .failed(
            message: error.localizedDescription,
            mediaID: mediaID,
            deliveryAmbiguous: false
        )
    }

    private func makeThumbnailJPEG(from image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let maxEdge: CGFloat = 1280
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.88)
    }

    private func videoAnalysisPrompt(
        basePrompt: String,
        duration: TimeInterval,
        frameCount: Int
    ) -> String {
        let roundedDuration = String(format: "%.1f", duration)
        return basePrompt
            + "\n\n중요: 첨부 이미지는 전체 동영상 파일이 아니라 동영상에서 시간 순서로 추출한 대표 프레임 "
            + "\(frameCount)개를 합친 contact sheet입니다. 대표 프레임 기반 분석임을 답변에 명시하고, "
            + "약 \(roundedDuration)초 구간에서 관찰 가능한 내용만 설명하세요. 프레임 사이의 동작이나 소리는 추정하지 마세요."
    }
}
