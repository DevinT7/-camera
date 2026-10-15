import SwiftUI
import UniformTypeIdentifiers

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

    var body: some View {
        NavigationStack {
            Form {
                Section { Button { achievements = true } label: { Label("Achievements & Stickers", systemImage: "trophy.fill") } }
                captureSection
                lookSection
                rollSection
                controlsSection
                colorwaySection
                stylesSection
                launchSection
                privacySection
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
    }

    @ViewBuilder private var captureSection: some View {
                Section("Capture") {
                    Picker("Processing", selection: $s.pipeline) { ForEach(CapturePipeline.allCases) { Text($0.rawValue).tag($0) } }
                    Text(s.pipeline.blurb).font(.footnote).foregroundStyle(.secondary)
                    Picker("Aspect ratio", selection: $s.aspect) { ForEach(AspectOption.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("HDR", isOn: $s.hdr)
                    Toggle("48MP max resolution", isOn: $s.hiRes)
                    Toggle("Save HEIC + DNG RAW", isOn: $s.rawPlusHeic)
                    Stepper("Photo Review: \(s.photoReviewSeconds == 0 ? "Off" : "\(s.photoReviewSeconds)s")", value: $s.photoReviewSeconds, in: 0...10)
                    Toggle("Mirror selfie preview", isOn: $s.mirrorPreview)
                    Toggle("Save selfies mirrored", isOn: $s.mirrorSelfies)
                    Toggle("Save to “!Camera” album", isOn: $s.saveToAlbum)
                }
    }

    @ViewBuilder private var lookSection: some View {
        Section("Look") {
            Picker("Date stamp", selection: $s.dateStamp) { ForEach(StampOption.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Light leaks", selection: $s.lightLeaks) { ForEach(LeakOption.allCases) { Text($0.rawValue).tag($0) } }
            Text("Date stamps and leaks are burned into saved photos. “Random” gives every shot a different leak from a random corner.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var rollSection: some View {
        Section("Film Roll") {
            Toggle("Film roll mode", isOn: $s.filmRoll)
            Text("A fixed number of frames. No preview, no deleting. Shots are held back and “developed” into Photos 24 hours after the last frame.").font(.footnote).foregroundStyle(.secondary)
            if s.filmRoll {
                Picker("Frames per roll", selection: $s.rollSize) { Text("24").tag(24); Text("36").tag(36) }.pickerStyle(.segmented)
                LabeledContent("On the roll", value: "\(roll.framesShot) of \(roll.current?.size ?? s.rollSize) shot")
                if roll.pendingFrames > 0 {
                    LabeledContent("Waiting to develop", value: "\(roll.pendingFrames) frames")
                    if let d = roll.nextDevelop { LabeledContent("Next develop", value: d.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Finish this roll early") { roll.rewind() }.disabled(roll.framesShot == 0)
                    Button("Develop everything now", role: .destructive) { roll.developDue(force: true) }
                }
            }
        }
    }

    @ViewBuilder private var controlsSection: some View {
                Section("Controls") {
                    Picker("Grid", selection: $s.grid) { ForEach(GridStyle.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Histogram", isOn: $s.histogram)
                    Toggle("Camera diagnostics overlay", isOn: $s.cameraDiagnostics)
                    Toggle("Zebra stripes", isOn: $s.zebra)
                    Toggle("Focus peaking", isOn: $s.focusPeaking)
                    Toggle("Remember Style, Lens, Flash, Mode & Exposure", isOn: $s.rememberSettings)
                    Toggle("Keep screen awake", isOn: $s.keepAwake)
                    Toggle("Sounds", isOn: $s.sounds)
                    Toggle("Haptics", isOn: $s.haptics)
                }
    }

    @ViewBuilder private var colorwaySection: some View {
                Section("Colorways") {
                    ForEach(Colorway.presets + s.customColorways) { c in
                        Button {
                            s.colorwayID = c.id
                        } label: {
                            HStack {
                                HStack(spacing: 4) { ForEach([c.bodyColor, c.dialColor, c.accentColor, c.shutterColor], id: \.self) { Circle().fill($0).frame(width: 18, height: 18).overlay(Circle().stroke(.gray.opacity(0.4))) } }
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                if s.colorwayID == c.id { Image(systemName: "checkmark") }
                            }
                        }
                        .swipeActions { if c.id.hasPrefix("custom-") {
                            Button("Delete", role: .destructive) { s.customColorways.removeAll { $0.id == c.id }; if s.colorwayID == c.id { s.colorwayID = "orange" } }
                            Button("Edit") { editing = c }.tint(.blue)
                        } else { Button("Duplicate") { editing = c }.tint(.blue) } }
                    }
                    Button { newColorway = true } label: { Label("New colorway…", systemImage: "paintbrush.pointed") }
                    Button { scanning = true } label: { Label("Scan colorway QR code", systemImage: "qrcode.viewfinder") }
                }
    }

    @ViewBuilder private var stylesSection: some View {
                Section("Styles") {
                    Text("\(model.styles.count) styles loaded (3D LUTs).").font(.footnote).foregroundStyle(.secondary)
                    Button { importing = true } label: {
                        Label("Import .CUBE LUT", systemImage: "square.and.arrow.down")
                    }
                    if let e = importError { Text(e).foregroundStyle(.red).font(.footnote) }
                }
    }

    @ViewBuilder private var launchSection: some View {
                Section("Launch") {
                    Text("Open from the Lock Screen, Action button, Camera Control, widgets or Control Center. Add the matching extensions in Xcode (see README).").font(.footnote).foregroundStyle(.secondary)
                }
    }

    @ViewBuilder private var privacySection: some View {
                Section { Text("Collects, stores and shares nothing.").font(.footnote).foregroundStyle(.secondary) }
    }

}
