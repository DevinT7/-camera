import AVFoundation
import CoreMotion
import CoreImage
import Vision
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

enum CaptureMode: Hashable, CaseIterable {
    case photo, video, long, double
    var label: String { switch self { case .photo: "PHOTO"; case .video: "VIDEO"; case .long: "LONG"; case .double: "DOUBLE" } }
    var symbol: String { switch self { case .photo: "camera.fill"; case .video: "video.fill"; case .long: "scribble.variable"; case .double: "square.on.square" } }
}

final class CameraModel: NSObject, ObservableObject {
    // MARK: UI state
    @Published var authorized = false
    @Published var hasCamera = true
    @Published var position: AVCaptureDevice.Position = .back
    @Published var zoom: CGFloat = 1
    @Published var minZoom: CGFloat = 1
    @Published var maxZoom: CGFloat = 10
    @Published var isManual = false {
        didSet {
            guard isManual != oldValue else { return }
            if isManual { seedManualFromAuto() }   // start from what Auto was doing, so the picture doesn't jump
            applyModeChange()
        }
    }
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
    @Published var diagnostics = ""
    private var previewGateOpen = true        // read on videoQueue, written on sessionQueue
    private var pendingFirstFrame = false
    private var savedBrightness: CGFloat = 0.5
    private var captureWasFront = false
    @Published var isRecording = false
    @Published var recordSeconds = 0
    /// How far the scene is from a normal exposure, in stops (+ = too bright). The Manual light meter's needle.
    @Published var meterOffset: Float = 0
    private var meterObservation: NSKeyValueObservation?
    /// 0...1 while a long exposure is gathering frames, nil otherwise.
    @Published var longProgress: Double?
    /// The first frame of a double exposure, shown faintly over the viewfinder until the second is taken.
    @Published var doubleGhost: UIImage?

    // Long exposure (videoQueue): live frames are lined up and averaged for a few seconds.
    static let longSeconds = 3.0
    private var longRunning = false
    private var longStart: CFTimeInterval = 0
    private var longCount = 0
    private var longTurn = 0
    private var longAcc: CIImageAccumulator?
    private var longRef: CIImage?
    private var longRefScale: CGFloat = 1

    // Double exposure: the first shot waits here (finish() runs on the photo delegate's queue, cancel on main).
    private let doubleLock = NSLock()
    private var doubleFirst: CIImage?
    private var captureIsDouble = false

    // stepped manual values (index into ladders)
    @Published var evIndex = 18 { didSet { applyEV() } }          // 0...36 -> -6...+6 in 1/3
    @Published var isoIndex = 0 { didSet { applyManualExposure() } }
    @Published var shutterIndex = 0 { didSet { applyManualExposure() } }
    @Published var wbIndex = 33 { didSet { applyWB() } }          // 2600...9000 step 100
    @Published var focusPos: Float = 0.5 { didSet { applyFocus() } }
    /// Settings the user has moved off their defaults (drives the reset affordance).
    @Published var touched: Set<ManualParam> = []
    private var seeding = false

    /// Manual values handed to the session queue (it can't read the main-thread ladders safely).
    private struct ManualValues { var iso: Float; var duration: Double; var kelvin: Float?; var lens: Float? }
    /// The back camera's lenses, widest first, with the zoom (relative to 1×) where each one takes over. Manual mode runs on
    /// one of these directly: the combined multi-lens camera Auto uses doesn't allow manual shutter, ISO, focus or white balance.
    private var backLenses: [(device: AVCaptureDevice, start: CGFloat)] = []   // sessionQueue
    private var laddersBuilt = false

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
        // The round last-photo button follows the library: a deleted photo drops out of it.
        PHPhotoLibrary.shared().register(self)
        NotificationCenter.default.addObserver(forName: .photoLogChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLastImage() }
        }
    }

    /// Thumbnail of the newest photo this app made that still exists in the library (nil if none).
    @MainActor func refreshLastImage() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        PhotoLog.shared.backfillIfNeeded()
        // The newest thing in the whole library (photo or video), so the button reads as "your photos" from the first launch.
        let o0 = PHFetchOptions()
        o0.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o0.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        o0.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: o0).firstObject ?? PhotoLog.shared.existingAssets().first?.1 else { lastImage = nil; return }
        let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.resizeMode = .fast; o.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 180, height: 180), contentMode: .aspectFill, options: o) { img, _ in
            DispatchQueue.main.async { if let img { self.lastImage = img } }
        }
    }

    func setViewfinderSize(_ s: CGSize) { layerProbe.frame = CGRect(origin: .zero, size: s) }

    // MARK: Lifecycle
    func start() {
        // iOS silences haptics and system sounds while a capture session is recording unless this is allowed.
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
        Task { @MainActor in self.refreshLastImage() }
        startMotion()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { self.authorized = ok; if ok { self.configureIfNeeded() } }
            }
        default: DispatchQueue.main.async { self.authorized = false }
        }
        // Read access too: the library button shows your newest photo, and Photo Lab needs it anyway.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in Task { @MainActor in self.refreshLastImage() } }
        }
    }

    func stop() { sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } } }

    private var configured = false
    private func configureIfNeeded() {
        authorized = true
        sessionQueue.async {
            if !self.configured { self.configure(position: .back); self.configured = true }
            if !self.session.isRunning { self.session.startRunning() }
            // Re-apply a remembered Manual mode now that the session is actually running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { if self.isManual { self.seedManualFromAuto(); self.applyModeChange() } }
        }
    }

    private func pickDevice(_ pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = pos == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInUltraWideCamera, .builtInTrueDepthCamera, .builtInWideAngleCamera]   // front ultra-wide = Center Stage selfie camera (iPhone 17 family), what the system Camera uses
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: pos).devices.first
    }

    /// `manual` set: run on a single physical lens with these values applied. `keepZoom`: stay at this zoom (lens swaps).
    private func configure(position pos: AVCaptureDevice.Position, manual: ManualValues? = nil, keepZoom: CGFloat? = nil) {
        guard let picked = pickDevice(pos) else {
            DispatchQueue.main.async { self.hasCamera = false }
            return
        }
        // Continuous zoom range, expressed relative to the main (1x) lens.
        var base: CGFloat = 1
        if pos == .back, picked.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let first = picked.virtualDeviceSwitchOverVideoZoomFactors.first {
            base = CGFloat(truncating: first)
        }
        if pos == .front, picked.deviceType == .builtInUltraWideCamera {
            // The Center Stage selfie camera is ultra-wide. Open at a normal selfie framing (~24mm equivalent, like the system
            // Camera) so "1×" isn't the full 95° view; the wider view stays available below 1×.
            var nominal: CGFloat = 0
            if #available(iOS 26.0, *) { nominal = CGFloat(picked.nominalFocalLengthIn35mmFilm) }
            let focal = nominal > 0 ? nominal : 18 / tan(CGFloat(picked.activeFormat.videoFieldOfView) * .pi / 360)
            base = min(max(24 / focal, 1), max(picked.maxAvailableVideoZoomFactor / 2, 1))
        }
        if pos == .back {
            backLenses = []
            if picked.isVirtualDevice {
                let starts = [1] + picked.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
                backLenses = zip(picked.constituentDevices, starts).map { ($0, $1 / base) }
            }
        }
        let lo = picked.minAvailableVideoZoomFactor / base
        let hi = min(picked.maxAvailableVideoZoomFactor / base, 25)
        let startZoom = min(max(keepZoom ?? (pos == .back && settings.rememberSettings ? CGFloat(settings.lastLens) : 1), lo), hi)
        var dev = picked
        if manual != nil, pos == .back, let lens = lens(for: startZoom) {
            dev = lens.device
            base = 1 / lens.start
        }
        guard let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.hasCamera = false }
            return
        }
        // Drop frames while the connections are rebuilt: for a moment they arrive in the sensor's native orientation
        // (that was the upside-down flash after flipping). The preview holds/blurs until they're upright.
        previewGateOpen = false; pendingFirstFrame = true
        DispatchQueue.main.async { self.isSwitching = true }
        session.beginConfiguration()
        session.sessionPreset = .photo
        // Only the camera input: the microphone (added the first time video is recorded) stays.
        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }.forEach { session.removeInput($0) }
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
        videoQueue.async { self.configuredAt = Date() }
        learnPortraitAngle()

        device = dev
        meterObservation = dev.observe(\.exposureTargetOffset, options: [.new]) { [weak self] d, _ in
            let v = (d.exposureTargetOffset * 10).rounded() / 10
            DispatchQueue.main.async { if let self, self.meterOffset != v { self.meterOffset = v } }
        }
        installCameraControls(dev)
        zoomBase = base
        buildLadders(dev)
        try? dev.lockForConfiguration()
        dev.videoZoomFactor = min(max(startZoom * base, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
        if let m = manual {
            applyManualLocked(dev, m)
        } else {
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        }
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

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// Set by the view: when the system preview layer is on screen we skip building our own preview frames.
    var nativePreviewActive = false
    private var angleObservation: NSKeyValueObservation?
    weak var systemPreviewLayer: AVCaptureVideoPreviewLayer?

    // How rotation works (the same idea as the system Camera): the live stream is always portrait and never changes shape,
    // so turning the phone never rebuilds the capture pipeline. Each frame is turned upright in Core Image instead, which
    // is free. Read/written on videoQueue.
    private var captureAngle: CGFloat = 90      // horizon-level angle from the coordinator
    private var frameAngle: CGFloat = 90        // the stream's portrait angle, videoQueue's copy of streamAngle
    /// The connection angle that makes this camera's stream portrait (sessionQueue). It's 90 on the back camera but not on
    /// every front camera (the Center Stage selfie sensor is mounted differently), so it's learned from the rotation
    /// coordinator while the phone is held upright, and remembered per camera.
    private var streamAngle: CGFloat = 90
    private let motion = CMMotionManager()
    private var phoneUpright = false            // sessionQueue; false until gravity says so
    private var recordTurn = 0                   // a video keeps the orientation it started in
    private var configuredAt = Date.distantPast
    private var fixingAngle = false

    /// Live rotation numbers for the diagnostics overlay.
    func rotationReport() -> String {
        func f(_ v: CGFloat?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        let coord = rotationCoordinator
        let out = videoOutput.connection(with: .video)
        let l1 = "coord capture \(f(coord?.videoRotationAngleForHorizonLevelCapture))  portrait \(f(streamAngle))  upright \(phoneUpright ? "Y" : "N")"
        let l2 = "layer \(f(systemPreviewLayer?.connection?.videoRotationAngle))  output \(f(out?.videoRotationAngle))  native \(nativePreviewActive ? "Y" : "N")"
        return [l1, l2].joined(separator: "\n")
    }

    /// Horizon-level rotation from the system coordinator (it accounts for each sensor's mounting and for gravity).
    func currentAngle() -> CGFloat { rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90 }

    /// Clockwise turn (0/90/180/270) that takes a frame shot at connection angle `from` to how it looks at angle `to`.
    static func turn(_ to: CGFloat, from: CGFloat) -> Int { ((Int((to - from).rounded()) % 360) + 360) % 360 / 90 * 90 }
    private func snap(_ a: CGFloat) -> CGFloat { CGFloat(((Int((a / 90).rounded()) * 90) % 360 + 360) % 360) }

    /// Which way the phone is held, from gravity (the UI is portrait-locked, so the interface can't tell us).
    private func startMotion() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            let upright = a.y < -0.75 && abs(a.x) < 0.4 && abs(a.z) < 0.85
            self.sessionQueue.async {
                let was = self.phoneUpright
                self.phoneUpright = upright
                if upright && !was { self.learnPortraitAngle() }
            }
        }
    }

    /// Runs on sessionQueue. Uses the remembered portrait angle for this camera, and while the phone is upright reads the
    /// real one from the coordinator (upright, horizon-level capture is portrait by definition).
    private func learnPortraitAngle() {
        guard let dev = device ?? session.inputs.compactMap({ ($0 as? AVCaptureDeviceInput)?.device }).first(where: { $0.hasMediaType(.video) }) else { return }
        let key = "portraitAngle.\(dev.uniqueID)"
        var angle = UserDefaults.standard.object(forKey: key) as? Double ?? 90
        if phoneUpright, let a = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture {
            angle = Double(snap(a))
            UserDefaults.standard.set(angle, forKey: key)
        }
        let target = CGFloat(angle)
        streamAngle = target
        if let c = videoOutput.connection(with: .video), c.videoRotationAngle != target, c.isVideoRotationAngleSupported(target) {
            c.videoRotationAngle = target
        }
        videoQueue.async { self.frameAngle = target }
    }

    /// Turns a frame clockwise by a multiple of 90°. Exact, and the result starts at the origin.
    private func turned(_ img: CIImage, clockwise deg: Int) -> CIImage {
        switch (deg % 360 + 360) % 360 {
        case 90: return img.oriented(.right)
        case 180: return img.oriented(.down)
        case 270: return img.oriented(.left)
        default: return img
        }
    }

    private func watchAngle(_ coordinator: AVCaptureDevice.RotationCoordinator) {
        // Only remembered: the stream itself is never re-rotated (that's what made turns slow and glitchy).
        angleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let a = change.newValue else { return }
            self.videoQueue.async { self.captureAngle = a }
        }
    }

    private func applyOrientation(for pos: AVCaptureDevice.Position) {
        for out in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let c = out.connection(with: .video) else { continue }
            let angle: CGFloat = out === videoOutput ? streamAngle : currentAngle()   // live stream: fixed portrait
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
        let shutterList = shutters.isEmpty ? [1.0 / 60] : shutters
        let first = !laddersBuilt
        laddersBuilt = true
        DispatchQueue.main.async {
            // Keep the chosen ISO and shutter across lens/camera switches (each lens has its own ladder); defaults ISO 100, 1/60.
            let iso = first ? 100 : self.isoLadder[min(self.isoIndex, self.isoLadder.count - 1)]
            let dur = first ? 1.0 / 60 : self.shutterLadder[min(self.shutterIndex, self.shutterLadder.count - 1)]
            self.seeding = true
            self.isoLadder = isos
            self.shutterLadder = shutterList
            self.isoIndex = isos.enumerated().min { abs($0.element - iso) < abs($1.element - iso) }?.offset ?? 0
            self.shutterIndex = shutterList.enumerated().min { abs(log($0.element / dur)) < abs(log($1.element / dur)) }?.offset ?? 0
            self.seeding = false
        }
    }

    /// The physical back lens that should be used at zoom `z`: the longest one that doesn't need to zoom out. sessionQueue.
    private func lens(for z: CGFloat) -> (device: AVCaptureDevice, start: CGFloat)? {
        backLenses.last { $0.start <= z + 0.001 } ?? backLenses.first
    }

    private func manualValues() -> ManualValues {
        ManualValues(iso: isoLadder[min(isoIndex, isoLadder.count - 1)],
                     duration: shutterLadder[min(shutterIndex, shutterLadder.count - 1)],
                     kelvin: touched.contains(.wb) ? wbLadder[wbIndex] : nil,
                     lens: touched.contains(.focus) ? focusPos : nil)
    }

    // MARK: Controls
    func flip() {
        let new: AVCaptureDevice.Position = position == .back ? .front : .back
        let m = isManual ? manualValues() : nil
        sessionQueue.async { self.configure(position: new, manual: m) }
    }

    func setZoom(_ z: CGFloat, ramp: Bool = false) {
        let clamped = min(max(z, minZoom), maxZoom)
        zoom = clamped
        settings.lastLens = Double(clamped)
        let m = isManual && !isRecording ? manualValues() : nil
        sessionQueue.async {
            guard let d = self.device else { return }
            // Manual runs on one physical lens: zooming past where another lens takes over swaps to that lens.
            if let m, let want = self.lens(for: clamped), want.device != d, self.backLenses.contains(where: { $0.device == d }) {
                self.configure(position: .back, manual: m, keepZoom: clamped)
                return
            }
            try? d.lockForConfiguration()
            let target = min(max(clamped * self.zoomBase, d.minAvailableVideoZoomFactor), d.maxAvailableVideoZoomFactor)
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

    /// Moves shutter speed (then ISO, if the shutter would get too slow to hand-hold) so the light meter reads 0.
    func matchMeter() {
        let off = Double(meterOffset)
        guard isManual, abs(off) >= 0.15 else { return }
        let dur = shutterLadder[min(shutterIndex, shutterLadder.count - 1)]
        var iso = Double(isoLadder[min(isoIndex, isoLadder.count - 1)])
        var want = dur * pow(2, -off)
        let slowest = max(dur, 1.0 / 30), fastest = shutterLadder.last ?? want
        if want > slowest { iso *= want / slowest; want = slowest }
        if want < fastest { iso *= want / fastest; want = fastest }
        func nearestLog<T: BinaryFloatingPoint>(_ a: [T], _ v: Double) -> Int { a.enumerated().min { abs(log(Double($0.element) / v)) < abs(log(Double($1.element) / v)) }?.offset ?? 0 }
        shutterIndex = nearestLog(shutterLadder, want)
        isoIndex = nearestLog(isoLadder, iso)
        touched.formUnion([.shutter, .iso])
        Feedback.detent()
    }

    /// Copies what auto exposure/WB/focus are doing right now into the manual ladders, so switching to manual doesn't jump.
    func seedManualFromAuto() {
        guard let d = device else { return }
        let iso = d.iso, dur = CMTimeGetSeconds(d.exposureDuration)
        let g = d.deviceWhiteBalanceGains
        let k = d.temperatureAndTintValues(for: AVCaptureDevice.WhiteBalanceGains(redGain: min(max(g.redGain, 1), d.maxWhiteBalanceGain), greenGain: min(max(g.greenGain, 1), d.maxWhiteBalanceGain), blueGain: min(max(g.blueGain, 1), d.maxWhiteBalanceGain))).temperature
        let lens = d.lensPosition
        seeding = true; defer { seeding = false }
        if let i = isoLadder.enumerated().min(by: { abs($0.element - iso) < abs($1.element - iso) })?.offset { isoIndex = i }
        if let i = shutterLadder.enumerated().min(by: { abs(log($0.element / max(dur, 1e-6))) < abs(log($1.element / max(dur, 1e-6))) })?.offset { shutterIndex = i }
        if let i = wbLadder.enumerated().min(by: { abs($0.element - k) < abs($1.element - k) })?.offset { wbIndex = i }
        focusPos = lens
    }

    private func applyModeChange() {
        if !isManual { param = .ev; touched = touched.intersection([.ev]) }
        // EV only steers Auto; in Manual the dial starts on shutter speed.
        if isManual && param == .ev { param = .shutter }
        pushRenderState()
        settings.lastManual = isManual
        let manual = isManual, m = manualValues(), pos = position, z = zoom, recording = isRecording
        sessionQueue.async {
            guard let d = self.device else { return }
            let onLens = self.backLenses.contains { $0.device == d }
            // The combined back camera can't do manual: move onto the physical lens for this zoom, and back again for Auto.
            if pos == .back, !recording, !self.backLenses.isEmpty, manual != onLens {
                self.configure(position: .back, manual: manual ? m : nil, keepZoom: z)
                return
            }
            try? d.lockForConfiguration()
            if manual {
                self.applyManualLocked(d, m)
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
        applyManualLocked(d, ManualValues(iso: isoLadder[min(isoIndex, isoLadder.count - 1)],
                                          duration: shutterLadder[min(shutterIndex, shutterLadder.count - 1)], kelvin: nil, lens: nil))
    }

    /// Applies manual values to a locked device. Every value is clamped to what this lens allows (out-of-range values raise).
    private func applyManualLocked(_ d: AVCaptureDevice, _ m: ManualValues) {
        // Calling this when custom exposure isn't available (session not running yet, combined multi-lens cameras) raises an NSException.
        if d.isExposureModeSupported(.custom) {
            let f = d.activeFormat
            let dur = min(max(m.duration, CMTimeGetSeconds(f.minExposureDuration)), CMTimeGetSeconds(f.maxExposureDuration))
            d.setExposureModeCustom(duration: CMTime(seconds: dur, preferredTimescale: 1_000_000_000),
                                    iso: min(max(m.iso, f.minISO), f.maxISO))
        }
        if let k = m.kelvin, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            var g = d.deviceWhiteBalanceGains(for: .init(temperature: k, tint: 0))
            let mx = d.maxWhiteBalanceGain
            g.redGain = min(max(g.redGain, 1), mx); g.greenGain = min(max(g.greenGain, 1), mx); g.blueGain = min(max(g.blueGain, 1), mx)
            d.setWhiteBalanceModeLocked(with: g)
        }
        if let p = m.lens, d.isLockingFocusWithCustomLensPositionSupported {
            d.setFocusModeLocked(lensPosition: min(max(p, 0), 1))
        }
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
        if captureMode == .long { startLongExposure(); return }
        guard hasCamera, !capturing else { return }
        capturing = true
        Feedback.shutter()
        captureIsDouble = captureMode == .double
        let wantSuper = settings.pipeline == .superRaw && abs(zoom - 1) < 0.05 && position == .back
        let wantPro = settings.pipeline == .proRaw && photoOutput.isAppleProRAWEnabled
        let flashMode = flash
        let hiRes = settings.hiRes
        let dims = photoOutput.maxPhotoDimensions
        let manualShot = isManual
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
            // Otherwise the photo pipeline may pick its own ISO/shutter for multi-frame fusion and ignore Manual.
            if manualShot, !self.captureUsedSuperRaw { s.photoQualityPrioritization = .speed }
            self.photoOutput.capturePhoto(with: s, delegate: self)
        }
    }

    private func finish(raw: Data?, processed: Data?, superRaw: Bool, image given: CIImage? = nil, double: Bool = false) {
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
        var image: CIImage? = given
        if image != nil {
        } else if superRaw, let raw, let f = CIRAWFilter(imageData: raw, identifierHint: "com.adobe.raw-image") {
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
        if double {
            doubleLock.lock()
            let first = doubleFirst
            if first == nil { doubleFirst = img }
            doubleLock.unlock()
            guard let first else {
                // First half: keep it, show it as a ghost to line up the second, save nothing yet.
                let k = min(1, 900 / max(img.extent.width, img.extent.height))
                let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
                let ghost = ciContext.createCGImage(small, from: small.extent).map(UIImage.init(cgImage:))
                DispatchQueue.main.async { self.doubleGhost = ghost; self.capturing = false; Feedback.detent() }
                return
            }
            img = Self.blendDouble(first, img)
            doubleLock.lock(); doubleFirst = nil; doubleLock.unlock()
            DispatchQueue.main.async { self.doubleGhost = nil }
        }
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
        writeLastPhoto(img)
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

    /// Throws away a waiting first half of a double exposure.
    func cancelDouble() {
        doubleLock.lock(); doubleFirst = nil; doubleLock.unlock()
        doubleGhost = nil
        Feedback.thump()
    }

    /// Two exposures on one frame, like rewinding film: a screen blend, so each picture shows through the other's shadows.
    static func blendDouble(_ a: CIImage, _ b: CIImage) -> CIImage {
        let e = b.extent, ae = a.extent
        let k = max(e.width / ae.width, e.height / ae.height)   // fill the second frame even if the phone was turned between shots
        var first = a.transformed(by: CGAffineTransform(scaleX: k, y: k))
        first = first.transformed(by: CGAffineTransform(translationX: e.midX - first.extent.midX, y: e.midY - first.extent.midY)).cropped(to: e)
        // Each half is pulled down a little first so the overlap doesn't blow out to white.
        func dim(_ i: CIImage) -> CIImage { i.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.45]) }
        return dim(b).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: dim(first)]).cropped(to: e)
    }

    // MARK: Long exposure
    private func startLongExposure() {
        guard hasCamera, !capturing else { return }
        capturing = true
        Feedback.shutter()
        captureWasFront = position == .front
        longProgress = 0
        videoQueue.async {
            self.longTurn = Self.turn(self.captureAngle, from: self.frameAngle)   // upright however the phone is held
            self.longAcc = nil; self.longRef = nil; self.longCount = 0
            self.longStart = CACurrentMediaTime()
            self.longRunning = true
        }
    }

    /// videoQueue. Lines each frame up with the first (so hand shake cancels out and only moving things blur), then
    /// folds it into a running average.
    private func accumulateLong(_ raw: CIImage) {
        let frame = turned(raw, clockwise: longTurn)
        let e = frame.extent
        var aligned = frame
        if let ref = longRef {
            let small = frame.transformed(by: CGAffineTransform(scaleX: longRefScale, y: longRefScale))
            let req = VNTranslationalImageRegistrationRequest(targetedCIImage: small)
            try? VNImageRequestHandler(ciImage: ref).perform([req])
            if let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform {
                aligned = frame.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: t.tx / longRefScale, y: t.ty / longRefScale)).cropped(to: e)
            }
        } else {
            longRefScale = 320 / max(e.width, e.height)
            longRef = frame.transformed(by: CGAffineTransform(scaleX: longRefScale, y: longRefScale))
        }
        if let acc = longAcc, acc.extent == e {
            longCount += 1
            let mixed = acc.image().applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: aligned, kCIInputTimeKey: 1 / Double(longCount)])
            acc.setImage(mixed)
        } else if longAcc == nil, let acc = CIImageAccumulator(extent: e, format: .RGBAh) {
            acc.setImage(aligned); longAcc = acc; longCount = 1
        }
        let progress = (CACurrentMediaTime() - longStart) / Self.longSeconds
        DispatchQueue.main.async { if self.longProgress != nil { self.longProgress = min(progress, 1) } }
        guard progress >= 1, let acc = longAcc else { return }
        longRunning = false
        let out = acc.image()
        let cg = ciContext.createCGImage(out, from: out.extent)
        longAcc = nil; longRef = nil
        DispatchQueue.main.async { self.longProgress = nil; Feedback.thump() }
        DispatchQueue.global(qos: .userInitiated).async {
            if let cg { self.finish(raw: nil, processed: nil, superRaw: false, image: CIImage(cgImage: cg)) }
            else { DispatchQueue.main.async { self.capturing = false } }
        }
    }

    /// A small JPEG of the latest photo for the Last Photo widget (skipped in film roll mode: those shots stay hidden).
    private func writeLastPhoto(_ img: CIImage) {
        guard let url = SharedStore.lastPhotoURL else { return }
        let e = img.extent
        let k = min(1, 800 / max(e.width, e.height))
        let small = img.transformed(by: CGAffineTransform(scaleX: k, y: k))
        if let data = ciContext.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) {
            try? data.write(to: url, options: .atomic)
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

    private final class IDBox { var id: String? }

    static func saveToLibrary(heic: Data, dng: Data?, date: Date = Date(), completion: ((Bool) -> Void)? = nil) {
        let box = IDBox()
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            box.id = req.placeholderForCreatedAsset?.localIdentifier
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
        }, completionHandler: { ok, _ in
            if ok, let id = box.id { DispatchQueue.main.async { PhotoLog.shared.add(id: id, date: date) } }
            completion?(ok)
        })
    }
}

extension CameraModel: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.refreshLastImage() }
    }
}

// MARK: - Photo delegate
extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { pendingRaw = data } else { pendingProcessed = data }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        finish(raw: pendingRaw, processed: pendingProcessed, superRaw: captureUsedSuperRaw, double: captureIsDouble)
    }
}

// MARK: - Live frames
extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput { appendAudio(sampleBuffer); return }
        guard previewGateOpen, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let st = renderState
        var raw = CIImage(cvPixelBuffer: pb)
        // The stream should always be portrait. Switching cameras rebuilds the connection and can drop that setting,
        // leaving frames in the sensor's native sideways shape: straighten them here and put portrait back.
        let c = connection.videoRotationAngle, want = frameAngle
        if abs(c - want) > 1 {
            raw = turned(raw, clockwise: Self.turn(want, from: c))
            if !fixingAngle {
                fixingAngle = true
                sessionQueue.async {
                    let a = self.streamAngle
                    if let conn = self.videoOutput.connection(with: .video), conn.isVideoRotationAngleSupported(a) { conn.videoRotationAngle = a }
                    self.videoQueue.async { self.fixingAngle = false }
                }
            }
        }
        let landscape = raw.extent.width > raw.extent.height
        // Right after a camera switch a few frames can still come in the wrong shape: skip those.
        if landscape && Date().timeIntervalSince(configuredAt) < 1 { return }
        if pendingFirstFrame {
            pendingFirstFrame = false
            let d = device
            let info = "\(d?.deviceType.rawValue.replacingOccurrences(of: "AVCaptureDeviceType", with: "") ?? "?")\nbuffer \(CVPixelBufferGetWidth(pb))×\(CVPixelBufferGetHeight(pb)) \(landscape ? "landscape" : "portrait")\nfov \(String(format: "%.1f", d?.activeFormat.videoFieldOfView ?? 0))° zoom \(String(format: "%.2f", d?.videoZoomFactor ?? 0)) base \(String(format: "%.2f", zoomBase))\nfmt \(d.map { "\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription).width)×\(CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription).height)" } ?? "?")"
            DispatchQueue.main.async { self.isSwitching = false; self.diagnostics = info }
        }
        let front = device?.position == .front
        let liveTurn = Self.turn(captureAngle, from: want)
        // Style and mirror in world-upright terms (what gets saved), so a sideways shot looks the same in the viewfinder.
        func upright(_ turn: Int, mirror: Bool) -> CIImage {
            let u = turned(raw, clockwise: turn)
            var img = Styles.apply(st.style, to: u).cropped(to: u.extent)
            if mirror { img = img.oriented(.upMirrored) }
            return img
        }
        if longRunning { accumulateLong(raw) }
        if isRecording {
            appendVideo(upright(recordTurn, mirror: front && settings.mirrorSelfies), at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        guard !nativePreviewActive || st.histogram else { return }
        // Live selfie preview: mirrored like a mirror (the system Camera's viewfinder), independent of what gets saved.
        // Then turned back to the phone's own frame: the viewfinder never turns, the scene in it stays upright.
        // Selfie: a mirrored portrait view that never turns, like a hand mirror (what the system Camera shows).
        var img = front
            ? { let m = Styles.apply(st.style, to: raw).cropped(to: raw.extent); return settings.mirrorPreview ? m.oriented(.upMirrored) : m }()
            : turned(upright(liveTurn, mirror: false), clockwise: 360 - liveTurn)
        frameCount += 1
        if st.histogram, frameCount % 4 == 0 { computeHistogram(img) }
        if st.peaking { img = overlayPeaking(img) }
        if st.zebra { img = overlayZebra(img) }
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
        guard longProgress == nil else { return }
        if captureMode == .double, doubleGhost != nil { cancelDouble() }
        if m == .video { prepareAudio { ok in DispatchQueue.main.async { self.captureMode = .video } } } else { captureMode = m }
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
            self.recordTurn = Self.turn(self.captureAngle, from: self.frameAngle)   // locked for the whole clip, like the system Camera
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
        // Pool buffers are recycled: paint every pixel, or parts of an old frame stay stuck in the clip.
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / e.width, y: CGFloat(outH) / e.height))
            .transformed(by: CGAffineTransform(translationX: -e.minX * CGFloat(outW) / e.width, y: -e.minY * CGFloat(outH) / e.height))
        let bounds = CGRect(x: 0, y: 0, width: outW, height: outH)
        ciContext.render(scaled.composited(over: CIImage(color: .black).cropped(to: bounds)), to: pb, bounds: bounds, colorSpace: nil)
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
