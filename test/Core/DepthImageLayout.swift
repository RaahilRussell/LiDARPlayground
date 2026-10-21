import CoreGraphics

/// The depth preview and its touch probe must use the same displayed rectangle.
nonisolated enum DepthImageLayout {
    static func fittedRect(image: CGSize, viewport: CGSize) -> CGRect {
        guard image.width.isFinite, image.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              image.width > 0, image.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2,
                      y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func rawProbe(at location: CGPoint, in fitted: CGRect) -> CGPoint? {
        guard fitted.width > 0, fitted.height > 0, fitted.contains(location) else { return nil }
        let x = (location.x - fitted.minX) / fitted.width
        let y = (location.y - fitted.minY) / fitted.height
        // The depth image is presented with a clockwise quarter-turn.
        return CGPoint(x: y, y: 1 - x)
    }
}
