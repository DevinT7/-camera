import SwiftUI
import Combine
import CoreMotion

final class TiltBox: ObservableObject {
    let tilt = Tilt()
    private var bag: AnyCancellable?
    init() { bag = tilt.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
}

/// A notched dial. Each notch fires a haptic tick + click sound. A tap (no drag) calls `onTap`.
struct Dial: View {
    let label: String
    let count: Int
    @Binding var index: Int
    let color: Color
    let ink: Color
    var size: CGFloat = 104
    var degreesPerNotch: Double = 10
    /// Slide a finger left/right across the dial instead of tracing a circle (easier with many positions).
    var linear = false
    var pointsPerNotch: CGFloat = 9
    var onTap: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    @EnvironmentObject var tiltHolder: TiltBox
    @State private var startIndex: Int?
    @State private var longPressed = false
    @State private var lastAngle: Double?
    @State private var accumDegrees: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.35), radius: 8, x: tiltHolder.tilt.x * 7, y: tiltHolder.tilt.y * 7 + 2)
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
            ZStack {
                ForEach(0..<36, id: \.self) { i in
                    Capsule().fill(ink.opacity(i % 3 == 0 ? 0.9 : 0.4))
                        .frame(width: 2.5, height: i % 3 == 0 ? 11 : 7)
                        .offset(y: -size / 2 + 12)
                        .rotationEffect(.degrees(Double(i) * 10))
                }
                Circle().fill(ink).frame(width: 9, height: 9).offset(y: -size / 2 + 26)
            }
            .rotationEffect(.degrees(Double(index) * degreesPerNotch))
            .animation(.spring(response: 0.18, dampingFraction: 0.8), value: index)
            Circle().fill(.black.opacity(0.12)).frame(width: size * 0.42)
            Text(label).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(ink).tracking(1)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        // Circular drag: the dial turns with your finger. One notch per 10 degrees of rotation (matches the tick marks).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if linear {
                    if startIndex == nil { startIndex = index }
                    let new = min(max((startIndex ?? 0) + Int((v.translation.width / pointsPerNotch).rounded()), 0), count - 1)
                    if new != index { index = new; Feedback.tick() }
                    return
                }
                let c = CGPoint(x: size / 2, y: size / 2)
                let dx = v.location.x - c.x, dy = v.location.y - c.y
                if startIndex == nil { startIndex = index; accumDegrees = 0; lastAngle = nil }
                guard hypot(dx, dy) > 10 else { return }          // angle is unstable right at the centre
                let angle = atan2(dy, dx) * 180 / .pi
                if let last = lastAngle {
                    var d = angle - last
                    if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                    accumDegrees += d
                }
                lastAngle = angle
                let start = Double(startIndex ?? 0)
                let raw = start + accumDegrees / degreesPerNotch
                let clamped = min(max(raw, 0), Double(count - 1))
                if raw != clamped { accumDegrees = (clamped - start) * degreesPerNotch }   // no wind-up past the ends
                let new = Int(clamped.rounded())
                if new != index { index = new; Feedback.tick() }
            }
            .onEnded { v in
                if !longPressed && abs(v.translation.width) < 6 && abs(v.translation.height) < 6 { onTap?() }
                startIndex = nil; lastAngle = nil; accumDegrees = 0; longPressed = false
            })
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            guard let onLongPress else { return }
            longPressed = true; onLongPress()
        })
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { d in
            index = min(max(index + (d == .increment ? 1 : -1), 0), count - 1)
        }
    }
}

/// Chunky two-state switch, like a physical toggle.
struct ChunkySwitch: View {
    let top: String
    let bottom: String
    @Binding var isOn: Bool
    let colorway: Colorway
    var labelColor: Color? = nil   // set when the switch sits on the picture (full-screen mode)
    @EnvironmentObject var tiltHolder: TiltBox

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(colorway.panelColor).frame(width: 78, height: 42)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                Capsule().fill(isOn ? colorway.dialColor : colorway.ink.opacity(0.85))
                    .frame(width: 40, height: 34).padding(4)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: tiltHolder.tilt.x * 4, y: tiltHolder.tilt.y * 4 + 1)
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isOn)
            Text(isOn ? top : bottom).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(labelColor ?? colorway.ink).tracking(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle(); Feedback.toggle() }
    }
}

/// A ring that expands from the shutter and fades out; recreated (via .id) on every shot.
private struct ShutterRipple: View {
    let color: Color
    @State private var go = false
    var body: some View {
        Circle().strokeBorder(color.opacity(0.9), lineWidth: 5)
            .frame(width: 92, height: 92)
            .scaleEffect(go ? 1.55 : 0.95).opacity(go ? 0 : 0.85)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { go = true } }
    }
}

struct ShutterButton: View {
    let colorway: Colorway
    var recording = false
    let action: () -> Void
    @GestureState private var pressed = false
    @State private var rippleID = 0
    @EnvironmentObject var tiltHolder: TiltBox

    var body: some View {
        ZStack {
            Circle().fill(colorway.panelColor).frame(width: 112, height: 112)
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 2))
            Circle().fill(LinearGradient(colors: [colorway.shutterColor, colorway.shutterColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(pressed ? 0.1 : 0.4), radius: pressed ? 2 : 9, x: tiltHolder.tilt.x * 6, y: pressed ? 1 : tiltHolder.tilt.y * 6 + 3)
                .overlay(Circle().fill(.black.opacity(pressed ? 0.22 : 0)))      // darkens while held
                .scaleEffect(pressed ? 0.86 : 1)
            if recording { RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 26, height: 26) }
            // Ring that flashes out from the button each time a photo is taken.
            ShutterRipple(color: colorway.shutterColor).id(rippleID).allowsHitTesting(false)
        }
        .animation(.spring(response: 0.15, dampingFraction: 0.6), value: pressed)
        .onChange(of: pressed) { _, down in if down { Feedback.press() } }
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { _ in rippleID += 1; action() })
        .accessibilityLabel("Shutter").accessibilityAddTraits(.isButton)
    }
}

struct GridOverlay: View {
    let style: GridStyle
    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                func vl(_ x: CGFloat) { p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: h)) }
                func hl(_ y: CGFloat) { p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: w, y: y)) }
                switch style {
                case .off: break
                case .thirds: [1, 2].forEach { vl(w * CGFloat($0) / 3); hl(h * CGFloat($0) / 3) }
                case .four: (1..<4).forEach { vl(w * CGFloat($0) / 4); hl(h * CGFloat($0) / 4) }
                case .sixByFour: (1..<4).forEach { vl(w * CGFloat($0) / 4) }; (1..<6).forEach { hl(h * CGFloat($0) / 6) }
                case .phi: let a: CGFloat = 0.382; [a, 1 - a].forEach { vl(w * $0); hl(h * $0) }
                case .golden: let a: CGFloat = 0.236; [a, 0.5, 1 - a].forEach { vl(w * $0) }; [a, 1 - a].forEach { hl(h * $0) }
                }
            }
            .stroke(.white.opacity(0.55), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

/// Phone roll against the horizon, from gravity. Runs only while the level is on screen.
final class LevelMotion: ObservableObject {
    /// Roll in degrees, clockwise positive (0 = upright portrait, 90 = turned clockwise onto its side).
    @Published var roll: Double = 0
    /// False when the phone is near flat (pointing at the floor or sky): there's no horizon to level against.
    @Published var usable = true
    private let mm = CMMotionManager()
    private var smoothed: Double?

    func start() {
        guard mm.isDeviceMotionAvailable, !mm.isDeviceMotionActive else { return }
        mm.deviceMotionUpdateInterval = 1 / 60
        mm.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            self.usable = abs(g.z) < 0.85
            let a = atan2(g.x, -g.y) * 180 / .pi
            // Light smoothing, unwrapped across ±180 so it never spins the long way round.
            if let s = self.smoothed {
                var d = a - s
                if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                self.smoothed = s + d * 0.35
            } else { self.smoothed = a }
            self.roll = self.smoothed!
        }
    }
    func stop() { mm.stopDeviceMotionUpdates(); smoothed = nil }
}

/// The iPhone Camera's level: two fixed side marks and a centre line that stays on the horizon. Shown only when the phone
/// is within a few degrees of upright or sideways; when it's level the pieces join, turn the accent colour and tap once.
struct LevelOverlay: View {
    let accent: Color
    @StateObject private var motion = LevelMotion()
    @State private var isLevel = false

    var body: some View {
        let r = motion.roll
        let base = (r / 90).rounded() * 90                 // nearest upright / sideways / upside-down hold
        let off = r - base
        let visible = motion.usable && abs(off) < 12
        let color = isLevel ? accent : .white
        ZStack {
            // Fixed marks, square to the way the phone is held.
            HStack(spacing: 0) {
                Capsule().fill(color).frame(width: 22, height: 2)
                Spacer().frame(width: isLevel ? 0 : 92)
                Capsule().fill(color).frame(width: 22, height: 2)
            }
            .rotationEffect(.degrees(-base))
            // Centre line on the horizon: turns against the phone's roll.
            Capsule().fill(color).frame(width: isLevel ? 92 : 84, height: isLevel ? 2.5 : 1.5)
                .rotationEffect(.degrees(-r))
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: visible)
        .animation(.easeOut(duration: 0.12), value: isLevel)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: abs(off)) { _, d in
            // Hysteresis so it doesn't flicker (or buzz) right at the edge.
            if !isLevel && d < 0.8 && visible { isLevel = true; Feedback.levelSnap() }
            else if isLevel && (d > 1.6 || !visible) { isLevel = false }
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }
}

struct HistogramView: View {
    let bins: [Float]
    var body: some View {
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(bins.indices, id: \.self) { i in
                    Rectangle().fill(.white.opacity(0.9)).frame(height: max(1, CGFloat(bins[i]) * g.size.height))
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
}

/// Yellow focus ring marked with min/max focus distance, as in the original's precision focus.
struct FocusRing: View {
    let manual: Bool
    let minFocusMM: Int
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color(hex: "FFD60A"), lineWidth: manual ? 3 : 2).frame(width: manual ? 120 : 76, height: manual ? 120 : 76)
            if manual {
                VStack {
                    Text("∞").font(.system(size: 12, weight: .heavy, design: .rounded))
                    Spacer()
                    Text(minFocusMM > 0 ? "\(max(minFocusMM / 10, 1))cm" : "MIN").font(.system(size: 12, weight: .heavy, design: .rounded))
                    if minFocusMM > 0 && minFocusMM <= 120 { Text("MACRO").font(.system(size: 9, weight: .heavy, design: .rounded)) }
                }
                .frame(height: 150).foregroundStyle(Color(hex: "FFD60A"))
            }
        }
        .allowsHitTesting(false)
        .transition(.scale(scale: 1.4).combined(with: .opacity))
    }
}


/// Appears over the viewfinder while the Style dial turns: a tick scale, big swatch + name, and a strip
/// of every look you can tap to jump straight to it.
struct StylePickerOverlay: View {
    let styles: [CameraStyle]
    @Binding var index: Int
    let accent: Color
    var visible = true
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    @State private var tickWidth: CGFloat = 1

    var body: some View {
        let cur = styles[min(index, styles.count - 1)]
        VStack(spacing: 10) {
            ticks
                .offset(y: visible ? 0 : -36).opacity(visible ? 1 : 0)
            VStack(spacing: 6) {
                swatch(cur, size: 64)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white, lineWidth: 3))
                    .shadow(radius: 6)
                Text(cur.name).font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(.white).shadow(radius: 6)
                Text("\(index + 1) / \(styles.count)").font(.system(size: 11, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            }
            .id(cur.id)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .scaleEffect(visible ? 1 : 0.8).opacity(visible ? 1 : 0)
            Spacer()
            strip
                .offset(y: visible ? 0 : 60).opacity(visible ? 1 : 0)
        }
        .padding(.top, 14 + topInset).padding(.bottom, 44 + bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom).opacity(visible ? 1 : 0))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: index)
        .animation(.easeInOut(duration: 0.35), value: visible)
        .allowsHitTesting(visible)
    }

    private var ticks: some View {
        HStack(spacing: 3) {
            ForEach(styles.indices, id: \.self) { i in
                let d = abs(i - index)
                Capsule().fill(i == index ? accent : .white.opacity(d == 1 ? 0.9 : 0.4))
                    .frame(width: i == index ? 3 : 2, height: i == index ? 26 : d == 1 ? 20 : 15)
            }
        }
        .frame(height: 28)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(GeometryReader { g in Color.clear.preference(key: TickWidthKey.self, value: g.size.width) })
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            // scrub: finger position along the tick row picks the look
            let w = max(tickWidth, 1)
            let i = min(max(Int((v.location.x / w) * CGFloat(styles.count)), 0), styles.count - 1)
            if i != index { index = i; Feedback.tick() }
        })
        .onPreferenceChange(TickWidthKey.self) { tickWidth = $0 }
    }

    private func swatch(_ s: CameraStyle, size: CGFloat) -> some View {
        Group {
            if let ui = Styles.swatch(for: s) { Image(uiImage: ui).resizable().scaledToFill() } else { Color.gray }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(styles.indices, id: \.self) { i in
                        Button { index = i; Feedback.tick() } label: {
                            VStack(spacing: 4) {
                                swatch(styles[i], size: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 12.3, style: .continuous).strokeBorder(i == index ? accent : .white.opacity(0.35), lineWidth: i == index ? 3 : 1))
                                Text(styles[i].name).font(.system(size: 9, weight: .heavy, design: .rounded)).lineLimit(1)
                                    .foregroundStyle(i == index ? accent : .white).frame(width: 56)
                            }
                        }.buttonStyle(.plain).id(i)
                    }
                }.padding(.horizontal, 12)
            }
            .onChange(of: index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
        .frame(height: 70)
    }
}

private struct TickWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A knurled drum wheel you flick up/down, like a physical scroll wheel. Ridges roll past as it turns,
/// each ridge passing is one notch (haptic tick). Tap it to open the picker.
struct DrumWheel: View {
    let count: Int
    @Binding var index: Int
    let color: Color        // drum body (same family as the dials)
    let panel: Color        // recess it sits in (same as the shutter ring / switches)
    let ink: Color
    var width: CGFloat = 84
    var height: CGFloat = 108
    var pointsPerNotch: CGFloat = 14
    var onTap: (() -> Void)? = nil
    @EnvironmentObject var tiltHolder: TiltBox
    @State private var phase: Double = 0        // fractional index while dragging
    @State private var dragStart: Int?

    private let step = 0.30                      // radians between ridges

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous).fill(panel)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 2))
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Canvas { ctx, size in
                    let R = size.height / 2
                    for k in -14...14 {
                        let a = (Double(k) - phase.truncatingRemainder(dividingBy: 1)) * step
                        guard abs(a) < .pi / 2 - 0.05 else { continue }
                        let y = size.height / 2 + R * sin(a)
                        let h = max(R * (sin(a + step / 2) - sin(a - step / 2)), 1)
                        let shade = cos(a)
                        // ridge crest catches light, groove below is a thin ink line (like the dial's tick marks)
                        let crest = CGRect(x: 10, y: y - h / 2 + 2, width: size.width - 20, height: max(h * 0.4, 1))
                        ctx.fill(Path(roundedRect: crest, cornerRadius: crest.height / 2), with: .color(.white.opacity(0.4 * shade)))
                        let groove = CGRect(x: 8, y: y + h / 2 - 1.5, width: size.width - 16, height: 2.5)
                        ctx.fill(Path(roundedRect: groove, cornerRadius: 1.25), with: .color(ink.opacity(0.5 * shade)))
                    }
                }
                // soft roll-off toward the top and bottom so it reads as a cylinder without going dark
                LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0), .init(color: .clear, location: 0.3),
                                       .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.28), location: 1)],
                               startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 8, x: tiltHolder.tilt.x * 7, y: tiltHolder.tilt.y * 7 + 2)
        }
        .frame(width: width + 20, height: height + 20)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil { dragStart = index }
                // drag up = next look
                let raw = Double(dragStart ?? 0) - Double(v.translation.height / pointsPerNotch)
                let clamped = min(max(raw, 0), Double(count - 1))
                phase = clamped
                let new = Int(clamped.rounded())
                if new != index { index = new; Feedback.tick() }
            }
            .onEnded { v in
                if abs(v.translation.height) < 6 && abs(v.translation.width) < 6 { onTap?() }
                dragStart = nil
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { phase = Double(index) }
            })
        .onChange(of: index) { _, i in if dragStart == nil { withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { phase = Double(i) } } }
        .onAppear { phase = Double(index) }
        .accessibilityLabel("Style")
        .accessibilityAdjustableAction { d in index = min(max(index + (d == .increment ? 1 : -1), 0), count - 1) }
    }
}

// MARK: - Zoom wheel
/// A dial that turns under a fixed pointer as zoom changes: ticks every tenth of a stop, the lens stops labelled, the exact
/// zoom (and 35mm-equivalent focal length) at the top. Drag it sideways to zoom, like turning a lens ring.
struct ZoomWheel: View {
    let zoom: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let stops: [CGFloat]
    let accent: Color
    let mm: Int?

    static let radius: CGFloat = 250
    static let top: CGFloat = 12
    static let degreesPerDoubling = 28.0
    /// Finger travel along the rim that doubles (or halves) the zoom.
    static var pointsPerDoubling: CGFloat { radius * CGFloat(degreesPerDoubling * .pi / 180) }
    private var radius: CGFloat { Self.radius }
    private var degreesPerDoubling: Double { Self.degreesPerDoubling }
    private let visible = 70.0   // degrees either side of the pointer

    var body: some View {
        Canvas { ctx, size in
            let top = Self.top
            let c = CGPoint(x: size.width / 2, y: top + radius)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(.black.opacity(0.42)))
            func angle(_ v: CGFloat) -> Double { (log2(Double(v)) - log2(Double(zoom))) * degreesPerDoubling }
            func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
                let a = (deg - 90) * .pi / 180
                return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            }
            func fade(_ deg: Double) -> Double { max(0, 1 - pow(abs(deg) / visible, 2)) }

            // Ticks: a tenth of a stop apart, longer every half stop.
            let n0 = Int((log2(Double(minZoom)) * 10).rounded(.up)), n1 = Int((log2(Double(maxZoom)) * 10).rounded(.down))
            if n0 <= n1 {
                for n in n0...n1 {
                    let deg = angle(CGFloat(pow(2, Double(n) / 10)))
                    guard abs(deg) < visible else { continue }
                    let len: CGFloat = n % 5 == 0 ? 9 : 5
                    var p = Path(); p.move(to: point(deg, radius - 3)); p.addLine(to: point(deg, radius - 3 - len))
                    ctx.stroke(p, with: .color(.white.opacity(0.55 * fade(deg))), lineWidth: 1.2)
                }
            }
            // Lens stops: long ticks with labels that follow the curve.
            for s in stops {
                let deg = angle(s)
                guard abs(deg) < visible else { continue }
                var p = Path(); p.move(to: point(deg, radius - 3)); p.addLine(to: point(deg, radius - 17))
                ctx.stroke(p, with: .color(.white.opacity(fade(deg))), lineWidth: 2)
                guard abs(deg) > 7 else { continue }   // the readout covers the middle
                let label = s < 1 ? String(format: "%.1f", s) : String(Int(s))
                ctx.drawLayer { l in
                    let q = point(deg, radius - 29)
                    l.translateBy(x: q.x, y: q.y)
                    l.rotate(by: .degrees(deg))
                    l.opacity = fade(deg)
                    l.draw(Text(label).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(.white), at: .zero)
                }
            }
            // Fixed pointer and the exact value under it.
            var tri = Path()
            tri.move(to: CGPoint(x: c.x - 6, y: top - 2)); tri.addLine(to: CGPoint(x: c.x + 6, y: top - 2)); tri.addLine(to: CGPoint(x: c.x, y: top + 9)); tri.closeSubpath()
            ctx.fill(tri, with: .color(accent))
            let z = String(format: zoom < 10 ? "%.1f×" : "%.0f×", zoom)
            ctx.draw(Text(z).font(.system(size: 17, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(accent),
                     at: CGPoint(x: c.x, y: top + 29))
            if let mm {
                ctx.draw(Text("\(mm)MM").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(accent.opacity(0.85)),
                         at: CGPoint(x: c.x, y: top + 46))
            }
        }
        .contentShape(WheelDisk())
        .accessibilityHidden(true)
    }

    /// Only the wheel's disk catches touches, not the empty corners of its frame.
    struct WheelDisk: Shape {
        func path(in r: CGRect) -> Path {
            Path(ellipseIn: CGRect(x: r.midX - ZoomWheel.radius, y: ZoomWheel.top, width: ZoomWheel.radius * 2, height: ZoomWheel.radius * 2))
        }
    }
}

// MARK: - Light meter
/// A needle on a −2…+2 stop scale. Centered and accent-coloured when the exposure is right; pinned to an end with an
/// arrow when it's further off than the scale shows.
struct LightMeterNeedle: View {
    let offset: Float
    let accent: Color
    let ink: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, mid = w / 2
            let span = (w - 10) / 2   // ±2 stops
            for i in -6...6 {
                let x = mid + CGFloat(i) / 3 * span / 2
                let len: CGFloat = i % 3 == 0 ? 6 : 3
                var p = Path(); p.move(to: CGPoint(x: x, y: h - 1)); p.addLine(to: CGPoint(x: x, y: h - 1 - len))
                ctx.stroke(p, with: .color(ink.opacity(i == 0 ? 0.9 : 0.45)), lineWidth: i == 0 ? 1.5 : 1)
            }
            let v = CGFloat(max(min(offset, 2), -2))
            let x = mid + v * span / 2
            let good = abs(offset) < 0.34
            var needle = Path(); needle.move(to: CGPoint(x: x, y: 0)); needle.addLine(to: CGPoint(x: x, y: h))
            ctx.stroke(needle, with: .color(good ? accent : ink), lineWidth: 2.5)
            if abs(offset) > 2 {
                let sym = offset > 0 ? "▶" : "◀"
                ctx.draw(Text(sym).font(.system(size: 8, weight: .black)).foregroundStyle(ink), at: CGPoint(x: offset > 0 ? w - 3 : 3, y: 4))
            }
        }
        .animation(.easeOut(duration: 0.15), value: offset)
    }
}

// MARK: - Long exposure progress
/// "Hold still" with a ring that fills while frames are gathered.
struct LongExposureProgress: View {
    let progress: Double
    let accent: Color

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 5)
                Circle().trim(from: 0, to: progress).stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                Text(String(format: "%.1f", max(0, CameraModel.longSeconds * (1 - progress))))
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            }
            .frame(width: 70, height: 70)
            Text("HOLD STILL").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.white)
        }
        .padding(16).background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 20))
        .allowsHitTesting(false)
    }
}
