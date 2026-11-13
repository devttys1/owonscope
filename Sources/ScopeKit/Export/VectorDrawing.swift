import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A tiny resolution-independent drawing model with SVG and Core Graphics (PDF / PNG)
// back ends. Coordinates are in points, origin top-left, y down (as in SVG).

public struct VColor: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double(hex >> 16 & 0xff) / 255, Double(hex >> 8 & 0xff) / 255, Double(hex & 0xff) / 255, alpha)
    }
    public func opacity(_ a: Double) -> VColor { VColor(r, g, b, self.a * a) }

    var svg: String { String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5)) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public struct VFont: Equatable, Sendable {
    public var size: CGFloat
    public var bold = false
    public var mono = false
    public init(_ size: CGFloat, bold: Bool = false, mono: Bool = false) { self.size = size; self.bold = bold; self.mono = mono }

    var ctFont: CTFont {
        if mono {
            return CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return b }
        return base
    }

    var svgFamily: String {
        mono ? "'SF Mono', Menlo, Consolas, monospace" : "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
    }
}

public enum VAnchor: Sendable { case start, middle, end }

public indirect enum VItem: Sendable {
    case path([CGPoint], closed: Bool, stroke: VColor?, fill: VColor?, width: CGFloat, dash: [CGFloat]?)
    case rect(CGRect, stroke: VColor?, fill: VColor?, width: CGFloat, radius: CGFloat)
    /// `at` is the text baseline position.
    case text(String, at: CGPoint, font: VFont, color: VColor, anchor: VAnchor)
    case group(clip: CGRect?, items: [VItem])
}

public struct VDrawing: Sendable {
    public var size: CGSize
    public var background: VColor
    public var items: [VItem] = []
    public var title = "OwonScope"

    public init(size: CGSize, background: VColor) {
        self.size = size
        self.background = background
    }

    // convenience builders
    public mutating func line(_ a: CGPoint, _ b: CGPoint, _ c: VColor, width: CGFloat = 1, dash: [CGFloat]? = nil) {
        items.append(.path([a, b], closed: false, stroke: c, fill: nil, width: width, dash: dash))
    }
    public mutating func text(_ s: String, _ p: CGPoint, _ f: VFont, _ c: VColor, _ anchor: VAnchor = .start) {
        items.append(.text(s, at: p, font: f, color: c, anchor: anchor))
    }
}

/// Text measurement shared by layout and both back ends.
public enum VText {
    public static func width(_ s: String, _ font: VFont) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font.ctFont])
        let line = CTLineCreateWithAttributedString(attr)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - SVG

public enum SVGWriter {
    public static func render(_ d: VDrawing) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(d.size.width))" height="\(n(d.size.height))" viewBox="0 0 \(n(d.size.width)) \(n(d.size.height))">
        <title>\(escape(d.title))</title>
        <rect width="100%" height="100%" fill="\(d.background.svg)"/>

        """
        var clipID = 0
        func emit(_ items: [VItem], indent: String) {
            for item in items {
                switch item {
                case let .path(pts, closed, stroke, fill, width, dash):
                    guard pts.count > 1 else { continue }
                    let tag = closed ? "polygon" : "polyline"
                    var attrs = "points=\"\(pts.map { "\(n($0.x)),\(n($0.y))" }.joined(separator: " "))\""
                    attrs += paint(stroke: stroke, fill: fill, width: width)
                    if let dash { attrs += " stroke-dasharray=\"\(dash.map(n).joined(separator: ","))\"" }
                    attrs += " stroke-linejoin=\"round\" stroke-linecap=\"round\""
                    out += "\(indent)<\(tag) \(attrs)/>\n"
                case let .rect(r, stroke, fill, width, radius):
                    var attrs = "x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\""
                    if radius > 0 { attrs += " rx=\"\(n(radius))\"" }
                    attrs += paint(stroke: stroke, fill: fill, width: width)
                    out += "\(indent)<rect \(attrs)/>\n"
                case let .text(s, p, font, color, anchor):
                    let a = anchor == .start ? "start" : anchor == .middle ? "middle" : "end"
                    var attrs = "x=\"\(n(p.x))\" y=\"\(n(p.y))\" font-family=\"\(font.svgFamily)\" font-size=\"\(n(font.size))\""
                    if font.bold { attrs += " font-weight=\"bold\"" }
                    attrs += " fill=\"\(color.svg)\""
                    if color.a < 1 { attrs += " fill-opacity=\"\(n(color.a))\"" }
                    attrs += " text-anchor=\"\(a)\""
                    out += "\(indent)<text \(attrs)>\(escape(s))</text>\n"
                case let .group(clip, items):
                    if let clip {
                        clipID += 1
                        out += "\(indent)<clipPath id=\"c\(clipID)\"><rect x=\"\(n(clip.minX))\" y=\"\(n(clip.minY))\" width=\"\(n(clip.width))\" height=\"\(n(clip.height))\"/></clipPath>\n"
                        out += "\(indent)<g clip-path=\"url(#c\(clipID))\">\n"
                    } else {
                        out += "\(indent)<g>\n"
                    }
                    emit(items, indent: indent + "  ")
                    out += "\(indent)</g>\n"
                }
            }
        }
        emit(d.items, indent: "")
        out += "</svg>\n"
        return out
    }

    private static func paint(stroke: VColor?, fill: VColor?, width: CGFloat) -> String {
        var s = ""
        if let fill {
            s += " fill=\"\(fill.svg)\""
            if fill.a < 1 { s += " fill-opacity=\"\(n(fill.a))\"" }
        } else {
            s += " fill=\"none\""
        }
        if let stroke {
            s += " stroke=\"\(stroke.svg)\" stroke-width=\"\(n(width))\""
            if stroke.a < 1 { s += " stroke-opacity=\"\(n(stroke.a))\"" }
        }
        return s
    }

    /// Compact number formatting (max 2 decimals).
    static func n(_ v: CGFloat) -> String {
        let r = (Double(v) * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%g", r)
    }

    static func n(_ v: Double) -> String { n(CGFloat(v)) }

    public static func escape(_ s: String) -> String {
        var o = ""
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&apos;"
            default: o.append(c)
            }
        }
        return o
    }
}

// MARK: - Core Graphics (PDF, PNG)

public enum CGVectorRenderer {
    /// Draws into a context whose origin is top-left (callers flip if needed).
    public static func draw(_ d: VDrawing, in ctx: CGContext) {
        ctx.setFillColor(d.background.cg)
        ctx.fill(CGRect(origin: .zero, size: d.size))
        draw(d.items, in: ctx)
    }

    private static func draw(_ items: [VItem], in ctx: CGContext) {
        for item in items {
            switch item {
            case let .path(pts, closed, stroke, fill, width, dash):
                guard pts.count > 1 else { continue }
                let p = CGMutablePath()
                p.addLines(between: pts)
                if closed { p.closeSubpath() }
                if let fill {
                    ctx.addPath(p)
                    ctx.setFillColor(fill.cg)
                    ctx.fillPath()
                }
                if let stroke {
                    ctx.addPath(p)
                    ctx.setStrokeColor(stroke.cg)
                    ctx.setLineWidth(width)
                    ctx.setLineJoin(.round)
                    ctx.setLineCap(.round)
                    ctx.setLineDash(phase: 0, lengths: dash ?? [])
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            case let .rect(r, stroke, fill, width, radius):
                let p = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
                if let fill { ctx.addPath(p); ctx.setFillColor(fill.cg); ctx.fillPath() }
                if let stroke { ctx.addPath(p); ctx.setStrokeColor(stroke.cg); ctx.setLineWidth(width); ctx.strokePath() }
            case let .text(s, at, font, color, anchor):
                let attr = NSAttributedString(string: s, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font.ctFont,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: color.cg,
                ])
                let line = CTLineCreateWithAttributedString(attr)
                let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let x = anchor == .start ? at.x : anchor == .middle ? at.x - w / 2 : at.x - w
                ctx.saveGState()
                // the context is flipped (y down): flip text back upright
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: x, y: at.y)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            case let .group(clip, items):
                ctx.saveGState()
                if let clip { ctx.clip(to: clip) }
                draw(items, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    public static func pdf(_ d: VDrawing) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: d.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: d.title,
                                                                       kCGPDFContextCreator as String: "OwonScope"] as CFDictionary)
        else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: d.size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(d, in: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    public static func png(_ d: VDrawing, scale: CGFloat = 2) -> Data? {
        let w = Int(d.size.width * scale), h = Int(d.size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(d, in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

/// Reduces a dense polyline to at most two points (min and max, in time order) per bucket.
public enum Decimator {
    public static func minMax(_ pts: [CGPoint], buckets: Int, xRange: ClosedRange<CGFloat>) -> [CGPoint] {
        guard pts.count > buckets * 2, buckets > 0 else { return pts }
        let span = max(xRange.upperBound - xRange.lowerBound, 1e-9)
        var out: [CGPoint] = []
        out.reserveCapacity(buckets * 2)
        var current = -1
        var lo = CGPoint.zero, hi = CGPoint.zero, loI = 0, hiI = 0
        func flush() {
            guard current >= 0 else { return }
            if loI == hiI { out.append(lo) } else if loI < hiI { out.append(lo); out.append(hi) } else { out.append(hi); out.append(lo) }
        }
        for (i, p) in pts.enumerated() {
            let b = min(buckets - 1, max(0, Int((p.x - xRange.lowerBound) / span * CGFloat(buckets))))
            if b != current {
                flush()
                current = b
                lo = p; hi = p; loI = i; hiI = i
            } else {
                // y down: "min" here is the visually lowest value (largest y)
                if p.y > lo.y { lo = p; loI = i }
                if p.y < hi.y { hi = p; hiI = i }
            }
        }
        flush()
        return out
    }
}
