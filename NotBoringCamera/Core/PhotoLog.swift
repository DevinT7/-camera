import Foundation
import Photos

/// The app's own record of the photos it made, so the Photo Book keeps working even if "Save to !Camera album" is off.
struct LoggedPhoto: Codable, Identifiable, Hashable {
    var id: String          // PHAsset local identifier
    var date: Date
}

@MainActor
final class PhotoLog: ObservableObject {
    static let shared = PhotoLog()
    @Published private(set) var items: [LoggedPhoto] = []
    private var backfilled = UserDefaults.standard.bool(forKey: "photoLogBackfilled")

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("photolog.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL), let i = try? JSONDecoder().decode([LoggedPhoto].self, from: d) { items = i }
    }

    func add(id: String, date: Date = Date()) {
        guard !items.contains(where: { $0.id == id }) else { return }
        items.append(LoggedPhoto(id: id, date: date))
        persist()
    }

    /// One-time: photos taken before the log existed live in the "!Camera" album; add them.
    func backfillIfNeeded() {
        guard !backfilled, PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else { return }
        backfilled = true
        UserDefaults.standard.set(true, forKey: "photoLogBackfilled")
        let o = PHFetchOptions(); o.predicate = NSPredicate(format: "title = %@", "!Camera")
        guard let album = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: o).firstObject else { return }
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { a, _, _ in
            if !self.items.contains(where: { $0.id == a.localIdentifier }) {
                self.items.append(LoggedPhoto(id: a.localIdentifier, date: a.creationDate ?? Date()))
            }
        }
        persist()
    }

    /// Logged photos that still exist in the library, newest first.
    func existingAssets() -> [(LoggedPhoto, PHAsset)] {
        guard !items.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: items.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { a, _, _ in byID[a.localIdentifier] = a }
        return items.compactMap { p in byID[p.id].map { (p, $0) } }.sorted { ($0.1.creationDate ?? $0.0.date) > ($1.1.creationDate ?? $1.0.date) }
    }

    private func persist() { try? JSONEncoder().encode(items).write(to: Self.fileURL, options: .atomic) }
}
