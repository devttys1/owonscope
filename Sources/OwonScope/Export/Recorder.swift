import AppKit
import QuartzCore
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Records the window to an animated GIF (automation only - used to make the README demos).
/// Frames come from the same in-process renderer as snapshots, so no Screen Recording
/// permission is needed.
@MainActor
final class GIFRecorder {
    static let shared = GIFRecorder()
    private var timer: Timer?
    private var chrome: CGImage?
    private var frames: [CGImage] = []
    private var times: [CFTimeInterval] = []
    private var width = 960
    private var fps = 10.0
    var caption: String?

    var isRecording: Bool { timer != nil }

    func start(fps: Double, width: Int) {
        NSApp.activate(ignoringOtherApps: true)
        frames = []
        times = []
        chrome = nil
        self.fps = fps
        self.width = width
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
            MainActor.assumeIsolated { GIFRecorder.shared.grab() }
        }
        grab()
    }

    private func grab() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        // title bar and toolbar: rendered once, a few frames in so the window shows as active
        if chrome == nil, frames.count >= 3, let frameView = window.contentView?.superview,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            chrome = rep.cgImage
        }
        guard let full = Snapshot.renderInProcess(window, scale: 1, chrome: chrome) else { return }
        let h = Int(Double(full.height) * Double(width) / Double(full.width))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: width, height: h))
        if let caption, !caption.isEmpty { drawCaption(caption, in: ctx, size: CGSize(width: width, height: h)) }
        if let img = ctx.makeImage() { frames.append(img); times.append(CACurrentMediaTime()) }
    }

    private func drawCaption(_ text: String, in ctx: CGContext, size: CGSize) {
        let fontSize = CGFloat(width) / 52
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, fontSize, nil)!
        let attr = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let padX = fontSize * 0.9, padY = fontSize * 0.55
        let boxW = tw + 2 * padX, boxH = fontSize + 2 * padY
        // centred near the top of the scope screen (CG origin is bottom-left)
        let box = CGRect(x: (size.width - boxW) / 2, y: size.height * 0.80 - boxH / 2, width: boxW, height: boxH)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: CGColor(gray: 0, alpha: 0.6))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: boxH / 2, cornerHeight: boxH / 2, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 0.92))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: boxH / 2, cornerHeight: boxH / 2, transform: nil))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0.82, blue: 0.18, alpha: 0.9))
        ctx.setLineWidth(max(1, fontSize / 10))
        ctx.strokePath()
        ctx.textPosition = CGPoint(x: box.minX + padX, y: box.minY + padY + fontSize * 0.22)
        CTLineDraw(line, ctx)
    }

    /// Stops and writes the GIF. Returns the frame count.
    @discardableResult
    func stop(to url: URL) -> Int {
        timer?.invalidate()
        timer = nil
        caption = nil
        let frames = self.frames, times = self.times
        self.frames = []
        self.times = []
        guard !frames.isEmpty,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { return 0 }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (i, f) in frames.enumerated() {
            // real capture intervals, so playback runs at true speed (GIF delays are in 1/100 s)
            let d = i + 1 < times.count ? times[i + 1] - times[i] : 1 / fps
            let delay = max(0.02, (d * 100).rounded() / 100)
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                        kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(dest, f, props)
        }
        CGImageDestinationFinalize(dest)
        return frames.count
    }
}
