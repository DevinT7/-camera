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

    @State private var placeholder: UIImage?      // the tapped thumbnail, shown in the card until the full photo is ready
    @State private var lastPickedID: String?      // so the library returns to where you were
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selecting = false
    @State private var selection = Set<String>()
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

    /// Step 1 is the library; tapping a photo opens step 2, which is only that photo and its editing tools.
    /// Both screens stay in place and cross-fade (opacity + a slight zoom) so they genuinely overlap, with no empty frame between.
    @State private var editorOpen = false
    private var editing: Bool { editorOpen }

    var body: some View {
        ZStack {
            cw.bodyColor.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                // One header for both steps: the title never moves or doubles; only the back arrow comes and goes.
                header(showBack: editing)
                ZStack {
                    // Step 1: the library. Fades out quickly, with a slight zoom.
                    library
                        .opacity(editing ? 0 : 1).scaleEffect(editing ? 1.05 : 1)
                        .allowsHitTesting(!editing).accessibilityHidden(editing)
                        .animation(.easeOut(duration: 0.24), value: editing)
                    // Step 2: one photo and its tools. Fades in a beat later. The photo, tabs and Save stay put; only the controls scroll.
                    VStack(alignment: .leading, spacing: 16) {
                        preview
                        ScrollView(showsIndicators: false) {
                            controls.padding(.top, 4).padding(.bottom, 14)
                        }
                        VStack(spacing: 14) { tabs; saveButton }
                    }
                    .padding(.bottom, 10)
                    .opacity(editing ? 1 : 0).scaleEffect(editing ? 1 : 0.97)
                    .allowsHitTesting(editing).accessibilityHidden(!editing)
                    .animation(.smooth(duration: 0.36).delay(editing ? 0.06 : 0), value: editing)
                }
            }
            .padding(.horizontal, 22).padding(.top, 14)
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
    private func header(showBack: Bool) -> some View {
        HStack(spacing: 12) {
            if showBack {
                Button { closeEditor(); Feedback.toggle() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                        .frame(width: 46, height: 46).background(cw.panelColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
                .accessibilityLabel("Back to photos")
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Text("Photo Lab").font(.system(size: 38, weight: .black, design: .rounded)).foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).foregroundStyle(ink)
                    .frame(width: 46, height: 46).background(cw.panelColor.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .accessibilityLabel("Close")
        }
        .animation(.smooth(duration: 0.3), value: showBack)
    }

    private func closeEditor() {
        withAnimation(.smooth(duration: 0.38)) { editorOpen = false }
        // Clear the photo only after the fade, so the screen doesn't change underneath while it fades out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard !editorOpen else { return }
            selectedID = nil; selectedDate = nil; source = nil; rendered = nil; loadingPhoto = false; saved = false; placeholder = nil
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
            } else if let placeholder {
                // The thumbnail you tapped, already in the card; the full photo fades in over it.
                Image(uiImage: placeholder).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { ProgressView().tint(.white).padding(.bottom, 12) }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if source != nil {
                Button {
                    if let id = selectedID {
                        let r = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                        if let a = r.firstObject { delete([a]) { closeEditor() } }
                    }
                } label: {
                    Image(systemName: "trash").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Color.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel("Delete photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(12)
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
        .frame(height: UIScreen.main.bounds.height * 0.34)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var chipText: String {
        let style = model.styles[min(styleIndex, model.styles.count - 1)].name.uppercased()
        let date = (selectedDate ?? Date()).formatted(.dateTime.month(.abbreviated).day()).uppercased()
        return "\(style) / \(date)"
    }

    // MARK: Library
    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(assets?.count ?? 0) PHOTOS").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(ink.opacity(0.6))
                Spacer()
                if assets != nil, (assets?.count ?? 0) > 0 {
                    Button(selecting ? "CANCEL" : "SELECT") {
                        withAnimation(.smooth(duration: 0.2)) { selecting.toggle(); selection = [] }
                        Feedback.toggle()
                    }
                    .font(.system(size: 12, weight: .heavy, design: .monospaced)).tracking(0.6).foregroundStyle(cw.dialColor)
                }
            }
            if denied {
                VStack(spacing: 10) {
                    Text("Allow photo access to browse your library here.").font(.footnote).foregroundStyle(ink.opacity(0.7))
                    Button("Open Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.buttonStyle(.borderedProminent).tint(cw.dialColor)
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else if let assets {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                            ForEach(0..<assets.count, id: \.self) { i in
                                let a = assets.object(at: i)
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay(LabThumb(asset: a))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                                    .id(a.localIdentifier)
                                    .overlay(alignment: .topTrailing) {
                                        if selecting {
                                            let on = selection.contains(a.localIdentifier)
                                            ZStack {
                                                Circle().fill(on ? cw.dialColor : Color.black.opacity(0.35)).frame(width: 24, height: 24)
                                                Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 24, height: 24)
                                                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white) }
                                            }.padding(6)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(cw.dialColor, lineWidth: selecting && selection.contains(a.localIdentifier) ? 3 : 0))
                                    .onTapGesture {
                                        if selecting {
                                            if selection.contains(a.localIdentifier) { selection.remove(a.localIdentifier) } else { selection.insert(a.localIdentifier) }
                                            Feedback.tick()
                                        } else { pick(a); Feedback.tick() }
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) { delete([a]) } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .onAppear { if let id = lastPickedID { proxy.scrollTo(id, anchor: .center) } }
                }
                .overlay(alignment: .bottom) {
                    if selecting && !selection.isEmpty {
                        Button {
                            let ids = selection
                            var list: [PHAsset] = []
                            assets.enumerateObjects { a, _, _ in if ids.contains(a.localIdentifier) { list.append(a) } }
                            delete(list)
                        } label: {
                            Label("Delete \(selection.count) \(selection.count == 1 ? "Photo" : "Photos")", systemImage: "trash")
                                .font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Color(red: 1, green: 0.23, blue: 0.19), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        }
                        .buttonStyle(.plain).padding(.bottom, 8).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
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
    private func fetchAssets() {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        assets = PHAsset.fetchAssets(with: .image, options: o)
    }

    /// Removes photos from the iPhone's library. iOS shows its own "Delete N Photos?" confirmation first; nothing happens if you cancel.
    private func delete(_ list: [PHAsset], then done: @escaping () -> Void = {}) {
        guard !list.isEmpty else { return }
        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(list as NSArray) }) { ok, _ in
            DispatchQueue.main.async {
                guard ok else { return }
                Feedback.thump()
                withAnimation(.smooth(duration: 0.25)) { selection = []; selecting = false }
                fetchAssets()
                done()
            }
        }
    }

    private func loadLibrary() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { denied = true; return }
        fetchAssets()
    }

    private func pick(_ a: PHAsset) {
        lastPickedID = a.localIdentifier
        // Grab the already-cached thumbnail synchronously so the card is filled from the first frame of the animation.
        let t = PHImageRequestOptions(); t.isSynchronous = true; t.deliveryMode = .fastFormat; t.resizeMode = .fast
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 700, height: 700), contentMode: .aspectFit, options: t) { img, _ in placeholder = img }
        withAnimation(.smooth(duration: 0.38)) {
            selectedID = a.localIdentifier; selectedDate = a.creationDate; loadingPhoto = true; editorOpen = true
        }
        let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.version = .current
        PHImageManager.default().requestImageDataAndOrientation(for: a, options: o) { data, _, _, _ in
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { loadingPhoto = false; if let data { setSource(data) } } }
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
            // The system slider shares touches with the scrolling page correctly: a vertical drag scrolls, a horizontal one adjusts.
            Slider(value: $value, in: range).tint(cw.dialColor)
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
