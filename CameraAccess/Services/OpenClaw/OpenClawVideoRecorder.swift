/*
 * OpenClaw Video Recorder
 * UIImage frame stream을 제한된 H.264 MP4로 기록한다.
 *
 * 녹화는 최대 10초, 입력은 최대 30fps이며 writer backpressure 시 frame을
 * 버린다. 30MiB는 encoder/muxer flush 특성상 soft budget이고 완료 후 실제
 * 파일 크기를 다시 확인할 수 있다.
 */

import Foundation
import AVFoundation
import CoreVideo
import QuartzCore
import UIKit
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "OpenClawVideoRecorder")

// MARK: - Errors

enum OpenClawVideoRecorderError: LocalizedError, Equatable, Sendable {
    case alreadyRecording
    case notRecording
    case cancelled
    case setupFailed(String)
    case writerFailed(String)
    case noFramesRecorded
    case recordingTooShort

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "video.recorder.error.alreadyrecording".localized
        case .notRecording:
            return "video.recorder.error.notrecording".localized
        case .cancelled:
            return "video.recorder.error.cancelled".localized
        case .setupFailed:
            return "video.recorder.error.setup".localized
        case .writerFailed:
            return "video.recorder.error.writer".localized
        case .noFramesRecorded:
            return "video.recorder.error.noframes".localized
        case .recordingTooShort:
            return "video.recorder.error.tooshort".localized
        }
    }
}

// MARK: - State

enum OpenClawVideoRecorderState: Equatable, Sendable {
    case idle
    case recording
    case finalizing
    case finished
    case cancelled
    case failed(String)
}

/// Reason an in-progress recording was auto-stopped by the recorder itself.
enum OpenClawVideoRecorderLimit: Sendable {
    case duration
    case fileSize
}

// MARK: - Recorder

/// Records a bounded video clip from a stream of already-decoded `UIImage` frames using
/// `AVAssetWriter`.
///
/// Limits enforced by this recorder:
/// - Duration: `maxDuration` seconds (10s) — a hard cap. Elapsed time is measured from the
///   first accepted frame's presentation time; once `elapsedSeconds >= maxDuration`, no further
///   frames are appended and auto-finalization begins on the very next check.
/// - Input rate: `maxInputFPS` fps (30) — a hard cap on what is *appended*. Frames arriving
///   closer together than `1/maxInputFPS` are dropped before ever reaching the encoder, never
///   queued or buffered.
/// - Output size: `maxFileSizeBytes` (30 MiB) — a **soft, best-effort** budget, not a byte-exact
///   guarantee. Two mechanisms work together to keep actual output close to this budget:
///   1. Proactive: the H.264 `AVVideoCompressionPropertiesKey` average bit rate is computed from
///      `maxFileSizeBytes` and `maxDuration` (with a safety margin) so the encoder targets a
///      size that fits the budget by construction if the clip runs its full duration.
///   2. Reactive: on-disk file size is checked after every appended frame, and auto-finalization
///      is triggered the moment the check observes `size >= maxFileSizeBytes`.
///   Because `AVAssetWriter` performs internal buffering/interleaving and `finishWriting`
///   flushes additional muxed data after the last check, actual final file size can exceed
///   `maxFileSizeBytes` by a small margin (typically well under one GOP's worth of data). Callers
///   that need a byte-exact hard cap must re-check `OpenClawMediaRepository`'s stored file size
///   after `finalize()`/`addItem` and reject/re-encode if still over their own hard limit.
///
/// `appendFrame` is safe to call from the main actor: it does a cheap timestamp check and then
/// dispatches the actual pixel buffer creation + `AVAssetWriter` append onto a private
/// background queue, so it never blocks the caller on encoding work. Frames are dropped
/// (never queued or blocked on) whenever the writer isn't ready for more data — this recorder
/// always prefers dropping frames over growing memory or stalling the caller.
final class OpenClawVideoRecorder: @unchecked Sendable {

    // MARK: - Limits

    static let maxDuration: TimeInterval = 10
    static let maxInputFPS: Double = 30
    static let minimumDuration: TimeInterval = 0.5
    /// Soft output-size budget in bytes — see the type-level doc comment for exactly what this
    /// does and does not guarantee.
    static let maxFileSizeBytes: Int = 30 * 1024 * 1024 // 30 MiB
    /// Safety margin applied when deriving the proactive target bit rate from
    /// `maxFileSizeBytes`/`maxDuration`, so the *targeted* encoder output sits comfortably under
    /// budget even before the reactive per-frame size check ever needs to fire.
    private static let bitRateSafetyMargin: Double = 0.85

    // MARK: - Callbacks (invoked on an arbitrary background queue — hop to @MainActor yourself)

    /// Called each time an incoming frame is dropped (rate-limited or writer-not-ready).
    var onFrameDropped: (@Sendable () -> Void)? {
        get { withStateLock { _onFrameDropped } }
        set { withStateLock { _onFrameDropped = newValue } }
    }
    /// Called once, right when a hard limit is hit and auto-finalization begins.
    var onLimitReached: (@Sendable (OpenClawVideoRecorderLimit) -> Void)? {
        get { withStateLock { _onLimitReached } }
        set { withStateLock { _onLimitReached = newValue } }
    }
    /// Called once auto-finalization (triggered by a limit) completes, with the resulting file
    /// or the failure. A caller-driven `finalize()` made after the limit was claimed awaits this
    /// same cached result; the callback remains available for immediate UI notification.
    var onAutoFinalized: (@Sendable (Result<URL, OpenClawVideoRecorderError>) -> Void)? {
        get { withStateLock { _onAutoFinalized } }
        set { withStateLock { _onAutoFinalized = newValue } }
    }

    private var _onFrameDropped: (@Sendable () -> Void)?
    private var _onLimitReached: (@Sendable (OpenClawVideoRecorderLimit) -> Void)?
    private var _onAutoFinalized: (@Sendable (Result<URL, OpenClawVideoRecorderError>) -> Void)?

    // MARK: - State

    var state: OpenClawVideoRecorderState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    private let stateLock = NSLock()
    private var _state: OpenClawVideoRecorderState = .idle
    private var finalizationStarted = false
    private var finalizationResult:
        Result<URL, OpenClawVideoRecorderError>?
    private var finalizationWaiters: [
        CheckedContinuation<URL, Error>
    ] = []

    // MARK: - Encoding pipeline (confined to encodingQueue)

    private let encodingQueue = DispatchQueue(label: "com.smartview.glassai.openclaw.videorecorder")

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?

    private var recordingStartHostTime: CFTimeInterval?
    private var lastAcceptedHostTime: CFTimeInterval?
    private var lastPresentationTime: CMTime = .zero
    private var frameCount = 0
    private var videoWidth = 0
    private var videoHeight = 0

    private let minFrameInterval: CFTimeInterval = 1.0 / OpenClawVideoRecorder.maxInputFPS

    init() {}

    // MARK: - Public API

    /// Starts a new recording session, writing to a fresh temp file. Throws if a recording is
    /// already in progress. The output frame size is established lazily from the first frame
    /// passed to `appendFrame`.
    func start() throws {
        guard claimStart() else {
            throw OpenClawVideoRecorderError.alreadyRecording
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclaw-rec-\(UUID().uuidString)")
            .appendingPathExtension("mp4")

        do {
            try encodingQueue.sync {
                let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)
                assetWriter = writer
                outputURL = tempURL
                videoInput = nil
                pixelBufferAdaptor = nil
                recordingStartHostTime = nil
                lastAcceptedHostTime = nil
                lastPresentationTime = .zero
                frameCount = 0
                videoWidth = 0
                videoHeight = 0
            }
        } catch {
            setState(.failed(error.localizedDescription))
            throw OpenClawVideoRecorderError.setupFailed(error.localizedDescription)
        }

        guard state == .recording else {
            encodingQueue.async { [weak self] in
                guard let self else { return }
                self.assetWriter?.cancelWriting()
                if let outputURL = self.outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                self.assetWriter = nil
                self.outputURL = nil
            }
            throw OpenClawVideoRecorderError.notRecording
        }

        logger.info("Recording session started")
    }

    /// Appends a decoded frame. Frames arriving faster than `maxInputFPS`, or while the writer
    /// isn't ready for more data, are dropped. Never blocks the caller on encoding work.
    func appendFrame(_ image: UIImage) {
        appendFrame(image, hostTime: CACurrentMediaTime())
    }

    func appendFrame(_ image: UIImage, hostTime: CFTimeInterval) {
        guard state == .recording else { return }

        encodingQueue.async { [weak self] in
            self?.encodeAndAppend(image, hostTime: hostTime)
        }
    }

    /// Stops recording, finalizes the MP4 container, and returns the output file URL. The
    /// caller owns the file afterward (e.g. hand it to
    /// `OpenClawMediaRepository.addItem(originalFileURL:...)`); it lives in the temp directory
    /// until moved or removed. If a recorder limit already started finalization, this method
    /// awaits that same shared result instead of racing the auto-finalization callback.
    func finalize() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let registration = withStateLock {
                () -> (
                    shouldStart: Bool,
                    immediate: Result<URL, OpenClawVideoRecorderError>?
                ) in
                if let finalizationResult {
                    return (false, finalizationResult)
                }

                switch _state {
                case .recording:
                    _state = .finalizing
                    finalizationStarted = true
                    finalizationWaiters.append(continuation)
                    return (true, nil)
                case .finalizing where finalizationStarted:
                    finalizationWaiters.append(continuation)
                    return (false, nil)
                case .cancelled:
                    return (false, .failure(.cancelled))
                case .idle, .finalizing, .finished, .failed:
                    return (false, .failure(.notRecording))
                }
            }

            if let immediate = registration.immediate {
                resume(continuation, with: immediate)
            } else if registration.shouldStart {
                encodingQueue.async { [self] in
                    finishWritingLocked { [self] result in
                        completeFinalization(result)
                    }
                }
            }
        }
    }

    /// Stops an active recording and deletes its partial output. If finalization has already
    /// started, the writer cannot be cancelled safely; the finalized temp file is deleted from
    /// the writer completion instead and the pending completion receives cancellation.
    func cancel() {
        let previousState = withStateLock { () -> OpenClawVideoRecorderState? in
            switch _state {
            case .recording, .finalizing:
                let previous = _state
                _state = .cancelled
                return previous
            case .idle, .finished, .cancelled, .failed:
                return nil
            }
        }
        guard let previousState else { return }

        if previousState == .recording {
            encodingQueue.async { [weak self] in
                guard let self else { return }
                self.assetWriter?.cancelWriting()
                if let outputURL = self.outputURL {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                self.clearWriterReferencesLocked()
                self.completeFinalization(.failure(.cancelled))
            }
        }
        logger.info("Recording cancelled")
    }

    // MARK: - Private (encodingQueue-confined)

    private func encodeAndAppend(_ image: UIImage, hostTime: CFTimeInterval) {
        guard state == .recording else { return }

        if let last = lastAcceptedHostTime, hostTime - last < minFrameInterval {
            callbackSnapshot().frameDropped?()
            return
        }

        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return }

        if videoInput == nil {
            guard configureWriterInput(width: cgImage.width, height: cgImage.height) else { return }
        }

        guard let input = videoInput else { return }

        guard input.isReadyForMoreMediaData else {
            callbackSnapshot().frameDropped?()
            return
        }

        guard let pixelBuffer = makePixelBuffer(from: cgImage, width: videoWidth, height: videoHeight) else {
            return
        }

        if recordingStartHostTime == nil {
            recordingStartHostTime = hostTime
        }
        let elapsedSeconds = hostTime - (recordingStartHostTime ?? hostTime)
        let presentationTime = CMTime(seconds: elapsedSeconds, preferredTimescale: 600)

        guard let adaptor = pixelBufferAdaptor,
              adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            logger.warning("Pixel buffer append failed")
            return
        }

        lastAcceptedHostTime = hostTime
        lastPresentationTime = presentationTime
        frameCount += 1

        checkLimits(elapsedSeconds: elapsedSeconds)
    }

    private func configureWriterInput(width: Int, height: Int) -> Bool {
        guard let writer = assetWriter else { return false }

        videoWidth = width
        videoHeight = height

        // Derive a proactive target average bit rate from the size/duration budget so the
        // encoder aims comfortably under maxFileSizeBytes by construction, rather than relying
        // solely on the reactive post-hoc file-size check to catch overruns.
        let targetBitsPerSecond = Int(
            (Double(Self.maxFileSizeBytes) * 8.0 / Self.maxDuration) * Self.bitRateSafetyMargin
        )
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitsPerSecond,
            AVVideoExpectedSourceFrameRateKey: Int(Self.maxInputFPS),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        guard writer.canAdd(input) else {
            setState(.failed("Writer cannot accept video input"))
            return false
        }
        writer.add(input)

        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "startWriting failed"
            setState(.failed(message))
            return false
        }
        writer.startSession(atSourceTime: .zero)

        videoInput = input
        pixelBufferAdaptor = adaptor
        return true
    }

    private func makePixelBuffer(from cgImage: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        guard let pool = pixelBufferAdaptor?.pixelBufferPool else { return nil }

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Reactive limit check, run after every appended frame. This is a best-effort backstop —
    /// see the type-level doc comment on `maxFileSizeBytes` for why the file-size branch cannot
    /// guarantee the final output never exceeds the budget (checked incrementally, but
    /// `AVAssetWriter` may flush additional buffered/muxed data after the last frame and during
    /// `finishWriting`). The proactive bit-rate target configured in `configureWriterInput` is
    /// what keeps normal-duration recordings under budget by construction; this check exists to
    /// stop pathological cases (e.g. an unexpectedly high-entropy scene) from growing unbounded.
    private func checkLimits(elapsedSeconds: CFTimeInterval) {
        if elapsedSeconds >= Self.maxDuration {
            autoFinalize(reason: .duration)
            return
        }

        if let outputURL,
           let size = try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int,
           size >= Self.maxFileSizeBytes {
            autoFinalize(reason: .fileSize)
        }
    }

    /// Triggered internally (already on encodingQueue) when a hard limit is hit mid-recording.
    private func autoFinalize(reason: OpenClawVideoRecorderLimit) {
        let didStart = withStateLock {
            guard _state == .recording,
                  !finalizationStarted else { return false }
            _state = .finalizing
            finalizationStarted = true
            return true
        }
        guard didStart else { return }

        let callbacks = callbackSnapshot()
        callbacks.limitReached?(reason)
        finishWritingLocked { [self] result in
            completeFinalization(result)
            callbacks.autoFinalized?(result)
        }
    }

    /// Shared finish path for both caller-driven `finalize()` and internal `autoFinalize`.
    /// Must be called on `encodingQueue`.
    private func finishWritingLocked(
        completion: @escaping @Sendable (Result<URL, OpenClawVideoRecorderError>) -> Void
    ) {
        guard let writer = assetWriter, let outputURL = outputURL else {
            setState(.failed("No active writer"))
            completion(.failure(.writerFailed("No active writer")))
            return
        }

        guard frameCount > 0 else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            setState(.failed("No frames recorded"))
            completion(.failure(.noFramesRecorded))
            return
        }

        guard lastPresentationTime.seconds >= Self.minimumDuration else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            setState(.failed("Recording too short"))
            completion(.failure(.recordingTooShort))
            return
        }

        videoInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(.writerFailed("Recorder deallocated")))
                return
            }

            self.encodingQueue.async {
                if self.state == .cancelled {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.clearWriterReferencesLocked()
                    completion(.failure(.cancelled))
                } else if writer.status == .completed {
                    self.setState(.finished)
                    logger.info("Recording finalized")
                    completion(.success(outputURL))
                } else {
                    let message = writer.error?.localizedDescription ?? "Unknown writer error"
                    self.setState(.failed(message))
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(.failure(.writerFailed(message)))
                }
            }
        }
    }

    private func clearWriterReferencesLocked() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil
    }

    private func completeFinalization(
        _ result: Result<URL, OpenClawVideoRecorderError>
    ) {
        let waiters: [CheckedContinuation<URL, Error>] =
            withStateLock {
                guard finalizationResult == nil else { return [] }
                finalizationResult = result
                let waiters = finalizationWaiters
                finalizationWaiters.removeAll(keepingCapacity: false)
                return waiters
            }
        waiters.forEach { resume($0, with: result) }
    }

    private func resume(
        _ continuation: CheckedContinuation<URL, Error>,
        with result: Result<URL, OpenClawVideoRecorderError>
    ) {
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func claimStart() -> Bool {
        withStateLock {
            guard _state != .recording, _state != .finalizing else {
                return false
            }
            _state = .recording
            finalizationStarted = false
            finalizationResult = nil
            finalizationWaiters.removeAll(keepingCapacity: false)
            return true
        }
    }

    private func callbackSnapshot() -> (
        frameDropped: (@Sendable () -> Void)?,
        limitReached: (@Sendable (OpenClawVideoRecorderLimit) -> Void)?,
        autoFinalized: (@Sendable (Result<URL, OpenClawVideoRecorderError>) -> Void)?
    ) {
        withStateLock {
            (_onFrameDropped, _onLimitReached, _onAutoFinalized)
        }
    }

    private func setState(_ newState: OpenClawVideoRecorderState) {
        withStateLock {
            _state = newState
        }
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}
