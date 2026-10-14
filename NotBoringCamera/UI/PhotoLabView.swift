import SwiftUI
import PhotosUI
import Photos
import CoreImage

/// Non-destructive editing: exposure, temperature/tint, highlights/shadows, Style + strength,
/// crop/rotate/flip, zoom & pan, tap-and-hold to compare.
struct PhotoLabView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    @State private var item: PhotosPickerItem?
    @State private var source: CIImage?
    @State private var rendered: UIImage?
    @State private var comparing = false
    @State private var exposure = 0.0
    @State private var temp = 6500.0
    @State private var tint = 0.0
    @State private var highlights = 1.0
    @State private var shadows = 0.0
    @State private var styleIndex = 0
    @State private var strength = 1.0
    @State private var rotation = 0
    @State private var flipped = false
    @State private var aspect: AspectOption?
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var saved = false
    @State private var placed: [PlacedSticker] = []
    @ObservedObject private var statsStore = StatsStore.shared
    private let ctx = CIContext()

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let r = rendered ?? nil, let src = source {
                        Image(uiImage: comparing ? original(src) : r).resizable().scaledToFit()
                            .scaleEffect(scale).offset(offset)
                            .gesture(MagnificationGesture().onChanged { scale = max(1, $0) })
                            .simultaneousGesture(DragGesture().onChanged { offset = $0.translation })
                            .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { comparing = $0 }, perform: {})
                            .overlay(GeometryReader { g in ForEach($placed) { $p in StickerView(sticker: p.sticker, size: g.size.width * 0.2 * p.scale).position(x: p.x * g.size.width, y: p.y * g.size.height).gesture(DragGesture().onChanged { v in p.x = min(max(v.location.x / g.size.width, 0), 1); p.y = min(max(v.location.y / g.size.height, 0), 1) }).onTapGesture(count: 2) { p.scale = p.scale >= 2 ? 0.6 : p.scale + 0.4 }.contextMenu { Button("Remove", role: .destructive) { placed.removeAll { $0.id == p.id } } } } })
                    } else {
                        PhotosPicker(selection: $item, matching: .images) { Label("Choose a photo", systemImage: "photo.on.rectangle").font(.headline) }
                    }
                }
                .frame(maxHeight: .infinity)
                if source != nil {
                    ScrollView {
                        VStack(spacing: 8) {
                            slider("Exposure", $exposure, -2...2)
                            slider("Temperature", $temp, 3000...10000)
                            slider("Tint", $tint, -100...100)
                            slider("Highlights", $highlights, 0...1)
                            slider("Shadows", $shadows, -1...1)
                            Picker("Style", selection: $styleIndex) { ForEach(model.styles.indices, id: \.self) { Text(model.styles[$0].name).tag($0) } }.pickerStyle(.menu)
                            slider("Style strength", $strength, 0...1)
                            HStack {
                                Button { rotation = (rotation + 1) % 4 } label: { Label("Rotate", systemImage: "rotate.right") }
                                Button { flipped.toggle() } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                                Menu("Crop") { Button("Original") { aspect = nil }; ForEach(AspectOption.allCases) { a in Button(a.rawValue) { aspect = a } } }
                                Button("Reset") { reset() }
                                Menu("Stickers") { ForEach(statsStore.unlockedStickers) { st in Button { placed.append(PlacedSticker(sticker: st)) } label: { Label(st.title, systemImage: st.symbol) } }; if statsStore.unlockedStickers.isEmpty { Text("Earn stickers with achievements") } }
                            }.buttonStyle(.bordered)
                        }.padding(.horizontal)
                    }.frame(maxHeight: 250)
                    Text("Tap and hold the photo to compare with the original.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Photo Lab").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(saved ? "Saved ✓" : "Save") { save() }.disabled(source == nil) }
                ToolbarItem(placement: .primaryAction) { PhotosPicker(selection: $item, matching: .images) { Image(systemName: "photo") } }
            }
            .onChange(of: item) { _, i in Task { await load(i) } }
            .onChange(of: [exposure, temp, tint, highlights, shadows, strength]) { _, _ in render() }
            .onChange(of: styleIndex) { _, _ in render() }
            .onChange(of: rotation) { _, _ in render() }
            .onChange(of: flipped) { _, _ in render() }
            .onChange(of: aspect) { _, _ in render() }
        }
    }

    private func slider(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack { Text(t).font(.caption).frame(width: 90, alignment: .leading); Slider(value: v, in: r) }
    }

    private func load(_ i: PhotosPickerItem?) async {
        guard let d = try? await i?.loadTransferable(type: Data.self),
              let img = CIImage(data: d, options: [.applyOrientationProperty: true]) else { return }
        source = img; reset()
    }

    private func reset() {
        exposure = 0; temp = 6500; tint = 0; highlights = 1; shadows = 0; strength = 1; styleIndex = 0
        rotation = 0; flipped = false; aspect = nil; scale = 1; offset = .zero; placed = []; render()
    }

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
        for _ in 0..<rotation { img = img.oriented(.right) }
        if flipped { img = img.oriented(.upMirrored) }
        if let a = aspect {
            let e = img.extent; var w = e.width, h = e.height
            let r = (rotation % 2 == 0) ? a.ratio : a.ratio
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
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }) { ok, _ in DispatchQueue.main.async { saved = ok; if ok { StatsStore.shared.recordLabSave() } } }
    }
}

struct PlacedSticker: Identifiable {
    let id = UUID()
    let sticker: Sticker
    var x: CGFloat = 0.5
    var y: CGFloat = 0.5
    var scale: CGFloat = 1
}
