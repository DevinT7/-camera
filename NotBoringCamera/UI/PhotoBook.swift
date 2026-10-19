import SwiftUI
import Photos

/// Polaroid-style photo book: every photo taken in the app, newest first, grouped by month.
struct PhotoBookView: View {
    @ObservedObject private var log = PhotoLog.shared
    @State private var entries: [(LoggedPhoto, PHAsset)] = []
    @State private var loaded = false
    @State private var viewing: PHAsset?
    private let tilts: [Double] = [-2.4, 1.6, -1.1, 2.3, -1.8, 1.2, -2.0, 1.9]

    private var months: [(String, [(Int, (LoggedPhoto, PHAsset))])] {
        var order: [String] = []
        var groups: [String: [(Int, (LoggedPhoto, PHAsset))]] = [:]
        for (i, e) in entries.enumerated() {
            let key = (e.1.creationDate ?? e.0.date).formatted(.dateTime.month(.wide).year()).uppercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((i, e))
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack").font(.system(size: 34, weight: .bold)).opacity(0.5)
                    Text(loaded ? "No photos yet" : "Loading…").font(.system(size: 17, weight: .black, design: .rounded))
                    if loaded { Text("Photos you take here show up as Polaroids.").font(.footnote).opacity(0.6) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50)
            } else {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(months, id: \.0) { month, items in
                        Text(month).font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(1.5).opacity(0.55)
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 22) {
                            ForEach(items, id: \.1.0.id) { i, e in
                                PolaroidCard(asset: e.1, fallbackDate: e.0.date, tilt: tilts[i % tilts.count])
                                    .padding(.top, i % 2 == 1 ? 20 : 0)
                                    .onTapGesture { viewing = e.1 }
                            }
                        }
                    }
                }
            }
        }
        .task { await refresh() }
        .onChange(of: log.items.count) { _, _ in Task { await refresh() } }
        .sheet(item: Binding(get: { viewing.map { AssetBox(asset: $0) } }, set: { viewing = $0?.asset })) { PolaroidViewer(asset: $0.asset) }
    }

    private func refresh() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { loaded = true; return }
        log.backfillIfNeeded()
        entries = log.existingAssets()
        loaded = true
    }
}

struct AssetBox: Identifiable { let asset: PHAsset; var id: String { asset.localIdentifier } }

/// White instant-film frame: square picture, thick bottom edge, handwritten date, a slight tilt.
struct PolaroidCard: View {
    let asset: PHAsset
    let fallbackDate: Date
    let tilt: Double
    var size: CGFloat = 520
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            Color(white: 0.88)
                .aspectRatio(1, contentMode: .fit)
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipped()
                .padding(.horizontal, 9).padding(.top, 9)
            Text((asset.creationDate ?? fallbackDate).formatted(.dateTime.month(.abbreviated).day().year()))
                .font(.custom("Noteworthy-Bold", size: 14)).foregroundStyle(.black.opacity(0.68))
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .background(Color(red: 0.99, green: 0.98, blue: 0.955))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        .rotationEffect(.degrees(tilt))
        .onAppear {
            let o = PHImageRequestOptions(); o.deliveryMode = .opportunistic; o.resizeMode = .fast; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: size, height: size), contentMode: .aspectFill, options: o) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}

/// One photo, large, on a straight Polaroid.
struct PolaroidViewer: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(red: 0.13, green: 0.12, blue: 0.11).ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14).padding(.top, 14)
                Text((asset.creationDate ?? Date()).formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.custom("Noteworthy-Bold", size: 18)).foregroundStyle(.black.opacity(0.7)).frame(height: 62)
            }
            .background(Color(red: 0.99, green: 0.98, blue: 0.955))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(18)
            .shadow(radius: 14)
            VStack { HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).tint(.black.opacity(0.5)).padding() }; Spacer() }
        }
        .preferredColorScheme(.dark)
        .task {
            let o = PHImageRequestOptions(); o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600), contentMode: .aspectFit, options: o) { img, _ in
                if let img { DispatchQueue.main.async { image = img } }
            }
        }
    }
}
