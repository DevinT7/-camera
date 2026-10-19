import SwiftUI
import PhotosUI

struct CameraView: View {
    @EnvironmentObject var model: CameraModel
    @EnvironmentObject var settings: AppSettings
    @StateObject private var tilt = TiltBox()
    @State private var showSettings = false
    @State private var showLab = false
    @State private var showAchievements = false
    @ObservedObject private var stats = StatsStore.shared
    @ObservedObject private var roll = RollStore.shared
    @State private var pinchBase: CGFloat?
    @State private var focusDragBase: Float?
    @State private var styleToast = false
    @State private var styleToastToken = 0
    @State private var zoomReadout = false
    @State private var zoomReadoutToken = 0
    @State private var zoomDragBase: CGFloat?
    @State private var shutterBlink = false
    @Environment(\.scenePhase) private var scenePhase

    private var cw: Colorway { settings.colorway }
    @State private var topH: CGFloat = 52
    @State private var bottomH: CGFloat = 300
    private var fullScreen: Bool { settings.fullScreenPreview }
    /// Labels sit on the picture in full-screen mode, so they turn white.
    private var ink: Color { fullScreen ? .white : cw.ink }
    private var safeInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
    }
    /// Space the picture's own overlays (badges, histogram) keep clear of the top bar in full-screen mode.
    private var vfTop: CGFloat { fullScreen ? safeInsets.top + 52 : 0 }
    /// With no live Style or overlay the system's own preview layer is used, exactly what the iPhone Camera app shows.
    private var useNativePreview: Bool { settings.systemPreview && model.style.id == "standard" && !settings.zebra && !settings.focusPeaking }

    var body: some View {
        ZStack {
            cw.bodyColor.ignoresSafeArea()
            viewfinder
                .padding(.horizontal, fullScreen ? 0 : 6)
                .padding(.top, fullScreen ? 0 : topH + 10)
                .padding(.bottom, fullScreen ? 0 : bottomH + 10)
                .ignoresSafeArea(edges: fullScreen ? .all : [])
            VStack(spacing: 0) {
                Group {
                    if fullScreen {
                        // Full screen is for looking: the only controls left are zoom and the shutter, plus a way out.
                        HStack { Spacer(); fullScreenExit }.padding(.top, 6)
                    } else {
                        topBar
                    }
                }
                .padding(.horizontal, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !fullScreen { topH = $0 } }
                Spacer(minLength: 0)
                Group {
                    if fullScreen {
                        fullScreenControls
                    } else {
                        VStack(spacing: 10) {
                            if model.isManual { manualStrip.transition(.move(edge: .bottom).combined(with: .opacity)) }
                            controls
                            switches
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 8).padding(.top, fullScreen ? 16 : 0)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    if fullScreen { LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !fullScreen { bottomH = $0 } }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.fullScreenPreview)
        .environmentObject(tilt)
        .preferredColorScheme(fullScreen || cw.isDarkBody ? .dark : .light)   // light status bar over the full-screen picture
        .animation(.easeInOut(duration: 0.2), value: model.isManual)
        .animation(.spring(), value: stats.justUnlocked?.id)
        .onAppear { model.start(); RollStore.shared.developDue(); UIApplication.shared.isIdleTimerDisabled = settings.keepAwake }
        .onChange(of: settings.keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .onChange(of: scenePhase) { _, p in if p == .active { model.start(); RollStore.shared.developDue() } else { model.stop() } }
        .onChange(of: useNativePreview, initial: true) { _, v in model.nativePreviewActive = v }
        .onChange(of: model.capturing) { _, on in
            guard on else { return }
            shutterBlink = true
            withAnimation(.easeOut(duration: 0.22).delay(0.05)) { shutterBlink = false }
        }
        .onChange(of: settings.zebra) { _, _ in model.pushRenderState() }
        .onChange(of: settings.focusPeaking) { _, _ in model.pushRenderState() }
        .onChange(of: settings.histogram) { _, _ in model.pushRenderState() }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings).environmentObject(model) }
        .sheet(isPresented: $showAchievements) { AchievementsView() }
        .overlay(alignment: .top) { unlockToast }
        .sheet(item: $roll.developed) { DevelopedRollView(roll: $0) }
        .overlay { if model.screenFlashing { Color(red: 1, green: 0.96, blue: 0.9).ignoresSafeArea().allowsHitTesting(false).transition(.opacity) } }
        .sheet(isPresented: $showLab) { PhotoLabView().environmentObject(settings).environmentObject(model) }
    }

    @ViewBuilder private var unlockToast: some View {
        if let a = stats.justUnlocked {
            HStack(spacing: 10) {
                StickerView(sticker: a.sticker, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sticker unlocked").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                    Text(a.title).font(.system(size: 15, weight: .heavy, design: .rounded))
                }
            }
            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.top, 54)
            .transition(.move(edge: .top).combined(with: .opacity)).onTapGesture { showAchievements = true }
        }
    }

    private var rollBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "film.fill").font(.system(size: 11, weight: .bold))
            Text("\(roll.framesLeft)").font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
        }
        .foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
        .accessibilityLabel("\(roll.framesLeft) frames left on the roll")
    }

    // MARK: Photo / Video switch (always visible so the current mode is obvious)
    private var modeToggle: some View {
        HStack(spacing: 0) {
            ForEach([CaptureMode.photo, .video], id: \.self) { m in
                let on = model.captureMode == m
                Image(systemName: m == .photo ? "camera.fill" : "video.fill").font(.system(size: 14, weight: .bold))
                    .frame(width: 40, height: 34)
                    .background(on ? (m == .video ? Color(hex: "FF3B30") : cw.dialColor) : .clear, in: Capsule())
                    .foregroundStyle(on ? .white : cw.ink.opacity(0.6))
                    .contentShape(Capsule())
                    .onTapGesture { model.setMode(m); Feedback.toggle() }
                    .accessibilityLabel(m == .photo ? "Photo" : "Video")
            }
        }
        .padding(3).background(cw.panelColor, in: Capsule())
        .opacity(model.isRecording ? 0.4 : 1).allowsHitTesting(!model.isRecording)
        .animation(.easeInOut(duration: 0.2), value: model.captureMode)
    }

    private var fullScreenExit: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { settings.fullScreenPreview = false }
            Feedback.toggle()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(.black.opacity(0.4), in: Circle())
        }
        .accessibilityLabel("Exit full screen")
    }

    /// Zoom stops and the shutter, nothing else. They step aside while the Style picker is up, like the normal layout's zoom row.
    private var fullScreenControls: some View {
        VStack(spacing: 18) {
            zoomBar
            ShutterButton(colorway: cw, recording: model.isRecording) { model.capture() }
        }
        .opacity(styleToast ? 0 : 1)
        .offset(y: styleToast ? 14 : 0)
        .allowsHitTesting(!styleToast)
        .animation(.easeInOut(duration: 0.25), value: styleToast)
    }

    // MARK: Top bar
    private var topBar: some View {
        HStack(spacing: 8) {
            roundButton("gearshape.fill") { showSettings = true }
            roundButton("trophy.fill") { showAchievements = true }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { settings.fullScreenPreview.toggle() }
                Feedback.toggle()
            } label: { icon(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel(fullScreen ? "Exit full screen" : "Full screen preview")
            Menu {
                Picker("Aspect ratio", selection: $settings.aspect) { ForEach(AspectOption.allCases) { Text($0.rawValue).tag($0) } }
            } label: {
                Text(fullScreen ? "Full" : settings.aspect.rawValue).font(.system(size: 13, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(cw.ink).frame(width: 52, height: 40)
                    .background(cw.panelColor, in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(fullScreen).opacity(fullScreen ? 0.6 : 1)
            .accessibilityLabel("Aspect ratio")
            Button { cycleFlash() } label: {
                Image(systemName: model.flash == .off ? "bolt.slash.fill" : (model.flash == .auto ? "bolt.badge.automatic.fill" : "bolt.fill"))
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(model.flash == .off ? cw.ink.opacity(0.6) : cw.dialColor)
                    .frame(width: 40, height: 40).background(cw.panelColor, in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Flash \(model.flash.rawValue)")
        }
        .padding(.top, 6)
    }

    private func cycleFlash() {
        let all = FlashSetting.allCases
        model.flash = all[(all.firstIndex(of: model.flash)! + 1) % all.count]
        settings.lastFlash = model.flash; Feedback.toggle()
    }

    private var formatLabel: String {
        let p = abs(model.zoom - 1) > 0.05 && settings.pipeline == .superRaw && model.position == .back ? "BASIC*" : settings.pipeline.rawValue.uppercased()
        return model.captureMode == .video ? "VIDEO" : "\(p) · \(settings.aspect.rawValue)"
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16, weight: .bold)).foregroundStyle(cw.ink)
            .frame(width: 40, height: 40).background(cw.panelColor, in: RoundedRectangle(cornerRadius: 10))
    }
    private func roundButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button { Feedback.toggle(); action() } label: { icon(name) }
    }

    // MARK: Viewfinder
    private var viewfinder: some View {
        GeometryReader { g in
            let r = fullScreen ? g.size.width / g.size.height : settings.aspect.ratio
            let width = min(g.size.width, g.size.height * r)
            let size = CGSize(width: width, height: width / r)
            ZStack {
                if model.hasCamera {
                    let sideways = abs(model.deviceTurn) == 90
                    Group {
                        if useNativePreview { SystemPreviewView(session: model.session, position: model.position, angle: model.liveAngle, model: model) }
                        else { PreviewView(model: model) }
                    }
                        .blur(radius: (model.isSwitching || model.isTurning) ? 18 : 0)
                        .animation(.easeInOut(duration: 0.25), value: model.isSwitching)
                        .animation(.easeOut(duration: 0.15), value: model.isTurning)
                        // Held sideways: draw the (world-upright, landscape) picture in a landscape-shaped frame and turn it,
                        // so the viewfinder reads as a wide landscape box, like the system Camera.
                        .frame(width: sideways ? size.height : size.width, height: sideways ? size.width : size.height)
                        .rotationEffect(.degrees(model.deviceTurn))
                        .frame(width: size.width, height: size.height)
                        .transaction { $0.animation = nil }   // snap, no spin, when the phone turns
                } else { simulatorPlaceholder }
                if settings.cameraDiagnostics && model.hasCamera {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in Text(model.diagnostics + "\n" + model.rotationReport()) }
                        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.green)
                        .padding(5).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8).padding(.top, vfTop).allowsHitTesting(false)
                }
                GridOverlay(style: settings.grid)
                if settings.histogram && model.isManual && model.hasCamera { HistogramView(bins: model.histogram).frame(width: 96, height: 44).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10).padding(.top, vfTop) }
                if let p = model.focusPoint { FocusRing(manual: model.manualFocusActive, minFocusMM: model.minFocusMM).position(p) }
                if let img = model.reviewImage { Image(uiImage: img).resizable().scaledToFill().transition(.opacity) }
                if !fullScreen {
                    VStack {
                        Spacer()
                        ZStack {
                            zoomBar
                            HStack {
                                labButton
                                Spacer()
                                Button { model.flip(); Feedback.toggle() } label: {
                                    Image(systemName: "arrow.triangle.2.circlepath.camera.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                        .frame(width: 44, height: 44).background(.black.opacity(0.4), in: Circle())
                                }.accessibilityLabel("Flip camera")
                            }.padding(.horizontal, 12)
                        }
                        .padding(.bottom, 10)
                        // Step aside while the Style picker is up; slide back in when it goes away.
                        .opacity(styleToast ? 0 : 1)
                        .offset(y: styleToast ? 14 : 0)
                        .allowsHitTesting(!styleToast)
                        .animation(.easeInOut(duration: 0.25), value: styleToast)
                    }
                }
                if model.isRecording {
                    Text(String(format: "● %02d:%02d", model.recordSeconds / 60, model.recordSeconds % 60))
                        .font(.system(size: 14, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.red, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 12 + vfTop)
                }
                if settings.filmRoll && model.captureMode == .photo { rollBadge.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fullScreen ? .topLeading : .topTrailing).padding(12).padding(.top, vfTop) }
                Color.black.opacity(shutterBlink ? 0.45 : 0).allowsHitTesting(false)
                StylePickerOverlay(styles: model.styles, index: $model.styleIndex, accent: cw.accentColor, visible: styleToast,
                                   topInset: fullScreen ? safeInsets.top : 0, bottomInset: fullScreen ? safeInsets.bottom : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: fullScreen ? 0 : 26, style: .continuous).strokeBorder(cw.panelColor, lineWidth: fullScreen ? 0 : 5))
            .shadow(color: .black.opacity(fullScreen ? 0 : 0.25), radius: fullScreen ? 0 : 10, x: tilt.tilt.x * -4, y: tilt.tilt.y * -4 + 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.setViewfinderSize(size) }
            .onChange(of: size) { _, s in model.setViewfinderSize(s) }
            .onChange(of: settings.aspect) { _, _ in model.setViewfinderSize(CGSize(width: min(g.size.width, g.size.height * settings.aspect.ratio), height: min(g.size.width, g.size.height * settings.aspect.ratio) / settings.aspect.ratio)) }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let manualFocus = model.isManual && model.param == .focus
                if manualFocus && hypot(v.translation.width, v.translation.height) > 6 {
                    if focusDragBase == nil { focusDragBase = model.focusPos; model.beginManualFocus(at: v.startLocation) }
                    model.focusPos = min(max((focusDragBase ?? 0.5) - Float(v.translation.height / 300), 0), 1)
                }
            }.onEnded { v in
                if abs(v.translation.width) > 70 && abs(v.translation.height) < 50 && focusDragBase == nil {
                    let n = model.styles.count
                    model.styleIndex = (model.styleIndex + (v.translation.width < 0 ? 1 : n - 1)) % n
                    Feedback.tick(); return
                }
                if styleToast, hypot(v.translation.width, v.translation.height) < 6 { withAnimation { styleToast = false }; return }
                if focusDragBase != nil { focusDragBase = nil; model.endManualFocus() }
                else if hypot(v.translation.width, v.translation.height) < 6 { model.tapFocus(at: v.location, in: size); Feedback.click() }
            })
            .simultaneousGesture(MagnificationGesture().onChanged { s in
                if pinchBase == nil { pinchBase = model.zoom }
                model.setZoom((pinchBase ?? 1) * s)
            }.onEnded { _ in pinchBase = nil })
        }
    }

    private var simulatorPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "3A4A6B"), Color(hex: "E58A4F"), Color(hex: "1B1B2B")], startPoint: .top, endPoint: .bottom)
            Text(model.authorized ? "NO CAMERA\n(run on a real iPhone)" : "CAMERA ACCESS NEEDED")
                .font(.system(size: 13, weight: .heavy, design: .rounded)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
        }
    }

    /// Last photo (or a gallery icon); opens Photo Lab.
    private var labButton: some View {
        Button { showLab = true; Feedback.toggle() } label: {
            ZStack {
                Circle().fill(.black.opacity(0.4))
                if !settings.filmRoll, let img = model.lastImage { Image(uiImage: img).resizable().scaledToFill().clipShape(Circle()).overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1.5)) }
                else { Image(systemName: "photo.on.rectangle").font(.system(size: 16, weight: .bold)).foregroundStyle(.white) }
            }.frame(width: 44, height: 44)
        }.accessibilityLabel("Photo Lab")
    }

    // MARK: Zoom: continuous. Presets are shortcuts, the ruler/pinch give every in-between value.
    /// Fixed-size stop buttons (nothing resizes while zooming, which is what made the old bar jump) with a
    /// separate readout above that shows the exact zoom while it's changing.
    private var zoomBar: some View {
        let stops = model.quickZoomStops
        return VStack(spacing: 6) {
            Text(zoomText(model.zoom))
                .font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                .padding(.vertical, 4).padding(.horizontal, 10)
                .background(cw.accentColor, in: Capsule()).foregroundStyle(.black)
                .opacity(zoomReadout ? 1 : 0).scaleEffect(zoomReadout ? 1 : 0.85)
                .animation(.easeOut(duration: 0.2), value: zoomReadout)
            HStack(spacing: 4) {
                ForEach(stops, id: \.self) { s in
                    let active = abs(model.zoom - s) < 0.03
                    Text(fmt(s) + (active ? "×" : ""))
                        .font(.system(size: 13, weight: .heavy, design: .rounded)).monospacedDigit()
                        .frame(width: 42, height: 32)
                        .background(Capsule().fill(active ? cw.accentColor : .clear))
                        .foregroundStyle(active ? .black : .white)
                        .contentShape(Capsule())
                        .onTapGesture { model.setZoom(s, ramp: true); Feedback.tick() }
                }
            }
            .animation(.easeOut(duration: 0.15), value: stops.map { abs(model.zoom - $0) < 0.03 })
            .padding(4).background(.black.opacity(0.35), in: Capsule())
            .highPriorityGesture(DragGesture(minimumDistance: 6).onChanged { v in
                if zoomDragBase == nil { zoomDragBase = model.zoom }
                let span = log(max(model.maxZoom / model.minZoom, 1.01))
                model.setZoom((zoomDragBase ?? 1) * exp(v.translation.width / 260 * span))
            }.onEnded { _ in zoomDragBase = nil })
        }
        .onChange(of: model.zoom) { _, _ in
            zoomReadout = true
            zoomReadoutToken += 1
            let t = zoomReadoutToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if t == zoomReadoutToken { zoomReadout = false } }
        }
    }
    private func fmt(_ s: CGFloat) -> String { s < 1 ? String(format: "%.1f", s).replacingOccurrences(of: "0.5", with: ".5") : String(Int(s)) }
    private func zoomText(_ z: CGFloat) -> String { String(format: z < 10 ? "%.1f×" : "%.0f×", z) }

    // MARK: Manual strip
    private var manualStrip: some View {
        HStack(spacing: 6) {
            ForEach(ManualParam.allCases) { p in
                VStack(spacing: 2) {
                    Text(p.rawValue).font(.system(size: 10, weight: .heavy, design: .rounded)).opacity(0.7)
                    Text(value(for: p)).font(.system(size: 12, weight: .heavy, design: .rounded)).monospacedDigit()
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(model.param == p ? cw.accentColor : cw.panelColor, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(model.param == p ? .black : ink)
                .onTapGesture { model.param = p; Feedback.tick() }
            }
        }
    }

    private func value(for p: ManualParam) -> String {
        switch p {
        case .ev: let e = model.evLadder[model.evIndex]; return e == 0 ? "0" : String(format: "%+.1f", e)
        case .iso: return String(Int(model.isoLadder[min(model.isoIndex, model.isoLadder.count - 1)]))
        case .shutter: let s = model.shutterLadder[min(model.shutterIndex, model.shutterLadder.count - 1)]; return s >= 0.5 ? String(format: "%.1fs", s) : "1/\(Int((1 / s).rounded()))"
        case .wb: return "\(Int(model.wbLadder[model.wbIndex]))K"
        case .focus: return model.focusPos > 0.97 ? "∞" : String(format: "%.0f%%", model.focusPos * 100)
        }
    }

    // MARK: Dials + shutter
    private var activeIndex: Binding<Int> {
        Binding(get: {
            switch model.param { case .ev: return model.evIndex; case .iso: return model.isoIndex; case .shutter: return model.shutterIndex; case .wb: return model.wbIndex; case .focus: return Int(model.focusPos * 50) }
        }, set: { v in
            // Turning a manual-only setting while in Auto hands control to Manual (values were seeded from Auto).
            model.touched.insert(model.param)
            if model.param != .ev && !model.isManual { model.isManual = true }
            switch model.param { case .ev: model.evIndex = v; case .iso: model.isoIndex = v; case .shutter: model.shutterIndex = v; case .wb: model.wbIndex = v; case .focus: model.focusPos = Float(v) / 50 }
        })
    }
    private var activeCount: Int {
        switch model.param { case .ev: return model.evLadder.count; case .iso: return model.isoLadder.count; case .shutter: return model.shutterLadder.count; case .wb: return model.wbLadder.count; case .focus: return 51 }
    }

    /// Shows the value; once it has been moved it becomes a one-tap reset to default (long-press on the dial does the same).
    @ViewBuilder private var valueReadout: some View {
        if model.touched.contains(model.param) {
            Button { model.reset(model.param) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .black))
                    Text(value(for: model.param)).font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit()
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(cw.dialColor, in: Capsule()).foregroundStyle(.white)
            }.buttonStyle(.plain).transition(.scale.combined(with: .opacity))
        } else {
            Text(value(for: model.param)).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(ink).monospacedDigit()
                .padding(.vertical, 4)
        }
    }

    /// Tap the dial to cycle what it controls: EXP → SS → ISO → WB → FOCUS → EXP (works in Auto and Manual).
    private func cycleParam() {
        let all = ManualParam.allCases
        let next = all[(all.firstIndex(of: model.param)! + 1) % all.count]
        if next != .ev && !model.isManual { model.seedManualFromAuto() }
        model.param = next
        Feedback.toggle()
    }

    private var controls: some View {
        HStack(alignment: .center) {
            VStack(spacing: 6) {
                Dial(label: model.param == .ev ? "EXP" : model.param.rawValue, count: activeCount, index: activeIndex, color: cw.dialColor, ink: .white, onTap: cycleParam, onLongPress: { model.reset(model.param) })
                valueReadout
            }
            Spacer()
            ShutterButton(colorway: cw, recording: model.isRecording) { model.capture() }
            Spacer()
            VStack(spacing: 6) {
                DrumWheel(count: model.styles.count, index: $model.styleIndex, color: cw.accentColor, panel: cw.panelColor, ink: .black, onTap: openStylePicker)
                Text(model.style.name.uppercased()).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(ink).lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
        .onChange(of: model.styleIndex) { _, _ in openStylePicker() }
    }

    /// Show the look picker; it hides itself a few seconds after the last interaction.
    private func openStylePicker() {
        withAnimation { styleToast = true }
        styleToastToken += 1
        let token = styleToastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if token == styleToastToken { withAnimation { styleToast = false } } }
    }

    // MARK: Switches
    private var switches: some View {
        HStack {
            VStack(spacing: 6) {
                modeToggle
                Text(model.captureMode == .video ? "VIDEO" : "PHOTO").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(ink).tracking(1)
            }
            Spacer()
            ChunkySwitch(top: "M", bottom: "A", isOn: $model.isManual, colorway: cw, labelColor: fullScreen ? .white : nil)
            Spacer()
            Button { model.cycleLens(); Feedback.toggle() } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Capsule().fill(cw.panelColor).frame(width: 78, height: 42)
                        Image(systemName: "plus.magnifyingglass").font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                    }
                    Text("ZOOM").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(ink).tracking(1)
                }
            }.buttonStyle(.plain).accessibilityLabel("Zoom")
        }
        .padding(.horizontal, 4)
    }
}

