import CoreGraphics

/// Inference and depth fusion use a portrait image produced with `.right`.
/// Rendering first undoes that rotation, then uses ARKit's native-image display
/// transform. Both boxes and masks therefore share the camera's rotation/crop.
nonisolated enum CameraOverlayGeometry {
    static let portraitToNative = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)

    static func viewportTransform(nativeToViewport: CGAffineTransform,
                                  viewportSize: CGSize) -> CGAffineTransform? {
        let values = [nativeToViewport.a, nativeToViewport.b, nativeToViewport.c,
                      nativeToViewport.d, nativeToViewport.tx, nativeToViewport.ty,
                      viewportSize.width, viewportSize.height]
        guard values.allSatisfy(\.isFinite), viewportSize.width > 0, viewportSize.height > 0,
              abs(nativeToViewport.a * nativeToViewport.d
                  - nativeToViewport.b * nativeToViewport.c) > 0.000001 else { return nil }
        return portraitToNative.concatenating(nativeToViewport)
            .concatenating(CGAffineTransform(scaleX: viewportSize.width, y: viewportSize.height))
    }

    static func box(_ normalizedPortraitBox: CGRect, transform: CGAffineTransform) -> CGRect? {
        let values = [normalizedPortraitBox.minX, normalizedPortraitBox.minY,
                      normalizedPortraitBox.maxX, normalizedPortraitBox.maxY]
        guard values.allSatisfy(\.isFinite) else { return nil }
        let bounded = normalizedPortraitBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounded.isNull, !bounded.isEmpty else { return nil }
        return bounded.applying(transform)
    }
}
