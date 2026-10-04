/*
 * Ray-Ban Meta 영상 RTMP 송출 서비스
 * HaishinKit을 사용해 H.264 스트림을 전송한다.
 * 스트림 키와 전체 송출 URL은 로그에 기록하지 않는다.
 */

import AVFoundation
import Foundation
import HaishinKit
import RTMPHaishinKit
import UIKit
import VideoToolbox
import os.log

private let logger = Logger(subsystem: "com.smartview.glassai", category: "RTMPStreaming")

enum RTMPStreamingState: Sendable {
    case idle
    case connecting
    case streaming
    case disconnected
    case error(String)
}

struct RTMPStreamingStats: Sendable {
    var framesSent: Int64 = 0
    var bytesSent: Int64 = 0
    var fps: Double = 0
    var connectionTime: TimeInterval = 0
}

final class RTMPStreamingService: NSObject, @unchecked Sendable {
    private static let defaultBitrate = 2_000_000
    private static let defaultFPS = 24

    private let lock = NSLock()
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?

    private var rtmpURL = ""
    private var streamKey = ""
    private var videoWidth = 0
    private var videoHeight = 0
    private var bitrate = defaultBitrate

    private(set) var isStreaming = false
    private var startTime: Date?
    private var totalFrames: Int64 = 0
    private var frameIndex: Int64 = 0
    private var baseTimestamp: Int64 = 0

    var onStateChanged: ((RTMPStreamingState) -> Void)?
    var onStatsUpdated: ((RTMPStreamingStats) -> Void)?
    var onError: ((String) -> Void)?

    private var statusTask: Task<Void, Never>?
    private var streamStatusTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    override init() {
        super.init()
        logger.info("RTMP 송출 서비스 초기화")
    }

    deinit {
        stopStreaming()
    }

    func startStreaming(
        url: String,
        width: Int,
        height: Int,
        bitrate: Int = defaultBitrate
    ) {
        guard !isStreaming else {
            logger.warning("이미 송출 중이므로 시작 요청 무시")
            return
        }

        guard let destination = parseRTMPURL(url) else {
            let message = "RTMP 주소 형식이 올바르지 않습니다"
            onStateChanged?(.error(message))
            onError?(message)
            logger.error("RTMP 주소 파싱 실패")
            return
        }

        videoWidth = width
        videoHeight = height
        self.bitrate = bitrate
        rtmpURL = destination.serverURL
        streamKey = destination.streamKey

        logger.info("RTMP 송출 준비 scheme=\(destination.scheme, privacy: .public) host=\(destination.host, privacy: .public) video=\(width, privacy: .public)x\(height, privacy: .public) bitrate=\(bitrate, privacy: .public) keyLength=\(destination.streamKey.count, privacy: .public)")
        onStateChanged?(.connecting)

        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.setupAndConnect()
        }
    }

    func stopStreaming() {
        logger.info("RTMP 송출 중지")
        isStreaming = false

        connectTask?.cancel()
        connectTask = nil

        let statusTaskToStop = statusTask
        statusTask = nil
        statusTaskToStop?.cancel()

        let streamStatusTaskToStop = streamStatusTask
        streamStatusTask = nil
        streamStatusTaskToStop?.cancel()

        let streamToClose = rtmpStream
        let connectionToClose = rtmpConnection
        rtmpStream = nil
        rtmpConnection = nil

        shutdownTask?.cancel()
        shutdownTask = Task.detached {
            _ = await statusTaskToStop?.value
            _ = await streamStatusTaskToStop?.value
            if let streamToClose {
                _ = try? await streamToClose.close()
            }
            if let connectionToClose {
                _ = try? await connectionToClose.close()
            }
        }

        totalFrames = 0
        frameIndex = 0
        baseTimestamp = 0
        startTime = nil
        streamKey = ""

        onStateChanged?(.idle)
        logger.info("RTMP 송출 정리 완료")
    }

    func feedFrame(_ image: UIImage, timestamp: Int64) {
        lock.lock()
        let streaming = isStreaming
        let stream = rtmpStream
        if streaming { totalFrames += 1 }
        lock.unlock()

        guard streaming, let stream else { return }
        guard let sampleBuffer = image.toCMSampleBuffer(timestamp: timestamp) else {
            logger.warning("UIImage를 CMSampleBuffer로 변환하지 못함")
            return
        }

        Task {
            await stream.append(sampleBuffer)
        }
        updateStats()
    }

    private func setupAndConnect() async {
        let connection = RTMPConnection()
        rtmpConnection = connection

        statusTask = Task { [weak self] in
            for await status in await connection.status {
                await self?.handleConnectionStatus(status)
            }
        }

        let serverURL = rtmpURL
        let sanitized = sanitizedEndpoint(serverURL)
        do {
            logger.info("RTMP 서버 연결 시작 endpoint=\(sanitized, privacy: .public)")
            _ = try await connection.connect(serverURL)
            logger.info("RTMP 서버 연결 성공 endpoint=\(sanitized, privacy: .public)")
            await createStreamAndPublish(connection: connection)
        } catch {
            let nsError = error as NSError
            logger.error("RTMP 연결 실패 domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
            await MainActor.run {
                let message = "RTMP 서버 연결 실패: \(nsError.localizedDescription)"
                onStateChanged?(.error(message))
                onError?(message)
            }
        }
    }

    private func createStreamAndPublish(connection: RTMPConnection) async {
        let stream = RTMPStream(connection: connection)
        rtmpStream = stream

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: videoWidth, height: videoHeight)
        videoSettings.bitRate = bitrate
        videoSettings.maxKeyFrameIntervalDuration = 1
        videoSettings.profileLevel = kVTProfileLevel_H264_Main_AutoLevel as String
        try? await stream.setVideoSettings(videoSettings)

        streamStatusTask = Task { [weak self] in
            for await status in await stream.status {
                await self?.handleStreamStatus(status)
            }
        }

        let key = streamKey
        do {
            logger.info("RTMP publish 시작 keyLength=\(key.count, privacy: .public)")
            _ = try await stream.publish(key, type: .live)
            logger.info("RTMP publish 요청 성공")

            await MainActor.run { [weak self] in
                self?.isStreaming = true
                self?.startTime = Date()
                self?.onStateChanged?(.streaming)
            }
        } catch {
            let nsError = error as NSError
            logger.error("RTMP publish 실패 domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(nsError.localizedDescription, privacy: .public)")
            await MainActor.run {
                let message = "RTMP 송출 시작 실패: \(nsError.localizedDescription)"
                onStateChanged?(.error(message))
                onError?(message)
            }
        }
    }

    @MainActor
    private func handleConnectionStatus(_ status: RTMPStatus) {
        logger.info("RTMP 연결 상태 code=\(status.code, privacy: .public)")

        if status.code == RTMPConnection.Code.connectFailed.rawValue {
            isStreaming = false
            let message = "RTMP 서버 연결에 실패했습니다: \(status.description)"
            onStateChanged?(.error(message))
            onError?(message)
        } else if status.code == RTMPConnection.Code.connectClosed.rawValue {
            isStreaming = false
            onStateChanged?(.disconnected)
        } else if status.code == RTMPConnection.Code.connectRejected.rawValue {
            isStreaming = false
            let message = "RTMP 서버가 연결을 거부했습니다: \(status.description)"
            onStateChanged?(.error(message))
            onError?(message)
        }
    }

    @MainActor
    private func handleStreamStatus(_ status: RTMPStatus) {
        logger.info("RTMP 스트림 상태 code=\(status.code, privacy: .public)")

        if status.code == RTMPStream.Code.publishStart.rawValue {
            isStreaming = true
            startTime = Date()
            onStateChanged?(.streaming)
        } else if status.code == RTMPStream.Code.publishBadName.rawValue {
            isStreaming = false
            let message = "스트림 키 또는 스트림 이름이 올바르지 않습니다"
            onStateChanged?(.error(message))
            onError?(message)
        } else if status.code == RTMPStream.Code.connectClosed.rawValue
                    || status.code == RTMPStream.Code.connectFailed.rawValue {
            isStreaming = false
            onStateChanged?(.disconnected)
        }
    }

    private func parseRTMPURL(_ value: String) -> (
        serverURL: String,
        streamKey: String,
        scheme: String,
        host: String
    )? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "rtmp" || scheme == "rtmps",
              let host = url.host,
              url.user == nil,
              url.password == nil else {
            return nil
        }

        let pathComponents = url.path.split(separator: "/")
        guard !pathComponents.isEmpty else { return nil }

        let key = String(pathComponents.last!)
        guard !key.isEmpty else { return nil }

        let appComponents = pathComponents.dropLast()
        let appPath = appComponents.isEmpty ? "live" : appComponents.map(String.init).joined(separator: "/")
        let defaultPort = scheme == "rtmps" ? 443 : 1935
        let serverURL = "\(scheme)://\(host):\(url.port ?? defaultPort)/\(appPath)"
        return (serverURL, key, scheme, host)
    }

    private func sanitizedEndpoint(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme,
              let host = components.host else {
            return "invalid"
        }
        return "\(scheme)://\(host):\(components.port ?? (scheme == "rtmps" ? 443 : 1935))"
    }

    private func updateStats() {
        guard let startTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let fps = elapsed > 0 ? Double(totalFrames) / elapsed : 0

        onStatsUpdated?(
            RTMPStreamingStats(
                framesSent: totalFrames,
                bytesSent: 0,
                fps: fps,
                connectionTime: elapsed
            )
        )
    }
}

extension UIImage {
    func toCMSampleBuffer(timestamp: Int64) -> CMSampleBuffer? {
        guard let cgImage else { return nil }

        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return nil }

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 24),
            presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    func toPixelBuffer() -> CVPixelBuffer? {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
