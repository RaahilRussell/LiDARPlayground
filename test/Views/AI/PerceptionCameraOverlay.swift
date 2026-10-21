import ARKit
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// The camera, segmentation mask, and annotations use one viewport. The window
/// containing this view supplies orientation, including iPad/multiple scenes.
struct PerceptionCameraOverlay<Overlay: View>: View {
    let manager: ARSessionManager
    let mask: CGImage?
    let maskOpacity: Double
    let frameTimestamp: TimeInterval
    @ViewBuilder let overlay: (CGAffineTransform?, CGSize) -> Overlay
    @State private var orientation: UIInterfaceOrientation?

    var body: some View {
        GeometryReader { geometry in
            let transform = projection(in: geometry.size)
            ZStack {
                ARSCNCameraView(manager: manager)
                if let mask, let transform {
                    Canvas { context, _ in
                        context.concatenate(transform)
                        context.draw(Image(decorative: mask, scale: 1, orientation: .up),
                                     in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    }
                    .opacity(maskOpacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                overlay(transform, geometry.size)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(CameraSceneOrientationReader(orientation: $orientation))
            .clipped()
        }
    }

    private func projection(in size: CGSize) -> CGAffineTransform? {
        guard frameTimestamp > 0, manager.isCurrentObservation(timestamp: frameTimestamp),
              let orientation, orientation != .unknown,
              let frame = manager.session.currentFrame, manager.isCurrentFrame(frame) else { return nil }
        return CameraOverlayGeometry.viewportTransform(
            nativeToViewport: frame.displayTransform(for: orientation, viewportSize: size),
            viewportSize: size)
    }
}

/// Reading an arbitrary connected scene can report a different window's
/// orientation. This transparent view reads the scene it actually belongs to.
private struct CameraSceneOrientationReader: UIViewRepresentable {
    @Binding var orientation: UIInterfaceOrientation?

    func makeUIView(context: Context) -> OrientationView {
        let view = OrientationView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.onChange = { orientation = $0 }
        return view
    }

    func updateUIView(_ uiView: OrientationView, context: Context) {
        uiView.onChange = { orientation = $0 }
        uiView.reportOrientation()
    }

    final class OrientationView: UIView {
        var onChange: ((UIInterfaceOrientation?) -> Void)?
        private var reported: UIInterfaceOrientation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            reportOrientation()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportOrientation()
        }

        func reportOrientation() {
            let current = window?.windowScene?.interfaceOrientation
            guard current != reported else { return }
            reported = current
            // UIKit layout can occur during a SwiftUI update; publish afterwards.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reported == current else { return }
                self.onChange?(current)
            }
        }
    }
}
