import AVFoundation
import CoreMotion
import CoreImage
import Photos
import UIKit
import SwiftUI

enum ManualParam: String, CaseIterable, Identifiable {
    case ev = "EV", shutter = "SS", iso = "ISO", wb = "WB", focus = "FOCUS"
    var id: String { rawValue }
}

struct RenderState {
    var style: CameraStyle = Styles.all[0]
    var zebra = false
    var peaking = false
    var histogram = false
}

enum CaptureMode: Hashable { case photo, video }

final class CameraModel: NSObject, ObservableObject {
    // MARK: UI state
    @Published var authorized = false
    @Published var hasCamera = true
    @Published var position: AVCaptureDevice.Position = .back
    @Published var zoom: CGFloat = 1
    @Published var minZoom: CGFloat = 1
    @Published var maxZoom: CGFloat = 10
    @Published var isManual = false { didSet { applyModeChange() } }
    @Published var param: ManualParam = .ev
    @Published var flash: FlashSetting = .off
    @Published var styles: [CameraStyle] = Styles.all
    @Published var styleIndex = 0 { didSet { pushRenderState() } }
    @Published var histogram: [Float] = Array(repeating: 0, count: 32)
    @Published var lastImage: UIImage?
    @Published var reviewImage: UIImage?
    @Published var capturing = false
    @Published var focusPoint: CGPoint?
    @Published var manualFocusActive = false
    @Published var minFocusMM: Int = 0
    @Published var captureMode: CaptureMode = .photo
    /// Front-camera flash lights the screen, like the system Camera's Retina Flash.
    @Published var screenFlashing = false
    /// True from the moment a camera switch starts until the first correctly oriented frame arrives (the preview blurs meanwhile).
    @Published var isSwitching = false
    /// True while the phone is mid-turn and the picture/box are being brought into agreement (the viewfinder softens meanwhile).
    @Published var isTurning = false
    @Published var diagnostics = ""
    private var previewGateOpen = true        // read on videoQueue, written on sessionQueue
    private var pendingFirstFrame = false
    private var savedBrightness: CGFloat = 0.5
    private var captureWasFront = false
    @Published var isRecording = false
    @Published var recordSeconds = 0

    // stepped manual values (index into ladders)
    @Published var evIndex = 18 { didSet { applyEV() } }          // 0...36 -> -6...+6 in 1/3
    @Published var isoIndex = 0 { didSet { applyManualExposure() } }
    @Published var shutterIndex = 0 { didSet { applyManualExposure() } }
    @Published var wbIndex = 33 { didSet { applyWB() } }          // 2600...9000 step 100
    @Published var focusPos: Float = 0.5 { didSet { applyFocus() } }
    /// Settings the user has moved off their defaults (drives the reset affordance).
    @Published var touched: Set<ManualParam> = []
    private var seeding = false

    var evLadder: [Float] { (0...36).map { Float($0 - 18) / 3 } }
    private(set) var isoLadder: [Float] = [54, 100, 200, 400, 800, 1600, 3200, 6400, 12000]
    private(set) var shutterLadder: [Double] = [1.0 / 60]
    let wbLadder: [Float] = stride(from: 2600, through: 9000, by: 100).map { Float($0) }

    var settings: AppSettings { AppSettings.shared }
    var style: CameraStyle { styles[min(styleIndex, styles.count - 1)] }

    // MARK: AV
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private var device: AVCaptureDevice?
    private var zoomBase: CGFloat = 1
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any])
    private var renderState = RenderState()
    private var frameCount = 0
    private let layerProbe: AVCaptureVideoPreviewLayer
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioConfigured = false
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerStarted = false
    private var recordingURL: URL?
    private var recordTimer: Timer?

    /// Receives preview frames; set by PreviewView.
    var frameSink: ((CGImage) -> Void)?

    // capture bookkeeping
    private var pendingRaw: Data?
    private var pendingProcessed: Data?
    private var captureUsedSuperRaw = false

    override init() {
        layerProbe = AVCaptureVideoPreviewLayer(session: session)
        layerProbe.videoGravity = .resizeAspectFill
        super.init()
        styles = Styles.all + Styles.loadCustom()
        if settings.rememberSettings {
            styleIndex = styles.firstIndex { $0.id == settings.lastStyleID } ?? 0
            flash = settings.lastFlash
            isManual = settings.lastManual
            if let i = evLadder.firstIndex(where: { abs(Double($0) - settings.lastEV) < 0.01 }) { evIndex = i }
        }
        pushRenderState()
    }

    func setViewfinderSize(_ s: CGSize) { layerProbe.frame = CGRect(origin: .zero, size: s) }

    // MARK: Lifecycle
    func start() {
        startMotion()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { self.authorized = ok; if ok { self.configureIfNeeded() } }
            }
        default: DispatchQueue.main.async { self.authorized = false }
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
    }

    func stop() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private var configured = false
    private func configureIfNeeded() {
        authorized = true
        sessionQueue.async {
            if !self.configured { self.configure(position: .back); self.configured = true }
            if !self.session.isRunning { self.session.startRunning() }
            // Re-apply a remembered Manual mode now that the session is actually running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.isManual { self.applyModeChange() } }
        }
    }

    private func pickDevice(_ pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = pos == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera]   // front ultra-wide = Center Stage selfie camera (iPhone 17 family), what the system Camera uses
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: pos).devices.first
    }

    private func configure(position pos: AVCaptureDevice.Position) {
        guard let dev = pickDevice(pos), let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.hasCamera = false }
            return
        }
        // Drop frames while the connections are rebuilt: for a moment they arrive in the sensor's native orientation
        // (that was the upside-down flash after flipping). The preview holds/blurs until they're upright.
        previewGateOpen = false; pendingFirstFrame = true
        DispatchQueue.main.async { self.isSwitching = true }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) { session.addInput(input) }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        if let dims = dev.activeFormat.supportedMaxPhotoDimensions.last { photoOutput.maxPhotoDimensions = dims }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        rotationCoordinator = coordinator
        watchAngle(coordinator)
        session.commitConfiguration()
        applyOrientation(for: pos)
        videoQueue.asyncAfter(deadline: .now() + 0.25) { self.previewGateOpen = true }
        videoQueue.async { self.lastBufferLandscape = nil; self.angleDirty = true; self.angleDirtyAt = Date() }

        device = dev
        installCameraControls(dev)
        // Continuous zoom range, expressed relative to the main (1x) lens.
        var base: CGFloat = 1
        if pos == .back, dev.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let first = dev.virtualDeviceSwitchOverVideoZoomFactors.first {
            base = CGFloat(truncating: first)
        }
        if pos == .front, dev.deviceType == .builtInUltraWideCamera {
            // The Center Stage selfie camera is ultra-wide. Open at a normal selfie framing (~24mm equivalent, like the system
            // Camera) so "1×" isn't the full 95° view; the wider view stays available below 1×.
            var nominal: CGFloat = 0
            if #available(iOS 26.0, *) { nominal = CGFloat(dev.nominalFocalLengthIn35mmFilm) }
            let focal = nominal > 0 ? nominal : 18 / tan(CGFloat(dev.activeFormat.videoFieldOfView) * .pi / 360)
            base = min(max(24 / focal, 1), max(dev.maxAvailableVideoZoomFactor / 2, 1))
        }
        zoomBase = base
        let lo = dev.minAvailableVideoZoomFactor / base
        let hi = min(dev.maxAvailableVideoZoomFactor / base, 25)
        let startZoom = min(max(pos == .back && settings.rememberSettings ? CGFloat(settings.lastLens) : 1, lo), hi)
        buildLadders(dev)
        try? dev.lockForConfiguration()
        dev.videoZoomFactor = startZoom * base
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        dev.unlockForConfiguration()
        let minFocus = Int(dev.minimumFocusDistance)
        DispatchQueue.main.async {
            self.hasCamera = true
            self.position = pos
            self.minZoom = lo; self.maxZoom = hi; self.zoom = startZoom
            self.minFocusMM = minFocus
            self.applyEV()
        }
    }

    /// Portrait + selfie mirroring. Must run after commitConfiguration: swapping inputs rebuilds the connections,
    /// so values set before the commit land on the old (discarded) connections and the front camera comes up sideways.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// Set by the view: when the system preview layer is on screen we skip building our own preview frames.
    var nativePreviewActive = false
    private let motion = CMMotionManager()

    /// Degrees to turn the preview box (clockwise) so the scene reads upright to the user while the phone is held sideways.
    /// The camera output is always world-upright (the coordinator's horizon-level angle), like the system Camera.
    @Published var deviceTurn: Double = 0
    @Published var liveAngle: CGFloat = 90
    private var angleObservation: NSKeyValueObservation?
    weak var systemPreviewLayer: AVCaptureVideoPreviewLayer?

    /// Live rotation numbers for the diagnostics overlay.
    func rotationReport() -> String {
        let o = UIDevice.current.orientation
        let names = [0: "unknown", 1: "portrait", 2: "upsideDown", 3: "landscapeLeft", 4: "landscapeRight", 5: "faceUp", 6: "faceDown"]
        let coord = rotationCoordinator
        func f(_ v: CGFloat?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        let layerAngle = f(systemPreviewLayer?.connection?.videoRotationAngle)
        let out = videoOutput.connection(with: .video)
        let mirror = out.map { $0.isVideoMirrored ? "Y" : "N" } ?? "-"
        let acc = motion.accelerometerData?.acceleration
        let l1 = "orient \(names[o.rawValue] ?? "?")  turn \(Int(deviceTurn))  accel x \(String(format: "%.2f", acc?.x ?? 0)) y \(String(format: "%.2f", acc?.y ?? 0))"
        let l2 = "coord capture \(f(coord?.videoRotationAngleForHorizonLevelCapture))  preview \(f(coord?.videoRotationAngleForHorizonLevelPreview))"
        let l3 = "layer \(layerAngle)  output \(f(out?.videoRotationAngle))  mirrored \(mirror)  native \(nativePreviewActive ? "Y" : "N")"
        return [l1, l2, l3].joined(separator: "\n")
    }

    /// Which way the phone is physically held, from gravity. The viewfinder turn must not be derived from the camera's rotation
    /// angle: that angle moves the opposite way on the selfie camera, which turned its preview upside down.
    /// (UIDevice.orientation isn't reliable either: with the interface locked to portrait it stays "portrait".)
    private func startMotion() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.05
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            guard abs(a.z) < 0.85 else { return }                                  // lying flat: keep the last one
            var t: Double?
            if abs(a.x) > abs(a.y) + 0.1 { t = a.x < 0 ? 90 : -90 }                // turned counter-clockwise: turn the picture clockwise
            else if abs(a.y) > abs(a.x) + 0.1 { t = a.y < 0 ? 0 : 180 }
            guard let t else { return }
            self.videoQueue.async {
                guard t != self.targetTurn else { return }
                self.targetTurn = t; self.angleDirty = true; self.angleDirtyAt = Date()
                DispatchQueue.main.async {
                    self.isTurning = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.isTurning = false }   // safety
                }
            }
        }
    }

    // Read/written on videoQueue. A rotation change is committed (box turn + layer angle) only when the first frame in the new
    // orientation arrives, so the picture and the box change in the same instant instead of one trailing the other.
    private var targetTurn: Double = 0
    private var committedTurn: Double = 0
    private var angleDirty = true
    private var angleDirtyAt = Date.distantPast
    private var lastBufferLandscape: Bool?

    /// Horizon-level rotation from the system coordinator (it accounts for each sensor's mounting and for gravity).
    /// No preview layer is attached to the coordinator, so the capture angle is the meaningful one.
    func currentAngle() -> CGFloat { rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90 }

    private func watchAngle(_ coordinator: AVCaptureDevice.RotationCoordinator) {
        angleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let a = change.newValue else { return }
            self.sessionQueue.async {
                if let c = self.videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(a) { c.videoRotationAngle = a }
            }
            self.videoQueue.async { self.angleDirty = true; self.angleDirtyAt = Date() }
        }
    }

    private func applyOrientation(for pos: AVCaptureDevice.Position) {
        for out in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let c = out.connection(with: .video) else { continue }
            let angle = currentAngle()
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = false   // frames stay raw; selfie mirroring is applied explicitly (preview / saved photo / video each follow their own setting)
            }
        }
    }

    private func buildLadders(_ dev: AVCaptureDevice) {
        let f = dev.activeFormat
        let isoMin = max(f.minISO, 54), isoMax = min(f.maxISO, 12000)
        var isos: [Float] = []; var v = isoMin
        while v < isoMax { isos.append(v); v *= pow(2, 1.0 / 3) }
        isos.append(isoMax)
        let dMin = CMTimeGetSeconds(f.minExposureDuration), dMax = min(CMTimeGetSeconds(f.maxExposureDuration), 1.0)
        var shutters: [Double] = []
        var t = dMax
        while t > dMin { shutters.append(t); t /= pow(2, 1.0 / 3) }
        isoLadder = isos
        shutterLadder = shutters.isEmpty ? [1.0 / 60] : shutters
        DispatchQueue.main.async {
            self.isoIndex = min(self.isoIndex, isos.count - 1)
            self.shutterIndex = self.shutterLadder.firstIndex { $0 <= 1.0 / 60 } ?? 0
        }
    }

    // MARK: Controls
    func flip() {
        let new: AVCaptureDevice.Position = position == .back ? .front : .back
        sessionQueue.async { self.configure(position: new) }
    }

    func setZoom(_ z: CGFloat, ramp: Bool = false) {
        let clamped = min(max(z, minZoom), maxZoom)
        zoom = clamped
        settings.lastLens = Double(clamped)
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            let target = clamped * self.zoomBase
            if ramp { d.ramp(toVideoZoomFactor: target, withRate: 6) } else { d.cancelVideoZoomRamp(); d.videoZoomFactor = target }
            d.unlockForConfiguration()
        }
    }

    /// Cycles the lens switch through the lenses that exist (0.5 / 1 / 2 ...).
    func cycleLens() {
        let stops = quickZoomStops
        let i = stops.firstIndex { abs($0 - zoom) < 0.05 } ?? -1
        setZoom(stops[(i + 1) % stops.count], ramp: true)
    }

    var quickZoomStops: [CGFloat] {
        (position == .front ? [0.5, 1, 1.5, 2] : [0.5, 1, 2, 4, 8]).filter { $0 >= minZoom - 0.001 && $0 <= maxZoom + 0.001 }
    }

    func tapFocus(at p: CGPoint, in size: CGSize) {
        focusPoint = p
        manualFocusActive = false
        let dp = layerProbe.captureDevicePointConverted(fromLayerPoint: p)
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = dp }
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            if !self.isManual {
                if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = dp }
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            }
            d.unlockForConfiguration()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if !self.manualFocusActive { self.focusPoint = nil } }
    }

    func beginManualFocus(at p: CGPoint) { manualFocusActive = true; focusPoint = p }
    func endManualFocus() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.manualFocusActive = false; self.focusPoint = nil } }

    /// Puts one setting back to its default: EV 0, ISO 100, 1/60s, 5500K, or autofocus.
    func reset(_ p: ManualParam) {
        func nearest<T: BinaryFloatingPoint>(_ a: [T], _ v: T) -> Int { a.enumerated().min { abs($0.element - v) < abs($1.element - v) }?.offset ?? 0 }
        switch p {
        case .ev: evIndex = 18
        case .iso: isoIndex = nearest(isoLadder, 100)
        case .shutter: shutterIndex = nearest(shutterLadder, 1.0 / 60)
        case .wb: wbIndex = nearest(wbLadder, 5500)
        case .focus:
            sessionQueue.async {
                guard let d = self.device else { return }
                try? d.lockForConfiguration()
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.seeding = true; self.focusPos = d.lensPosition; self.seeding = false
                }
            }
        }
        touched.remove(p)
        Feedback.thump()
    }

    /// Copies what auto exposure/WB/focus are doing right now into the manual ladders, so switching to manual doesn't jump.
    func seedManualFromAuto() {
        guard let d = device else { return }
        let iso = d.iso, dur = CMTimeGetSeconds(d.exposureDuration)
        let g = d.deviceWhiteBalanceGains
        let k = d.temperatureAndTintValues(for: AVCaptureDevice.WhiteBalanceGains(redGain: min(max(g.redGain, 1), d.maxWhiteBalanceGain), greenGain: min(max(g.greenGain, 1), d.maxWhiteBalanceGain), blueGain: min(max(g.blueGain, 1), d.maxWhiteBalanceGain))).temperature
        let lens = d.lensPosition
        if let i = isoLadder.enumerated().min(by: { abs($0.element - iso) < abs($1.element - iso) })?.offset { isoIndex = i }
        if let i = shutterLadder.enumerated().min(by: { abs(log($0.element / max(dur, 1e-6))) < abs(log($1.element / max(dur, 1e-6))) })?.offset { shutterIndex = i }
        if let i = wbLadder.enumerated().min(by: { abs($0.element - k) < abs($1.element - k) })?.offset { wbIndex = i }
        focusPos = lens
    }

    private func applyModeChange() {
        if !isManual { param = .ev; touched = touched.intersection([.ev]) }
        pushRenderState()
        settings.lastManual = isManual
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            if self.isManual {
                if d.isExposureModeSupported(.custom) { d.exposureMode = .custom; self.applyManualExposureLocked(d) }
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            }
            d.unlockForConfiguration()
        }
        if !isManual { applyEV() }
    }

    private func applyEV() {
        settings.lastEV = Double(evLadder[evIndex])
        let bias = evLadder[evIndex]
        sessionQueue.async {
            guard let d = self.device, !self.isManual else { return }
            try? d.lockForConfiguration()
            d.setExposureTargetBias(min(max(bias, d.minExposureTargetBias), d.maxExposureTargetBias))
            d.unlockForConfiguration()
        }
    }

    private func applyManualExposure() {
        guard isManual, !seeding else { return }
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration(); self.applyManualExposureLocked(d); d.unlockForConfiguration()
        }
    }

    private func applyManualExposureLocked(_ d: AVCaptureDevice) {
        // Calling this when custom exposure isn't available (session not running yet, some front cameras) raises an NSException.
        guard d.isExposureModeSupported(.custom) else { return }
        let iso = isoLadder[min(isoIndex, isoLadder.count - 1)]
        let dur = shutterLadder[min(shutterIndex, shutterLadder.count - 1)]
        d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000_000),
                                iso: min(max(iso, d.activeFormat.minISO), d.activeFormat.maxISO))
    }

    private func applyWB() {
        guard isManual, !seeding else { return }
        let k = wbLadder[wbIndex]
        sessionQueue.async {
            guard let d = self.device, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
            try? d.lockForConfiguration()
            var g = d.deviceWhiteBalanceGains(for: .init(temperature: k, tint: 0))
            let m = d.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), m); g.greenGain = min(max(g.greenGain, 1), m); g.blueGain = min(max(g.blueGain, 1), m)
            d.setWhiteBalanceModeLocked(with: g)
            d.unlockForConfiguration()
        }
    }

    private func applyFocus() {
        guard isManual, !seeding else { return }
        let p = focusPos
        sessionQueue.async {
            guard let d = self.device, d.isLockingFocusWithCustomLensPositionSupported else { return }
            try? d.lockForConfiguration(); d.setFocusModeLocked(lensPosition: p); d.unlockForConfiguration()
        }
    }

    func pushRenderState() {
        settings.lastStyleID = style.id
        let st = RenderState(style: style, zebra: settings.zebra && isManual, peaking: settings.focusPeaking && isManual, histogram: settings.histogram)
        videoQueue.async { self.renderState = st }
    }

    // MARK: Capture
    func capture() {
        if captureMode == .video { toggleRecording(); return }
        guard hasCamera, !capturing else { return }
        capturing = true
        Feedback.shutter()
        let wantSuper = settings.pipeline == .superRaw && abs(zoom - 1) < 0.05 && position == .back
        let wantPro = settings.pipeline == .proRaw && photoOutput.isAppleProRAWEnabled
        let flashMode = flash
        let hiRes = settings.hiRes
        let dims = photoOutput.maxPhotoDimensions
        captureWasFront = position == .front
        var lead = 0.0
        if position == .front && flash != .off {
            lead = 0.3
            savedBrightness = UIScreen.main.brightness
            screenFlashing = true
            UIScreen.main.brightness = 1
        }
        sessionQueue.asyncAfter(deadline: .now() + lead) {
            self.pendingRaw = nil; self.pendingProcessed = nil
            // The UI is portrait-locked but the saved photo should be upright however the phone is held.
            if let c = self.photoOutput.connection(with: .video), let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture, c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
            let s: AVCapturePhotoSettings
            let bayer = self.photoOutput.availableRawPhotoPixelFormatTypes.first { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            let pro = self.photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
            if wantSuper, let fmt = bayer {
                s = AVCapturePhotoSettings(rawPixelFormatType: fmt); self.captureUsedSuperRaw = true
            } else if wantPro, let fmt = pro {
                s = AVCapturePhotoSettings(rawPixelFormatType: fmt, processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]); self.captureUsedSuperRaw = false
            } else {
                s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc]); self.captureUsedSuperRaw = false
            }
            if self.device?.isFlashAvailable == true, !self.captureUsedSuperRaw {
                let m: AVCaptureDevice.FlashMode = flashMode == .on ? .on : (flashMode == .auto ? .auto : .off)
                if self.photoOutput.supportedFlashModes.contains(m) { s.flashMode = m }
            }
            if hiRes, !self.captureUsedSuperRaw, dims.width > 0 { s.maxPhotoDimensions = dims }
            self.photoOutput.capturePhoto(with: s, delegate: self)
        }
    }

    private func finish(raw: Data?, processed: Data?, superRaw: Bool) {
        DispatchQueue.main.async {
            if self.screenFlashing { self.screenFlashing = false; UIScreen.main.brightness = self.savedBrightness }
        }
        let s = settings
        var style = self.style
        switch s.dateStamp { case .on: style.fx.stamp = "date"; case .off: style.fx.stamp = nil; case .style: break }
        switch s.lightLeaks {
        case .off: style.fx.leak = 0
        case .random: style.fx.leak = Float.random(in: 0.35...0.95); style.fx.leakCorner = Int.random(in: 0..<4)
        case .style: break
        }
        var image: CIImage?
        if superRaw, let raw, let f = CIRAWFilter(imageData: raw, identifierHint: "com.adobe.raw-image") {
            f.isGamutMappingEnabled = true
            image = f.outputImage
        } else if let processed {
            image = CIImage(data: processed, options: [.applyOrientationProperty: true])
        } else if let raw, let f = CIRAWFilter(imageData: raw, identifierHint: "com.adobe.raw-image") {
            image = f.outputImage
        }
        guard var img = image else { DispatchQueue.main.async { self.capturing = false }; return }
        // The live preview is always mirrored; the saved selfie is mirrored too only when the setting is on (like iOS's Mirror Front Camera).
        if captureWasFront && s.mirrorSelfies { img = img.oriented(.upMirrored) }
        img = Styles.apply(style, to: img)
        if superRaw { img = Styles.addGrain(max(style.grain, 0.12), to: img) } else if style.grain > 0 { img = Styles.addGrain(style.grain * 0.6, to: img) }
        img = crop(img, to: s.fullScreenPreview ? AppSettings.screenRatio : s.aspect.ratio)   // full-screen mode saves what the screen shows
        img = Styles.decorate(style.fx, img)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let heic: Data? = s.hdr
            ? try? ciContext.heif10Representation(of: img, colorSpace: p3, options: [:])
            : ciContext.heifRepresentation(of: img, format: .RGBA8, colorSpace: p3, options: [:])
        if s.filmRoll, let heic {
            // Film roll: no thumbnail, no review. The frame goes into the roll and shows up in Photos once developed.
            let name = RollStore.write(heic)
            DispatchQueue.main.async {
                if let name { RollStore.shared.add(file: name) }
                self.capturing = false
                StatsStore.shared.recordPhoto(styleID: style.id, manual: self.isManual, superRaw: superRaw, zoom: Double(self.zoom))
            }
            return
        }
        let thumb = ciContext.createCGImage(img.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25)), from: img.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25)).extent).map(UIImage.init(cgImage:))
        let rawToSave = s.rawPlusHeic ? raw : nil
        if let heic { save(heic: heic, dng: rawToSave) }
        DispatchQueue.main.async {
            self.lastImage = thumb
            if s.photoReviewSeconds > 0 {
                self.reviewImage = thumb
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(s.photoReviewSeconds)) { self.reviewImage = nil }
            }
            self.capturing = false
            StatsStore.shared.recordPhoto(styleID: style.id, manual: self.isManual, superRaw: superRaw, zoom: Double(self.zoom))
        }
    }

    private func crop(_ img: CIImage, to ratio: CGFloat) -> CIImage {
        let e = img.extent
        var w = e.width, h = e.height
        let ratio = e.width > e.height ? 1 / ratio : ratio   // landscape shots keep the same aspect, turned
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let r = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral
        return img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    private func save(heic: Data, dng: Data?) { Self.saveToLibrary(heic: heic, dng: dng) }

    static func saveToLibrary(heic: Data, dng: Data?, completion: ((Bool) -> Void)? = nil) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: heic, options: nil)
            if let dng {
                let o = PHAssetResourceCreationOptions(); o.uniformTypeIdentifier = "com.adobe.raw-image"
                req.addResource(with: .alternatePhoto, data: dng, options: o)
            }
            guard AppSettings.shared.saveToAlbum, let ph = req.placeholderForCreatedAsset else { return }
            let opts = PHFetchOptions(); opts.predicate = NSPredicate(format: "title = %@", "!Camera")
            if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "!Camera").addAssets([ph] as NSArray)
            }
        }, completionHandler: { ok, _ in completion?(ok) })
    }
}

// MARK: - Photo delegate
extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { pendingRaw = data } else { pendingProcessed = data }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finish(raw: pendingRaw, processed: pendingProcessed, superRaw: captureUsedSuperRaw)
    }
}

// MARK: - Live frames
extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput { appendAudio(sampleBuffer); return }
        guard previewGateOpen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let st = renderState
        var img = CIImage(cvPixelBuffer: pb)
        let landscape = CVPixelBufferGetWidth(pb) > CVPixelBufferGetHeight(pb)
        // Portrait <-> landscape: wait until the camera really delivers frames in the new shape, so the box never turns while
        // the picture hasn't (or the other way round). Same-shape changes (0 <-> 180, 90 <-> -90) settle after a short hold.
        func wantsLandscape(_ turn: Double) -> Bool { abs(turn) == 90 }
        if angleDirty {
            let age = Date().timeIntervalSince(angleDirtyAt)
            let sameShape = wantsLandscape(committedTurn) == wantsLandscape(targetTurn)
            if (sameShape ? age > 0.15 : landscape == wantsLandscape(targetTurn)) || age > 0.6 {
                angleDirty = false
                committedTurn = targetTurn
                let a = currentAngle(), t = targetTurn
                DispatchQueue.main.async {
                    self.deviceTurn = t; self.liveAngle = a
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.isTurning = false }
                }
            }
        }
        lastBufferLandscape = landscape
        // Frames whose shape disagrees with the box's current turn belong to a turn in progress: don't show them.
        if landscape != wantsLandscape(committedTurn) { return }
        if pendingFirstFrame {
            pendingFirstFrame = false
            let d = device
            let info = "\(d?.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: "") ?? "?")\nbuffer \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb)) \(landscape ? "landscape" : "portrait")\nfov \(String(format: "%.1f", d?.activeFormat.videoFieldOfView ?? 0))° zoom \(String(format: "%.2f", d?.videoZoomFactor ?? 0)) base \(String(format: "%.2f", zoomBase))\nfmt \(d.map { "\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription).width)×\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription).height)" } ?? "?")"
            DispatchQueue.main.async { self.isSwitching = false; self.diagnostics = info }
        }
        img = Styles.apply(st.style, to: img)
        let front = device?.position == .front
        if isRecording { appendVideo(front && settings.mirrorSelfies ? img.oriented(.upMirrored) : img, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        // Live selfie preview: mirrored like a mirror (the system Camera's viewfinder), independent of what gets saved.
        if front && settings.mirrorPreview { img = img.oriented(.upMirrored) }
        frameCount += 1
        if st.histogram, frameCount % 4 == 0 { computeHistogram(img) }
        if isManual || true {
            if st.peaking { img = overlayPeaking(img) }
            if st.zebra { img = overlayZebra(img) }
        }
        if !nativePreviewActive, let cg = ciContext.createCGImage(img, from: img.extent) { frameSink?(cg) }
    }

    private func gray(_ img: CIImage) -> CIImage {
        let v = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        return img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": v, "inputGVector": v, "inputBVector": v])
    }

    private func tint(_ mask: CIImage, _ color: CIColor, over img: CIImage) -> CIImage {
        let solid = CIImage(color: color).cropped(to: img.extent)
        return solid.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: mask.applyingFilter("CIMaskToAlpha")])
    }

    private func overlayZebra(_ img: CIImage) -> CIImage {
        let g = gray(img)
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: ["inputCenter": CIVector(x: 0, y: 0), "inputColor0": CIColor.white, "inputColor1": CIColor.black, "inputWidth": 7, "inputSharpness": 1])!
            .outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 4)).cropped(to: img.extent)
        let hi = g.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.96])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: stripes])
        let lo = g.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.03]).applyingFilter("CIColorInvert")
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: stripes])
        return tint(lo, CIColor(red: 0.1, green: 0.35, blue: 1, alpha: 1), over: tint(hi, CIColor(red: 1, green: 0.1, blue: 0.1, alpha: 1), over: img))
    }

    private func overlayPeaking(_ img: CIImage) -> CIImage {
        let edges = gray(img).applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6])
        let mask = gray(edges).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.3])
        return tint(mask, CIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1), over: img)
    }

    private func computeHistogram(_ img: CIImage) {
        let w = 64, h = 48
        let e = img.extent
        let small = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        ciContext.render(small, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var bins = [Float](repeating: 0, count: 32)
        for i in stride(from: 0, to: buf.count, by: 4) {
            let l = 0.299 * Float(buf[i]) + 0.587 * Float(buf[i + 1]) + 0.114 * Float(buf[i + 2])
            bins[min(31, Int(l / 8))] += 1
        }
        let m = max(bins.max() ?? 1, 1)
        let norm = bins.map { $0 / m }
        DispatchQueue.main.async { self.histogram = norm }
    }
}


// MARK: - Video recording (styled frames written with AVAssetWriter)
extension CameraModel {
    func setMode(_ m: CaptureMode) {
        guard m != captureMode, !isRecording else { return }
        if m == .video { prepareAudio { ok in DispatchQueue.main.async { self.captureMode = .video } } } else { captureMode = .photo }
        Feedback.toggle()
    }

    private func prepareAudio(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            self.sessionQueue.async {
                if ok, !self.audioConfigured, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic) {
                    self.session.beginConfiguration()
                    if self.session.canAddInput(input) { self.session.addInput(input) }
                    if self.session.canAddOutput(self.audioOutput) { self.audioOutput.setSampleBufferDelegate(self, queue: self.videoQueue); self.session.addOutput(self.audioOutput) }
                    self.session.commitConfiguration()
                    self.audioConfigured = true
                }
                done(ok)
            }
        }
    }

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        videoQueue.async {
            self.writer = w; self.writerStarted = false; self.recordingURL = url
            self.writerVideo = nil; self.writerAudio = nil; self.adaptor = nil
        }
        Feedback.shutter()
        recordSeconds = 0
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.recordSeconds += 1 }
    }

    private func stopRecording() {
        isRecording = false
        recordTimer?.invalidate(); recordTimer = nil
        Feedback.thump()
        videoQueue.async {
            guard let w = self.writer, self.writerStarted, let url = self.recordingURL else { self.writer = nil; return }
            self.writerVideo?.markAsFinished(); self.writerAudio?.markAsFinished()
            self.writer = nil
            w.finishWriting {
                self.save(videoAt: url)
                DispatchQueue.main.async { StatsStore.shared.recordVideo() }
            }
        }
    }

    private func appendVideo(_ image: CIImage, at pts: CMTime) {
        guard let w = writer else { return }
        let e = image.extent
        let k = min(1, 1920 / max(e.width, e.height))
        let outW = Int((e.width * k) / 2) * 2, outH = Int((e.height * k) / 2) * 2
        if !writerStarted {
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: outW, AVVideoHeightKey: outH])
            v.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: outW, kCVPixelBufferHeightKey as String: outH])
            if w.canAdd(v) { w.add(v) }
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100, AVEncoderBitRateKey: 96_000])
            a.expectsMediaDataInRealTime = true
            if audioConfigured, w.canAdd(a) { w.add(a); writerAudio = a }
            writerVideo = v; adaptor = ad
            w.startWriting(); w.startSession(atSourceTime: pts)
            writerStarted = true
        }
        guard let v = writerVideo, let ad = adaptor, v.isReadyForMoreMediaData, let pool = ad.pixelBufferPool else { return }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return }
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / e.width, y: CGFloat(outH) / e.height))
        ciContext.render(scaled, to: pb)
        ad.append(pb, withPresentationTime: pts)
    }

    private func appendAudio(_ sb: CMSampleBuffer) {
        guard isRecording, writerStarted, let a = writerAudio, a.isReadyForMoreMediaData else { return }
        a.append(sb)
    }

    private func save(videoAt url: URL) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .video, fileURL: url, options: nil)
            guard AppSettings.shared.saveToAlbum, let ph = req.placeholderForCreatedAsset else { return }
            let opts = PHFetchOptions(); opts.predicate = NSPredicate(format: "title = %@", "!Camera")
            if let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts).firstObject {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "!Camera").addAssets([ph] as NSArray)
            }
        }) { _, _ in try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Camera Control / hardware controls (iPhone 16+)
extension CameraModel: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {}

    fileprivate func installCameraControls(_ dev: AVCaptureDevice) {
        guard session.supportsControls else { return }
        session.setControlsDelegate(self, queue: sessionQueue)
        session.controls.forEach { session.removeControl($0) }

        let zoomSlider = AVCaptureSlider("Zoom", symbolName: "plus.magnifyingglass", in: 0.5...10, step: 0.1)
        zoomSlider.value = 1
        zoomSlider.setActionQueue(.main) { [weak self] v in self?.setZoom(CGFloat(v)) }

        let ev = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", in: -6...6, step: 1.0 / 3)
        ev.setActionQueue(.main) { [weak self] v in
            guard let self, let i = self.evLadder.firstIndex(where: { abs($0 - v) < 0.17 }) else { return }
            self.evIndex = i
        }

        let names = styles.map(\.name)
        let picker = AVCaptureIndexPicker("Style", symbolName: "paintpalette", localizedIndexTitles: names)
        picker.setActionQueue(.main) { [weak self] i in self?.styleIndex = i }

        for c in [zoomSlider, ev, picker] where session.canAddControl(c) { session.addControl(c) }
    }
}
