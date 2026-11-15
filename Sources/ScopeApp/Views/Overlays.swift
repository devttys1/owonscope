import ScopeKit
import SwiftUI

/// Bus-style decode lanes along the bottom of the screen.
struct DecodeLanesView: View {
    var model: ScopeModel
    var map: ScreenMapping

    static let laneHeight: CGFloat = 20

    var body: some View {
        let active = model.decoders.filter(\.enabled)
        Canvas { ctx, size in
            for (lane, d) in active.enumerated() {
                let yTop = size.height - CGFloat(active.count - lane) * (Self.laneHeight + 4) - 4
                let base = Theme.decoderPalette[lane % Theme.decoderPalette.count]
                var idle = Path()
                idle.move(to: CGPoint(x: 0, y: yTop + Self.laneHeight / 2))
                idle.addLine(to: CGPoint(x: size.width, y: yTop + Self.laneHeight / 2))
                ctx.stroke(idle, with: .color(base.opacity(0.35)), lineWidth: 1)

                defer {
                    // lane label, drawn last so it sits on top of the event boxes
                    let label = ctx.resolve(Text(d.kind.name).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(base))
                    let sz = label.measure(in: CGSize(width: 200, height: 40))
                    let r = CGRect(x: 4, y: yTop + (Self.laneHeight - sz.height - 4) / 2, width: sz.width + 10, height: sz.height + 4)
                    ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.black.opacity(0.85)))
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(base.opacity(0.6)), lineWidth: 1)
                    ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY))
                }
                guard let r = model.analysis.decodes[d.id] else { continue }
                for e in r.events {
                    var x0 = map.x(e.start), x1 = map.x(e.end)
                    guard x1 > 0, x0 < size.width else { continue }
                    x0 = max(x0, -10); x1 = min(x1, size.width + 10)
                    let color = Theme.eventColor(e.kind, base: base)
                    let rect = CGRect(x: x0, y: yTop, width: max(2, x1 - x0), height: Self.laneHeight)
                    let path = Self.hexagon(rect)
                    ctx.fill(path, with: .color(color.opacity(0.22)))
                    ctx.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
                    let width = rect.width - 8
                    guard width > 6 else { continue }
                    for text in [e.label, e.short] {
                        let t = ctx.resolve(Text(text).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.white))
                        if t.measure(in: CGSize(width: 1000, height: 100)).width <= width {
                            ctx.draw(t, at: CGPoint(x: rect.midX, y: rect.midY))
                            break
                        }
                    }
                }
            }
        }
    }

    static func hexagon(_ r: CGRect) -> Path {
        let k = min(4, r.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + k, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Time (vertical) and amplitude (horizontal) cursors with a readout. Amplitude cursors
/// belong to the selected trace; in Track mode they follow the trace at the time cursors.
struct CursorsOverlay: View {
    @Bindable var model: ScopeModel
    var map: ScreenMapping
    /// Live offset while the readout is being dragged.
    @GestureState private var readoutDrag: CGSize = .zero

    static let readoutSize = CGSize(width: 210, height: 150)

    private var mode: CursorMode { model.display.cursorMode }
    private var trace: Trace { model.selectedTrace }
    private var scale: (perDiv: Double, unit: String) { model.scale(of: trace) }
    private var offset: Double { model.offset(of: trace) }

    var body: some View {
        let c = model.cursors
        let color = Theme.traceColor(trace)
        ZStack(alignment: .topLeading) {
            if mode.showsTime {
                timeLine(x: map.x(c.t1), label: "A") { model.cursors.t1 = map.t($0) }
                timeLine(x: map.x(c.t2), label: "B") { model.cursors.t2 = map.t($0) }
            }
            if mode == .amplitude || mode == .both {
                levelLine(y: map.y(value: c.y1, perDiv: scale.perDiv, offset: offset), label: "Y1", color: color, draggable: true) {
                    model.cursors.y1 = map.value($0, perDiv: scale.perDiv, offset: offset)
                }
                levelLine(y: map.y(value: c.y2, perDiv: scale.perDiv, offset: offset), label: "Y2", color: color, draggable: true) {
                    model.cursors.y2 = map.value($0, perDiv: scale.perDiv, offset: offset)
                }
            }
            if mode == .track {
                ForEach(Array([c.t1, c.t2].enumerated()), id: \.offset) { i, t in
                    if let v = value(at: t) {
                        let y = map.y(value: v, perDiv: scale.perDiv, offset: offset)
                        levelLine(y: y, label: i == 0 ? "A" : "B", color: color, draggable: false) { _ in }
                        Circle().stroke(color, lineWidth: 1.5).frame(width: 10, height: 10)
                            .position(x: map.x(t), y: y)
                            .allowsHitTesting(false)
                    }
                }
            }
            draggableReadout
        }
        .coordinateSpace(name: "cursors")
        .onAppear { recentre(force: false) }
        .onChange(of: model.settings.timebaseIndex) { recentre(force: true) }
        .onChange(of: model.selectedTrace) { recentreY() }
        .onChange(of: model.display.cursorMode) { recentre(force: false) }
    }

    /// Value of the selected trace at time t.
    private func value(at t: Double) -> Double? {
        switch trace {
        case .math:
            return model.analysis.math.map { Double($0.values[$0.index(at: t)]) }
        default:
            return model.acquisition?.channel(trace.rawValue).map { Double($0.volts[$0.index(at: t)]) }
        }
    }

    /// Keep cursors on screen: 35 % / 65 % in time, ±2 div around the trace's zero.
    private func recentre(force: Bool) {
        let start = map.start, w = map.window
        if force || model.cursors.t1 < start || model.cursors.t1 > start + w { model.cursors.t1 = start + w * 0.35 }
        if force || model.cursors.t2 < start || model.cursors.t2 > start + w { model.cursors.t2 = start + w * 0.65 }
        let top = (5 - offset) * scale.perDiv, bottom = (-5 - offset) * scale.perDiv
        if !(bottom...top).contains(model.cursors.y1) || !(bottom...top).contains(model.cursors.y2) { recentreY() }
    }

    private func recentreY() {
        model.cursors.y1 = (2 - offset) * scale.perDiv
        model.cursors.y2 = (-2 - offset) * scale.perDiv
    }

    private func timeLine(x: CGFloat, label: String, set: @escaping (CGFloat) -> Void) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1, height: map.size.height)
                .allowsHitTesting(false)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.85)))
                .contentShape(Rectangle().inset(by: Platform.isTouch ? -14 : 0))
                .offset(y: 22)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cursors")).onChanged { set($0.location.x) })
        }
        .frame(width: 18, height: map.size.height)
        .position(x: x, y: map.size.height / 2)
    }

    private func levelLine(y: CGFloat, label: String, color: Color, draggable: Bool, set: @escaping (CGFloat) -> Void) -> some View {
        ZStack(alignment: .trailing) {
            Path { p in p.move(to: CGPoint(x: 0, y: 0.5)); p.addLine(to: CGPoint(x: map.size.width, y: 0.5)) }
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(height: 1)
                .allowsHitTesting(false)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 22, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.9)))
                .contentShape(Rectangle().inset(by: Platform.isTouch ? -14 : 0))
                .padding(.trailing, Platform.isTouch ? 48 : 34)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cursors")).onChanged { set($0.location.y) })
                .allowsHitTesting(draggable)
        }
        .frame(width: map.size.width, height: 16)
        .position(x: map.size.width / 2, y: min(max(y, 0), map.size.height))
    }

    /// Readout centre, kept fully inside the screen. Defaults to the upper left, clear of
    /// the Y1/Y2 and trigger handles on the right.
    private func readoutCentre(adding drag: CGSize = .zero) -> CGPoint {
        let w = map.size.width, h = map.size.height
        let half = CGSize(width: Self.readoutSize.width / 2, height: Self.readoutSize.height / 2)
        let base = model.display.cursorReadout.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            ?? CGPoint(x: 40 + half.width, y: 50 + half.height)
        return CGPoint(x: min(max(base.x + drag.width, half.width + 4), max(half.width + 4, w - half.width - 4)),
                       y: min(max(base.y + drag.height, half.height + 4), max(half.height + 4, h - half.height - 4)))
    }

    private var draggableReadout: some View {
        readout
            .overlay(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(6)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .openHandCursor()
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("cursors"))
                .updating($readoutDrag) { g, state, _ in state = g.translation }
                .onEnded { g in
                    let p = readoutCentre(adding: g.translation)
                    model.display.cursorReadout = CGPoint(x: p.x / max(1, map.size.width), y: p.y / max(1, map.size.height))
                })
            .onTapGesture(count: 2) { model.display.cursorReadout = nil }
            .help(Platform.isTouch ? "Drag to move · double-tap to reset position" : "Drag to move · double-click to reset position")
            .position(readoutCentre(adding: readoutDrag))
    }

    private var readout: some View {
        let c = model.cursors
        let dt = c.t2 - c.t1
        let unit = scale.unit
        let ys: (Double, Double)? = {
            switch mode {
            case .amplitude, .both: return (c.y1, c.y2)
            case .track: if let a = value(at: c.t1), let b = value(at: c.t2) { return (a, b) }; return nil
            default: return nil
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text("Cursors · \(trace.name)").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.traceColor(trace))
            if mode.showsTime {
                row("Δt", Format.seconds(abs(dt)), .white)
                row("1/Δt", dt != 0 ? Format.hertz(1 / abs(dt)) : "—", .white)
            }
            if let (a, b) = ys {
                let color = Theme.traceColor(trace)
                row(mode == .track ? "A" : "Y1", Format.si(a, unit: unit), color)
                row(mode == .track ? "B" : "Y2", Format.si(b, unit: unit), color)
                row("ΔY", Format.si(b - a, unit: unit), color)
                if mode.showsTime && dt != 0 {
                    row("ΔY/Δt", Format.si((b - a) / dt, unit: unit + "/s"), color)
                }
            }
        }
        .padding(8)
        .frame(width: Self.readoutSize.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.15)))
    }

    private func row(_ k: String, _ v: String, _ color: Color) -> some View {
        HStack {
            Text(k).foregroundStyle(color.opacity(0.75))
            Spacer()
            Text(v).foregroundStyle(color)
        }
        .font(.system(size: 11, design: .monospaced))
    }
}
