import SwiftUI

enum CapturePipeline: String, CaseIterable, Identifiable {
    case superRaw = "SuperRAW", proRaw = "ProRAW", basic = "Basic"
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .superRaw: return "Our own pipeline from the Bayer RAW. No multi-frame processing. Natural grain, film-like exposure."
        case .proRaw: return "Apple's ProRAW with Apple's processing."
        case .basic: return "Apple's default processing."
        }
    }
}

enum GridStyle: String, CaseIterable, Identifiable {
    case off = "Off", thirds = "3×3", four = "4×4", sixByFour = "6×4", phi = "Phi", golden = "Golden Ratio"
    var id: String { rawValue }
}

enum AspectOption: String, CaseIterable, Identifiable {
    case fourThree = "4:3", threeTwo = "3:2", sixteenNine = "16:9", square = "1:1"
    var id: String { rawValue }
    /// width / height in portrait
    var ratio: CGFloat {
        switch self { case .fourThree: return 3.0 / 4; case .threeTwo: return 2.0 / 3; case .sixteenNine: return 9.0 / 16; case .square: return 1 }
    }
}

enum StampOption: String, CaseIterable, Identifiable { case style = "Per Style", off = "Off", on = "On"; var id: String { rawValue } }
enum LeakOption: String, CaseIterable, Identifiable { case style = "Per Style", off = "Off", random = "Random"; var id: String { rawValue } }

enum FlashSetting: String, CaseIterable { case off, auto, on }

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("pipeline") var pipeline: CapturePipeline = .superRaw
    @AppStorage("aspect") var aspect: AspectOption = .fourThree
    @AppStorage("grid") var grid: GridStyle = .off
    @AppStorage("photoReview") var photoReviewSeconds = 0
    @AppStorage("rememberSettings") var rememberSettings = true
    @AppStorage("keepAwake") var keepAwake = false
    @AppStorage("sounds") var sounds = true
    @AppStorage("haptics") var haptics = true
    @AppStorage("saveToAlbum") var saveToAlbum = true
    @AppStorage("mirrorSelfies") var mirrorSelfies = true
    @AppStorage("hdr") var hdr = false
    @AppStorage("hiRes") var hiRes = false
    @AppStorage("rawPlusHeic") var rawPlusHeic = false
    @AppStorage("peaking") var focusPeaking = false
    @AppStorage("zebra") var zebra = false
    @AppStorage("histogram") var histogram = true
    @AppStorage("dateStamp") var dateStamp: StampOption = .style
    @AppStorage("lightLeaks") var lightLeaks: LeakOption = .style
    @AppStorage("filmRoll") var filmRoll = false
    @AppStorage("rollSize") var rollSize = 24
    @AppStorage("colorway") var colorwayID = "orange"
    @AppStorage("customColorways") private var customColorwaysData = Data()

    // remembered state
    @AppStorage("lastStyle") var lastStyleID = "standard"
    @AppStorage("lastLens") var lastLens = 1.0
    @AppStorage("lastFlash") var lastFlash: FlashSetting = .off
    @AppStorage("lastManual") var lastManual = false
    @AppStorage("lastEV") var lastEV = 0.0
    @AppStorage("onboarded") var onboarded = false

    var customColorways: [Colorway] {
        get { (try? JSONDecoder().decode([Colorway].self, from: customColorwaysData)) ?? [] }
        set { customColorwaysData = (try? JSONEncoder().encode(newValue)) ?? Data(); objectWillChange.send() }
    }
    var colorway: Colorway {
        Colorway.presets.first { $0.id == colorwayID } ?? customColorways.first { $0.id == colorwayID } ?? Colorway.presets[0]
    }
}
