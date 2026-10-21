import SwiftUI
import AVKit
import Photos
import CoreImage

/// Photo Lab, in the app's own look: cream body, mono labels, orange sliders, a yellow active tab and a big "Save a copy".
/// Non-destructive editing: exposure, grain, warmth/tint, highlights/shadows, Style + strength, crop/rotate/flip, stickers.
struct PhotoLabView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    /// The editor's tools, in the order of the sliding name row under the photo.
    /// One tool, one control: each name in the row opens exactly one thing to change.
    enum LabTab: String, CaseIterable, Identifiable {
        case exposure = "Exposure", style = "Style", highlights = "Highlights", shadows = "Shadows", warmth = "Warmth", tint = "Tint",
             grain = "Grain", crop = "Crop", stickers = "Stickers"
        var id: String { rawValue }
    }

    @State private var placeholder: UIImage?      // the tapped thumbnail, shown in the card until the full photo is ready
    @State private var lastPickedID: String?      // so the library returns to where you were
    @State private var assets: PHFetchResult<PHAsset>?
    @State private var selecting = false
    @State private var videoAsset: PHAsset?        // set while a video is open (no editing tools for videos)
    @State private var player: AVPlayer?
    @State private var selection = Set<String>()
    @State private var selectedID: String?
    @State private var selectedDate: Date?
    @State private var loadingPhoto = false
    @State private var denied = false
    @State private var source: CIImage?
    @StateObject private var lab = LabRenderer()
    @State private var styleTuning = false        // Style tab: strength dial instead of the thumbnails
    @State private var nameWidths: [LabTab: CGFloat] = [:]
    @State private var nameDrag: CGFloat = 0
    @State private var comparing = false
    @State private var tab: LabTab = .exposure
    @State private var exposure = 0.0
    @State private var grain = 0.0
    @State private var temp = 6500.0
    @State private var tint = 0.0
    @State private var highlights = 0.0           // −1 recovers bright areas, +1 brightens them
    @State private var shadows = 0.0
    @State private var styleIndex = 0
    @State private var strength = 1.0
    @State private var rotation = 0
    @State private var flipped = false
    @State private var aspect: AspectOption?
    @State private var saved = false
    @State private var placed: [PlacedSticker] = []
    @ObservedObject private var statsStore = StatsStore.shared
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
                    // Step 2: one photo and its tools. Fades in a beat later. The photo fills the free space; the tool row and Save sit below.
                    Group {
                        if videoAsset != nil {
                            videoView
                        } else {
                            VStack(spacing: 0) {
                                preview.frame(maxHeight: .infinity)
                                readout.frame(height: 30).padding(.top, 14)
                                toolNames.padding(.top, 6)
                                controls.frame(height: 100, alignment: .center).padding(.top, 8)
                                bottomBar.padding(.top, 16)
                            }
                        }
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
        .onChange(of: params) { _, _ in render() }
        .onChange(of: tab) { _, _ in styleTuning = false }
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
        player?.pause()
        withAnimation(.smooth(duration: 0.38)) { editorOpen = false }
        // Clear the photo only after the fade, so the screen doesn't change underneath while it fades out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard !editorOpen else { return }
            selectedID = nil; selectedDate = nil; source = nil; lab.clear(); loadingPhoto = false; saved = false; placeholder = nil
            player?.pause(); player = nil; videoAsset = nil
        }
    }

    // MARK: Preview
    /// The photo at its own shape (no letterbox bars), rounded and centred in whatever room is left.
    private var preview: some View {
        ZStack {
            if source != nil, let r = lab.image {
                Image(uiImage: comparing ? (lab.original ?? r) : r).resizable().scaledToFit()
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
                    .overlay { photoBadges }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { comparing = $0 }, perform: {})
            } else if let placeholder {
                // The thumbnail you tapped, already in place; the full photo fades in over it.
                Image(uiImage: placeholder).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(alignment: .bottom) { ProgressView().tint(.white).padding(.bottom, 12) }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Style/date chip, delete, and the compare hint, sitting on the photo itself.
    private var photoBadges: some View {
        ZStack {
            Text(chipText).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6).background(Color.black.opacity(0.5), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            Button {
                if let id = selectedID {
                    let r = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                    if let a = r.firstObject { delete([a]) { closeEditor() } }
                }
            } label: {
                Image(systemName: "trash").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(Color.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Delete photo")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
            Text(comparing ? "ORIGINAL" : "HOLD TO COMPARE").font(.system(size: 9, weight: .heavy, design: .monospaced)).tracking(1)
                .foregroundStyle(.white.opacity(0.85)).shadow(color: .black.opacity(0.5), radius: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8).allowsHitTesting(false)
        }
    }

    // MARK: Video (viewing only)
    private var videoView: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black)
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ZStack {
                        if let placeholder { Image(uiImage: placeholder).resizable().scaledToFit() }
                        ProgressView().tint(.white)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            // Not an overlay: the system video layer draws above SwiftUI content.
            Button {
                if let a = videoAsset { delete([a]) { closeEditor() } }
            } label: {
                Label("Delete video", systemImage: "trash")
                    .font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color(red: 1, green: 0.23, blue: 0.19), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func openVideo(_ a: PHAsset) {
        lastPickedID = a.localIdentifier
        let t = PHImageRequestOptions(); t.isSynchronous = true; t.deliveryMode = .fastFormat; t.resizeMode = .fast
        PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 700, height: 700), contentMode: .aspectFit, options: t) { img, _ in placeholder = img }
        withAnimation(.smooth(duration: 0.38)) {
            videoAsset = a; selectedID = a.localIdentifier; selectedDate = a.creationDate; editorOpen = true
        }
        let o = PHVideoRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .automatic
        PHImageManager.default().requestPlayerItem(forVideo: a, options: o) { item, _ in
            guard let item else { return }
            DispatchQueue.main.async {
                guard videoAsset?.localIdentifier == a.localIdentifier else { return }
                let p = AVPlayer(playerItem: item)
                player = p
                p.play()
            }
        }
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
                Text(libraryCountText).font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(ink.opacity(0.6))
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
                                        } else if a.mediaType == .video { openVideo(a); Feedback.tick() } else { pick(a); Feedback.tick() }
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
    // MARK: Tools
    private var activeStyle: CameraStyle { model.styles[min(styleIndex, model.styles.count - 1)] }

    /// True when a tool has been moved off its default (its name gets a dot).
    private func edited(_ t: LabTab) -> Bool {
        switch t {
        case .exposure: exposure != 0
        case .style: styleIndex != 0 || strength < 1
        case .highlights: highlights != 0
        case .shadows: shadows != 0
        case .warmth: temp != 6500
        case .tint: tint != 0
        case .grain: grain != 0
        case .crop: rotation != 0 || flipped || aspect != nil
        case .stickers: !placed.isEmpty
        }
    }

    /// The current tool's value, big and centred above the tool names.
    private var readout: some View {
        let text: String = switch tab {
        case .exposure: String(format: "%+.1f EV", exposure)
        case .style: activeStyle.name.uppercased() + (strength < 0.999 ? String(format: " · %.0f%%", strength * 100) : "")
        case .highlights: String(format: "%+.0f", highlights * 100)
        case .shadows: String(format: "%+.0f", shadows * 100)
        case .warmth: String(format: "%.0fK", temp)
        case .tint: String(format: "%+.0f", tint)
        case .grain: String(format: "%.0f", grain)
        case .crop: (aspect?.rawValue ?? "ORIGINAL") + (flipped ? " · FLIPPED" : "") + (rotation > 0 ? " · \(rotation * 90)°" : "")
        case .stickers: placed.isEmpty ? "TAP ONE TO ADD" : "DRAG TO MOVE · DOUBLE-TAP TO RESIZE"
        }
        return Text(text)
            .font(.system(size: 16, weight: .semibold, design: .monospaced)).monospacedDigit()
            .foregroundStyle(edited(tab) ? cw.dialColor : ink)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }

    /// Tool names in a sliding row, like a lens ring: whichever name is in the middle is the tool you're using.
    /// Swipe the row (it snaps to the nearest name) or tap a name. A dot marks tools you've changed.
    private var toolNames: some View {
        GeometryReader { g in
            let w = g.size.width
            HStack(spacing: Self.nameGap) {
                ForEach(LabTab.allCases) { t in
                    VStack(spacing: 3) {
                        Text(t.rawValue)
                            .font(.system(size: 21, weight: .black, design: .rounded))
                            .foregroundStyle(ink.opacity(t == focusedName ? 1 : 0.28))
                        Circle().fill(cw.dialColor).frame(width: 5, height: 5).opacity(edited(t) ? 1 : 0)
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidths[t] = $0 }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.3)) { tab = t }
                        Feedback.tick()
                    }
                }
            }
            .fixedSize()
            .offset(x: w / 2 - nameCenter(tab) + nameDrag)
            .frame(width: w, alignment: .leading)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 6).onChanged { v in
            let before = focusedName
            nameDrag = v.translation.width
            if focusedName != before { Feedback.zoomTick() }
        }.onEnded { v in
            let target = nameCenter(tab) - v.predictedEndTranslation.width
            let best = LabTab.allCases.min { abs(nameCenter($0) - target) < abs(nameCenter($1) - target) } ?? tab
            withAnimation(.smooth(duration: 0.32)) { tab = best; nameDrag = 0 }
            Feedback.tick()
        })
        .padding(.horizontal, -22)   // run edge to edge under the screen's side margins
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    }

    private static let nameGap: CGFloat = 24
    /// Centre of a tool's name along the row.
    private func nameCenter(_ t: LabTab) -> CGFloat {
        var x: CGFloat = 0
        for c in LabTab.allCases {
            let wd = nameWidths[c] ?? 90
            if c == t { return x + wd / 2 }
            x += wd + Self.nameGap
        }
        return x
    }
    /// The name under the middle right now (follows the finger while the row is being dragged).
    private var focusedName: LabTab {
        let target = nameCenter(tab) - nameDrag
        return LabTab.allCases.min { abs(nameCenter($0) - target) < abs(nameCenter($1) - target) } ?? tab
    }

    @ViewBuilder private var controls: some View {
        switch tab {
        case .exposure:
            RulerDial(value: $exposure, range: -2...2, step: 0.1, defaultValue: 0, colors: [Color(white: 0.08), Color(white: 0.97)], cw: cw)
        case .highlights:
            RulerDial(value: $highlights, range: -1...1, step: 0.05, defaultValue: 0, colors: [Color(white: 0.35), Color(white: 1)], cw: cw)
        case .shadows:
            RulerDial(value: $shadows, range: -1...1, step: 0.05, defaultValue: 0, colors: [Color(white: 0.05), Color(white: 0.5)], cw: cw)
        case .warmth:
            RulerDial(value: $temp, range: 3000...10000, step: 100, defaultValue: 6500,
                      colors: [Color(red: 0.25, green: 0.5, blue: 1), Color(white: 0.92), Color(red: 1, green: 0.62, blue: 0.15)], cw: cw)
        case .tint:
            RulerDial(value: $tint, range: -100...100, step: 5, defaultValue: 0,
                      colors: [Color(red: 0.2, green: 0.75, blue: 0.35), Color(white: 0.92), Color(red: 0.9, green: 0.3, blue: 0.8)], cw: cw)
        case .grain:
            RulerDial(value: $grain, range: 0...100, step: 2, defaultValue: 0, colors: nil, cw: cw)
        case .style:
            if styleTuning {
                // Strength of the chosen Style; the chevron goes back to the Style thumbnails.
                HStack(spacing: 8) {
                    Button { withAnimation(.smooth(duration: 0.25)) { styleTuning = false }; Feedback.tick() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)).foregroundStyle(ink)
                            .frame(width: 40, height: 40).background(cw.panelColor, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel("Back to styles")
                    RulerDial(value: $strength, range: 0...1, step: 0.025, defaultValue: 1, colors: nil, cw: cw)
                }
                .transition(.opacity)
            } else {
                styleThumbnails.transition(.opacity)
            }
        case .crop:
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    roundTool("rotate.right", "Rotate", on: rotation != 0) { rotation = (rotation + 1) % 4 }
                    roundTool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip", on: flipped) { flipped.toggle() }
                }
                HStack(spacing: 6) {
                    chip("Original", nil, on: aspect == nil) { aspect = nil }
                    ForEach(AspectOption.allCases) { a in chip(a.rawValue, nil, on: aspect == a) { aspect = a } }
                }
            }
            .frame(maxWidth: .infinity)
        case .stickers:
            if statsStore.unlockedStickers.isEmpty {
                Text("Earn stickers with achievements.").font(.footnote).foregroundStyle(ink.opacity(0.6)).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(statsStore.unlockedStickers) { st in
                            StickerView(sticker: st, size: 52).onTapGesture { placed.append(PlacedSticker(sticker: st)); Feedback.tick() }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minWidth: UIScreen.main.bounds.width - 44)   // centred when there are only a few
                }
            }
        }
    }

    /// Each Style as a small copy of this photo. Tap to apply; tap the chosen one again to set its strength.
    private var styleThumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.styles.indices, id: \.self) { i in
                        let on = styleIndex == i
                        Button {
                            if on { withAnimation(.smooth(duration: 0.25)) { styleTuning = true } }
                            else { styleIndex = i; withAnimation(.smooth) { proxy.scrollTo(i, anchor: .center) } }
                            Feedback.tick()
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    if let t = lab.thumbs[i] { Image(uiImage: t).resizable().scaledToFill() } else { cw.panelColor }
                                    if on {
                                        Color.black.opacity(0.3)
                                        Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? cw.accentColor : .clear, lineWidth: 3))
                                Text(model.styles[i].name.uppercased())
                                    .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(ink.opacity(on ? 1 : 0.5)).lineLimit(1).frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain).id(i)
                        .accessibilityLabel(model.styles[i].name + (on ? ", selected. Tap to adjust strength." : ""))
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear { proxy.scrollTo(styleIndex, anchor: .center) }
        }
        .padding(.horizontal, -22).contentMargins(.horizontal, 22, for: .scrollContent)
    }

    private func roundTool(_ symbol: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); Feedback.tick() } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: .bold))
                Text(title).font(.system(size: 14, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(on ? Color.black.opacity(0.88) : ink)
            .padding(.horizontal, 18).frame(height: 42)
            .background(on ? cw.accentColor : cw.panelColor, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func chip(_ title: String, _ symbol: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); Feedback.tick() } label: {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .heavy, design: .rounded)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(on ? Color.black.opacity(0.88) : ink)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? cw.accentColor : cw.panelColor.opacity(0.7), in: Capsule())
        }.buttonStyle(.plain)
    }

    /// Reset everything on the left, Save a copy filling the rest.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { reset(); Feedback.thump() } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
                    .frame(width: 60, height: 60)
                    .background(cw.panelColor, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            }
            .buttonStyle(.plain).accessibilityLabel("Reset edits")
            Button { save(); Feedback.thump() } label: {
                HStack {
                    Text(saved ? "Saved ✓" : "Save a copy").font(.system(size: 20, weight: .black, design: .rounded))
                    Spacer()
                    Image(systemName: saved ? "checkmark" : "arrow.down.to.line").font(.system(size: 20, weight: .bold))
                }
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 22).frame(height: 60)
                .background(cw.dialColor, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 6, y: 4)
            }
            .buttonStyle(.plain).disabled(source == nil).opacity(source == nil ? 0.45 : 1)
        }
    }

    // MARK: Library + photo loading
    private var libraryCountText: String {
        guard let assets else { return "0 PHOTOS" }
        var photos = 0, videos = 0
        assets.enumerateObjects { a, _, _ in if a.mediaType == .video { videos += 1 } else { photos += 1 } }
        return videos > 0 ? "\(photos) PHOTOS · \(videos) \(videos == 1 ? "VIDEO" : "VIDEOS")" : "\(photos) PHOTOS"
    }

    private func fetchAssets() {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        o.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        assets = PHAsset.fetchAssets(with: o)
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
        source = img; saved = false
        lab.load(img, styles: model.styles)
        reset()
    }

    private func reset() {
        exposure = 0; grain = 0; temp = 6500; tint = 0; highlights = 0; shadows = 0; strength = 1; styleIndex = 0
        rotation = 0; flipped = false; aspect = nil; placed = []; styleTuning = false; render()
    }

    // MARK: Image pipeline
    private var params: LabParams {
        LabParams(exposure: exposure, grain: grain, temp: temp, tint: tint, highlights: highlights, shadows: shadows,
                  strength: strength, styleIndex: styleIndex, rotation: rotation, flipped: flipped, aspect: aspect)
    }

    /// Pure function of the source and the settings, so it can run off the main thread.
    static func pipeline(_ src: CIImage, _ p: LabParams, style: CameraStyle) -> CIImage {
        var img = src
        img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: p.exposure])
        img = img.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: CGFloat(6500 * 6500 / p.temp), y: CGFloat(-p.tint))])
        // Both mirrored so the picture moves the way the dial's strip shows: higher K = warmer, + tint = magenta.
        img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + min(p.highlights, 0), "inputShadowAmount": p.shadows])
        if p.highlights > 0 {   // lift the top of the tone curve
            let h = CGFloat(p.highlights)
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25), "inputPoint2": CIVector(x: 0.5, y: 0.5 + 0.03 * h),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.14 * h), "inputPoint4": CIVector(x: 1, y: 1)])
        }
        img = Styles.apply(style, to: img, strength: Float(p.strength))
        if p.grain > 0 { img = Styles.addGrain(Float(p.grain / 100) * 0.9, to: img) }
        for _ in 0..<p.rotation { img = img.oriented(.right) }
        if p.flipped { img = img.oriented(.upMirrored) }
        if let a = p.aspect {
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
        guard source != nil else { return }
        lab.submit(params, style: activeStyle)
    }

    private func save() {
        guard let src = source else { return }
        // Full resolution, off the main thread; stickers are drawn by SwiftUI so they're composited here first.
        let p = params, style = activeStyle
        let stickered = compositeStickers(CIImage(color: .clear).cropped(to: Self.pipeline(src, p, style: style).extent))
        DispatchQueue.global(qos: .userInitiated).async {
            let out = stickered.composited(over: Self.pipeline(src, p, style: style))
            guard let data = CIContext().heifRepresentation(of: out, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [:]) else { return }
            // Saved like any other photo: into the !Camera album and the Photo Book.
            CameraModel.saveToLibrary(heic: data, dng: nil) { ok in
                DispatchQueue.main.async { saved = ok; if ok { StatsStore.shared.recordLabSave() } }
            }
        }
    }
}

struct LabParams: Equatable {
    var exposure = 0.0, grain = 0.0, temp = 6500.0, tint = 0.0, highlights = 0.0, shadows = 0.0, strength = 1.0
    var styleIndex = 0, rotation = 0, flipped = false
    var aspect: AspectOption?
}

/// Renders Photo Lab previews on its own queue from a small copy of the photo made once, keeping only the newest request,
/// so dragging a dial never waits on the full-size photo or blocks the screen.
final class LabRenderer: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var original: UIImage?
    @Published private(set) var thumbs: [Int: UIImage] = [:]
    private let queue = DispatchQueue(label: "photolab.render", qos: .userInteractive)
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private var base: CIImage?            // queue only
    private var quickBase: CIImage?       // ~half size, used while a dial is moving
    private var settle: DispatchWorkItem?  // main only: the sharp redraw once input stops
    private let lock = NSLock()
    private var pending: (LabParams, CameraStyle, Bool)?
    private var busy = false
    private var token = 0                 // main only; bumps on every new photo

    func load(_ src: CIImage, styles: [CameraStyle]) {
        token += 1
        let t = token
        queue.async {
            let k = min(1, 1400 / max(src.extent.width, src.extent.height))
            let small = src.transformed(by: CGAffineTransform(scaleX: k, y: k))
            guard let cg = self.ctx.createCGImage(small, from: small.extent) else { return }
            let base = CIImage(cgImage: cg)
            self.base = base
            let qk = 700 / max(base.extent.width, base.extent.height)
            let q = base.transformed(by: CGAffineTransform(scaleX: qk, y: qk))
            self.quickBase = self.ctx.createCGImage(q, from: q.extent).map { CIImage(cgImage: $0) }
            DispatchQueue.main.async { if t == self.token { self.original = UIImage(cgImage: cg) } }
            // A tiny copy of the photo in every Style, for the Style picker.
            let tk = 180 / max(base.extent.width, base.extent.height)
            let tinySmall = base.transformed(by: CGAffineTransform(scaleX: tk, y: tk))
            guard let tcg = self.ctx.createCGImage(tinySmall, from: tinySmall.extent) else { return }
            let tiny = CIImage(cgImage: tcg)
            var out: [Int: UIImage] = [:]
            for (i, st) in styles.enumerated() {
                let o = Styles.apply(st, to: tiny).cropped(to: tiny.extent)
                if let c = self.ctx.createCGImage(o, from: tiny.extent) { out[i] = UIImage(cgImage: c) }
            }
            DispatchQueue.main.async { if t == self.token { self.thumbs = out } }
        }
    }

    func clear() {
        token += 1
        image = nil; original = nil; thumbs = [:]
        settle?.cancel()
        queue.async { self.base = nil; self.quickBase = nil }
    }

    /// Draws quickly from the small copy right away, then sharp from the full preview once changes pause.
    func submit(_ p: LabParams, style: CameraStyle) {
        enqueue(p, style, quick: true)
        settle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.enqueue(p, style, quick: false) }
        settle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func enqueue(_ p: LabParams, _ style: CameraStyle, quick: Bool) {
        lock.lock(); pending = (p, style, quick); let start = !busy; busy = true; lock.unlock()
        let t = token
        if start { queue.async { self.drain(t) } }
    }

    private func drain(_ t: Int) {
        while true {
            lock.lock()
            guard let job = pending else { busy = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            guard let src = (job.2 ? quickBase : nil) ?? base else { continue }
            let out = PhotoLabView.pipeline(src, job.0, style: job.1)
            guard let cg = ctx.createCGImage(out, from: out.extent) else { continue }
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async { if t == self.token { self.image = ui } }
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

/// A tick ruler that slides under a fixed centre mark. Under the ticks runs a colour strip showing what the dial does
/// (dark→light, blue→amber, green→magenta), so each tool reads differently at a glance. A notch you can feel on every
/// step and a firmer one at the default (the dot). Double-tap puts it back to the default.
struct RulerDial: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    let colors: [Color]?
    let cw: Colorway
    @State private var dragBase: Double?
    private let spacing: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2
            let lo = Int((range.lowerBound / step).rounded()), hi = Int((range.upperBound / step).rounded())
            let at = value / step
            func x(_ k: Double) -> CGFloat { mid + CGFloat(k - at) * spacing }
            let tickTop: CGFloat = 4, tickBottom: CGFloat = 32
            for k in lo...hi {
                let px = x(Double(k))
                guard px > -2, px < size.width + 2 else { continue }
                let edge = min(1, Double(min(px, size.width - px) / (size.width * 0.2)))
                let major = k % 5 == 0
                let h: CGFloat = major ? 22 : 12
                var p = Path(); p.move(to: CGPoint(x: px, y: tickBottom - h)); p.addLine(to: CGPoint(x: px, y: tickBottom))
                ctx.stroke(p, with: .color(cw.ink.opacity((major ? 0.7 : 0.3) * edge)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            // The strip covers the whole range and slides with the ticks.
            let x0 = x(Double(lo)), x1 = x(Double(hi))
            let strip = Path(roundedRect: CGRect(x: x0, y: tickBottom + 6, width: x1 - x0, height: 6), cornerRadius: 3)
            if let colors {
                ctx.fill(strip, with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0)))
                ctx.stroke(strip, with: .color(cw.ink.opacity(0.15)), lineWidth: 0.5)
            } else {
                ctx.fill(strip, with: .color(cw.ink.opacity(0.12)))
            }
            // The default as a dot under the strip, then the fixed centre mark.
            let dx = x(defaultValue / step)
            if dx > 0, dx < size.width {
                ctx.fill(Path(ellipseIn: CGRect(x: dx - 2.5, y: tickBottom + 16, width: 5, height: 5)), with: .color(cw.ink.opacity(0.55)))
            }
            var c = Path(); c.move(to: CGPoint(x: mid, y: tickTop - 3)); c.addLine(to: CGPoint(x: mid, y: tickBottom + 14))
            ctx.stroke(c, with: .color(cw.dialColor), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        .frame(height: 56)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
            if dragBase == nil { dragBase = value }
            let raw = (dragBase ?? value) - Double(v.translation.width / spacing) * step
            let snapped = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
            guard abs(snapped - value) > step / 2 else { return }
            let crossedDefault = (value - defaultValue) * (snapped - defaultValue) <= 0
            value = snapped
            if crossedDefault { Feedback.detent() } else { Feedback.zoomTick() }
        }.onEnded { _ in dragBase = nil })
        .onTapGesture(count: 2) { withAnimation(.smooth) { value = defaultValue }; Feedback.thump() }
    }
}

private struct LabThumb: View {
    let asset: PHAsset
    @State private var image: UIImage?
    static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
    }
    var body: some View {
        GeometryReader { g in
            Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.gray.opacity(0.25) } }
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .overlay(alignment: .bottomLeading) {
            if asset.mediaType == .video {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    Text(Self.duration(asset.duration)).font(.system(size: 11, weight: .heavy, design: .monospaced))
                }
                .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule()).padding(6)
            }
        }
        .onAppear {
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.resizeMode = .fast; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 320, height: 320), contentMode: .aspectFill, options: o) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}
