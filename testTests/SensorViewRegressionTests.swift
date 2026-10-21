import CoreGraphics
import Testing
@testable import test

struct SensorViewRegressionTests {
    @Test func portraitDepthFitsWideViewportWithoutClipping() {
        let fitted = DepthImageLayout.fittedRect(image: CGSize(width: 192, height: 256),
                                                viewport: CGSize(width: 400, height: 300))
        #expect(fitted == CGRect(x: 87.5, y: 0, width: 225, height: 300))
        #expect(DepthImageLayout.rawProbe(at: CGPoint(x: 40, y: 150), in: fitted) == nil)
        #expect(DepthImageLayout.rawProbe(at: CGPoint(x: 200, y: 150), in: fitted) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func portraitDepthFitsTallViewportAndProbeMatchesImage() {
        let fitted = DepthImageLayout.fittedRect(image: CGSize(width: 192, height: 256),
                                                viewport: CGSize(width: 300, height: 600))
        #expect(fitted == CGRect(x: 0, y: 100, width: 300, height: 400))
        #expect(DepthImageLayout.rawProbe(at: CGPoint(x: 150, y: 40), in: fitted) == nil)
        #expect(DepthImageLayout.rawProbe(at: CGPoint(x: 75, y: 200), in: fitted) == CGPoint(x: 0.25, y: 0.75))
    }

    @Test func unusableViewportHasNoDepthProbe() {
        let fitted = DepthImageLayout.fittedRect(image: CGSize(width: 192, height: 256), viewport: .zero)
        #expect(fitted == .zero)
        #expect(DepthImageLayout.rawProbe(at: .zero, in: fitted) == nil)
    }
}
