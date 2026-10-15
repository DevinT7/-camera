import AVFoundation
import SwiftUI

/// Shows the processed (styled, overlaid) live frames.
struct PreviewView: UIViewRepresentable {
    let model: CameraModel

    final class V: UIView {}

    func makeUIView(context: Context) -> V {
        let v = V()
        v.backgroundColor = .black
        v.layer.contentsGravity = .resizeAspectFill
        v.layer.masksToBounds = true
        model.frameSink = { [weak v] cg in DispatchQueue.main.async { v?.layer.contents = cg } }
        return v
    }
    func updateUIView(_ uiView: V, context: Context) {}
}

/// The system's own preview layer, the one the iPhone Camera app uses: it handles selfie mirroring, rotation and field of view itself.
/// Shows the raw camera (no live Style); here to compare against the styled preview.
struct SystemPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let position: AVCaptureDevice.Position

    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        func upright() {
            guard let c = preview.connection else { return }
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.backgroundColor = .black
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ v: V, context: Context) {
        v.upright()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { v.upright() }   // the connection is rebuilt after a flip
    }
}
