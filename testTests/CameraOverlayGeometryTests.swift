import CoreGraphics
import Testing
@testable import test

@Suite("Camera overlay orientation and crop")
struct CameraOverlayGeometryTests {
    private let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)

    @Test func portraitUndoThenDisplayRotationPreservesPortraitCoordinates() throws {
        // Native 4:3 landscape image displayed in a matching 3:4 portrait view.
        let display = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let transform = try #require(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: display, viewportSize: CGSize(width: 300, height: 400)))
        let rect = try #require(CameraOverlayGeometry.box(box, transform: transform))
        expect(rect, equals: CGRect(x: 30, y: 80, width: 90, height: 160))
        expect(CGPoint(x: 0.2, y: 0.3).applying(transform), equals: CGPoint(x: 60, y: 120))
    }

    @Test func landscapeRightUsesNativeSensorAxes() throws {
        let transform = try #require(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: .identity, viewportSize: CGSize(width: 400, height: 300)))
        let rect = try #require(CameraOverlayGeometry.box(box, transform: transform))
        expect(rect, equals: CGRect(x: 80, y: 180, width: 160, height: 90))
        expect(CGPoint(x: 0.2, y: 0.3).applying(transform), equals: CGPoint(x: 120, y: 240))
    }

    @Test func landscapeLeftRotatesBoxesAndMaskPointsTogether() throws {
        let display = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)
        let transform = try #require(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: display, viewportSize: CGSize(width: 400, height: 300)))
        let rect = try #require(CameraOverlayGeometry.box(box, transform: transform))
        expect(rect, equals: CGRect(x: 160, y: 30, width: 160, height: 90))
        expect(CGPoint(x: 0.2, y: 0.3).applying(transform), equals: CGPoint(x: 280, y: 60))
        // Canvas draws the unit mask through this same transform. Its corners
        // must enclose the exact rectangle used for the detection outline.
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            .map { $0.applying(transform) }
        #expect(abs(corners.map(\.x).min()! - rect.minX) < 0.0001)
        #expect(abs(corners.map(\.y).max()! - rect.maxY) < 0.0001)
    }

    @Test func portraitAspectFillKeepsOffscreenCropInsteadOfStretching() throws {
        // 3:4 portrait source fills a 1:2 viewport: width 450, cropped 75 on each side.
        let display = CGAffineTransform(a: 0, b: 1, c: -1.5, d: 0, tx: 1.25, ty: 0)
        let transform = try #require(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: display, viewportSize: CGSize(width: 300, height: 600)))
        let rect = try #require(CameraOverlayGeometry.box(box, transform: transform))
        expect(rect, equals: CGRect(x: -30, y: 120, width: 135, height: 240))
        expect(CGPoint(x: 0.5, y: 0.5).applying(transform), equals: CGPoint(x: 150, y: 300))
    }

    @Test func landscapeAspectFillUsesActualViewportDimensions() throws {
        // 4:3 sensor source fills a 2:1 viewport: height 450, cropped 75 at top/bottom.
        let display = CGAffineTransform(a: 1, b: 0, c: 0, d: 1.5, tx: 0, ty: -0.25)
        let transform = try #require(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: display, viewportSize: CGSize(width: 600, height: 300)))
        let rect = try #require(CameraOverlayGeometry.box(box, transform: transform))
        expect(rect, equals: CGRect(x: 120, y: 195, width: 240, height: 135))
    }

    @Test func invalidViewportOrDetectionProducesNoOverlay() {
        #expect(CameraOverlayGeometry.viewportTransform(nativeToViewport: .identity,
                                                        viewportSize: .zero) == nil)
        #expect(CameraOverlayGeometry.viewportTransform(nativeToViewport: .identity,
                   viewportSize: CGSize(width: CGFloat.nan, height: 200)) == nil)
        #expect(CameraOverlayGeometry.viewportTransform(
            nativeToViewport: CGAffineTransform(scaleX: 0, y: 0),
            viewportSize: CGSize(width: 300, height: 400)) == nil)
        #expect(CameraOverlayGeometry.box(CGRect(x: 2, y: 2, width: 1, height: 1),
                                          transform: .identity) == nil)
    }

    private func expect(_ actual: CGPoint, equals expected: CGPoint) {
        #expect(abs(actual.x - expected.x) < 0.0001)
        #expect(abs(actual.y - expected.y) < 0.0001)
    }

    private func expect(_ actual: CGRect, equals expected: CGRect) {
        #expect(abs(actual.minX - expected.minX) < 0.0001)
        #expect(abs(actual.minY - expected.minY) < 0.0001)
        #expect(abs(actual.width - expected.width) < 0.0001)
        #expect(abs(actual.height - expected.height) < 0.0001)
    }
}
