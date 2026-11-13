import MetalKit
import ScopeKit
import SwiftUI

/// Maps between screen points and scope coordinates.
struct ScreenMapping {
    var size: CGSize
    var settings: ScopeSettings

    var start: Double { settings.screenStart }
    var window: Double { settings.timebase.window }

    func x(_ t: Double) -> CGFloat { CGFloat((t - start) / window) * size.width }
    func t(_ x: CGFloat) -> Double { start + Double(x / size.width) * window }
    /// y for a position in divisions from centre (+ up).
    func y(divs: Double) -> CGFloat { size.height / 2 - CGFloat(divs) * size.height / 10 }
    func divs(_ y: CGFloat) -> Double { Double((size.height / 2 - y) / (size.height / 10)) }
    func y(volts: Double, channel: Int) -> CGFloat {
        let c = settings.channels[channel]
        return y(divs: volts / c.unitsPerDivision + c.offsetDivisions)
    }
    func volts(_ y: CGFloat, channel: Int) -> Double {
        let c = settings.channels[channel]
        return (divs(y) - c.offsetDivisions) * c.unitsPerDivision
    }
    func y(value: Double, perDiv: Double, offset: Double) -> CGFloat { y(divs: value / perDiv + offset) }
    func value(_ y: CGFloat, perDiv: Double, offset: Double) -> Double { (divs(y) - offset) * perDiv }
}

enum TraceGeometry {
    /// NDC polyline of a sampled series using the current horizontal mapping; sin(x)/x
    /// reconstruction when zoomed past the sample density.
    static func polyline(values v: [Float], t0: Double, dt: Double, settings: ScopeSettings,
                         perDiv: Double, offset: Double, pixelWidth: Double) -> [SIMD2<Float>] {
        let start = settings.screenStart, window = settings.timebase.window, end = start + window
        guard v.count > 1, dt > 0 else { return [] }
        func idx(_ t: Double) -> Int { max(0, min(v.count - 1, Int(((t - t0) / dt).rounded()))) }
        let i0 = max(0, idx(start) - 1), i1 = min(v.count - 1, idx(end) + 1)
        guard i1 > i0 else { return [] }
        let pd = Float(perDiv), off = Float(offset)
        func ndcX(_ t: Double) -> Float { Float((t - start) / window * 2 - 1) }
        func ndcY(_ x: Float) -> Float { (x / pd + off) / 5 }
        var pts: [SIMD2<Float>] = []
        if i1 - i0 < Int(pixelWidth / 4) {
            let a = max(start, t0), b = min(end, t0 + Double(v.count - 1) * dt)
            guard b > a else { return [] }
            let n = max(2, min(4000, Int(pixelWidth * 1.5)))
            let vals = Interpolator.sinc(values: v, t0: t0, dt: dt, from: a, to: b, points: n)
            pts.reserveCapacity(n)
            for (k, x) in vals.enumerated() where x.isFinite {
                pts.append(SIMD2(ndcX(a + (b - a) * Double(k) / Double(n - 1)), ndcY(x)))
            }
        } else {
            pts.reserveCapacity(i1 - i0 + 1)
            for i in i0...i1 where v[i].isFinite { pts.append(SIMD2(ndcX(t0 + Double(i) * dt), ndcY(v[i]))) }
        }
        return pts
    }

    static func band(lo: [Float], hi: [Float], t0: Double, dt: Double, settings: ScopeSettings,
                     perDiv: Double, offset: Double) -> [SIMD2<Float>] {
        let start = settings.screenStart, window = settings.timebase.window
        let n = min(lo.count, hi.count)
        guard n > 1 else { return [] }
        let i0 = max(0, Int((start - t0) / dt) - 1), i1 = min(n - 1, Int((start + window - t0) / dt) + 1)
        guard i1 > i0 else { return [] }
        let pd = Float(perDiv), off = Float(offset)
        var strip: [SIMD2<Float>] = []
        strip.reserveCapacity((i1 - i0 + 1) * 2)
        for i in i0...i1 {
            let x = Float((t0 + Double(i) * dt - start) / window * 2 - 1)
            strip.append(SIMD2(x, (lo[i] / pd + off) / 5))
            strip.append(SIMD2(x, (hi[i] / pd + off) / 5))
        }
        return strip
    }

    @MainActor
    static func scene(_ model: ScopeModel, pixelWidth: Double) -> (bands: [TraceBand], lines: [TracePolyline]) {
        var bands: [TraceBand] = [], lines: [TracePolyline] = []
        let s = model.settings
        guard let acq = model.acquisition else { return ([], []) }

        if model.display.format == .xy {
            guard let a = acq.channel(0), let b = acq.channel(1) else { return ([], []) }
            let ca = s.channels[0], cb = s.channels[1]
            let n = min(a.count, b.count)
            var pts: [SIMD2<Float>] = []
            pts.reserveCapacity(n)
            for i in 0..<n {
                pts.append(SIMD2(Float((Double(a.volts[i]) / ca.unitsPerDivision + ca.offsetDivisions) / 5),
                                 Float((Double(b.volts[i]) / cb.unitsPerDivision + cb.offsetDivisions) / 5)))
            }
            lines.append(TracePolyline(points: pts, color: Theme.xySIMD))
            return ([], lines)
        }

        let visibleCount = [s.channels[0].enabled, s.channels[1].enabled, model.processing.math.enabled].filter { $0 }.count
        func dim(_ c: SIMD4<Float>, _ trace: Trace) -> SIMD4<Float> {
            visibleCount > 1 && model.selectedTrace != trace ? c * SIMD4(0.72, 0.72, 0.72, 1) : c
        }

        // references (underneath)
        for (i, r) in model.references.enumerated() {
            guard let r, r.visible else { continue }
            let pts = polyline(values: r.waveform.values, t0: r.waveform.t0, dt: r.waveform.dt, settings: s,
                               perDiv: r.unitsPerDivision, offset: r.offsetDivisions, pixelWidth: pixelWidth)
            lines.append(TracePolyline(points: pts, color: Theme.refSIMD[i] * SIMD4(0.8, 0.8, 0.8, 1)))
        }

        var ordered: [Trace] = [.ch1, .ch2, .math].filter { $0 != model.selectedTrace }
        ordered.append(model.selectedTrace)
        for trace in ordered {
            switch trace {
            case .ch1, .ch2:
                let ch = trace.rawValue
                let c = s.channels[ch]
                guard c.enabled, let w = acq.channel(ch), w.count > 1 else { continue }
                let color = dim(Theme.chSIMD[ch], trace)
                // raw capture faintly under the average
                if model.processing.mode == .average && model.display.showRawUnderAverage,
                   let raw = model.rawAcquisition?.channel(ch) {
                    let pts = polyline(values: raw.volts, t0: raw.t0, dt: raw.dt, settings: s,
                                       perDiv: c.unitsPerDivision, offset: c.offsetDivisions, pixelWidth: pixelWidth)
                    lines.append(TracePolyline(points: pts, color: color * SIMD4(0.3, 0.3, 0.3, 1)))
                }
                if let lo = w.envelopeMin, let hi = w.envelopeMax {
                    let strip = band(lo: lo, hi: hi, t0: w.t0, dt: w.dt, settings: s, perDiv: c.unitsPerDivision, offset: c.offsetDivisions)
                    bands.append(TraceBand(strip: strip, color: color * SIMD4(0.32, 0.32, 0.32, 1)))
                }
                let pts = polyline(values: w.volts, t0: w.t0, dt: w.dt, settings: s,
                                   perDiv: c.unitsPerDivision, offset: c.offsetDivisions, pixelWidth: pixelWidth)
                lines.append(TracePolyline(points: pts, color: color))
            case .math:
                guard model.processing.math.enabled, let m = model.analysis.math else { continue }
                let pts = polyline(values: m.values, t0: m.t0, dt: m.dt, settings: s,
                                   perDiv: model.processing.math.unitsPerDivision,
                                   offset: model.processing.math.offsetDivisions, pixelWidth: pixelWidth)
                lines.append(TracePolyline(points: pts, color: dim(Theme.mathSIMD, .math)))
            }
        }
        return (bands, lines)
    }
}

/// The Metal trace layer.
struct TraceLayer: NSViewRepresentable {
    var scene: TraceScene
    var onScroll: (NSEvent) -> Void
    var onMagnify: (CGFloat) -> Void
    var onDrag: (CGPoint, CGPoint, NSEvent.ModifierFlags) -> Void
    var onDragEnded: () -> Void
    var onClick: (CGPoint) -> Void

    final class Coordinator { var renderer: TraceRenderer? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScopeMTKView {
        let v = ScopeMTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.isPaused = true
        v.enableSetNeedsDisplay = true
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0.03, green: 0.037, blue: 0.05, alpha: 1)
        let r = TraceRenderer(view: v)
        context.coordinator.renderer = r
        v.renderer = r
        v.delegate = r
        return v
    }

    func updateNSView(_ v: ScopeMTKView, context: Context) {
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        v.onDrag = onDrag
        v.onDragEnded = onDragEnded
        v.onClick = onClick
        context.coordinator.renderer?.scene = scene
        v.needsDisplay = true
    }
}

struct ScopeDisplay: View {
    @Bindable var model: ScopeModel
    @State private var scrollAccum: CGFloat = 0
    @State private var magnifyAccum: CGFloat = 0
    @State private var dragOrigin: (pos: Double, offset: Double)?
    @State private var levelDragging = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let map = ScreenMapping(size: geo.size, settings: model.settings)
            let xy = model.display.format == .xy
            ZStack(alignment: .topLeading) {
                TraceLayer(scene: scene(width: geo.size.width),
                           onScroll: { handleScroll($0) },
                           onMagnify: { handleMagnify($0) },
                           onDrag: { t, _, _ in handleDrag(t, size: geo.size) },
                           onDragEnded: { dragOrigin = nil },
                           onClick: { selectTrace(at: $0, map: map) })

                GraticuleView(map: map).allowsHitTesting(false)

                if levelDragging, let ch = model.settings.trigger.source.channel {
                    let y = map.y(volts: model.settings.trigger.level, channel: ch)
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                        .stroke(Theme.trigger, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .allowsHitTesting(false)
                }

                if !xy {
                    DecodeLanesView(model: model, map: map).allowsHitTesting(false)
                    if model.display.cursorMode != .off {
                        CursorsOverlay(model: model, map: map)
                    }
                    MarkersOverlay(model: model, map: map, levelDragging: $levelDragging)
                }

                HUDOverlay(model: model)

                ConnectionBanner(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
        }
    }

    private func scene(width: CGFloat) -> TraceScene {
        var s = TraceScene()
        let parts = TraceGeometry.scene(model, pixelWidth: Double(width * displayScale))
        s.bands = parts.bands
        s.lines = parts.lines
        s.sequence = model.acquisition?.sequence ?? -1
        s.generation = model.displayGeneration
        s.decay = model.display.persistence.decay
        s.halfWidth = Float(model.display.traceWidth / 2)
        return s
    }

    // MARK: Gestures

    /// Selects the trace nearest to a click (within 40 pt).
    private func selectTrace(at p: CGPoint, map: ScreenMapping) {
        guard model.display.format == .yt else { return }
        let t = map.t(p.x)
        var best: (Trace, CGFloat)?
        for trace in Trace.allCases where model.isVisible(trace) {
            let value: Double?
            switch trace {
            case .math:
                value = model.analysis.math.map { Double($0.values[$0.index(at: t)]) }
            default:
                value = model.acquisition?.channel(trace.rawValue).map { Double($0.volts[$0.index(at: t)]) }
            }
            guard let v = value, v.isFinite else { continue }
            let s = model.scale(of: trace)
            let d = abs(map.y(value: v, perDiv: s.perDiv, offset: model.offset(of: trace)) - p.y)
            if d < 40 && d < (best?.1 ?? .infinity) { best = (trace, d) }
        }
        if let b = best { model.selectTrace(b.0) }
    }

    private func handleScroll(_ e: NSEvent) {
        let mods = e.modifierFlags
        let precise = e.hasPreciseScrollingDeltas
        // horizontal trackpad scroll pans the trigger position
        if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) {
            let dx = Double(e.scrollingDeltaX) / (precise ? 900 : 30)
            model.settings.triggerPosition = min(1, max(0, model.settings.triggerPosition + dx))
            return
        }
        if mods.contains(.command) {
            let d = Double(e.scrollingDeltaY) / (precise ? 40 : 4)
            model.setOffset(of: model.selectedTrace, model.offset(of: model.selectedTrace) + d)
            return
        }
        scrollAccum += e.scrollingDeltaY
        let threshold: CGFloat = precise ? 28 : 0.9
        guard abs(scrollAccum) >= threshold else { return }
        let step = scrollAccum > 0 ? -1 : 1
        scrollAccum = 0
        if mods.contains(.option) {
            model.stepSelectedScale(step)
        } else {
            model.stepTimebase(step)
        }
    }

    private func handleMagnify(_ m: CGFloat) {
        magnifyAccum += m
        if abs(magnifyAccum) > 0.22 {
            model.stepTimebase(magnifyAccum > 0 ? -1 : 1)
            magnifyAccum = 0
        }
    }

    /// Grab-and-move: horizontal drag pans the trigger point, vertical moves the selected trace.
    private func handleDrag(_ translation: CGPoint, size: CGSize) {
        let trace = model.selectedTrace
        if dragOrigin == nil {
            dragOrigin = (model.settings.triggerPosition, model.offset(of: trace))
        }
        guard let o = dragOrigin, size.width > 0 else { return }
        if !model.settings.timebase.isRollMode && model.display.format == .yt {
            model.settings.triggerPosition = min(1, max(0, o.pos + Double(translation.x / size.width)))
        }
        let divs = -Double(translation.y / (size.height / 10)) // translation is y-down
        model.setOffset(of: trace, ((o.offset + divs) * 25).rounded() / 25)
    }
}

struct GraticuleView: View {
    var map: ScreenMapping

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var minor = Path()
            var major = Path()
            for i in 0...10 {
                let x = w * CGFloat(i) / 10
                let y = h * CGFloat(i) / 10
                major.move(to: CGPoint(x: x, y: 0)); major.addLine(to: CGPoint(x: x, y: h))
                major.move(to: CGPoint(x: 0, y: y)); major.addLine(to: CGPoint(x: w, y: y))
            }
            var ticks = Path()
            for i in 0...50 {
                let x = w * CGFloat(i) / 50, y = h * CGFloat(i) / 50
                let len: CGFloat = i % 5 == 0 ? 6 : 3.5
                ticks.move(to: CGPoint(x: x, y: h / 2 - len)); ticks.addLine(to: CGPoint(x: x, y: h / 2 + len))
                ticks.move(to: CGPoint(x: w / 2 - len, y: y)); ticks.addLine(to: CGPoint(x: w / 2 + len, y: y))
                if i % 5 != 0 {
                    for j in 1..<10 {
                        let gx = w * CGFloat(j) / 10, gy = h * CGFloat(j) / 10
                        minor.addRect(CGRect(x: gx - 0.5, y: y - 0.5, width: 1, height: 1))
                        minor.addRect(CGRect(x: x - 0.5, y: gy - 0.5, width: 1, height: 1))
                    }
                }
            }
            ctx.stroke(major, with: .color(Theme.grid), lineWidth: 1)
            ctx.fill(minor, with: .color(Color.white.opacity(0.16)))
            ctx.stroke(ticks, with: .color(Theme.gridStrong), lineWidth: 1)
            var axes = Path()
            axes.move(to: CGPoint(x: w / 2, y: 0)); axes.addLine(to: CGPoint(x: w / 2, y: h))
            axes.move(to: CGPoint(x: 0, y: h / 2)); axes.addLine(to: CGPoint(x: w, y: h / 2))
            ctx.stroke(axes, with: .color(Theme.gridStrong), lineWidth: 1)
            ctx.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.gridStrong), lineWidth: 1)
        }
    }
}

/// Draggable zero markers (left), trigger level (right) and trigger position (top).
struct MarkersOverlay: View {
    @Bindable var model: ScopeModel
    var map: ScreenMapping
    @Binding var levelDragging: Bool

    var body: some View {
        let s = model.settings
        ZStack(alignment: .topLeading) {
            ForEach(Trace.allCases, id: \.self) { trace in
                if model.isVisible(trace) {
                    let y = map.y(divs: model.offset(of: trace))
                    MarkerTag(text: trace == .math ? "M" : "\(trace.rawValue + 1)",
                              color: Theme.traceColor(trace), pointing: .right,
                              selected: model.selectedTrace == trace)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scope"))
                            .onChanged { g in
                                model.selectTrace(trace)
                                model.setOffset(of: trace, (map.divs(g.location.y) * 25).rounded() / 25)
                            })
                        .help("\(trace.name) zero — drag to move, click to select")
                        .position(x: 13, y: min(max(y, 9), map.size.height - 9))
                }
            }

            if let ch = s.trigger.source.channel, s.channels[ch].enabled {
                let y = map.y(volts: s.trigger.level, channel: ch)
                MarkerTag(text: "T", color: Theme.triggerColor(s.trigger.source), pointing: .left, selected: levelDragging)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scope"))
                        .onChanged { g in
                            levelDragging = true
                            let v = map.volts(g.location.y, channel: ch)
                            let step = s.channels[ch].unitsPerDivision / 25
                            model.settings.trigger.level = (v / step).rounded() * step
                        }
                        .onEnded { _ in levelDragging = false })
                    .help("Trigger level — drag to adjust")
                    .position(x: map.size.width - 13, y: min(max(y, 9), map.size.height - 9))
            }

            if !s.timebase.isRollMode {
                let x = map.x(0)
                TriggerPositionTag()
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scope"))
                        .onChanged { g in
                            model.settings.triggerPosition = min(1, max(0, Double(g.location.x / map.size.width)))
                        })
                    .help("Trigger position — drag to move")
                    .position(x: min(max(x, 8), map.size.width - 8), y: 8)
            }
        }
        .coordinateSpace(name: "scope")
    }
}

struct MarkerTag: View {
    enum Pointing { case left, right }
    var text: String
    var color: Color
    var pointing: Pointing
    var selected = false

    var body: some View {
        ZStack {
            TagShape(pointing: pointing)
                .fill(color)
                .shadow(color: color.opacity(selected ? 0.9 : 0.4), radius: selected ? 6 : 2)
            Text(text)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .offset(x: pointing == .right ? -2 : 2)
        }
        .frame(width: 24, height: 16)
        .contentShape(Rectangle().inset(by: -6))
    }
}

struct TagShape: Shape {
    var pointing: MarkerTag.Pointing
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tip: CGFloat = 7
        if pointing == .right {
            p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width - tip, height: r.height), cornerSize: CGSize(width: 3, height: 3))
            p.move(to: CGPoint(x: r.maxX - tip - 1, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - tip - 1, y: r.maxY))
        } else {
            p.addRoundedRect(in: CGRect(x: r.minX + tip, y: r.minY, width: r.width - tip, height: r.height), cornerSize: CGSize(width: 3, height: 3))
            p.move(to: CGPoint(x: r.minX + tip + 1, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX + tip + 1, y: r.maxY))
        }
        return p
    }
}

struct TriggerPositionTag: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 14, y: 0)); p.addLine(to: CGPoint(x: 7, y: 9)); p.closeSubpath()
        }
        .fill(Theme.trigger)
        .frame(width: 14, height: 10)
        .contentShape(Rectangle().inset(by: -6))
    }
}

/// Status readouts drawn over the screen. The trace labels are clickable.
struct HUDOverlay: View {
    var model: ScopeModel

    var body: some View {
        let s = model.settings
        let state: TriggerState = model.running ? (model.acquisition?.triggerState ?? .waiting) : .stopped
        VStack(alignment: .leading) {
            HStack(spacing: 6) {
                Pill(text: state.rawValue, color: Theme.stateColor(state), filled: true)
                Pill(text: s.timebase.label, color: .white)
                Pill(text: Format.si(s.timebase.sampleRate, unit: "Sa/s"), color: .gray)
                if s.timebase.isZoomed { Pill(text: "sin(x)/x", color: .gray) }
                if s.peakDetect { Pill(text: "Peak detect", color: .gray) }
                if let acc = accumulation { Pill(text: acc, color: .white) }
                if model.display.format == .xy { Pill(text: "XY", color: Theme.xy) }
                if s.trigger.mode == .pulse {
                    Pill(text: "Pulse \(s.trigger.slope == .rising ? "+" : "−")width \(s.trigger.pulseCondition.rawValue) \(Format.seconds(s.trigger.pulseWidth))",
                         color: Theme.trigger)
                }
                Spacer()
                if model.display.persistence != .off { Pill(text: "Persist \(model.display.persistence.rawValue)", color: .gray) }
                Text(String(format: "%.0f fps", model.framesPerSecond))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.leading, 28)
            .padding(.trailing, 30)
            .padding(.top, 14)
            .allowsHitTesting(false)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Trace.allCases, id: \.self) { trace in
                    if model.isVisible(trace) {
                        Button { model.selectTrace(trace) } label: {
                            Pill(text: label(trace), color: Theme.traceColor(trace), filled: model.selectedTrace == trace)
                        }
                        .buttonStyle(.plain)
                        .help("Select \(trace.name)")
                    }
                }
                Spacer()
                let t = s.trigger
                Pill(text: "\(t.source.rawValue) \(t.slope == .rising ? "↑" : "↓") \(triggerLevel)  \(t.sweep.rawValue)",
                     color: Theme.triggerColor(t.source))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8 + CGFloat(model.decoders.filter(\.enabled).count) * 24)
        }
    }

    private var triggerLevel: String {
        guard let ch = model.settings.trigger.source.channel else { return Format.volts(model.settings.trigger.level) }
        return model.settings.channels[ch].format(model.settings.trigger.level)
    }

    private var accumulation: String? {
        guard let w = model.acquisition?.channels.compactMap({ $0 }).first else { return nil }
        switch model.processing.mode {
        case .average: return "Avg \(min(w.accumulated, model.processing.averages))/\(model.processing.averages)"
        case .envelope: return "Envelope ×\(w.accumulated)"
        default: return nil
        }
    }

    private func label(_ trace: Trace) -> String {
        switch trace {
        case .math:
            let m = model.processing.math
            let unit = model.analysis.math?.unit ?? ""
            return "MATH \(m.label)  \(Format.si(m.unitsPerDivision, unit: unit))/div"
        default:
            let c = model.settings.channels[trace.rawValue]
            let clipped = model.acquisition?.channel(trace.rawValue)?.clipped ?? false
            return "CH\(trace.rawValue + 1)  \(c.format(c.unitsPerDivision))/div  \(c.coupling.rawValue)  \(c.probeLabel)\(clipped ? "  ⚠︎ clip" : "")"
        }
    }
}

/// Shown over the screen when no device is connected.
struct ConnectionBanner: View {
    var model: ScopeModel

    var body: some View {
        switch model.connection {
        case .connected:
            EmptyView()
        case .searching:
            card {
                ProgressView().controlSize(.small)
                Text("Looking for an OWON VDS1022…").font(.headline)
                Text("Connect the scope over USB, or explore with a simulated signal.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Use Demo Signals") { model.source = .demo(.reference) }
            }
        case .connecting:
            card { ProgressView().controlSize(.small); Text("Connecting…").font(.headline) }
        case .loadingFirmware(let p):
            card {
                Text("Loading FPGA firmware").font(.headline)
                ProgressView(value: p).frame(width: 220)
                Text("\(Int(p * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            card {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                Text(msg).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack {
                    if msg.contains("firmware") {
                        Button("Choose Firmware Folder…") { model.chooseFirmwareFolder() }
                    }
                    Button("Retry") { model.reconnect() }
                    Button("Use Demo") { model.source = .demo(.reference) }
                }
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
    }
}
