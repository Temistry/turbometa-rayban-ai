/*
 * OpenClaw Video Contact Sheet Builder
 * 녹화 중 시간축에서 선택한 UIImage를 OpenClaw 분석용 JPEG 한 장으로
 * 합성한다. 호출자는 시간 분산 sampling을 담당하며, 이 builder는 최대
 * 6프레임, 2x3 grid, 긴 변 4,096px, 4MiB 제한을 강제한다.
 */

import UIKit

// MARK: - Contact Sheet Builder

/// Builds a single grid ("contact sheet") image from a sequence of already-decoded video
/// frames (`UIImage`). Frames are assumed to have been produced during recording (e.g. sampled
/// from `OpenClawVideoRecorder`'s input), so this builder does no video decoding itself — it is
/// pure `UIGraphicsImageRenderer` composition, kept off the main thread by the caller.
enum OpenClawVideoContactSheetBuilder {
    private struct SendableFrames: @unchecked Sendable {
        let images: [UIImage]
    }

    /// Layout parameters for the generated sheet. Defaults enforce the hard caps: at most 6
    /// frames arranged in a 2-column x 3-row grid, long edge capped at 4096px, and JPEG output
    /// capped at 4 MiB via progressive quality/resolution fallback.
    struct Options: Sendable {
        /// Hard cap on the number of frames composited. Extra frames beyond this are ignored
        /// (see `buildImage(from:options:)`, which uses the first `maxFrames` in the input
        /// order rather than sampling — callers wanting even coverage should pre-sample before
        /// calling in).
        var maxFrames: Int = 6
        /// Grid columns. With `maxFrames = 6` this yields a 2x3 grid (2 columns, 3 rows).
        var columns: Int = 2
        /// Spacing between cells and around the sheet edges, in points.
        var spacing: CGFloat = 4
        /// Maximum length of the sheet's longer edge, in points. The grid is scaled down
        /// (preserving aspect ratio) if composing at the natural cell size would exceed this.
        var maxLongEdge: CGFloat = 4096
        /// Maximum size of the encoded JPEG, in bytes. `buildJPEGData` reduces quality and, if
        /// still over budget, reduces resolution further, until this is satisfied or the image
        /// can no longer be shrunk further.
        var maxJPEGBytes: Int = 4 * 1024 * 1024
        /// Starting JPEG compression quality for the fallback search.
        var initialJPEGQuality: CGFloat = 1.0

        static let `default` = Options()
    }

    enum BuilderError: Error, Equatable {
        case noFrames
        /// The image could not be encoded under `maxJPEGBytes` even at the lowest attempted
        /// quality/resolution step.
        case unableToMeetSizeBudget
    }

    /// Renders up to `options.maxFrames` frames into a single grid image, laid out
    /// left-to-right, top-to-bottom in the order provided. Each frame is scaled (aspect-fill,
    /// center-cropped) into a uniform cell. The overall sheet is scaled down, preserving aspect
    /// ratio, so its longer edge never exceeds `options.maxLongEdge`.
    static func buildImage(from frames: [UIImage], options: Options = .default) throws -> UIImage {
        guard !frames.isEmpty else { throw BuilderError.noFrames }

        let cappedFrames = Array(frames.prefix(max(1, options.maxFrames)))
        let columns = max(1, options.columns)
        let rows = Int(ceil(Double(cappedFrames.count) / Double(columns)))
        let spacing = max(0, options.spacing)

        // Preserve the source frame's pixel dimensions whenever the natural grid already fits
        // under maxLongEdge. This avoids upscaling small inputs while retaining every available
        // source pixel from the 720x1280 DAT high-resolution stream.
        let firstFrame = cappedFrames[0]
        let sourceWidth = CGFloat(firstFrame.cgImage?.width ?? 0)
        let sourceHeight = CGFloat(firstFrame.cgImage?.height ?? 0)
        let naturalCellWidth = sourceWidth > 0 ? sourceWidth : max(1, firstFrame.size.width)
        let naturalCellHeight = sourceHeight > 0 ? sourceHeight : max(1, firstFrame.size.height)
        let widthColumns = CGFloat(columns)
        let heightRows = CGFloat(rows)
        let horizontalSpacing = spacing * (widthColumns + 1)
        let verticalSpacing = spacing * (heightRows + 1)
        let boundedLongEdge = max(1, options.maxLongEdge)
        let availableWidth = max(1, boundedLongEdge - horizontalSpacing)
        let availableHeight = max(1, boundedLongEdge - verticalSpacing)
        let widthScale = availableWidth / (widthColumns * naturalCellWidth)
        let heightScale = availableHeight / (heightRows * naturalCellHeight)
        let scale = max(0, min(1, min(widthScale, heightScale)))
        let cellWidth = max(1, floor(naturalCellWidth * scale))
        let cellHeight = max(1, floor(naturalCellHeight * scale))

        let sheetWidth = spacing + widthColumns * (cellWidth + spacing)
        let sheetHeight = spacing + heightRows * (cellHeight + spacing)
        let sheetSize = CGSize(width: sheetWidth, height: sheetHeight)

        let rendererFormat = UIGraphicsImageRendererFormat.default()
        rendererFormat.opaque = true
        rendererFormat.scale = 1
        let renderer = UIGraphicsImageRenderer(size: sheetSize, format: rendererFormat)

        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: sheetSize))

            for (index, frame) in cappedFrames.enumerated() {
                let column = index % columns
                let row = index / columns
                let originX = spacing + CGFloat(column) * (cellWidth + spacing)
                let originY = spacing + CGFloat(row) * (cellHeight + spacing)
                let cellRect = CGRect(x: originX, y: originY, width: cellWidth, height: cellHeight)
                drawAspectFill(frame, in: cellRect)
            }
        }

        return image
    }

    /// Renders the grid (per `buildImage`) and encodes it as JPEG data guaranteed to be at most
    /// `options.maxJPEGBytes`. If the initial quality doesn't meet budget, quality is stepped
    /// down; if quality alone can't meet budget, the sheet is progressively downscaled and
    /// re-encoded. Throws `.unableToMeetSizeBudget` if no attempted combination fits.
    static func buildJPEGData(from frames: [UIImage], options: Options = .default) throws -> Data {
        let image = try buildImage(from: frames, options: options)
        return try encodeWithinBudget(image, options: options)
    }

    static func buildJPEGDataOffMain(
        from frames: [UIImage],
        options: Options = .default
    ) async throws -> Data {
        let sendableFrames = SendableFrames(images: frames)
        return try await Task.detached(priority: .userInitiated) {
            try buildJPEGData(from: sendableFrames.images, options: options)
        }.value
    }

    // MARK: - Size-budget fallback

    private static func encodeWithinBudget(_ image: UIImage, options: Options) throws -> Data {
        // Step 1: quality ladder at full resolution.
        let initialQuality = min(max(options.initialJPEGQuality, 0.3), 1.0)
        let qualitySteps: [CGFloat] = stride(
            from: initialQuality,
            through: 0.3,
            by: -0.1
        ).map { $0 }

        for quality in qualitySteps {
            if let data = image.jpegData(compressionQuality: quality), data.count <= options.maxJPEGBytes {
                return data
            }
        }

        // Step 2: progressively downscale (each step to 90% linear size) and retry the full
        // quality ladder. Smaller steps preserve more detail, and restarting at the highest
        // quality selects the best available quality/resolution combination under the budget.
        var currentImage = image
        let scaleFactor: CGFloat = 0.9
        let minDimension: CGFloat = 200 // avoid scaling into an unusably tiny/empty image

        for _ in 0..<12 {
            guard currentImage.size.width * scaleFactor >= minDimension,
                  currentImage.size.height * scaleFactor >= minDimension else {
                break
            }

            let newSize = CGSize(
                width: floor(currentImage.size.width * scaleFactor),
                height: floor(currentImage.size.height * scaleFactor)
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.opaque = true
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            currentImage = renderer.image { _ in
                currentImage.draw(in: CGRect(origin: .zero, size: newSize))
            }

            for quality in qualitySteps {
                if let data = currentImage.jpegData(compressionQuality: quality), data.count <= options.maxJPEGBytes {
                    return data
                }
            }
        }

        throw BuilderError.unableToMeetSizeBudget
    }

    // MARK: - Private

    /// Draws `image` into `rect` using aspect-fill (center-crop) scaling, matching the visual
    /// behavior of `UIView.ContentMode.scaleAspectFill` for a static composited grid.
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }

        context.saveGState()
        defer { context.restoreGState() }

        let imageAspect = image.size.width / image.size.height
        let rectAspect = rect.width / rect.height

        var drawRect = rect
        if imageAspect > rectAspect {
            // Image is wider than the cell: scale to fill height, crop width.
            let scaledWidth = rect.height * imageAspect
            drawRect = CGRect(
                x: rect.midX - scaledWidth / 2,
                y: rect.minY,
                width: scaledWidth,
                height: rect.height
            )
        } else {
            // Image is taller than the cell: scale to fill width, crop height.
            let scaledHeight = rect.width / imageAspect
            drawRect = CGRect(
                x: rect.minX,
                y: rect.midY - scaledHeight / 2,
                width: rect.width,
                height: scaledHeight
            )
        }

        context.clip(to: rect)
        image.draw(in: drawRect)
    }
}
