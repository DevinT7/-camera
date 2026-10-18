import SwiftUI
import Photos
import ImageIO

private let sheetInk = Color(red: 0.07, green: 0.065, blue: 0.06)
private let sheetOrange = Color(red: 1, green: 0.55, blue: 0.1)

/// A roll that has just been developed: small frames kept for the reveal and the contact sheet.
struct DevelopedRoll: Identifiable {
    let id = UUID()
    let frames: [UIImage]
    let date: Date
    let size: Int
}

enum RollThumbs {
    static func thumbnail(from data: Data, maxPixel: Int = 480) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map(UIImage.init(cgImage:))
    }
}

/// The exported image: every frame on a dark sheet, numbered like a darkroom proof.
struct ContactSheetView: View {
    let frames: [UIImage]
    let size: Int
    let date: Date
    private let columns = 6
    private let width: CGFloat = 900
    private var cell: CGFloat { (width - 48 - CGFloat(columns - 1) * 6) / CGFloat(columns) }

    var body: some View {
        let rows = Int(ceil(Double(max(size, frames.count, 1)) / Double(columns)))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("!CAMERA").fontWeight(.black)
                Spacer()
                Text("ROLL OF \(size) · \(date.formatted(.dateTime.day().month(.abbreviated).year()).uppercased())")
            }
            .font(.system(size: 17, weight: .heavy, design: .monospaced)).foregroundStyle(sheetOrange)
            VStack(spacing: 6) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 6) {
                        ForEach(0..<columns, id: \.self) { c in frame(r * columns + c) }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: width)
        .background(sheetInk)
    }

    private func frame(_ i: Int) -> some View {
        // Fixed-size cell first, picture clipped inside it, label on the cell (not on the oversized fill image).
        Color.clear
            .frame(width: cell, height: cell)
            .overlay {
                if i < frames.count { Image(uiImage: frames[i]).resizable().scaledToFill() } else { Color.white.opacity(0.06) }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if i < max(size, frames.count) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundStyle(sheetOrange)
                        .padding(.horizontal, 4).padding(.vertical, 2).background(.black.opacity(0.55)).padding(3)
                }
            }
    }
}

/// Shown when a roll is developed: frames come up one by one out of the dark, then the contact sheet can be shared.
struct DevelopedRollView: View {
    let roll: DevelopedRoll
    @Environment(\.dismiss) private var dismiss
    @State private var revealed = Set<Int>()
    @State private var sheet: UIImage?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ZStack {
                sheetInk.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 4) {
                            Image(systemName: "film.stack.fill").font(.system(size: 30)).foregroundStyle(sheetOrange)
                            Text("Your roll is developed").font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(.white)
                            Text("\(roll.frames.count) \(roll.frames.count == 1 ? "frame" : "frames") · now in your library")
                                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.top, 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                            ForEach(roll.frames.indices, id: \.self) { i in
                                let on = revealed.contains(i)
                                Color.clear.aspectRatio(1, contentMode: .fit)
                                    .overlay(Image(uiImage: roll.frames[i]).resizable().scaledToFill())
                                    .clipped()
                                    .overlay(alignment: .bottomLeading) {
                                        Text("\(i + 1)").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(sheetOrange).padding(3)
                                    }
                                    // the emulsion coming up: dark, grey and soft first, then colour and sharpness
                                    .saturation(on ? 1 : 0).brightness(on ? 0 : -0.75).blur(radius: on ? 0 : 9)
                                    .animation(.easeOut(duration: 0.8), value: on)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom) {
                actions
                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                    .background(sheetInk.opacity(0.94))
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(sheetOrange) } }
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
        .task {
            sheet = renderSheet()
            for i in roll.frames.indices {
                try? await Task.sleep(nanoseconds: 90_000_000)
                revealed.insert(i)
                if i % 3 == 0 { Feedback.tick() }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let sheet {
                ShareLink(item: Image(uiImage: sheet), preview: SharePreview("Contact sheet", image: Image(uiImage: sheet))) {
                    Label("Share contact sheet", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(sheetOrange).controlSize(.large)
                Button {
                    PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: sheet) }) { ok, _ in
                        DispatchQueue.main.async { saved = ok }
                    }
                } label: {
                    Label(saved ? "Saved to Photos" : "Save contact sheet to Photos", systemImage: saved ? "checkmark" : "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.white).controlSize(.large).disabled(saved)
            } else {
                ProgressView().tint(.white)
            }
        }
    }

    @MainActor private func renderSheet() -> UIImage? {
        let r = ImageRenderer(content: ContactSheetView(frames: roll.frames, size: roll.size, date: roll.date))
        r.scale = 3
        return r.uiImage
    }
}
