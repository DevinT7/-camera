import SwiftUI
import Combine

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

struct ShutterButton: View {
    let colorway: Colorway
    var recording = false
    let action: () -> Void
    @GestureState private var pressed = false
    @EnvironmentObject var tiltHolder: TiltBox

    var body: some View {
        ZStack {
            Circle().fill(colorway.panelColor).frame(width: 112, height: 112)
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 2))
            Circle().fill(LinearGradient(colors: [colorway.shutterColor, colorway.shutterColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(pressed ? 0.1 : 0.4), radius: pressed ? 2 : 9, x: tiltHolder.tilt.x * 6, y: pressed ? 1 : tiltHolder.tilt.y * 6 + 3)
                .scaleEffect(pressed ? 0.93 : 1)
            if recording { RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 26, height: 26) }
        }
        .animation(.spring(response: 0.15, dampingFraction: 0.6), value: pressed)
        .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }.onEnded { _ in action() })
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
        .padding(.top, 14).padding(.bottom, 44)
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
