import SwiftUI
import UniformTypeIdentifiers

/// Settings in the camera's own look: the body colour behind everything, recessed cards, mono section labels,
/// chunky toggles in the dial colour. Nothing here should feel like leaving the camera.
struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importError: String?
    @State private var editing: Colorway?
    @State private var newColorway = false
    @State private var scanning = false
    @State private var achievements = false
    @ObservedObject private var roll = RollStore.shared

    private var cw: Colorway { s.colorway }
    private var ink: Color { cw.ink }

    var body: some View {
        ZStack {
            cw.bodyColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    trophySection
                    cameraSection
                    selfieSection
                    lookSection
                    rollSection
                    viewfinderSection
                    feelSection
                    bodySection
                    stylesSection
                    smallPrintSection
                    footer
                }
                .padding(.horizontal, 22)
            }
        }
        .preferredColorScheme(cw.isDarkBody ? .dark : .light)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .plainText, .data]) { r in
            switch r {
            case .success(let u):
                do { try Styles.importCube(from: u); model.styles = Styles.all + Styles.loadCustom(); importError = nil; StatsStore.shared.recordLUTImport() }
                catch { importError = "That doesn't look like a 3D .cube LUT." }
            case .failure(let e): importError = e.localizedDescription
            }
        }
        .sheet(isPresented: $newColorway) { ColorwayEditorView().environmentObject(s) }
        .sheet(item: $editing) { ColorwayEditorView(editing: $0).environmentObject(s) }
        .sheet(isPresented: $scanning) { QRScannerView().environmentObject(s) }
        .sheet(isPresented: $achievements) { AchievementsView() }
    }

    // MARK: Header / footer
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("!CAMERA / SETTINGS").font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.5).foregroundStyle(ink.opacity(0.6))
                Spacer()
                Button { dismiss(); Feedback.toggle() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(ink)
                        .frame(width: 46, height: 46)
                        .background(cw.panelColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 3)
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
        }
        .padding(.top, 18)
    }

    private var footer: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("!Camera").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(ink)
            Spacer()
            Text("V\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") / MADE FOR PLAY")
                .font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(0.4).foregroundStyle(ink.opacity(0.6))
        }
        .padding(.top, 34).padding(.bottom, 30)
    }

    // MARK: Sections
    private var trophySection: some View {
        SettingsGroup(title: nil, cw: cw) {
            SettingsButtonRow(icon: "trophy.fill", title: "Achievements & stickers", subtitle: { let n = StatsStore.shared.unlockedStickers.count; return n == 1 ? "1 sticker earned" : "\(n) stickers earned" }(), cw: cw) { achievements = true }
        }
    }

    private var cameraSection: some View {
        SettingsGroup(title: "THE CAMERA", cw: cw) {
            SettingsMenuRow(icon: "cpu", title: "Processing", subtitle: s.pipeline.blurb.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." }, value: s.pipeline.rawValue, cw: cw) {
                Picker("Processing", selection: $s.pipeline) { ForEach(CapturePipeline.allCases) { Text($0.rawValue).tag($0) } }
            }
            SettingsMenuRow(icon: "aspectratio", title: "Aspect ratio", value: s.aspect.rawValue, cw: cw) {
                Picker("Aspect ratio", selection: $s.aspect) { ForEach(AspectOption.allCases) { Text($0.rawValue).tag($0) } }
            }
            SettingsToggleRow(icon: "sun.max.fill", title: "HDR", subtitle: "Brighter highlights on HDR screens", isOn: $s.hdr, cw: cw)
            SettingsToggleRow(icon: "square.resize.up", title: "48MP max resolution", isOn: $s.hiRes, cw: cw)
            SettingsToggleRow(icon: "doc.on.doc", title: "Save HEIC + DNG RAW", subtitle: "Keeps a RAW copy for editing later", isOn: $s.rawPlusHeic, cw: cw)
            SettingsMenuRow(icon: "eye", title: "Photo review", value: s.photoReviewSeconds == 0 ? "Off" : "\(s.photoReviewSeconds)s", cw: cw) {
                Picker("Photo review", selection: $s.photoReviewSeconds) {
                    Text("Off").tag(0); ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
            SettingsToggleRow(icon: "rectangle.stack", title: "Own album", subtitle: "Keeps shots in a “!Camera” album", isOn: $s.saveToAlbum, cw: cw)
        }
    }

    private var selfieSection: some View {
        SettingsGroup(title: "SELFIES", cw: cw) {
            SettingsToggleRow(icon: "person.crop.square", title: "Mirror the preview", subtitle: "Like looking in a mirror", isOn: $s.mirrorPreview, cw: cw)
            SettingsToggleRow(icon: "arrow.left.and.right.square", title: "Save selfies mirrored", isOn: $s.mirrorSelfies, cw: cw)
        }
    }

    private var lookSection: some View {
        SettingsGroup(title: "THE LOOK", footnote: "Date stamps and leaks are burned into saved photos. “Random” gives every shot a leak from a different corner.", cw: cw) {
            SettingsMenuRow(icon: "calendar", title: "Date stamp", value: s.dateStamp.rawValue, cw: cw) {
                Picker("Date stamp", selection: $s.dateStamp) { ForEach(StampOption.allCases) { Text($0.rawValue).tag($0) } }
            }
            SettingsMenuRow(icon: "flame", title: "Light leaks", value: s.lightLeaks.rawValue, cw: cw) {
                Picker("Light leaks", selection: $s.lightLeaks) { ForEach(LeakOption.allCases) { Text($0.rawValue).tag($0) } }
            }
        }
    }

    private var rollSection: some View {
        SettingsGroup(title: "THE FILM ROLL", footnote: rollFootnote, cw: cw) {
            SettingsToggleRow(icon: "film", title: "Film roll mode", subtitle: "No preview, no deleting. Shots develop later.", isOn: $s.filmRoll, cw: cw)
            if s.filmRoll {
                SettingsMenuRow(icon: "number", title: "Frames per roll", value: "\(s.rollSize)", cw: cw) {
                    Picker("Frames per roll", selection: $s.rollSize) { Text("24").tag(24); Text("36").tag(36) }
                }
                SettingsMenuRow(icon: "clock", title: "Film development", value: "\(s.developHours) hours", cw: cw) {
                    Picker("Development time", selection: $s.developHours) { ForEach([2, 4, 8, 24], id: \.self) { Text("\($0) hours").tag($0) } }
                }
                SettingsInfoRow(icon: "camera.shutter.button", title: "On the roll", value: "\(roll.framesShot) of \(roll.current?.size ?? s.rollSize)", cw: cw)
                if roll.pendingFrames > 0 {
                    SettingsInfoRow(icon: "hourglass", title: "Waiting to develop", value: "\(roll.pendingFrames) frames", cw: cw)
                    if let d = roll.nextDevelop {
                        SettingsInfoRow(icon: "calendar.badge.clock", title: "Next develop", value: d.formatted(date: .abbreviated, time: .shortened), cw: cw)
                    }
                    if roll.framesShot > 0 {
                        SettingsButtonRow(icon: "forward.end", title: "Finish this roll early", cw: cw) { roll.rewind() }
                    }
                    SettingsButtonRow(icon: "bolt.fill", title: "Develop everything now", tint: Color(hex: "E5483B"), cw: cw) { roll.developDue(force: true) }
                }
            }
        }
        .onChange(of: s.filmRoll) { _, on in if on { RollNotifications.requestIfNeeded() } }
    }

    private var rollFootnote: String? {
        guard s.filmRoll else { return nil }
        return s.developHours <= 8
            ? "When a roll is finished, your Lock Screen and Dynamic Island count down until it develops."
            : "iOS keeps a Live Activity for 8 hours at most, so a 24-hour roll sends a notification when it's sealed and another when it's ready."
    }

    private var viewfinderSection: some View {
        SettingsGroup(title: "THE VIEWFINDER", cw: cw) {
            SettingsMenuRow(icon: "grid", title: "Viewfinder grid", value: s.grid.rawValue, cw: cw) {
                Picker("Grid", selection: $s.grid) { ForEach(GridStyle.allCases) { Text($0.rawValue).tag($0) } }
            }
            SettingsToggleRow(icon: "level", title: "Level", isOn: $s.level, cw: cw)
            SettingsToggleRow(icon: "chart.bar.fill", title: "Histogram", subtitle: "Shown in Manual", isOn: $s.histogram, cw: cw)
            SettingsToggleRow(icon: "line.diagonal", title: "Zebra stripes", subtitle: "Marks blown-out highlights in Manual", isOn: $s.zebra, cw: cw)
            SettingsToggleRow(icon: "scope", title: "Focus peaking", subtitle: "Outlines what's sharp in Manual", isOn: $s.focusPeaking, cw: cw)
            SettingsToggleRow(icon: "camera.viewfinder", title: "Native preview", subtitle: "Used when no Style is on", isOn: $s.systemPreview, cw: cw)
            SettingsToggleRow(icon: "stethoscope", title: "Diagnostics overlay", isOn: $s.cameraDiagnostics, cw: cw)
        }
    }

    private var feelSection: some View {
        SettingsGroup(title: "THE FEEL", cw: cw) {
            SettingsToggleRow(icon: "iphone.radiowaves.left.and.right", title: "Haptic clicks", subtitle: "Feel every turn of the dial", isOn: $s.haptics, cw: cw)
            SettingsToggleRow(icon: "speaker.wave.2", title: "Sounds", isOn: $s.sounds, cw: cw)
            SettingsToggleRow(icon: "sun.min", title: "Keep screen awake", isOn: $s.keepAwake, cw: cw)
            SettingsToggleRow(icon: "memorychip", title: "Remember my setup", subtitle: "Style, lens, flash, mode and exposure", isOn: $s.rememberSettings, cw: cw)
        }
    }

    private var bodySection: some View {
        SettingsGroup(title: "CAMERA BODY", footnote: "Long-press a colorway to edit, duplicate or delete it.", cw: cw) {
            ForEach(Colorway.presets + s.customColorways) { c in
                Button { s.colorwayID = c.id; Feedback.toggle() } label: {
                    SettingsRowLayout(cw: cw) {
                        // The colorway's four colours as a tiny 2×2 swatch, the same width as the other rows' icons.
                        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                            GridRow { swatch(c.bodyColor); swatch(c.dialColor) }
                            GridRow { swatch(c.accentColor); swatch(c.shutterColor) }
                        }
                    } title: {
                        Text(c.name)
                    } trailing: {
                        if s.colorwayID == c.id {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(cw.dialColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if c.id.hasPrefix("custom-") {
                        Button("Edit", systemImage: "pencil") { editing = c }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            s.customColorways.removeAll { $0.id == c.id }
                            if s.colorwayID == c.id { s.colorwayID = "orange" }
                        }
                    } else {
                        Button("Duplicate and edit", systemImage: "plus.square.on.square") { editing = c }
                    }
                }
            }
            SettingsButtonRow(icon: "paintbrush.pointed", title: "New colorway…", cw: cw) { newColorway = true }
            SettingsButtonRow(icon: "qrcode.viewfinder", title: "Scan a colorway QR code", cw: cw) { scanning = true }
        }
    }

    private func swatch(_ c: Color) -> some View {
        Circle().fill(c).frame(width: 12, height: 12).overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.75))
    }

    private var stylesSection: some View {
        SettingsGroup(title: "STYLES", footnote: importError, footnoteIsError: importError != nil, cw: cw) {
            SettingsInfoRow(icon: "swatchpalette", title: "Styles loaded", value: "\(model.styles.count)", cw: cw)
            SettingsButtonRow(icon: "square.and.arrow.down", title: "Import a .cube LUT", subtitle: "Turn any 3D LUT into a Style", cw: cw) { importing = true }
        }
    }

    private var smallPrintSection: some View {
        SettingsGroup(title: "THE SMALL PRINT", cw: cw) {
            SettingsInfoRow(icon: "bolt.horizontal", title: "Quick launch", subtitle: "Lock Screen, Action button, Camera Control, widgets and Control Center", cw: cw)
            SettingsInfoRow(icon: "lock.shield", title: "Privacy", subtitle: "Collects, stores and shares nothing", cw: cw)
        }
    }
}

// MARK: - Building blocks

/// A mono label, a recessed card of rows with hairlines between them, and an optional note under it.
struct SettingsGroup<Content: View>: View {
    let title: String?
    var footnote: String? = nil
    var footnoteIsError = false
    let cw: Colorway
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 12, weight: .medium, design: .monospaced)).tracking(0.6).foregroundStyle(cw.ink.opacity(0.6))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(cw.ink.opacity(0.09)).frame(height: 1).padding(.leading, 58).padding(.trailing, 16) }
                        row
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(cw.panelColor.shadow(.inner(color: .black.opacity(0.14), radius: 3, y: 2)))
            )
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(cw.isDarkBody ? 0.06 : 0.35), lineWidth: 1))
            if let footnote {
                Text(footnote).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(footnoteIsError ? Color(hex: "E5483B") : cw.ink.opacity(0.55))
                    .padding(.horizontal, 4)
            }
        }
        .padding(.top, 26)
    }
}

/// Icon, title (and optional subtitle), and whatever goes on the right.
struct SettingsRowLayout<Icon: View, Title: View, Trailing: View>: View {
    let cw: Colorway
    var subtitle: String? = nil
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                title.font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(cw.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(cw.ink.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, subtitle == nil ? 13 : 11)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

private func settingsIcon(_ name: String, _ color: Color) -> some View {
    Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(color).frame(width: 28)
}

/// A row with the app's own toggle. Tapping anywhere on the row flips it.
struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    let cw: Colorway

    var body: some View {
        SettingsRowLayout(cw: cw, subtitle: subtitle) { settingsIcon(icon, cw.ink) } title: { Text(title) } trailing: {
            ChunkyToggle(isOn: isOn, cw: cw)
        }
        .onTapGesture { withAnimation(.spring(duration: 0.28)) { isOn.toggle() }; Feedback.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(subtitle ?? "")
    }
}

/// The pill toggle from the design: dial colour when on, a soft recess when off, white knob.
struct ChunkyToggle: View {
    let isOn: Bool
    let cw: Colorway
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill((isOn ? cw.dialColor : cw.ink.opacity(0.14)).shadow(.inner(color: .black.opacity(0.22), radius: 2, y: 1)))
                .frame(width: 52, height: 31)
            Circle().fill(.white).frame(width: 25, height: 25).shadow(color: .black.opacity(0.22), radius: 2, y: 1.5).padding(3)
        }
        .animation(.spring(duration: 0.28), value: isOn)
    }
}

/// A row that opens a menu of choices; shows the current choice and a chevron.
struct SettingsMenuRow<Choices: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let value: String
    let cw: Colorway
    @ViewBuilder let choices: Choices

    var body: some View {
        Menu { choices } label: {
            SettingsRowLayout(cw: cw, subtitle: subtitle) { settingsIcon(icon, cw.ink) } title: { Text(title) } trailing: {
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(cw.ink.opacity(0.6)).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(cw.ink.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Feedback.tick() })
    }
}

/// A row that does something when tapped.
struct SettingsButtonRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color? = nil
    let cw: Colorway
    let action: () -> Void

    var body: some View {
        Button { action(); Feedback.toggle() } label: {
            SettingsRowLayout(cw: cw, subtitle: subtitle) { settingsIcon(icon, tint ?? cw.ink) } title: {
                Text(title).foregroundStyle(tint ?? cw.ink)
            } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(cw.ink.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A row that only shows information.
struct SettingsInfoRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    let cw: Colorway

    var body: some View {
        SettingsRowLayout(cw: cw, subtitle: subtitle) { settingsIcon(icon, cw.ink) } title: { Text(title) } trailing: {
            if let value { Text(value).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(cw.ink.opacity(0.6)).monospacedDigit() }
        }
        .accessibilityElement(children: .combine)
    }
}
