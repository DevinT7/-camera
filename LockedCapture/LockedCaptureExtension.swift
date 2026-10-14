import SwiftUI
import AVFoundation
import LockedCameraCapture

/// Lightweight camera shown over the Lock Screen / launched from Camera Control.
/// Photos are written to the session container; the main app imports them into Photos on next launch.
@main
struct NotBoringLockedCapture: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCaptureView(session: session)
        }
    }
}

final class LockedCaptureModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "locked.session")
    let contentURL: URL
    @Published var count = 0
    @Published var layer: AVCaptureVideoPreviewLayer

    init(contentURL: URL) {
        self.contentURL = contentURL
        layer = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        layer.videoGravity = .resizeAspectFill
        queue.async { self.configure() }
    }

    private func configure() {
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
    }

    func capture() {
        queue.async {
            self.output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let url = contentURL.appendingPathComponent("capture-\(UUID().uuidString).heic")
        try? data.write(to: url)
        DispatchQueue.main.async { self.count += 1 }
    }
}

struct PreviewLayerView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> UIView { let v = UIView(); v.layer.addSublayer(layer); return v }
    func updateUIView(_ v: UIView, context: Context) { layer.frame = v.bounds }
}

struct LockedCaptureView: View {
    let session: LockedCameraCaptureSession
    @StateObject private var model: LockedCaptureModel

    init(session: LockedCameraCaptureSession) {
        self.session = session
        _model = StateObject(wrappedValue: LockedCaptureModel(contentURL: session.sessionContentURL))
    }

    var body: some View {
        ZStack {
            Color(red: 0.91, green: 0.89, blue: 0.85).ignoresSafeArea()
            VStack(spacing: 18) {
                PreviewLayerView(layer: model.layer)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color(red: 0.81, green: 0.79, blue: 0.73), lineWidth: 5))
                    .padding(.horizontal, 16).padding(.top, 8)
                HStack {
                    Text("\(model.count) saved").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.7))
                    Spacer()
                    Button { model.capture() } label: {
                        ZStack {
                            Circle().fill(Color(red: 0.81, green: 0.79, blue: 0.73)).frame(width: 96, height: 96)
                            Circle().fill(Color(red: 1, green: 0.23, blue: 0.19)).frame(width: 78, height: 78)
                        }
                    }
                    Spacer()
                    Button("Open") {
                        let a = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
                        Task { try? await session.openApplication(for: a) }
                    }.font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.black)
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }
}
