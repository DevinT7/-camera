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
