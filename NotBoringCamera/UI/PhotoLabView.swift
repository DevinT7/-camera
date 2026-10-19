import SwiftUI
import Photos
import CoreImage

/// Photo Lab, in the app's own look: cream body, mono labels, orange sliders, a yellow active tab and a big "Save a copy".
/// Non-destructive editing: exposure, grain, warmth/tint, highlights/shadows, Style + strength, crop/rotate/flip, stickers.
struct PhotoLabView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    enum LabTab { case adjust, crop, style }

    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selectedID: String?
    @State private var selectedDate: Date?
    @State private var loadingPhoto = false
    @State private var denied = false
    @State private var source: CIImage?
    @State private var rendered: UIImage?
    @State private var comparing = false
    @State private var tab: LabTab = .adjust
    @State private var exposure = 0.0
    @State private var grain = 0.0
    @State private var temp = 6500.0
    @State private var tint = 0.0
    @State private var highlights = 1.0
    @State private var shadows = 0.0
    @State private var styleIndex = 0
    @State private var strength = 1.0
    @State private var rotation = 0
    @State private var flipped = false
    @State private var aspect: AspectOption?
    @State private var saved = false
    @State private var placed: [PlacedSticker] = []
    @ObservedObject private var statsStore = StatsStore.shared
    private let ctx = CIContext()
    private var cw: Colorway { s.colorway }
    private var ink: Color { cw.ink }

    var body: some View {
        ZStack {
            cw.bodyColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    preview
                    library
                    controls
                    tabs
                    saveButton
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 34)
            }
        }
        .preferredColorScheme(cw.isDarkBody ? .dark : .light)
        .task { await loadLibrary() }
        .onChange(of: [exposure, temp, tint, highlights, shadows, strength, grain]) { _, _ in render() }
        .onChange(of: styleIndex) { _, _ in render() }
        .onChange(of: rotation) { _, _ in render() }
        .onChange(of: flipped) { _, _ in render() }
        .onChange(of: aspect) { _, _ in render() }
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAKE IT YOURS").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(ink.opacity(0.6))
                Text("Photo Lab.").font(.system(size: 42, weight: .black, design: .rounded)).foregroundStyle(ink)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                    .frame(width: 46, height: 46).background(cw.panelColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .accessibilityLabel("Close")
        }
    }

    // MARK: Preview
    private var preview: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black.opacity(0.88))
            if let r = rendered, let src = source {
                Image(uiImage: comparing ? original(src) : r).resizable().scaledToFit()
                    .overlay(GeometryReader { g in
                        ForEach($placed) { $p in
                            StickerView(sticker: p.sticker, size: g.size.width * 0.2 * p.scale)
                                .position(x: p.x * g.size.width, y: p.y * g.size.height)
                                .gesture(DragGesture().onChanged { v in
                                    p.x = min(max(v.location.x / g.size.width, 0), 1); p.y = min(max(v.location.y / g.size.height, 0), 1)
                                })
                                .onTapGesture(count: 2) { p.scale = p.scale >= 2 ? 0.6 : p.scale + 0.4 }
                                .contextMenu { Button("Remove", role: .destructive) { placed.removeAll { $0.id == p.id } } }
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { comparing = $0 }, perform: {})
            } else {
                VStack(spacing: 8) {
                    if loadingPhoto { ProgressView().tint(.white) } else { Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30)).foregroundStyle(.white.opacity(0.6)) }
                    Text(loadingPhoto ? "Loading…" : "Pick a photo below").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if source != nil {
                Text(chipText).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Color.black.opacity(0.62), in: Capsule()).padding(14)
            }
            if source != nil {
                Text(comparing ? "ORIGINAL" : "HOLD TO COMPARE").font(.system(size: 9, weight: .heavy, design: .monospaced)).tracking(1).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10).allowsHitTesting(false)
            }
        }
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var chipText: String {
        let style = model.styles[min(styleIndex, model.styles.count - 1)].name.uppercased()
        let date = (selectedDate ?? Date()).formatted(.dateTime.month(.abbreviated).day()).uppercased()
        return "\(style) / \(date)"
    }

    // MARK: Library
    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ALL PHOTOS").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6)
                Spacer()
                Text("\(assets?.count ?? 0) PHOTOS").font(.system(size: 12, weight: .medium, design: .monospaced)).opacity(0.65)
            }
            .foregroundStyle(ink)
            if denied {
                VStack(spacing: 8) {
                    Text("Allow photo access to browse your library here.").font(.footnote).foregroundStyle(ink.opacity(0.7))
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.buttonStyle(.borderedProminent).tint(cw.dialColor)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if let assets {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(0..<assets.count, id: \.self) { i in
                            let a = assets.object(at: i)
                            Color.clear.aspectRatio(1.45, contentMode: .fit)
                                .overlay(LabThumb(asset: a))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selectedID == a.localIdentifier ? cw.dialColor : ink.opacity(0.12), lineWidth: selectedID == a.localIdentifier ? 3 : 1))
                                .contentShape(Rectangle())
                                .onTapGesture { pick(a); Feedback.tick() }
                        }
                    }
                    .padding(2)
                }
                .frame(height: 180)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
    }

    // MARK: Controls
    @ViewBuilder private var controls: some View {
        switch tab {
        case .adjust:
            VStack(spacing: 16) {
                LabSlider(title: "Exposure", value: $exposure, range: -2...2, cw: cw) { String(format: "%+.1f", $0) }
                LabSlider(title: "Grain", value: $grain, range: 0...100, cw: cw) { String(format: "%.0f", $0) }
                LabSlider(title: "Warmth", value: $temp, range: 3000...10000, cw: cw) { String(format: "%.0fK", $0) }
                LabSlider(title: "Tint", value: $tint, range: -100...100, cw: cw) { String(format: "%+.0f", $0) }
                LabSlider(title: "Highlights", value: $highlights, range: 0...1, cw: cw) { String(format: "%.0f", $0 * 100) }
                LabSlider(title: "Shadows", value: $shadows, range: -1...1, cw: cw) { String(format: "%+.0f", $0 * 100) }
            }
        case .crop:
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    chip("Rotate", "rotate.right", on: false) { rotation = (rotation + 1) % 4 }
                    chip("Flip", "arrow.left.and.right.righttriangle.left.righttriangle.right", on: flipped) { flipped.toggle() }
                }
                Text("RATIO").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(ink.opacity(0.6))
                HStack(spacing: 8) {
                    chip("Original", nil, on: aspect == nil) { aspect = nil }
                    ForEach(AspectOption.allCases) { a in chip(a.rawValue, nil, on: aspect == a) { aspect = a } }
                }
            }
        case .style:
            VStack(alignment: .leading, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.styles.indices, id: \.self) { i in chip(model.styles[i].name, nil, on: styleIndex == i) { styleIndex = i } }
                    }
                }
                LabSlider(title: "Style strength", value: $strength, range: 0...1, cw: cw) { String(format: "%.0f", $0 * 100) }
                Text("STICKERS").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(ink.opacity(0.6))
                if statsStore.unlockedStickers.isEmpty {
                    Text("Earn stickers with achievements.").font(.footnote).foregroundStyle(ink.opacity(0.6))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(statsStore.unlockedStickers) { st in
                                StickerView(sticker: st, size: 46).onTapGesture { placed.append(PlacedSticker(sticker: st)); Feedback.tick() }
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, _ symbol: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .heavy, design: .rounded)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Color.black.opacity(0.88) : ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(on ? cw.accentColor : cw.panelColor.opacity(0.7), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var tabs: some View {
        HStack(spacing: 12) {
            tabButton("Adjust", "slider.horizontal.3", on: tab == .adjust) { tab = .adjust }
            tabButton("Crop", "crop", on: tab == .crop) { tab = .crop }
            tabButton("Style", "sparkles", on: tab == .style) { tab = .style }
            tabButton("Reset", "arrow.counterclockwise", on: false) { reset() }
        }
    }

    private func tabButton(_ title: String, _ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); Feedback.toggle() } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .bold))
                Text(title).font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(on ? Color.black.opacity(0.88) : ink)
            .frame(maxWidth: .infinity).frame(height: 78)
            .background(on ? cw.accentColor : cw.panelColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.14), radius: 4, y: 3)
        }.buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button { save(); Feedback.thump() } label: {
            HStack {
                Text(saved ? "Saved ✓" : "Save a copy").font(.system(size: 22, weight: .black, design: .rounded))
                Spacer()
                Image(systemName: saved ? "checkmark" : "arrow.down.to.line").font(.system(size: 22, weight: .bold))
            }
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, 24).padding(.vertical, 22)
            .background(cw.dialColor, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 6, y: 4)
        }
        .buttonStyle(.plain).disabled(source == nil).opacity(source == nil ? 0.45 : 1)
    }

    // MARK: Library + photo loading
    private func loadLibrary() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { denied = true; return }
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assets = PHAsset.fetchAssets(with: .image, options: o)
        if source == nil, let first = assets?.firstObject { pick(first) }   // open with the newest photo loaded
    }

    private func pick(_ a: PHAsset) {
        selectedID = a.localIdentifier; selectedDate = a.creationDate; loadingPhoto = true
        let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { data, _, _, _ in
            DispatchQueue.main.async { loadingPhoto = false; if let data { setSource(data) } }
        }
    }

    private func setSource(_ d: Data) {
        guard let img = CIImage(data: d, options: [.applyOrientationProperty: true]) else { return }
        source = img; saved = false; reset()
    }

    private func reset() {
        exposure = 0; grain = 0; temp = 6500; tint = 0; highlights = 1; shadows = 0; strength = 1; styleIndex = 0
        rotation = 0; flipped = false; aspect = nil; placed = []; render()
    }

    // MARK: Image pipeline
    private func original(_ src: CIImage) -> UIImage {
        let small = src.transformed(by: CGAffineTransform(scaleX: min(1, 1600 / src.extent.width), y: min(1, 1600 / src.extent.width)))
        return ctx.createCGImage(small, from: small.extent).map(UIImage.init(cgImage:)) ?? UIImage()
    }

    private func pipeline(_ src: CIImage) -> CIImage {
        var img = src
        img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        img = img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: CGFloat(temp), y: CGFloat(tint))])
        img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": highlights, "inputShadowAmount": shadows])
        img = Styles.apply(model.styles[min(styleIndex, model.styles.count - 1)], to: img, strength: Float(strength))
        if grain > 0 { img = Styles.addGrain(Float(grain / 100) * 0.9, to: img) }
        for _ in 0..<rotation { img = img.oriented(.right) }
        if flipped { img = img.oriented(.upMirrored) }
        if let a = aspect {
            let e = img.extent; var w = e.width, h = e.height
            let r = a.ratio
            if w / h > r { w = h * r } else { h = w / r }
            img = img.cropped(to: CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h))
        }
        return img
    }

    @MainActor private func compositeStickers(_ base: CIImage) -> CIImage {
        var img = base
        let e = base.extent
        for p in placed {
            let side = e.width * 0.2 * p.scale
            let r = ImageRenderer(content: StickerView(sticker: p.sticker, size: 120))
            r.scale = 3
            guard let ui = r.uiImage, var ci = CIImage(image: ui) else { continue }
            let k = side / ci.extent.width
            ci = ci.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let x = e.minX + p.x * e.width - side / 2
            let y = e.minY + (1 - p.y) * e.height - side / 2
            img = ci.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: img)
        }
        return img
    }

    private func render() {
        guard let src = source else { return }
        let scaled = src.transformed(by: CGAffineTransform(scaleX: min(1, 1600 / src.extent.width), y: min(1, 1600 / src.extent.width)))
        let out = pipeline(scaled)
        if let cg = ctx.createCGImage(out, from: out.extent) { rendered = UIImage(cgImage: cg) }
    }

    private func save() {
        guard let src = source else { return }
        let out = compositeStickers(pipeline(src))
        guard let data = ctx.heifRepresentation(of: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [:]) else { return }
        // Saved like any other photo: into the !Camera album and the Photo Book.
        CameraModel.saveToLibrary(heic: data, dng: nil) { ok in
            DispatchQueue.main.async { saved = ok; if ok { StatsStore.shared.recordLabSave() } }
        }
    }
}

struct PlacedSticker: Identifiable {
    let id = UUID()
    let sticker: Sticker
    var x: CGFloat = 0.5
    var y: CGFloat = 0.5
    var scale: CGFloat = 1
}

/// Orange-filled track, white knob, mono label and value (as in the design).
struct LabSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let cw: Colorway
    let display: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(cw.ink)
                Spacer()
                Text(display(value)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(cw.dialColor)
            }
            GeometryReader { g in
                let r: CGFloat = 15   // knob radius: the track runs from knob-centre to knob-centre so the knob never hangs off the ends
                let travel = max(g.size.width - 2 * r, 1)
                let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let x = r + min(max(frac, 0), 1) * travel
                ZStack(alignment: .leading) {
                    Capsule().fill(cw.panelColor).frame(height: 9)
                    Capsule().fill(cw.dialColor).frame(width: x, height: 9)
                    Circle().fill(.white).frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        .offset(x: x - 15)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let f = min(max((v.location.x - r) / travel, 0), 1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 30)
        }
    }
}

private struct LabThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { g in
            Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.gray.opacity(0.25) } }
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .onAppear {
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.resizeMode = .fast; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: o) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}
