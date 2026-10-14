import Foundation
import CoreImage
import UIKit

/// A Style is a 3D LUT applied live in the viewfinder and to the saved photo.
struct CameraStyle: Identifiable, Hashable {
    let id: String
    let name: String
    let dimension: Int
    let cube: Data          // Float32 RGBA, red fastest (CIColorCube layout)
    var isCustom = false
    var grain: Float = 0

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

    static func apply(_ style: CameraStyle, to image: CIImage, strength: Float = 1) -> CIImage {
        guard style.id != "standard" else { return image }
        let f = CIFilter(name: "CIColorCubeWithColorSpace")!
        f.setValue(style.dimension, forKey: "inputCubeDimension")
        f.setValue(style.cube, forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.displayP3), forKey: "inputColorSpace")
        f.setValue(image, forKey: kCIInputImageKey)
        guard var out = f.outputImage else { return image }
        if strength < 0.999 {
            out = out.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputImageKey: image, kCIInputTimeKey: strength])
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

    // MARK: Swatches (what a style does to colour, for the picker)
    private static var swatchCache: [String: UIImage] = [:]
    private static let swatchContext = CIContext()

    static func swatch(for style: CameraStyle) -> UIImage? {
        if let c = swatchCache[style.id] { return c }
        guard let wheel = CIFilter(name: "CIHueSaturationValueGradient", parameters: ["inputValue": 0.95, "inputRadius": 60, "inputSoftness": 0, "inputDither": 0, "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])?.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: 120, height: 120)) else { return nil }
        // darken towards the bottom so shadows/contrast show too
        let shade = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 120), "inputPoint1": CIVector(x: 0, y: 0), "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1), "inputColor1": CIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)])!.outputImage!.cropped(to: wheel.extent)
        let base = wheel.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade])
        let out = apply(style, to: base)
        guard let cg = swatchContext.createCGImage(out, from: out.extent) else { return nil }
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
