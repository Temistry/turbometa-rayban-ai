/*
 * OpenClaw Video Frame Extractor
 * 보호 원본 MP4에서 시간 분산 대표 프레임과 비식별 품질 metadata를 읽는다.
 */

import AVFoundation
import UIKit

enum OpenClawVideoFrameExtractorError: Error, Equatable {
    case noVideoTrack
    case noFrames
}

struct OpenClawVideoQualityMetadata: Equatable, Sendable {
    let width: Int
    let height: Int
    let nominalFrameRate: Float
    let estimatedDataRate: Float
    let durationSeconds: Double
}

enum OpenClawVideoFrameExtractor {
    static func contactSheetJPEG(
        from url: URL,
        maxFrames: Int = 6
    ) async throws -> Data {
        let frames = try await representativeFrames(
            from: url,
            maxFrames: maxFrames
        )
        return try await OpenClawVideoContactSheetBuilder
            .buildJPEGDataOffMain(from: frames)
    }

    static func representativeFrames(
        from url: URL,
        maxFrames: Int = 6
    ) async throws -> [UIImage] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else {
            throw OpenClawVideoFrameExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let seconds = max(0, duration.seconds.isFinite ? duration.seconds : 0)
        let count = max(1, min(maxFrames, 6))
        let times: [CMTime]
        if seconds <= 0 {
            times = [.zero]
        } else if count == 1 {
            times = [CMTime(seconds: seconds / 2, preferredTimescale: 600)]
        } else {
            times = (0..<count).map { index in
                let fraction = Double(index) / Double(count - 1)
                let bounded = min(max(seconds * fraction, 0), max(0, seconds - 0.001))
                return CMTime(seconds: bounded, preferredTimescale: 600)
            }
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var images: [UIImage] = []
        for try await generated in generator.images(for: times) {
            images.append(UIImage(cgImage: try generated.image))
        }
        guard !images.isEmpty else {
            throw OpenClawVideoFrameExtractorError.noFrames
        }
        return images
    }

    static func qualityMetadata(from url: URL) async -> OpenClawVideoQualityMetadata? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        do {
            async let naturalSize = track.load(.naturalSize)
            async let transform = track.load(.preferredTransform)
            async let frameRate = track.load(.nominalFrameRate)
            async let dataRate = track.load(.estimatedDataRate)
            async let duration = asset.load(.duration)
            let transformed = try await naturalSize.applying(transform)
            let resolvedDuration = try await duration
            return OpenClawVideoQualityMetadata(
                width: Int(abs(transformed.width).rounded()),
                height: Int(abs(transformed.height).rounded()),
                nominalFrameRate: try await frameRate,
                estimatedDataRate: try await dataRate,
                durationSeconds: max(0, resolvedDuration.seconds)
            )
        } catch {
            return nil
        }
    }
}
