/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import XCTest
import UIKit
@testable import CameraAccess

final class OpenClawVideoContactSheetBuilderTests: XCTestCase {

    private func makeSolidImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testThrowsOnEmptyFrames() {
        XCTAssertThrowsError(try OpenClawVideoContactSheetBuilder.buildImage(from: [])) { error in
            XCTAssertEqual(error as? OpenClawVideoContactSheetBuilder.BuilderError, .noFrames)
        }
    }

    func testLongEdgeNeverExceedsCap() throws {
        let frames = (0..<6).map { _ in makeSolidImage(size: CGSize(width: 720, height: 1280), color: .red) }

        let image = try OpenClawVideoContactSheetBuilder.buildImage(from: frames)

        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), OpenClawVideoContactSheetBuilder.Options.default.maxLongEdge)
    }

    func testNaturalGridPreservesSourcePixelsWithoutUpscaling() throws {
        let frameSize = CGSize(width: 320, height: 240)
        let frames = (0..<6).map { _ in
            makeSolidImage(size: frameSize, color: .cyan)
        }

        let image = try OpenClawVideoContactSheetBuilder.buildImage(from: frames)
        let spacing = OpenClawVideoContactSheetBuilder.Options.default.spacing
        let expectedWidth = spacing + 2 * (frameSize.width + spacing)
        let expectedHeight = spacing + 3 * (frameSize.height + spacing)

        XCTAssertEqual(image.size.width, expectedWidth, accuracy: 0.5)
        XCTAssertEqual(image.size.height, expectedHeight, accuracy: 0.5)
    }

    func testFramesBeyondMaxAreIgnored() throws {
        // 10 frames supplied, default maxFrames = 6 -> only first 6 should be composited.
        // We can't directly introspect composited frame count, but we can assert the sheet
        // dimensions match what a 6-frame, 2-column/3-row layout would produce (not a
        // 10-frame layout), by comparing against an explicit 6-frame call.
        let manyFrames = (0..<10).map { _ in makeSolidImage(size: CGSize(width: 100, height: 100), color: .blue) }
        let sixFrames = Array(manyFrames.prefix(6))

        let imageFromMany = try OpenClawVideoContactSheetBuilder.buildImage(from: manyFrames)
        let imageFromSix = try OpenClawVideoContactSheetBuilder.buildImage(from: sixFrames)

        XCTAssertEqual(imageFromMany.size.width, imageFromSix.size.width, accuracy: 0.5)
        XCTAssertEqual(imageFromMany.size.height, imageFromSix.size.height, accuracy: 0.5)
    }

    func testEachGridCellRendersItsFrame() throws {
        let colors: [UIColor] = [.red, .green, .blue, .yellow]
        let frames = colors.map {
            makeSolidImage(size: CGSize(width: 100, height: 100), color: $0)
        }
        var options = OpenClawVideoContactSheetBuilder.Options.default
        options.maxLongEdge = 220

        let image = try OpenClawVideoContactSheetBuilder.buildImage(
            from: frames,
            options: options
        )
        let cgImage = try XCTUnwrap(image.cgImage)
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let cellCenters = [
            CGPoint(x: CGFloat(pixelWidth) / 4, y: CGFloat(pixelHeight) / 4),
            CGPoint(x: 3 * CGFloat(pixelWidth) / 4, y: CGFloat(pixelHeight) / 4),
            CGPoint(x: CGFloat(pixelWidth) / 4, y: 3 * CGFloat(pixelHeight) / 4),
            CGPoint(x: 3 * CGFloat(pixelWidth) / 4, y: 3 * CGFloat(pixelHeight) / 4)
        ]

        for (center, expected) in zip(cellCenters, colors) {
            let actual = try pixelColor(
                in: cgImage,
                x: Int(center.x),
                y: Int(center.y)
            )
            XCTAssertTrue(
                colorsAreClose(actual, expected),
                "Expected \(expected), got \(actual)"
            )
        }
    }

    func testDefaultLayoutIsTwoColumns() throws {
        // With 6 frames and 2 columns, we expect 3 rows. Verify indirectly: a 1-frame sheet and
        // a 2-frame sheet should have the same height (both fit in row 1), but a 3-frame sheet
        // should be taller (spills into row 2).
        let frame = makeSolidImage(size: CGSize(width: 100, height: 100), color: .green)

        let oneFrameImage = try OpenClawVideoContactSheetBuilder.buildImage(from: [frame])
        let twoFrameImage = try OpenClawVideoContactSheetBuilder.buildImage(from: [frame, frame])
        let threeFrameImage = try OpenClawVideoContactSheetBuilder.buildImage(from: [frame, frame, frame])

        XCTAssertEqual(oneFrameImage.size.height, twoFrameImage.size.height, accuracy: 0.5)
        XCTAssertGreaterThan(threeFrameImage.size.height, twoFrameImage.size.height)
    }

    func testJPEGDataNeverExceedsSizeBudget() throws {
        // Use noisy-ish content (gradient-free solid is very compressible, so force a small
        // budget to exercise the fallback path deterministically).
        let frames = (0..<6).map { i -> UIImage in
            let hue = CGFloat(i) / 6.0
            return makeSolidImage(size: CGSize(width: 800, height: 600), color: UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))
        }

        var options = OpenClawVideoContactSheetBuilder.Options.default
        options.maxJPEGBytes = 50_000 // aggressively small to force the fallback ladder

        let data = try OpenClawVideoContactSheetBuilder.buildJPEGData(from: frames, options: options)
        XCTAssertLessThanOrEqual(data.count, options.maxJPEGBytes)
    }

    func testJPEGDataUnderDefaultBudgetForTypicalInput() throws {
        let frames = (0..<6).map { _ in makeSolidImage(size: CGSize(width: 640, height: 480), color: .orange) }

        let data = try OpenClawVideoContactSheetBuilder.buildJPEGData(from: frames)
        XCTAssertLessThanOrEqual(data.count, OpenClawVideoContactSheetBuilder.Options.default.maxJPEGBytes)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testSingleFrameProducesValidImage() throws {
        let frame = makeSolidImage(size: CGSize(width: 200, height: 200), color: .purple)
        let image = try OpenClawVideoContactSheetBuilder.buildImage(from: [frame])

        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    private func pixelColor(
        in image: CGImage,
        x: Int,
        y: Int
    ) throws -> UIColor {
        let pixelData = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(pixelData))
        let bitsPerPixel = image.bitsPerPixel
        let bytesPerPixel = bitsPerPixel / 8
        guard bytesPerPixel >= 3 else {
            XCTFail("Expected RGB image data")
            return .clear
        }
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        return UIColor(
            red: CGFloat(bytes[offset]) / 255,
            green: CGFloat(bytes[offset + 1]) / 255,
            blue: CGFloat(bytes[offset + 2]) / 255,
            alpha: bytesPerPixel >= 4
                ? CGFloat(bytes[offset + 3]) / 255
                : 1
        )
    }

    private func colorsAreClose(
        _ lhs: UIColor,
        _ rhs: UIColor,
        tolerance: CGFloat = 0.1
    ) -> Bool {
        var lhsRed: CGFloat = 0
        var lhsGreen: CGFloat = 0
        var lhsBlue: CGFloat = 0
        var lhsAlpha: CGFloat = 0
        var rhsRed: CGFloat = 0
        var rhsGreen: CGFloat = 0
        var rhsBlue: CGFloat = 0
        var rhsAlpha: CGFloat = 0
        guard lhs.getRed(
            &lhsRed,
            green: &lhsGreen,
            blue: &lhsBlue,
            alpha: &lhsAlpha
        ), rhs.getRed(
            &rhsRed,
            green: &rhsGreen,
            blue: &rhsBlue,
            alpha: &rhsAlpha
        ) else {
            return false
        }
        return abs(lhsRed - rhsRed) <= tolerance
            && abs(lhsGreen - rhsGreen) <= tolerance
            && abs(lhsBlue - rhsBlue) <= tolerance
            && abs(lhsAlpha - rhsAlpha) <= tolerance
    }
}
