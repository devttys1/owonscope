import MetalKit
import ScopeKit
import simd

struct TracePolyline {
    var points: [SIMD2<Float>] // normalised device coordinates
    var color: SIMD4<Float>
}

/// A filled band (envelope): triangle strip of alternating (x, min) / (x, max) vertices.
struct TraceBand {
    var strip: [SIMD2<Float>]
    var color: SIMD4<Float>
}

struct TraceScene {
    var bands: [TraceBand] = []
    var lines: [TracePolyline] = []
    var sequence = -1
    var generation = 0
    var decay: Float = 0
    var halfWidth: Float = 0.8
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TraceUniforms { float2 viewport; float halfWidth; float pad; float4 color; };
struct TraceOut { float4 pos [[position]]; float dist; float halfW; float4 color; };

vertex TraceOut trace_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device float2 *pts [[buffer(0)]],
                             constant TraceUniforms &u [[buffer(1)]]) {
    float2 a = (pts[iid] * 0.5 + 0.5) * u.viewport;
    float2 b = (pts[iid + 1] * 0.5 + 0.5) * u.viewport;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1, 0);
    float2 n = float2(-dir.y, dir.x);
    float w = u.halfWidth + 1.0;
    float2 corner;
    switch (vid) {
        case 0: corner = float2(0, -1); break;
        case 1: corner = float2(1, -1); break;
        case 2: corner = float2(0, 1); break;
        case 3: corner = float2(0, 1); break;
        case 4: corner = float2(1, -1); break;
        default: corner = float2(1, 1); break;
    }
    float2 p = (corner.x < 0.5 ? a - dir * w * 0.5 : b + dir * w * 0.5) + n * corner.y * w;
    TraceOut o;
    o.pos = float4(p / u.viewport * 2.0 - 1.0, 0, 1);
    o.dist = corner.y * w;
    o.halfW = u.halfWidth;
    o.color = u.color;
    return o;
}

fragment float4 trace_fragment(TraceOut in [[stage_in]]) {
    float a = 1.0 - smoothstep(in.halfW - 0.6, in.halfW + 0.9, abs(in.dist));
    return float4(in.color.rgb * a, a);
}

struct BandOut { float4 pos [[position]]; float4 color; };

vertex BandOut band_vertex(uint vid [[vertex_id]], const device float2 *pts [[buffer(0)]],
                           constant float4 &color [[buffer(1)]]) {
    BandOut o;
    o.pos = float4(pts[vid], 0, 1);
    o.color = color;
    return o;
}

fragment float4 band_fragment(BandOut in [[stage_in]]) { return in.color; }

struct FSOut { float4 pos [[position]]; float2 uv; };

vertex FSOut fs_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.pos = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 persist_fragment(FSOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 texture2d<float> accum [[texture(1)]],
                                 constant float &decay [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float4 f = frame.sample(s, in.uv);
    float4 a = accum.sample(s, in.uv) * decay;
    return max(f, a);
}

fragment float4 present_fragment(FSOut in [[stage_in]],
                                 texture2d<float> accum [[texture(0)]],
                                 constant float2 &texel [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c = accum.sample(s, in.uv);
    float4 g = 0;
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * 0.785398;
        g += accum.sample(s, in.uv + float2(cos(ang), sin(ang)) * texel * 3.0);
        g += accum.sample(s, in.uv + float2(cos(ang + 0.39), sin(ang + 0.39)) * texel * 6.0) * 0.5;
    }
    g /= 12.0;
    float2 q = in.uv - 0.5;
    float vig = 1.0 - dot(q, q) * 0.6;
    float3 bg = float3(0.030, 0.037, 0.050) * vig;
    float3 col = bg + c.rgb * 0.92 + g.rgb * 0.55;
    return float4(col, 1);
}
"""

private struct TraceUniforms {
    var viewport: SIMD2<Float>
    var halfWidth: Float
    var pad: Float = 0
    var color: SIMD4<Float>
}

/// Draws the waveform traces with Metal: antialiased thick lines, persistence and glow.
final class TraceRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let tracePipeline: MTLRenderPipelineState
    private let bandPipeline: MTLRenderPipelineState
    private let persistPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState

    private var frameTex: MTLTexture?
    private var accum: [MTLTexture] = []
    private var accumIndex = 0
    private var lastSequence = -1
    private var lastGeneration = -1
    private var geometryDirty = true

    var scene = TraceScene() {
        didSet { geometryDirty = true }
    }

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            let hdr = MTLPixelFormat.rgba16Float

            let t = MTLRenderPipelineDescriptor()
            t.vertexFunction = lib.makeFunction(name: "trace_vertex")
            t.fragmentFunction = lib.makeFunction(name: "trace_fragment")
            t.colorAttachments[0].pixelFormat = hdr
            t.colorAttachments[0].isBlendingEnabled = true
            t.colorAttachments[0].rgbBlendOperation = .max
            t.colorAttachments[0].alphaBlendOperation = .max
            t.colorAttachments[0].sourceRGBBlendFactor = .one
            t.colorAttachments[0].destinationRGBBlendFactor = .one
            t.colorAttachments[0].sourceAlphaBlendFactor = .one
            t.colorAttachments[0].destinationAlphaBlendFactor = .one
            tracePipeline = try device.makeRenderPipelineState(descriptor: t)

            t.vertexFunction = lib.makeFunction(name: "band_vertex")
            t.fragmentFunction = lib.makeFunction(name: "band_fragment")
            bandPipeline = try device.makeRenderPipelineState(descriptor: t)

            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = lib.makeFunction(name: "fs_vertex")
            p.fragmentFunction = lib.makeFunction(name: "persist_fragment")
            p.colorAttachments[0].pixelFormat = hdr
            persistPipeline = try device.makeRenderPipelineState(descriptor: p)

            let o = MTLRenderPipelineDescriptor()
            o.vertexFunction = lib.makeFunction(name: "fs_vertex")
            o.fragmentFunction = lib.makeFunction(name: "present_fragment")
            o.colorAttachments[0].pixelFormat = view.colorPixelFormat
            presentPipeline = try device.makeRenderPipelineState(descriptor: o)
        } catch {
            NSLog("Metal setup failed: \(error)")
            return nil
        }
        super.init()
    }

    /// Drawable pixels per point (2 or 3 on Retina screens).
    private func pixelScale(_ view: MTKView) -> Float {
        view.bounds.width > 0 ? Float(view.drawableSize.width / view.bounds.width) : 2
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        frameTex = nil
        accum = []
        geometryDirty = true
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    private func ensureTextures(_ size: CGSize) {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        if let f = frameTex, f.width == w, f.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        frameTex = device.makeTexture(descriptor: d)
        accum = [device.makeTexture(descriptor: d)!, device.makeTexture(descriptor: d)!]
        lastGeneration = -1 // force clear
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        ensureTextures(size)
        guard let frameTex, accum.count == 2, let cmd = queue.makeCommandBuffer() else { return }

        let newAcquisition = scene.sequence != lastSequence
        let reset = scene.generation != lastGeneration
        if newAcquisition || geometryDirty || reset {
            // 1. traces into the frame texture
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = frameTex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rp) {
                if !scene.bands.isEmpty {
                    enc.setRenderPipelineState(bandPipeline)
                    for band in scene.bands where band.strip.count >= 4 {
                        guard let buf = device.makeBuffer(bytes: band.strip, length: band.strip.count * MemoryLayout<SIMD2<Float>>.stride) else { continue }
                        var color = band.color
                        enc.setVertexBuffer(buf, offset: 0, index: 0)
                        enc.setVertexBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: band.strip.count)
                    }
                }
                enc.setRenderPipelineState(tracePipeline)
                for line in scene.lines where line.points.count >= 2 {
                    guard let buf = device.makeBuffer(bytes: line.points, length: line.points.count * MemoryLayout<SIMD2<Float>>.stride) else { continue }
                    var u = TraceUniforms(viewport: SIMD2(Float(size.width), Float(size.height)),
                                          halfWidth: scene.halfWidth * pixelScale(view),
                                          color: line.color)
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<TraceUniforms>.stride, index: 1)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: line.points.count - 1)
                }
                enc.endEncoding()
            }

            // 2. persistence: accum' = max(accum * decay, frame). Only decay on new data.
            // Geometry-only redraws (e.g. dragging an offset while stopped) show just the current frame.
            var decay: Float = reset ? 0 : newAcquisition ? scene.decay : (scene.decay >= 1 ? 1 : 0)
            let src = accum[accumIndex], dst = accum[1 - accumIndex]
            let pp = MTLRenderPassDescriptor()
            pp.colorAttachments[0].texture = dst
            pp.colorAttachments[0].loadAction = .dontCare
            pp.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: pp) {
                enc.setRenderPipelineState(persistPipeline)
                enc.setFragmentTexture(frameTex, index: 0)
                enc.setFragmentTexture(src, index: 1)
                enc.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            accumIndex = 1 - accumIndex
            lastSequence = scene.sequence
            lastGeneration = scene.generation
            geometryDirty = false
        }

        // 3. present
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else {
            cmd.commit()
            return
        }
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(accum[accumIndex], index: 0)
            var texel = SIMD2<Float>(1 / Float(size.width), 1 / Float(size.height))
            enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Renders the current persistence buffer to a CGImage (for screenshots).
    func snapshot(size: CGSize, pixelFormat: MTLPixelFormat) -> CGImage? {
        guard accum.count == 2, let cmd = queue.makeCommandBuffer() else { return nil }
        let w = Int(size.width), h = Int(size.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(presentPipeline)
        enc.setFragmentTexture(accum[accumIndex], index: 0)
        var texel = SIMD2<Float>(1 / Float(w), 1 / Float(h))
        enc.setFragmentBytes(&texel, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

#if os(macOS)
import AppKit

/// MTKView that reports scroll, pinch and drag gestures.
final class ScopeMTKView: MTKView {
    weak var renderer: TraceRenderer?
    var onScroll: ((NSEvent) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onDrag: ((CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void)? // translation, location
    var onDragEnded: (() -> Void)?
    /// Click without drag, in top-left-origin view coordinates.
    var onClick: ((CGPoint) -> Void)?
    private var dragStart: CGPoint?
    private var dragged = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func magnify(with event: NSEvent) { onMagnify?(event.magnification) }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragged && hypot(p.x - s.x, p.y - s.y) < 3 { return }
        dragged = true
        // NSView is y-up; report y-down like SwiftUI
        onDrag?(CGPoint(x: p.x - s.x, y: s.y - p.y), p, event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged, let s = dragStart {
            onClick?(CGPoint(x: s.x, y: isFlipped ? s.y : bounds.height - s.y))
        }
        dragStart = nil
        if dragged { onDragEnded?() }
        dragged = false
    }
}
#endif
