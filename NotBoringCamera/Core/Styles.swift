import Foundation
import CoreImage
import UIKit

/// A Style is a 3D LUT applied live in the viewfinder and to the saved photo.
/// Non-colour character of a look (lens, light leaks, frames, stamps). Colour lives in the LUT.
struct StyleFX: Hashable {
    enum Frame: Hashable { case none, instant, square, film }
    var vignette: Float = 0      // 0...1 corner darkening
    var bloom: Float = 0         // 0...1 highlight glow / halation
    var soften: Float = 0        // 0...1 lens softness
    var leak: Float = 0          // 0...1 warm light leak from a corner
    var leakCorner = 0           // 0 top-right, 1 top-left, 2 bottom-right, 3 bottom-left
    var fisheye: Float = 0       // 0...1 barrel distortion
    var stamp: String? = nil     // "date" burns an orange date stamp into saved photos
    var frame: Frame = .none     // border composited onto saved photos
}

struct CameraStyle: Identifiable, Hashable {
    let id: String
    let name: String
    let dimension: Int
    let cube: Data          // Float32 RGBA, red fastest (CIColorCube layout)
    var isCustom = false
    var grain: Float = 0
    var fx = StyleFX()

    static func == (l: CameraStyle, r: CameraStyle) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Styles {
    static let dim = 33

    static func build(_ f: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var out = [Float](); out.reserveCapacity(dim * dim * dim * 4)
        let m = Float(dim - 1)
        for b in 0..<dim { for g in 0..<dim { for r in 0..<dim {
            let (R, G, B) = f(Float(r) / m, Float(g) / m, Float(b) / m)
            out += [min(max(R, 0), 1), min(max(G, 0), 1), min(max(B, 0), 1), 1]
        }}}
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    private static func scurve(_ x: Float, _ k: Float) -> Float { let t = x * 2 - 1; return 0.5 + 0.5 * (t * (1 + k) / (1 + k * abs(t))) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static let builtIn: [CameraStyle] = [
        CameraStyle(id: "standard", name: "Standard", dimension: dim, cube: build { ($0, $1, $2) }),
        CameraStyle(id: "cinematic", name: "Cinematic", dimension: dim, cube: build { r, g, b in
            let l = luma(r, g, b)
            let sh = 1 - l, hi = l
            var R = scurve(r, 0.5), G = scurve(g, 0.5), B = scurve(b, 0.5)
            R += 0.07 * hi - 0.05 * sh; G += 0.01 * hi + 0.015 * sh; B += -0.06 * hi + 0.08 * sh
            return (R, G, B)
        }, grain: 0.35),
        CameraStyle(id: "mono-expired", name: "Mono Expired", dimension: dim, cube: build { r, g, b in
            var l = luma(r, g, b); l = scurve(l, 0.15) * 0.86 + 0.09
            return (l * 1.02 + 0.015, l * 0.99 + 0.005, l * 0.93)
        }, grain: 0.7),
        CameraStyle(id: "mono-tokyo", name: "Mono Tokyo", dimension: dim, cube: build { r, g, b in
            let l = scurve(luma(r * 1.1, g, b * 0.8), 1.4)
            return (l * 0.97, l, l * 1.04)
        }, grain: 0.5),
        CameraStyle(id: "deakins", name: "Deakins", dimension: dim, cube: build { r, g, b in
            let l = luma(r, g, b)
            let s: Float = 0.82
            var R = mix(l, r, s), G = mix(l, g, s), B = mix(l, b, s)
            R = scurve(R, 0.2) + 0.02; G = scurve(G, 0.2) + 0.008; B = scurve(B, 0.2) - 0.015
            return (R, G, B)
        }, grain: 0.25),
        CameraStyle(id: "altman", name: "Altman", dimension: dim, cube: build { r, g, b in
            let l = luma(r, g, b)
            let s: Float = 0.7
            var R = mix(l, r, s), G = mix(l, g, s), B = mix(l, b, s)
            R = R * 0.9 + 0.08; G = G * 0.9 + 0.085; B = B * 0.86 + 0.05
            return (R + 0.02 * l, G + 0.03 * l, B)
        }, grain: 0.5),
    ]


    // MARK: Grade helper
    /// Parametric colour grade: saturation, S-curve contrast, black lift (fade), and split tint.
    private static func grade(sat: Float = 1, contrast: Float = 0.2, lift: Float = 0, gain: (Float, Float, Float) = (1, 1, 1),
                              shadow: (Float, Float, Float) = (0, 0, 0), high: (Float, Float, Float) = (0, 0, 0),
                              mono: Bool = false) -> (Float, Float, Float) -> (Float, Float, Float) {
        return { r, g, b in
            var l = luma(r, g, b)
            var R = r, G = g, B = b
            if mono { R = l; G = l; B = l } else { R = mix(l, r, sat); G = mix(l, g, sat); B = mix(l, b, sat) }
            R = scurve(R * gain.0, contrast); G = scurve(G * gain.1, contrast); B = scurve(B * gain.2, contrast)
            l = luma(R, G, B)
            let sh = (1 - l) * (1 - l), hi = l * l
            R = R * (1 - lift) + lift + shadow.0 * sh + high.0 * hi
            G = G * (1 - lift) + lift + shadow.1 * sh + high.1 * hi
            B = B * (1 - lift) + lift + shadow.2 * sh + high.2 * hi
            return (R, G, B)
        }
    }

    private static func look(_ id: String, _ name: String, grain: Float = 0, fx: StyleFX = StyleFX(),
                             _ f: @escaping (Float, Float, Float) -> (Float, Float, Float)) -> CameraStyle {
        CameraStyle(id: id, name: name, dimension: dim, cube: build(f), grain: grain, fx: fx)
    }

    /// Camera-inspired looks, grouped like a retro camera app: digital, 135 film, medium format/slide,
    /// instant, toy, video/camcorder, then creative effects.
    static let retro: [CameraStyle] = [
        // Digital compacts
        look("d-classic", "D Classic", grain: 0.2, fx: StyleFX(vignette: 0.2, bloom: 0.15),
             grade(sat: 1.1, contrast: 0.3, lift: 0.03, gain: (1.04, 1.0, 0.94), shadow: (0, 0.01, 0.03), high: (0.04, 0.02, -0.03))),
        look("ccd", "CCD", grain: 0.15, fx: StyleFX(bloom: 0.35, stamp: "date"),
             grade(sat: 1.25, contrast: 0.35, lift: 0.02, gain: (0.96, 1.03, 1.1), shadow: (0, 0.02, 0.05), high: (0.03, 0.04, 0.02))),
        look("fxn", "FXN", grain: 0.2, fx: StyleFX(vignette: 0.25),
             grade(sat: 0.95, contrast: 0.5, gain: (1.05, 1.0, 0.95), shadow: (-0.02, 0.03, 0.06), high: (0.07, 0.03, -0.06))),
        look("grd", "GRD", grain: 0.45, fx: StyleFX(vignette: 0.15),
             grade(sat: 0.35, contrast: 1.0, gain: (1.02, 1, 0.98), high: (0.02, 0.01, 0))),
        look("compact-flash", "Flash Compact", grain: 0.25, fx: StyleFX(vignette: 0.45, bloom: 0.2),
             grade(sat: 1.15, contrast: 0.7, lift: 0.01, gain: (1.08, 1.02, 0.95), shadow: (0.02, 0, 0.04), high: (0.05, 0.03, 0))),
        // 135 film
        look("135-ne", "135 NE", grain: 0.5, fx: StyleFX(vignette: 0.2, bloom: 0.1),
             grade(sat: 1.05, contrast: 0.35, lift: 0.025, gain: (1.05, 1.0, 0.92), shadow: (0.01, 0.03, 0.02), high: (0.06, 0.03, -0.04))),
        look("135-sr", "135 SR", grain: 0.55, fx: StyleFX(vignette: 0.25),
             grade(sat: 0.85, contrast: 0.45, lift: 0.04, gain: (1.0, 1.02, 0.96), shadow: (0.01, 0.04, 0.03), high: (0.05, 0.02, -0.02))),
        look("gold-200", "Gold 200", grain: 0.5, fx: StyleFX(vignette: 0.15, bloom: 0.15),
             grade(sat: 1.2, contrast: 0.3, lift: 0.02, gain: (1.08, 1.02, 0.88), shadow: (0.03, 0.01, 0), high: (0.08, 0.05, -0.05))),
        look("superia", "Superia", grain: 0.5, fx: StyleFX(vignette: 0.2),
             grade(sat: 1.15, contrast: 0.4, lift: 0.015, gain: (0.97, 1.05, 1.0), shadow: (-0.01, 0.04, 0.04), high: (0.03, 0.05, 0.01))),
        look("portra", "Portra", grain: 0.3, fx: StyleFX(bloom: 0.2),
             grade(sat: 0.88, contrast: 0.12, lift: 0.05, gain: (1.03, 1.0, 0.97), shadow: (0.02, 0.02, 0.03), high: (0.05, 0.03, 0.01))),
        look("ektar", "Ektar", grain: 0.2,
             grade(sat: 1.45, contrast: 0.45, gain: (1.04, 1.0, 0.98), high: (0.03, 0.01, -0.01))),
        look("cinestill", "Tungsten 800", grain: 0.6, fx: StyleFX(vignette: 0.2, bloom: 0.7),
             grade(sat: 1.05, contrast: 0.35, lift: 0.02, gain: (1.0, 0.97, 1.08), shadow: (-0.03, 0.02, 0.08), high: (0.08, -0.01, -0.02))),
        look("fade-90s", "Faded 90s", grain: 0.45, fx: StyleFX(vignette: 0.15),
             grade(sat: 0.75, contrast: 0.15, lift: 0.1, gain: (1.02, 1.0, 1.0), shadow: (0.03, 0.04, 0.05), high: (0.04, 0.02, -0.02))),
        look("disposable", "Disposable", grain: 0.65, fx: StyleFX(vignette: 0.5, bloom: 0.2, leak: 0.35, stamp: "date"),
             grade(sat: 1.15, contrast: 0.65, lift: 0.025, gain: (1.08, 1.03, 0.9), shadow: (0.03, 0.01, 0), high: (0.07, 0.03, -0.04))),
        // Medium format & slide
        look("120-film", "120 Film", grain: 0.3, fx: StyleFX(vignette: 0.1, frame: .film),
             grade(sat: 0.95, contrast: 0.3, lift: 0.02, gain: (1.02, 1.0, 0.97), shadow: (0, 0.02, 0.03), high: (0.04, 0.03, 0))),
        look("slide", "Slide", grain: 0.2, fx: StyleFX(vignette: 0.3),
             grade(sat: 1.5, contrast: 0.75, gain: (1.02, 1.0, 1.02), shadow: (-0.02, 0.0, 0.03), high: (0.02, 0.02, -0.02))),
        look("velvia", "Velvia", grain: 0.15,
             grade(sat: 1.65, contrast: 0.6, gain: (1.03, 1.02, 1.0), shadow: (-0.02, 0, 0.04))),
        look("cross", "Cross Process", grain: 0.4, fx: StyleFX(vignette: 0.25),
             { r, g, b in
                 let R = scurve(r, 1.1) * 1.05 - 0.02
                 let G = scurve(g, 0.5) * 0.98 + 0.03 * r
                 let B = (0.2 + b * 0.55) * (1.1 - 0.3 * r)
                 return (R, G, B)
             }),
        look("cpm35", "CPM35", grain: 0.5, fx: StyleFX(vignette: 0.3, bloom: 0.15),
             { r, g, b in
                 let l = luma(r, g, b)
                 let R = scurve(r, 0.7) * 0.95 + 0.04 * (1 - l)
                 let G = scurve(g, 0.7) * 1.02 + 0.03
                 let B = scurve(b, 0.7) * 0.9 + 0.1 * (1 - l)
                 return (R, G, B)
             }),
        // Instant
        look("inst-c", "Instant C", grain: 0.3, fx: StyleFX(vignette: 0.25, bloom: 0.2, leak: 0.2, frame: .instant),
             grade(sat: 0.9, contrast: 0.3, lift: 0.07, gain: (1.04, 1.02, 0.95), shadow: (0.02, 0.04, 0.05), high: (0.06, 0.03, -0.02))),
        look("inst-sq", "Instant SQ", grain: 0.25, fx: StyleFX(vignette: 0.3, bloom: 0.15, frame: .square),
             grade(sat: 1.0, contrast: 0.4, lift: 0.05, gain: (1.02, 1.03, 1.02), shadow: (0, 0.04, 0.04), high: (0.04, 0.04, 0.03))),
        look("inst-bw", "Instant B&W", grain: 0.4, fx: StyleFX(vignette: 0.3, frame: .instant),
             grade(contrast: 0.45, lift: 0.06, gain: (1.02, 1.0, 0.96), mono: true)),
        // Toy & lo-fi
        look("holga", "Holga", grain: 0.55, fx: StyleFX(vignette: 0.8, bloom: 0.3, soften: 0.45, leak: 0.45),
             grade(sat: 1.2, contrast: 0.55, lift: 0.03, gain: (1.05, 1.0, 0.92), shadow: (0, 0.02, 0.04), high: (0.05, 0.02, -0.03))),
        look("lomo", "Lomo", grain: 0.45, fx: StyleFX(vignette: 0.85),
             grade(sat: 1.45, contrast: 0.85, gain: (1.03, 1.0, 1.02), shadow: (0, 0.01, 0.05))),
        look("half-frame", "Half Frame", grain: 0.55, fx: StyleFX(vignette: 0.3, leak: 0.25, stamp: "date"),
             grade(sat: 0.95, contrast: 0.4, lift: 0.04, gain: (1.04, 1.0, 0.93), shadow: (0.02, 0.02, 0.02), high: (0.05, 0.03, -0.02))),
        look("sunleak", "Sun Leak", grain: 0.35, fx: StyleFX(vignette: 0.2, bloom: 0.3, leak: 0.9),
             grade(sat: 1.1, contrast: 0.25, lift: 0.04, gain: (1.08, 1.0, 0.9), high: (0.07, 0.03, -0.03))),
        // Video / camcorder
        look("vhs", "VHS", grain: 0.75, fx: StyleFX(vignette: 0.25, bloom: 0.35, soften: 0.35, stamp: "date"),
             grade(sat: 0.8, contrast: 0.5, lift: 0.06, gain: (1.0, 0.98, 1.08), shadow: (0.02, 0, 0.06), high: (0.04, 0.0, 0.03))),
        look("dcr", "DCR Cam", grain: 0.4, fx: StyleFX(vignette: 0.15, bloom: 0.25, soften: 0.15, stamp: "date"),
             grade(sat: 1.1, contrast: 0.35, lift: 0.03, gain: (0.98, 1.02, 1.08), shadow: (0, 0.02, 0.05))),
        look("8mm", "8mm", grain: 0.9, fx: StyleFX(vignette: 0.55, bloom: 0.2, soften: 0.3, leak: 0.35),
             grade(sat: 0.85, contrast: 0.4, lift: 0.07, gain: (1.08, 1.0, 0.85), shadow: (0.04, 0.02, 0), high: (0.07, 0.04, -0.04))),
        look("16mm", "16mm", grain: 0.8, fx: StyleFX(vignette: 0.35, bloom: 0.1, soften: 0.1),
             grade(sat: 0.9, contrast: 0.45, lift: 0.04, gain: (1.02, 1.01, 0.96), shadow: (0, 0.03, 0.03), high: (0.04, 0.02, -0.01))),
        // Creative
        look("fisheye", "Fisheye", grain: 0.2, fx: StyleFX(vignette: 0.4, fisheye: 0.8),
             grade(sat: 1.2, contrast: 0.45, gain: (1.02, 1.0, 1.0))),
        look("ir", "Infrared", grain: 0.4, fx: StyleFX(vignette: 0.2, bloom: 0.45),
             { r, g, b in
                 // false-colour IR: foliage goes pale pink/white, sky goes dark blue
                 let l = luma(r, g, b)
                 let R = scurve(0.15 * r + 0.95 * g + 0.1 * b, 0.4)
                 let G = scurve(0.3 * r + 0.55 * g + 0.2 * b, 0.4) * 0.85
                 let B = scurve(0.55 * b + 0.3 * l, 0.5) * 1.05 + 0.05 * r
                 return (R, G, B)
             }),
        look("teal-orange", "Teal & Orange", grain: 0.15, fx: StyleFX(vignette: 0.2),
             grade(sat: 1.1, contrast: 0.5, gain: (1.06, 1.0, 0.94), shadow: (-0.03, 0.04, 0.09), high: (0.1, 0.03, -0.07))),
        look("noir", "Noir", grain: 0.6, fx: StyleFX(vignette: 0.55),
             grade(contrast: 1.6, gain: (1.0, 1.0, 1.0), mono: true)),
        look("tri-x", "Tri-X", grain: 0.85, fx: StyleFX(vignette: 0.25),
             grade(contrast: 0.7, lift: 0.015, gain: (1.05, 1.0, 0.9), mono: true)),
        look("sepia", "Sepia", grain: 0.5, fx: StyleFX(vignette: 0.5, soften: 0.1),
             grade(contrast: 0.3, lift: 0.04, gain: (1.12, 1.0, 0.78), shadow: (0.03, 0.01, -0.01), mono: true)),
        look("dreamy", "Dreamy", grain: 0.15, fx: StyleFX(bloom: 1.0, soften: 0.5),
             grade(sat: 0.9, contrast: 0.1, lift: 0.07, gain: (1.04, 1.0, 1.04), shadow: (0.03, 0.01, 0.04), high: (0.05, 0.03, 0.04))),
        look("neon-night", "Neon Night", grain: 0.3, fx: StyleFX(vignette: 0.3, bloom: 0.8),
             grade(sat: 1.4, contrast: 0.7, gain: (1.04, 0.94, 1.12), shadow: (0.02, -0.01, 0.1), high: (0.1, -0.02, 0.06))),
    ]

    static let all: [CameraStyle] = builtIn + retro

    static func apply(_ style: CameraStyle, to image: CIImage, strength: Float = 1) -> CIImage {
        guard style.id != "standard" else { return image }
        let f = CIFilter(name: "CIColorCubeWithColorSpace")!
        f.setValue(style.dimension, forKey: "inputCubeDimension")
        f.setValue(style.cube, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.displayP3), forKey: "inputColorSpace")
        f.setValue(image, forKey: kCIInputImageKey)
        guard var out = f.outputImage else { return image }
        out = applyFX(style.fx, to: out)
        if strength < 0.999 {
            out = out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputImageKey: image, kCIInputTimeKey: strength])
        }
        return out
    }

    // MARK: Look effects (cheap enough for the live viewfinder)
    static func applyFX(_ fx: StyleFX, to image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 1, e.height > 1 else { return image }
        var out = image
        if fx.fisheye > 0 {
            let r = min(e.width, e.height) * 0.75
            out = out.applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: CIVector(x: e.midX, y: e.midY), kCIInputRadiusKey: r, kCIInputScaleKey: 0.55 * fx.fisheye])
                .cropped(to: e)
        }
        if fx.soften > 0 {
            let blur = out.clampedToExtent().applyingGaussianBlur(sigma: Double(min(e.width, e.height)) * 0.004 * Double(fx.soften) * 2).cropped(to: e)
            out = blur.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputTimeKey: 0.5 + 0.5 * (1 - fx.soften)])
        }
        if fx.bloom > 0 {
            out = out.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: min(e.width, e.height) * 0.012, kCIInputIntensityKey: 0.5 * fx.bloom]).cropped(to: e)
        }
        if fx.leak > 0 {
            let reach = max(e.width, e.height) * 0.7
            let left = fx.leakCorner == 1 || fx.leakCorner == 3
            let top = fx.leakCorner < 2
            let c = CIVector(x: left ? e.minX : e.maxX, y: top ? e.maxY * 0.85 + e.minY * 0.15 : e.minY * 0.85 + e.maxY * 0.15)
            let glow = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": 0, "inputRadius1": reach,
                "inputColor0": CIColor(red: 1, green: 0.38, blue: 0.1, alpha: CGFloat(0.75 * fx.leak)),
                "inputColor1": CIColor(red: 1, green: 0.2, blue: 0.05, alpha: 0)])!.outputImage!.cropped(to: e)
            out = glow.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: out]).cropped(to: e)
        }
        if fx.vignette > 0 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.6 * fx.vignette, kCIInputRadiusKey: 1.6])
        }
        return out
    }

    // MARK: Saved-photo-only decoration (frames, date stamp)
    static func decorate(_ fx: StyleFX, _ image: CIImage) -> CIImage {
        var out = image
        let e = image.extent
        if fx.stamp != nil {
            let f = DateFormatter(); f.dateFormat = "yy  M  d"
            let text = "'" + f.string(from: Date())
            let size = e.size
            let fontSize = min(size.width, size.height) * 0.04
            let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
            let img = r.image { _ in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.92),
                    .shadow: { let s = NSShadow(); s.shadowColor = UIColor(red: 1, green: 0.3, blue: 0, alpha: 0.7); s.shadowBlurRadius = fontSize * 0.25; return s }()]
                let ts = (text as NSString).size(withAttributes: attrs)
                (text as NSString).draw(at: CGPoint(x: size.width - ts.width - size.width * 0.05, y: size.height - ts.height - size.height * 0.05), withAttributes: attrs)
            }
            if let ci = CIImage(image: img) {
                out = ci.transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY)).composited(over: out)
            }
        }
        switch fx.frame {
        case .none: break
        case .instant, .square, .film:
            let m = min(e.width, e.height)
            let side = m * (fx.frame == .film ? 0.035 : 0.07)
            let bottom = m * (fx.frame == .instant ? 0.24 : fx.frame == .film ? 0.035 : 0.07)
            let top = side
            let canvas = CGRect(x: e.minX - side, y: e.minY - bottom, width: e.width + side * 2, height: e.height + top + bottom)
            let color = fx.frame == .film ? CIColor(red: 0.05, green: 0.05, blue: 0.05) : CIColor(red: 0.96, green: 0.94, blue: 0.89)
            out = out.composited(over: CIImage(color: color).cropped(to: canvas))
            out = out.transformed(by: CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY))
        }
        return out
    }

    static func addGrain(_ amount: Float, to image: CIImage) -> CIImage {
        guard amount > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33 * CGFloat(amount) * 0.5, y: 0.33 * CGFloat(amount) * 0.5, z: 0.33 * CGFloat(amount) * 0.5, w: 0),
                "inputGVector": CIVector(x: 0.33 * CGFloat(amount) * 0.5, y: 0.33 * CGFloat(amount) * 0.5, z: 0.33 * CGFloat(amount) * 0.5, w: 0),
                "inputBVector": CIVector(x: 0.33 * CGFloat(amount) * 0.5, y: 0.33 * CGFloat(amount) * 0.5, z: 0.33 * CGFloat(amount) * 0.5, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(amount) * 0.5)])
            .cropped(to: image.extent)
        return grain.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    }

    /// A small colourful scene (sky, sun, hills, barn, pond, skin-tone) so each look is previewed on real content.
    private static let scene: CIImage = {
        // Real sample photo (CC0, Wikimedia Commons: "Elm Street, Over-the-Rhine, Cincinnati, OH") if bundled.
        if let url = Bundle.main.url(forResource: "filter-sample", withExtension: "jpg"), let ci = CIImage(contentsOf: url) { return ci }
        let n: CGFloat = 160
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: f).image { ctx in
            let c = ctx.cgContext
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { c.setFillColor(red: r, green: g, blue: b, alpha: 1) }
            let sky = CGGradient(colorsSpace: cs, colors: [UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1).cgColor, UIColor(red: 1, green: 0.84, blue: 0.62, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: n * 0.62), options: [])
            fill(1, 0.93, 0.5); c.fillEllipse(in: CGRect(x: n * 0.68, y: n * 0.14, width: n * 0.2, height: n * 0.2))
            fill(0.42, 0.40, 0.58)
            c.move(to: CGPoint(x: 0, y: n * 0.65)); c.addLine(to: CGPoint(x: n * 0.3, y: n * 0.36)); c.addLine(to: CGPoint(x: n * 0.55, y: n * 0.65)); c.fillPath()
            c.move(to: CGPoint(x: n * 0.35, y: n * 0.65)); c.addLine(to: CGPoint(x: n * 0.72, y: n * 0.4)); c.addLine(to: CGPoint(x: n, y: n * 0.65)); c.fillPath()
            fill(0.25, 0.62, 0.28); c.fillEllipse(in: CGRect(x: -n * 0.2, y: n * 0.55, width: n * 1.1, height: n * 0.7))
            fill(0.15, 0.45, 0.2); c.fillEllipse(in: CGRect(x: n * 0.3, y: n * 0.68, width: n * 1.1, height: n * 0.7))
            fill(0.15, 0.45, 0.85); c.fillEllipse(in: CGRect(x: n * 0.05, y: n * 0.84, width: n * 0.5, height: n * 0.14))
            fill(0.78, 0.18, 0.15); c.fill(CGRect(x: n * 0.58, y: n * 0.58, width: n * 0.26, height: n * 0.2))
            fill(0.35, 0.12, 0.1)
            c.move(to: CGPoint(x: n * 0.55, y: n * 0.58)); c.addLine(to: CGPoint(x: n * 0.71, y: n * 0.47)); c.addLine(to: CGPoint(x: n * 0.87, y: n * 0.58)); c.fillPath()
            fill(0.97, 0.95, 0.9); c.fill(CGRect(x: n * 0.67, y: n * 0.66, width: n * 0.07, height: n * 0.12))
            fill(0.93, 0.7, 0.55); c.fillEllipse(in: CGRect(x: n * 0.16, y: n * 0.7, width: n * 0.14, height: n * 0.14))
            fill(0.95, 0.85, 0.2); c.fill(CGRect(x: n * 0.13, y: n * 0.82, width: n * 0.2, height: n * 0.12))
        }
        return CIImage(image: img)!
    }()

    /// SF Symbol badge that identifies each look in the picker.
    static func symbol(for id: String) -> String {
        switch id {
        case "standard": return "camera"
        case "cinematic", "fxn", "teal-orange": return "film"
        case "mono-expired", "mono-tokyo", "noir", "tri-x", "grd", "inst-bw": return "circle.lefthalf.filled"
        case "deakins", "altman": return "movieclapper"
        case "d-classic", "compact-flash": return "camera.fill"
        case "ccd": return "calendar"
        case "135-ne", "135-sr", "120-film": return "film.stack"
        case "gold-200", "sunleak": return "sun.max.fill"
        case "superia", "ektar", "velvia": return "leaf.fill"
        case "portra": return "person.fill"
        case "cinestill", "neon-night": return "moon.stars.fill"
        case "fade-90s": return "clock.arrow.circlepath"
        case "disposable": return "bolt.fill"
        case "slide": return "rectangle.on.rectangle"
        case "cross", "cpm35": return "arrow.triangle.2.circlepath"
        case "inst-c", "inst-sq": return "photo.on.rectangle"
        case "holga", "lomo": return "circle.dashed"
        case "half-frame": return "rectangle.split.2x1"
        case "vhs", "dcr", "8mm", "16mm": return "video.fill"
        case "fisheye": return "eye.fill"
        case "ir": return "thermometer.sun.fill"
        case "sepia": return "cup.and.saucer.fill"
        case "dreamy": return "cloud.fill"
        default: return "paintpalette.fill"
        }
    }

    // MARK: Swatches (the look applied to a sample scene, for the picker)
    private static var swatchCache: [String: UIImage] = [:]
    private static let swatchContext = CIContext()

    static func swatch(for style: CameraStyle) -> UIImage? {
        if let c = swatchCache[style.id] { return c }
        var out = apply(style, to: scene).cropped(to: scene.extent)
        out = addGrain(style.grain * 0.5, to: out)
        out = decorate(style.fx, out)
        // frames (Instant etc.) make the image non-square: fit it inside a square tile
        let e = out.extent, side = scene.extent.width
        let k = side / max(e.width, e.height)
        out = out.transformed(by: CGAffineTransform(scaleX: k, y: k))
        let fitted = out.extent
        out = out.transformed(by: CGAffineTransform(translationX: (side - fitted.width) / 2 - fitted.minX, y: (side - fitted.height) / 2 - fitted.minY))
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        out = out.composited(over: CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.11)).cropped(to: tile))
        guard let cg = swatchContext.createCGImage(out, from: tile) else { return nil }
        let img = UIImage(cgImage: cg)
        swatchCache[style.id] = img
        return img
    }

    // MARK: .cube import
    enum CubeError: Error { case invalid }

    static func parseCube(_ text: String, id: String, name: String) throws -> CameraStyle {
        var size = 0
        var values = [Float]()
        var domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if line.hasPrefix("LUT_3D_SIZE") { size = Int(parts.last ?? "") ?? 0; continue }
            if line.hasPrefix("LUT_1D_SIZE") { throw CubeError.invalid }
            if line.hasPrefix("DOMAIN_MIN") { domainMin = parts.dropFirst().compactMap { Float($0) }; continue }
            if line.hasPrefix("DOMAIN_MAX") { domainMax = parts.dropFirst().compactMap { Float($0) }; continue }
            if line.hasPrefix("LUT_") { continue }
            let nums = parts.compactMap { Float($0) }
            guard nums.count == 3 else { continue }
            for c in 0..<3 {
                let span = max(domainMax[c] - domainMin[c], 1e-6)
                values.append((nums[c] - domainMin[c]) / span)
            }
            values.append(1)
        }
        guard size >= 2, values.count == size * size * size * 4 else { throw CubeError.invalid }
        return CameraStyle(id: id, name: name, dimension: size,
                           cube: values.withUnsafeBufferPointer { Data(buffer: $0) }, isCustom: true)
    }

    static var lutDirectory: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("LUTs")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func loadCustom() -> [CameraStyle] {
        let files = (try? FileManager.default.contentsOfDirectory(at: lutDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }.compactMap {
            guard let t = try? String(contentsOf: $0, encoding: .utf8) else { return nil }
            let name = $0.deletingPathExtension().lastPathComponent
            return try? parseCube(t, id: "custom-" + name, name: name)
        }
    }

    static func importCube(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: url, encoding: .utf8)
        _ = try parseCube(text, id: "tmp", name: "tmp")   // validate
        try text.write(to: lutDirectory.appendingPathComponent(url.lastPathComponent), atomically: true, encoding: .utf8)
    }
}
