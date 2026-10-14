import SwiftUI
import CoreImage.CIFilterBuiltins
import VisionKit

/// Colorways travel as a QR code containing a notboringcamera://colorway deep link.
enum ColorwayCodec {
    struct Payload: Codable { var n: String; var b: String; var p: String; var d: String; var a: String; var s: String }

    static func url(for c: Colorway) -> URL? {
        let p = Payload(n: c.name, b: c.body, p: c.panel, d: c.dial, a: c.accent, s: c.shutter)
        guard let data = try? JSONEncoder().encode(p) else { return nil }
        let b64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "notboringcamera://colorway?d=\(b64)")
    }

    static func colorway(from url: URL) -> Colorway? {
        guard url.scheme == "notboringcamera", url.host == "colorway",
              let d = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value else { return nil }
        var b64 = d.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        func ok(_ h: String) -> Bool { h.count == 6 && UInt64(h, radix: 16) != nil }
        guard [p.b, p.p, p.d, p.a, p.s].allSatisfy(ok) else { return nil }
        return Colorway(id: "custom-" + UUID().uuidString.prefix(8), name: String(p.n.prefix(24)), body: p.b, panel: p.p, dial: p.d, accent: p.a, shutter: p.s)
    }

    static func qr(for c: Colorway) -> UIImage? {
        guard let url = url(for: c) else { return nil }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension Color {
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

struct ColorwayEditorView: View {
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    @State var body_: Color
    @State var panel: Color
    @State var dial: Color
    @State var accent: Color
    @State var shutter: Color
    @State private var qrImage: UIImage?
    private let existingID: String?

    init(editing c: Colorway? = nil) {
        let base = c ?? Colorway.presets[0]
        _name = State(initialValue: c?.name ?? "My Colorway")
        _body_ = State(initialValue: base.bodyColor); _panel = State(initialValue: base.panelColor)
        _dial = State(initialValue: base.dialColor); _accent = State(initialValue: base.accentColor); _shutter = State(initialValue: base.shutterColor)
        existingID = (c?.id.hasPrefix("custom-") ?? false) ? c?.id : nil
    }

    private var current: Colorway {
        Colorway(id: existingID ?? "custom-" + UUID().uuidString.prefix(8), name: name, body: body_.hexString, panel: panel.hexString, dial: dial.hexString, accent: accent.hexString, shutter: shutter.hexString)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { preview }
                Section("Name") { TextField("Name", text: $name) }
                Section("Colors") {
                    ColorPicker("Body", selection: $body_); ColorPicker("Panels & switches", selection: $panel)
                    ColorPicker("Exposure dial", selection: $dial); ColorPicker("Style dial", selection: $accent); ColorPicker("Shutter", selection: $shutter)
                }
                Section {
                    Button("Save colorway") { save(); dismiss() }
                    Button("Share as QR code") { qrImage = ColorwayCodec.qr(for: current); StatsStore.shared.recordQRShare() }
                }
                if let img = qrImage {
                    Section("Scan to import") {
                        Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(maxWidth: .infinity).padding(8).background(.white)
                        if let url = ColorwayCodec.url(for: current) { ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") } }
                    }
                }
            }
            .navigationTitle("Colorway").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Circle().fill(dial).frame(width: 54, height: 54)
            Circle().fill(shutter).frame(width: 54, height: 54)
            Circle().fill(accent).frame(width: 54, height: 54)
            Capsule().fill(panel).frame(width: 70, height: 36)
        }
        .frame(maxWidth: .infinity).padding(16).background(body_, in: RoundedRectangle(cornerRadius: 18))
    }

    private func save() {
        var list = s.customColorways
        let c = current
        if let i = list.firstIndex(where: { $0.id == c.id }) { list[i] = c } else { list.append(c) }
        s.customColorways = list
        s.colorwayID = c.id
    }
}

struct QRScannerView: View {
    @EnvironmentObject var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Point at a !Camera colorway QR code"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onCode: handle)
                } else {
                    Text("QR scanning isn't available on this device. Open the shared link instead.").padding().multilineTextAlignment(.center)
                }
                Text(message).font(.footnote.bold()).padding(10).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 24)
            }
            .navigationTitle("Scan colorway").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func handle(_ payload: String) {
        guard let u = URL(string: payload), let c = ColorwayCodec.colorway(from: u) else { message = "Not a !Camera colorway"; return }
        s.customColorways.append(c); s.colorwayID = c.id
        Feedback.thump(); dismiss()
    }

    struct Scanner: UIViewControllerRepresentable {
        let onCode: (String) -> Void
        func makeCoordinator() -> Coord { Coord(onCode) }
        func makeUIViewController(context: Context) -> DataScannerViewController {
            let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
            v.delegate = context.coordinator
            try? v.startScanning()
            return v
        }
        func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
        final class Coord: NSObject, DataScannerViewControllerDelegate {
            let onCode: (String) -> Void
            init(_ f: @escaping (String) -> Void) { onCode = f }
            func dataScanner(_ d: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                for case .barcode(let b) in items { if let v = b.payloadStringValue { onCode(v); return } }
            }
        }
    }
}
