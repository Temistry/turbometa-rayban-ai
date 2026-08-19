/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import MWDATCamera
import MWDATCore
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "StreamSession")

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamCaptureOwner: String {
  case manual
  case quickVision
  case openClawQuickShot
}

private enum StreamCaptureKind: Equatable {
  case photo
  case recording
}

struct StreamCapturedPhoto {
  let image: UIImage
  let jpegData: Data
}

enum StreamCaptureError: LocalizedError, Equatable {
  case captureBusy
  case photoTimeout
  case photoDecodingFailed
  case captureInterrupted

  var errorDescription: String? {
    switch self {
    case .captureBusy:
      return "다른 촬영 작업이 진행 중입니다. 잠시 후 다시 시도하세요."
    case .photoTimeout:
      return "사진 촬영 시간이 초과되었습니다. 다시 시도하세요."
    case .photoDecodingFailed:
      return "촬영한 사진을 처리하지 못했습니다. 다시 시도하세요."
    case .captureInterrupted:
      return "촬영 연결이 중단되었습니다. 다시 시도하세요."
    }
  }
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  // Timer properties
  @Published var activeTimeLimit: StreamTimeLimit = .noLimit
  @Published var remainingTime: TimeInterval = 0

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showVisionRecognition: Bool = false
  @Published var showLeanEat: Bool = false

  private var timerTask: Task<Void, Never>?
  // The core DAT SDK StreamSession - handles all streaming operations
  // IMPORTANT: SDK requires ONE session instance, reused with start()/stop()
  private var streamSession: StreamSession
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var isProcessingFrame = false
  private var captureOwner: StreamCaptureOwner?
  private var captureKind: StreamCaptureKind?
  private var photoCaptureContinuation: CheckedContinuation<StreamCapturedPhoto, Error>?
  private var photoCaptureTimeoutTask: Task<Void, Never>?
  private var recordingFrameHandler: ((UIImage, TimeInterval) -> Void)?
  private var lastRecordingFrameUptime: TimeInterval = 0
  private var recordingFrameInterval: TimeInterval = 1.0 / 15.0

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    logger.info("🟢 StreamSessionViewModel init")
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    // Get saved video quality setting from UserDefaults (only read at init)
    let savedQuality = UserDefaults.standard.string(forKey: "video_quality") ?? "medium"
    let resolution: StreamingResolution
    switch savedQuality {
    case "low":
      resolution = .low
    case "high":
      resolution = .high
    default:
      resolution = .medium
    }
    logger.info("🟢 Using video quality: \(savedQuality) -> \(String(describing: resolution))")

    // Create ONE session at init - SDK pattern requires reusing same session
    let config = StreamSessionConfig(
      videoCodec: VideoCodec.raw,
      resolution: resolution,
      frameRate: 24)
    streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
    logger.info("🟢 StreamSession created")

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in deviceSelector.activeDeviceStream() {
        logger.info("📱 Device changed: \(device != nil ? "connected" : "disconnected")")
        self.hasActiveDevice = device != nil
      }
    }

    // Subscribe to session state changes
    stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        logger.info("📊 State changed: \(String(describing: state))")
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames (skip if previous frame still processing)
    videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self, !self.isProcessingFrame else { return }
        self.isProcessingFrame = true
        defer { self.isProcessingFrame = false }

        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            logger.info("🎥 First frame received and converted")
            self.hasReceivedFirstFrame = true
          }

          if let recordingFrameHandler = self.recordingFrameHandler {
            let uptime = ProcessInfo.processInfo.systemUptime
            if uptime - self.lastRecordingFrameUptime >= self.recordingFrameInterval {
              self.lastRecordingFrameUptime = uptime
              recordingFrameHandler(image, uptime)
            }
          }
        }
      }
    }

    // Subscribe to errors
    errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        logger.error("❌ Stream error: \(String(describing: error))")
        if self.captureOwner != nil {
          self.interruptCapture()
        }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    // Subscribe to photo capture
    photoDataListenerToken = streamSession.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        logger.info("📸 Photo captured - size: \(photoData.data.count) bytes")
        guard let owner = self.captureOwner, self.captureKind == .photo else {
          logger.warning("📸 Ignoring photo data without an active photo capture")
          return
        }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.finishPhotoCapture(
            with: .success(StreamCapturedPhoto(image: uiImage, jpegData: photoData.data))
          )
          self.showPhotoPreview = owner == .manual
        } else {
          logger.error("📸 Captured photo could not be decoded")
          self.finishPhotoCapture(with: .failure(StreamCaptureError.photoDecodingFailed))
        }
      }
    }

    updateStatusFromState(streamSession.state)
    logger.info("🟢 StreamSessionViewModel init complete")
  }

  func handleStartStreaming() async {
    logger.info("▶️ handleStartStreaming called")
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      logger.info("▶️ Permission status: \(String(describing: status))")
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      logger.info("▶️ Permission request result: \(String(describing: requestStatus))")
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      logger.error("❌ Permission error: \(error.localizedDescription)")
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    logger.info("🚀 startSession START")

    // Reset to unlimited time when starting a new stream
    activeTimeLimit = .noLimit
    remainingTime = 0
    stopTimer()

    // Reset frame state
    hasReceivedFirstFrame = false

    logger.info("🚀 Calling session.start()...")
    await streamSession.start()
    logger.info("🚀 startSession END - session.start() returned")
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    logger.info("⏹️ stopSession START")
    stopTimer()
    if captureOwner != nil {
      interruptCapture()
    }
    await streamSession.stop()
    logger.info("⏹️ stopSession END")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func setTimeLimit(_ limit: StreamTimeLimit) {
    activeTimeLimit = limit
    remainingTime = limit.durationInSeconds ?? 0

    if limit.isTimeLimited {
      startTimer()
    } else {
      stopTimer()
    }
  }

  func capturePhoto() async {
    do {
      _ = try await capturePhotoResult(owner: .manual)
    } catch is CancellationError {
      return
    } catch {
      logger.error("📸 Manual photo capture failed: \(error.localizedDescription)")
      showError(error.localizedDescription)
    }
  }

  func capturePhoto(
    owner: StreamCaptureOwner,
    timeout: TimeInterval = 4
  ) async throws -> UIImage {
    try await capturePhotoResult(owner: owner, timeout: timeout).image
  }

  func capturePhotoResult(
    owner: StreamCaptureOwner,
    timeout: TimeInterval = 4
  ) async throws -> StreamCapturedPhoto {
    guard captureOwner == nil, photoCaptureContinuation == nil else {
      throw StreamCaptureError.captureBusy
    }

    captureOwner = owner
    captureKind = .photo
    capturedPhoto = nil
    showPhotoPreview = false
    let boundedTimeout = timeout.isFinite ? min(max(timeout, 0.5), 60) : 4

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        photoCaptureContinuation = continuation
        photoCaptureTimeoutTask?.cancel()
        photoCaptureTimeoutTask = Task { @MainActor [weak self] in
          try? await Task.sleep(
            nanoseconds: UInt64(boundedTimeout * 1_000_000_000)
          )
          guard !Task.isCancelled else { return }
          self?.finishPhotoCapture(with: .failure(StreamCaptureError.photoTimeout))
        }
        streamSession.capturePhoto(format: .jpeg)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.finishPhotoCapture(with: .failure(CancellationError()))
      }
    }
  }

  // The handler runs on the main actor; it must enqueue encoding work and return immediately.
  func startRecordingFrames(
    owner: StreamCaptureOwner,
    maximumFrameRate: Double = 15,
    handler: @escaping (UIImage, TimeInterval) -> Void
  ) throws {
    guard captureOwner == nil, recordingFrameHandler == nil else {
      throw StreamCaptureError.captureBusy
    }

    let boundedFrameRate = maximumFrameRate.isFinite
      ? min(max(maximumFrameRate, 1), 15)
      : 15
    captureOwner = owner
    captureKind = .recording
    recordingFrameInterval = 1.0 / boundedFrameRate
    lastRecordingFrameUptime = 0
    recordingFrameHandler = handler
  }

  func stopRecordingFrames(owner: StreamCaptureOwner) {
    guard captureOwner == owner, captureKind == .recording else { return }
    recordingFrameHandler = nil
    lastRecordingFrameUptime = 0
    captureKind = nil
    captureOwner = nil
  }

  func cancelCapture(owner: StreamCaptureOwner) {
    guard captureOwner == owner else { return }
    switch captureKind {
    case .photo:
      finishPhotoCapture(with: .failure(CancellationError()))
    case .recording:
      stopRecordingFrames(owner: owner)
    case nil:
      captureOwner = nil
    }
  }

  private func finishPhotoCapture(with result: Result<StreamCapturedPhoto, Error>) {
    guard captureKind == .photo else { return }
    photoCaptureTimeoutTask?.cancel()
    photoCaptureTimeoutTask = nil
    let continuation = photoCaptureContinuation
    photoCaptureContinuation = nil
    captureKind = nil
    captureOwner = nil
    continuation?.resume(with: result)
  }

  private func interruptCapture(
    photoError: Error = StreamCaptureError.captureInterrupted
  ) {
    switch captureKind {
    case .photo:
      finishPhotoCapture(with: .failure(photoError))
    case .recording:
      recordingFrameHandler = nil
      lastRecordingFrameUptime = 0
      captureKind = nil
      captureOwner = nil
    case nil:
      captureOwner = nil
    }
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func startTimer() {
    stopTimer()
    timerTask = Task { @MainActor [weak self] in
      while let self, remainingTime > 0 {
        try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        guard !Task.isCancelled else { break }
        remainingTime -= 1
      }
      if let self, !Task.isCancelled {
        await stopSession()
      }
    }
  }

  private func stopTimer() {
    timerTask?.cancel()
    timerTask = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    logger.info("📊 updateStatusFromState: \(String(describing: state)) -> streamingStatus update")
    switch state {
    case .stopped:
      logger.info("📊 State is STOPPED - clearing frame")
      currentVideoFrame = nil
      streamingStatus = .stopped
      if captureOwner != nil {
        interruptCapture()
      }
    case .waitingForDevice, .starting, .stopping, .paused:
      logger.info("📊 State is WAITING (\(String(describing: state)))")
      streamingStatus = .waiting
    case .streaming:
      logger.info("📊 State is STREAMING ✅")
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "Glasses hinges are closed. Please open them to continue."
    case .thermalCritical:
      return "Device temperature is too high. Streaming paused."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }

  /// Full cleanup of all resources - call when ViewModel is no longer needed
  func cleanup() async {
    logger.info("🔴 cleanup START")
    stopTimer()
    interruptCapture(photoError: CancellationError())
    deviceMonitorTask?.cancel()
    deviceMonitorTask = nil
    await streamSession.stop()
    // Clear listeners
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
    logger.info("🔴 cleanup END")
  }
}
