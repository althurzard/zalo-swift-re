import AppKit
import SwiftUI

/// User-visible product name. The package, bundle id and log subsystem still say Olaz until the rename.
enum AppBrand {
    static let name = "Olaz"
}

/// `@AppStorage` keys of the Olaz appearance and first-run settings.
enum OlazPrefs {
    /// `OlazAccent.rawValue`.
    static let accent = "olaz.accent"
    /// `OlazTextSize.rawValue`.
    static let textSize = "olaz.textSize"
    /// `ChatWallpaper.rawValue`.
    static let wallpaper = "olaz.wallpaper"
    /// `OlazAppIcon.rawValue`.
    static let appIcon = "olaz.appIcon"
    /// Video player volume, 0...1 (shared by the chat viewer and the zCloud preview; default 1).
    static let videoVolume = "olaz.video.volume"
    /// Video player muted (kept apart from the volume so unmuting restores the level).
    static let videoMuted = "olaz.video.muted"
    /// Set once the first-run setup (sign-in → phone sync → tour offer) was completed or skipped.
    static let didFinishSetup = "olaz.didFinishSetup"
    /// A fresh QR sign-in happened and the setup's sync / welcome steps are still due (survives a relaunch).
    static let setupPending = "olaz.setupPending"
}

/// Accent color picked in Settings ▸ Giao diện; applied with `.tint` at the window root, so views use `.tint` /
/// `TintShapeStyle` rather than a fixed blue.
enum OlazAccent: String, CaseIterable, Identifiable {
    case blue, teal, indigo, pink, orange, green, graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: ZaloTheme.blue
        case .teal: Color(red: 0.0, green: 0.62, blue: 0.70)
        case .indigo: Color(red: 0.36, green: 0.34, blue: 0.84)
        case .pink: Color(red: 0.93, green: 0.25, blue: 0.48)
        case .orange: Color(red: 0.96, green: 0.50, blue: 0.10)
        case .green: Color(red: 0.16, green: 0.66, blue: 0.33)
        case .graphite: Color(red: 0.43, green: 0.45, blue: 0.49)
        }
    }

    var title: String {
        switch self {
        case .blue: "Xanh dương"
        case .teal: "Xanh ngọc"
        case .indigo: "Chàm"
        case .pink: "Hồng"
        case .orange: "Cam"
        case .green: "Xanh lá"
        case .graphite: "Than chì"
        }
    }
}

/// Chat text size (Settings ▸ Giao diện); a multiplier for message text, not for the window chrome.
enum OlazTextSize: String, CaseIterable, Identifiable {
    case small, standard, large, extraLarge

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small: 0.92
        case .standard: 1
        case .large: 1.12
        case .extraLarge: 1.26
        }
    }

    var title: String {
        switch self {
        case .small: "Nhỏ"
        case .standard: "Vừa"
        case .large: "Lớn"
        case .extraLarge: "Rất lớn"
        }
    }
}

/// Chat background (Settings ▸ Giao diện). Images ship in `Resources/Olaz/wallpaper-<name>.jpg`.
enum ChatWallpaper: String, CaseIterable, Identifiable {
    case none, mist, silk, lotus, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Không"
        case .mist: "Sương"
        case .silk: "Lụa"
        case .lotus: "Sen"
        case .night: "Đêm"
        }
    }

    @MainActor var image: NSImage? {
        self == .none ? nil : OlazAssets.image("wallpaper-\(rawValue).jpg")
    }
}

/// Alternate Dock icons (Settings ▸ Giao diện). `c` is the primary icon baked into the bundle's icns.
enum OlazAppIcon: String, CaseIterable, Identifiable {
    case c, a, b

    var id: String { rawValue }

    var title: String {
        switch self {
        case .c: "Bong bóng"
        case .a: "Cổ điển"
        case .b: "Tối giản"
        }
    }

    @MainActor var image: NSImage? { OlazAssets.image("AppIcon-\(rawValue).png") }
}

/// Images in `Resources/Olaz` (copied into the SwiftPM resource bundle), cached by name.
@MainActor
enum OlazAssets {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = ResourceLocator.url(for: "Olaz/\(name)", in: "Resources"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

/// Message text scale from Settings ▸ Giao diện ▸ Cỡ chữ.
extension EnvironmentValues {
    @Entry var olazTextScale: CGFloat = 1
}

/// Renders an SF Symbol into a square template `NSImage` whose drawn pixel bounding box (plus optical center adjustment
/// for circular arrows, play triangles, and directional chevrons) sits at the exact center `(box / 2, box / 2)`, eliminating
/// AppKit/SwiftUI `alignmentRect` baseline shifts and integer-point snapping inside circular buttons.
struct CenteredSymbol: View {
    let symbol: String
    var size: CGFloat = 13
    var weight: NSFont.Weight = .semibold
    var box: CGFloat = 20

    init(_ symbol: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold, box: CGFloat = 20) {
        self.symbol = symbol
        self.size = size
        self.weight = weight
        self.box = box
    }

    var body: some View {
        if let nsImage = Self.image(symbol: symbol, pointSize: size, weight: weight, box: box) {
            Image(nsImage: nsImage)
                .frame(width: box, height: box)
                .contentTransition(.symbolEffect(.replace))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: swiftUIWeight))
                .frame(width: box, height: box)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private var swiftUIWeight: Font.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .semibold
        }
    }

    private struct CacheKey: Hashable {
        let symbol: String
        let pointSizeTenths: Int
        let weightRaw: CGFloat
        let boxTenths: Int
    }

    @MainActor private static var cache: [CacheKey: NSImage] = [:]

    /// Optical shift in screen points (positive x = right, positive y = down) relative to the drawn pixel bounding box center.
    static func opticalOffset(for symbol: String, pointSize: CGFloat) -> CGPoint {
        let s = pointSize / 13.0
        return switch symbol {
        case "gobackward.5", "goforward.5", "gobackward.10", "goforward.10", "gobackward.15", "goforward.15":
            // Top arrowhead at 12 o'clock protrudes above the circular ring; shifting up centers the ring and digit.
            CGPoint(x: 0, y: -0.65 * s)
        case "arrow.counterclockwise", "arrow.clockwise":
            CGPoint(x: 0, y: -0.65 * s)
        case "play.fill":
            // Right-pointing triangle centroid sits at 1/3 width from left edge; shift right so centroid aligns with center.
            CGPoint(x: 0.85 * s, y: 0)
        case "chevron.left":
            CGPoint(x: -0.4 * s, y: 0)
        case "chevron.right":
            CGPoint(x: 0.4 * s, y: 0)
        case "chevron.down":
            CGPoint(x: 0, y: 0.3 * s)
        case "chevron.up":
            CGPoint(x: 0, y: -0.3 * s)
        default:
            .zero
        }
    }

    @MainActor static func image(symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .semibold, box: CGFloat = 20) -> NSImage? {
        let key = CacheKey(symbol: symbol, pointSizeTenths: Int((pointSize * 10).rounded()),
                           weightRaw: weight.rawValue, boxTenths: Int((box * 10).rounded()))
        if let cached = cache[key] { return cached }

        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let raw = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
            return nil
        }

        let scale: CGFloat = 2.0
        let pxSize = max(Int((box * scale).rounded()), 16)
        let scratchPx = max(pxSize * 2, 96)

        guard let scratch = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: scratchPx, pixelsHigh: scratchPx,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: scratchPx * 4, bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: scratch) else { return nil }

        let rawSize = raw.size
        let baseOrigin = NSPoint(x: (CGFloat(scratchPx) / scale - rawSize.width) / 2.0,
                                 y: (CGFloat(scratchPx) / scale - rawSize.height) / 2.0)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        raw.draw(in: NSRect(origin: baseOrigin, size: rawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let ptr = scratch.bitmapData else { return nil }
        let bpr = scratch.bytesPerRow
        var minX = scratchPx, maxX = 0, minY = scratchPx, maxY = 0
        for y in 0..<scratchPx {
            for x in 0..<scratchPx {
                if ptr[y * bpr + x * 4 + 3] > 38 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX <= maxX && minY <= maxY else { return raw }

        let bboxCenterPtX = CGFloat(minX + maxX + 1) / 2.0 / scale
        let bboxCenterFromTopPtY = CGFloat(minY + maxY + 1) / 2.0 / scale
        let bboxCenterFromBottomPtY = CGFloat(scratchPx) / scale - bboxCenterFromTopPtY

        let optical = opticalOffset(for: symbol, pointSize: pointSize)
        let targetCenterPtX = box / 2.0 + optical.x
        let targetCenterFromBottomPtY = box / 2.0 - optical.y
        let finalOrigin = NSPoint(
            x: baseOrigin.x + (targetCenterPtX - bboxCenterPtX),
            y: baseOrigin.y + (targetCenterFromBottomPtY - bboxCenterFromBottomPtY)
        )

        guard let outRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxSize, pixelsHigh: pxSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pxSize * 4, bitsPerPixel: 32
        ), let outCtx = NSGraphicsContext(bitmapImageRep: outRep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = outCtx
        outCtx.cgContext.scaleBy(x: scale, y: scale)
        raw.draw(in: NSRect(origin: finalOrigin, size: rawSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let outImage = NSImage(size: NSSize(width: box, height: box))
        outImage.addRepresentation(outRep)
        outImage.isTemplate = true
        cache[key] = outImage
        return outImage
    }

    /// Returns the non-transparent pixel margins `(left, right, top, bottom)` of the rendered symbol bitmap for testing.
    @MainActor static func pixelMargins(symbol: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .semibold, box: CGFloat = 28) -> (left: Int, right: Int, top: Int, bottom: Int)? {
        guard let img = image(symbol: symbol, pointSize: pointSize, weight: weight, box: box),
              let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let ptr = rep.bitmapData else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                if ptr[y * bpr + x * 4 + 3] > 38 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX <= maxX && minY <= maxY else { return nil }
        return (left: minX, right: w - 1 - maxX, top: minY, bottom: h - 1 - maxY)
    }
}
