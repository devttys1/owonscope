import Foundation
import ScopeKit

enum ExportFormat: String, CaseIterable { case svg = "SVG", pdf = "PDF", png = "PNG" }

struct ExportTheme {
    var name: String
    var background, plot, grid, gridStrong, text, secondary, panel, panelStroke: VColor
    var ch: [VColor]
    var math: VColor
    var refs: [VColor]
    var trigger: VColor
    var cursor: VColor
    var xy: VColor
    var decoders: [VColor]

    func color(_ t: Trace) -> VColor { t == .math ? math : ch[t.rawValue] }

    static let dark = ExportTheme(
        name: "Dark",
        background: VColor(hex: 0x111418), plot: VColor(hex: 0x07090C),
        grid: VColor(1, 1, 1, 0.10), gridStrong: VColor(1, 1, 1, 0.28),
        text: VColor(hex: 0xE8EAED), secondary: VColor(hex: 0x8B929C),
        panel: VColor(1, 1, 1, 0.04), panelStroke: VColor(1, 1, 1, 0.12),
        ch: [VColor(hex: 0xFFD12E), VColor(hex: 0x38D6FF)], math: VColor(hex: 0xFA6BF2),
        refs: [VColor(hex: 0xD9D9D9), VColor(hex: 0x8CFF99)], trigger: VColor(hex: 0xFF8C33),
        cursor: VColor(1, 1, 1, 0.75), xy: VColor(hex: 0x8CFF8C),
        decoders: [VColor(hex: 0x9E7AFF), VColor(hex: 0x59E68C), VColor(hex: 0xFF73A6), VColor(hex: 0xFFA64D)])

    static let light = ExportTheme(
        name: "Light",
        background: VColor(hex: 0xFFFFFF), plot: VColor(hex: 0xFFFFFF),
        grid: VColor(0, 0, 0, 0.10), gridStrong: VColor(0, 0, 0, 0.32),
        text: VColor(hex: 0x1C1C1E), secondary: VColor(hex: 0x6B6B70),
        panel: VColor(0, 0, 0, 0.03), panelStroke: VColor(0, 0, 0, 0.12),
        ch: [VColor(hex: 0xC28A00), VColor(hex: 0x0A7FC2)], math: VColor(hex: 0xB0179E),
        refs: [VColor(hex: 0x7A7A7A), VColor(hex: 0x2A9D3F)], trigger: VColor(hex: 0xE8590C),
        cursor: VColor(hex: 0x333333, alpha: 0.85), xy: VColor(hex: 0x1F8A3A),
        decoders: [VColor(hex: 0x6A40D8), VColor(hex: 0x1E9E52), VColor(hex: 0xD6336C), VColor(hex: 0xD9730D)])
}

struct ExportOptions {
    var format: ExportFormat = .svg
    var theme: ExportTheme = .light
    var includeStatistics = true
}

/// Builds a vector report of the current screen: plot, axes, markers, cursors, decode lanes,
/// settings, measurements and statistics.
@MainActor
enum ReportBuilder {
    static let width: CGFloat = 1200
    static let margin: CGFloat = 28

    static func build(_ model: ScopeModel, options: ExportOptions, date: Date = Date()) -> VDrawing {
        let th = options.theme
        let s = model.settings
        var d = VDrawing(size: CGSize(width: width, height: 100), background: th.background)
        d.title = "OwonScope capture \(timestamp(date))"
        var y = margin

        // MARK: Header
        d.text("OwonScope", CGPoint(x: margin, y: y + 16), VFont(18, bold: true), th.text)
        let device: String = {
            if case .connected(let i) = model.connection {
                return i.isSimulated ? "Simulated signals" : "\(i.model) · \(i.serial) · HW \(i.hardwareVersion)"
            }
            return "No device"
        }()
        d.text(device, CGPoint(x: margin + VText.width("OwonScope", VFont(18, bold: true)) + 14, y: y + 16), VFont(12), th.secondary)
        d.text(timestamp(date), CGPoint(x: width - margin, y: y + 16), VFont(12), th.secondary, .end)
        y += 30
        let state: TriggerState = model.running ? (model.acquisition?.triggerState ?? .waiting) : .stopped
        let summary = [s.timebase.label, Format.si(s.timebase.sampleRate, unit: "Sa/s"), triggerSummary(model), state.rawValue]
            .joined(separator: "   ·   ")
        d.text(summary, CGPoint(x: margin, y: y + 12), VFont(12, mono: true), th.text)
        y += 26

        // MARK: Plot
        let left: CGFloat = margin + 62, right: CGFloat = 40
        let pw = width - left - right
        let plot = CGRect(x: left, y: y + 10, width: pw, height: (pw * 0.6).rounded())
        drawPlot(&d, model, th, plot)
        y = plot.maxY + 34

        // MARK: Settings + cursor readout
        let settingsTop = y
        let rows = settingsRows(model, th)
        let keyW: CGFloat = 70
        d.text("SETTINGS", CGPoint(x: margin, y: y + 11), VFont(10, bold: true), th.secondary)
        y += 22
        for (k, v, c) in rows {
            d.text(k, CGPoint(x: margin, y: y + 12), VFont(11, bold: true), c)
            d.text(v, CGPoint(x: margin + keyW, y: y + 12), VFont(11, mono: true), c == th.secondary ? th.text : c)
            y += 18
        }
        var blockBottom = y
        if model.display.cursorMode != .off, let lines = cursorLines(model), !lines.isEmpty {
            let boxW: CGFloat = 300
            let x = width - margin - boxW
            var cy = settingsTop
            let h = CGFloat(lines.count) * 18 + 32
            d.items.append(.rect(CGRect(x: x, y: cy, width: boxW, height: h), stroke: th.panelStroke, fill: th.panel, width: 1, radius: 6))
            d.text("CURSORS · \(model.selectedTrace.name)", CGPoint(x: x + 12, y: cy + 18), VFont(10, bold: true), th.color(model.selectedTrace))
            cy += 26
            for (k, v) in lines {
                d.text(k, CGPoint(x: x + 12, y: cy + 12), VFont(11), th.secondary)
                d.text(v, CGPoint(x: x + boxW - 12, y: cy + 12), VFont(11, mono: true), th.text, .end)
                cy += 18
            }
            blockBottom = max(blockBottom, cy + 8)
        }
        y = blockBottom + 18

        // MARK: Measurements
        y = drawMeasurements(&d, model, th, top: y)
        if options.includeStatistics { y = drawStatistics(&d, model, th, top: y) }

        // MARK: Footer
        y += 8
        d.line(CGPoint(x: margin, y: y), CGPoint(x: width - margin, y: y), th.panelStroke)
        y += 16
        d.text("Exported from OwonScope · \(timestamp(date))", CGPoint(x: width - margin, y: y), VFont(9), th.secondary, .end)
        d.size = CGSize(width: width, height: y + margin - 8)
        return d
    }

    // MARK: - Plot

    private static func drawPlot(_ d: inout VDrawing, _ model: ScopeModel, _ th: ExportTheme, _ plot: CGRect) {
        let s = model.settings
        d.items.append(.rect(plot, stroke: nil, fill: th.plot, width: 0, radius: 0))

        // graticule
        var grid: [VItem] = []
        for i in 0...10 {
            let x = plot.minX + plot.width * CGFloat(i) / 10, yy = plot.minY + plot.height * CGFloat(i) / 10
            grid.append(.path([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)], closed: false, stroke: th.grid, fill: nil, width: 0.75, dash: nil))
            grid.append(.path([CGPoint(x: plot.minX, y: yy), CGPoint(x: plot.maxX, y: yy)], closed: false, stroke: th.grid, fill: nil, width: 0.75, dash: nil))
        }
        for i in 0...50 {
            let x = plot.minX + plot.width * CGFloat(i) / 50, yy = plot.minY + plot.height * CGFloat(i) / 50
            let len: CGFloat = i % 5 == 0 ? 5 : 3
            grid.append(.path([CGPoint(x: x, y: plot.midY - len), CGPoint(x: x, y: plot.midY + len)], closed: false, stroke: th.gridStrong, fill: nil, width: 0.75, dash: nil))
            grid.append(.path([CGPoint(x: plot.midX - len, y: yy), CGPoint(x: plot.midX + len, y: yy)], closed: false, stroke: th.gridStrong, fill: nil, width: 0.75, dash: nil))
        }
        grid.append(.path([CGPoint(x: plot.midX, y: plot.minY), CGPoint(x: plot.midX, y: plot.maxY)], closed: false, stroke: th.gridStrong, fill: nil, width: 0.75, dash: nil))
        grid.append(.path([CGPoint(x: plot.minX, y: plot.midY), CGPoint(x: plot.maxX, y: plot.midY)], closed: false, stroke: th.gridStrong, fill: nil, width: 0.75, dash: nil))
        d.items.append(.group(clip: nil, items: grid))

        func toPlot(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((p.x + 1) / 2) * plot.width, y: plot.minY + CGFloat(1 - (p.y + 1) / 2) * plot.height)
        }
        func yt(_ pts: [SIMD2<Float>]) -> [CGPoint] {
            Decimator.minMax(pts.map(toPlot), buckets: Int(plot.width), xRange: plot.minX...plot.maxX)
        }
        let pixelWidth = Double(plot.width) * 2
        var traces: [VItem] = []
        let lineW: CGFloat = 1.4

        if model.display.format == .xy {
            if let acq = model.acquisition, let a = acq.channel(0), let b = acq.channel(1) {
                let ca = s.channels[0], cb = s.channels[1]
                let pts = (0..<min(a.count, b.count)).map { i in
                    toPlot(SIMD2(Float((Double(a.volts[i]) / ca.unitsPerDivision + ca.offsetDivisions) / 5),
                                 Float((Double(b.volts[i]) / cb.unitsPerDivision + cb.offsetDivisions) / 5)))
                }
                traces.append(.path(pts, closed: false, stroke: th.xy, fill: nil, width: 1, dash: nil))
            }
        } else if let acq = model.acquisition {
            for (i, r) in model.references.enumerated() {
                guard let r, r.visible else { continue }
                let pts = TraceGeometry.polyline(values: r.waveform.values, t0: r.waveform.t0, dt: r.waveform.dt, settings: s,
                                                 perDiv: r.unitsPerDivision, offset: r.offsetDivisions, pixelWidth: pixelWidth)
                traces.append(.path(yt(pts), closed: false, stroke: th.refs[i].opacity(0.8), fill: nil, width: 1.1, dash: [5, 3]))
            }
            var order: [Trace] = Trace.allCases.filter { $0 != model.selectedTrace }
            order.append(model.selectedTrace)
            for trace in order where model.isVisible(trace) {
                let color = th.color(trace)
                if trace == .math {
                    guard let m = model.analysis.math else { continue }
                    let pts = TraceGeometry.polyline(values: m.values, t0: m.t0, dt: m.dt, settings: s,
                                                     perDiv: model.processing.math.unitsPerDivision,
                                                     offset: model.processing.math.offsetDivisions, pixelWidth: pixelWidth)
                    traces.append(.path(yt(pts), closed: false, stroke: color, fill: nil, width: lineW, dash: nil))
                    continue
                }
                let c = s.channels[trace.rawValue]
                guard let w = acq.channel(trace.rawValue) else { continue }
                if model.processing.mode == .average, model.display.showRawUnderAverage, let raw = model.rawAcquisition?.channel(trace.rawValue) {
                    let pts = TraceGeometry.polyline(values: raw.volts, t0: raw.t0, dt: raw.dt, settings: s,
                                                     perDiv: c.unitsPerDivision, offset: c.offsetDivisions, pixelWidth: pixelWidth)
                    traces.append(.path(yt(pts), closed: false, stroke: color.opacity(0.3), fill: nil, width: 0.8, dash: nil))
                }
                if let lo = w.envelopeMin, let hi = w.envelopeMax {
                    let strip = TraceGeometry.band(lo: lo, hi: hi, t0: w.t0, dt: w.dt, settings: s, perDiv: c.unitsPerDivision, offset: c.offsetDivisions)
                    var top: [CGPoint] = [], bottom: [CGPoint] = []
                    for k in stride(from: 0, to: strip.count - 1, by: 2) {
                        bottom.append(toPlot(strip[k])); top.append(toPlot(strip[k + 1]))
                    }
                    let topD = Decimator.minMax(top, buckets: Int(plot.width) / 2, xRange: plot.minX...plot.maxX)
                    let botD = Decimator.minMax(bottom, buckets: Int(plot.width) / 2, xRange: plot.minX...plot.maxX)
                    traces.append(.path(topD + botD.reversed(), closed: true, stroke: nil, fill: color.opacity(0.22), width: 0, dash: nil))
                }
                let pts = TraceGeometry.polyline(values: w.volts, t0: w.t0, dt: w.dt, settings: s,
                                                 perDiv: c.unitsPerDivision, offset: c.offsetDivisions, pixelWidth: pixelWidth)
                traces.append(.path(yt(pts), closed: false, stroke: color, fill: nil, width: lineW, dash: nil))
            }
        }

        // decode lanes along the bottom
        let map = ScreenMapping(size: plot.size, settings: s)
        let active = model.decoders.filter(\.enabled)
        if model.display.format == .yt {
            for (lane, dec) in active.enumerated() {
                let base = th.decoders[lane % th.decoders.count]
                let laneH: CGFloat = 16
                let top = plot.maxY - CGFloat(active.count - lane) * (laneH + 4) - 4
                traces.append(.path([CGPoint(x: plot.minX, y: top + laneH / 2), CGPoint(x: plot.maxX, y: top + laneH / 2)],
                                    closed: false, stroke: base.opacity(0.4), fill: nil, width: 0.75, dash: nil))
                guard let r = model.analysis.decodes[dec.id] else { continue }
                for e in r.events {
                    let x0 = max(plot.minX - 5, plot.minX + map.x(e.start)), x1 = min(plot.maxX + 5, plot.minX + map.x(e.end))
                    guard x1 > plot.minX, x0 < plot.maxX, x1 - x0 > 1 else { continue }
                    let k = min(3, (x1 - x0) / 2), mid = top + laneH / 2
                    let hex = [CGPoint(x: x0, y: mid), CGPoint(x: x0 + k, y: top), CGPoint(x: x1 - k, y: top),
                               CGPoint(x: x1, y: mid), CGPoint(x: x1 - k, y: top + laneH), CGPoint(x: x0 + k, y: top + laneH)]
                    let col = e.kind == .error || e.kind == .nack ? VColor(hex: 0xE5484D) : base
                    traces.append(.path(hex, closed: true, stroke: col, fill: col.opacity(0.18), width: 0.75, dash: nil))
                    let f = VFont(9, mono: true)
                    for label in [e.label, e.short] where VText.width(label, f) <= x1 - x0 - 6 {
                        traces.append(.text(label, at: CGPoint(x: (x0 + x1) / 2, y: mid + 3.2), font: f, color: th.text, anchor: .middle))
                        break
                    }
                }
                traces.append(.text(dec.kind.name, at: CGPoint(x: plot.minX + 4, y: top + laneH / 2 + 3.2), font: VFont(8, bold: true), color: base, anchor: .start))
            }
        }

        // cursors
        if model.display.format == .yt && model.display.cursorMode != .off {
            let c = model.cursors
            let trace = model.selectedTrace
            let sc = model.scale(of: trace), off = model.offset(of: trace)
            func yv(_ v: Double) -> CGFloat { plot.minY + map.y(value: v, perDiv: sc.perDiv, offset: off) }
            if model.display.cursorMode.showsTime {
                for (t, label) in [(c.t1, "A"), (c.t2, "B")] {
                    let x = plot.minX + map.x(t)
                    traces.append(.path([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)], closed: false, stroke: th.cursor, fill: nil, width: 0.9, dash: [4, 3]))
                    traces.append(.rect(CGRect(x: x - 7, y: plot.minY + 4, width: 14, height: 13), stroke: nil, fill: th.cursor, width: 0, radius: 2))
                    traces.append(.text(label, at: CGPoint(x: x, y: plot.minY + 14), font: VFont(9, bold: true), color: th.plot, anchor: .middle))
                }
            }
            var levels: [(Double, String)] = []
            switch model.display.cursorMode {
            case .amplitude, .both: levels = [(c.y1, "Y1"), (c.y2, "Y2")]
            case .track:
                for (t, label) in [(c.t1, "A"), (c.t2, "B")] { if let v = value(model, trace, at: t) { levels.append((v, label)) } }
            default: break
            }
            let col = th.color(trace)
            for (v, label) in levels {
                let yy = yv(v)
                traces.append(.path([CGPoint(x: plot.minX, y: yy), CGPoint(x: plot.maxX, y: yy)], closed: false, stroke: col.opacity(0.8), fill: nil, width: 0.9, dash: [4, 3]))
                traces.append(.rect(CGRect(x: plot.maxX - 28, y: yy - 7, width: 22, height: 13), stroke: nil, fill: col, width: 0, radius: 2))
                traces.append(.text(label, at: CGPoint(x: plot.maxX - 17, y: yy + 3.5), font: VFont(8, bold: true), color: th.plot, anchor: .middle))
            }
        }
        d.items.append(.group(clip: plot, items: traces))
        d.items.append(.rect(plot, stroke: th.gridStrong, fill: nil, width: 1, radius: 0))

        guard model.display.format == .yt else {
            d.text("XY: CH1 → X, CH2 → Y", CGPoint(x: plot.midX, y: plot.maxY + 16), VFont(10), th.secondary, .middle)
            return
        }

        // time axis labels (relative to the trigger)
        let tb = s.timebase
        for i in 0...10 {
            let t = s.screenStart + Double(i) * tb.secondsPerDivision
            let label = abs(t) < tb.secondsPerDivision * 1e-6 ? "0" : (t > 0 ? "+" : "") + Format.seconds(t)
            d.text(label, CGPoint(x: plot.minX + plot.width * CGFloat(i) / 10, y: plot.maxY + 15), VFont(9, mono: true), th.secondary, .middle)
        }

        // amplitude axis labels for the selected trace
        let sel = model.selectedTrace
        if model.isVisible(sel) {
            let sc = model.scale(of: sel), off = model.offset(of: sel)
            for i in stride(from: 5, through: -5, by: -1) {
                let v = (Double(i) - off) * sc.perDiv
                let yy = plot.minY + plot.height * CGFloat(5 - i) / 10
                d.text(Format.si(abs(v) < sc.perDiv * 1e-6 ? 0 : v, unit: sc.unit), CGPoint(x: plot.minX - 22, y: yy + 3.5), VFont(9, mono: true), th.color(sel), .end)
            }
        }

        // zero markers (left)
        for trace in Trace.allCases where model.isVisible(trace) {
            let yy = min(max(plot.minY + map.y(divs: model.offset(of: trace)), plot.minY), plot.maxY)
            let col = th.color(trace)
            d.items.append(.path([CGPoint(x: plot.minX - 16, y: yy - 6), CGPoint(x: plot.minX - 6, y: yy - 6), CGPoint(x: plot.minX, y: yy),
                                  CGPoint(x: plot.minX - 6, y: yy + 6), CGPoint(x: plot.minX - 16, y: yy + 6)],
                                 closed: true, stroke: nil, fill: col, width: 0, dash: nil))
            d.text(trace == .math ? "M" : "\(trace.rawValue + 1)", CGPoint(x: plot.minX - 10, y: yy + 3.5), VFont(9, bold: true), th.plot, .middle)
        }

        // trigger level (right) and position (top)
        if let ch = s.trigger.source.channel, s.channels[ch].enabled {
            let yy = min(max(plot.minY + map.y(volts: s.trigger.level, channel: ch), plot.minY), plot.maxY)
            d.items.append(.path([CGPoint(x: plot.maxX, y: yy), CGPoint(x: plot.maxX + 6, y: yy - 6), CGPoint(x: plot.maxX + 18, y: yy - 6),
                                  CGPoint(x: plot.maxX + 18, y: yy + 6), CGPoint(x: plot.maxX + 6, y: yy + 6)],
                                 closed: true, stroke: nil, fill: th.ch[ch], width: 0, dash: nil))
            d.text("T", CGPoint(x: plot.maxX + 12, y: yy + 3.5), VFont(9, bold: true), th.plot, .middle)
        }
        if !tb.isRollMode {
            let x = plot.minX + map.x(0)
            if x >= plot.minX && x <= plot.maxX {
                d.items.append(.path([CGPoint(x: x - 6, y: plot.minY - 9), CGPoint(x: x + 6, y: plot.minY - 9), CGPoint(x: x, y: plot.minY - 1)],
                                     closed: true, stroke: nil, fill: th.trigger, width: 0, dash: nil))
            }
        }
    }

    private static func value(_ model: ScopeModel, _ trace: Trace, at t: Double) -> Double? {
        switch trace {
        case .math: return model.analysis.math.map { Double($0.values[$0.index(at: t)]) }
        default: return model.acquisition?.channel(trace.rawValue).map { Double($0.volts[$0.index(at: t)]) }
        }
    }

    // MARK: - Text blocks

    static func triggerSummary(_ model: ScopeModel) -> String {
        let t = model.settings.trigger
        let level: String = t.source.channel.map { model.settings.channels[$0].format(t.level) } ?? Format.volts(t.level)
        if t.mode == .pulse && t.source != .ext {
            return "Trig \(t.source.rawValue) \(t.slope == .rising ? "+" : "−")pulse width \(t.pulseCondition.rawValue) \(Format.seconds(t.pulseWidth)) @ \(level) \(t.sweep.rawValue)"
        }
        return "Trig \(t.source.rawValue) \(t.slope == .rising ? "↑" : "↓") \(level) \(t.sweep.rawValue)"
    }

    private static func settingsRows(_ model: ScopeModel, _ th: ExportTheme) -> [(String, String, VColor)] {
        let s = model.settings
        var rows: [(String, String, VColor)] = []
        for ch in 0..<2 {
            let c = s.channels[ch]
            if c.enabled {
                let off = c.offsetDivisions * c.unitsPerDivision
                rows.append(("CH\(ch + 1)", "\(c.format(c.unitsPerDivision))/div  ·  \(c.coupling.rawValue)  ·  probe \(c.probeLabel)  ·  offset \(off >= 0 ? "+" : "")\(c.format(off))", th.ch[ch]))
            } else {
                rows.append(("CH\(ch + 1)", "off", th.secondary))
            }
        }
        let m = model.processing.math
        if m.enabled {
            let unit = model.analysis.math?.unit ?? ""
            rows.append(("MATH", "\(m.label)  ·  \(Format.si(m.unitsPerDivision, unit: unit))/div  ·  offset \(Format.number(m.offsetDivisions)) div", th.math))
        }
        for (i, r) in model.references.enumerated() {
            guard let r, r.visible else { continue }
            rows.append(("R\(i + 1)", "\(r.waveform.label)  ·  \(Format.si(r.unitsPerDivision, unit: r.waveform.unit))/div  ·  saved \(timeOnly(r.saved))", th.refs[i]))
        }
        let tb = s.timebase
        var horiz = "\(tb.label)  ·  \(Format.si(tb.sampleRate, unit: "Sa/s"))  ·  \(VDS1022.samplesPerFrame) pts"
        if tb.isRollMode { horiz += "  ·  roll" } else {
            let pos = (0.5 - s.triggerPosition) * tb.window
            horiz += abs(pos) < tb.secondsPerDivision * 1e-3 ? "  ·  trigger at centre"
                : "  ·  trigger \(Format.seconds(abs(pos))) \(pos > 0 ? "right" : "left") of centre"
            if tb.isZoomed { horiz += "  ·  sin(x)/x" }
        }
        rows.append(("Time", horiz, th.secondary))
        rows.append(("Trigger", triggerSummary(model).replacingOccurrences(of: "Trig ", with: "") + "  ·  holdoff \(Format.seconds(s.trigger.holdoff))", th.secondary))
        var acq = model.acquireMode.rawValue
        if model.acquireMode == .average {
            let n = model.acquisition?.channels.compactMap { $0 }.first?.accumulated ?? 0
            acq += " \(model.processing.averages)  (\(min(n, model.processing.averages)) combined)"
        } else if model.acquireMode == .envelope {
            acq += "  (\(model.acquisition?.channels.compactMap { $0 }.first?.accumulated ?? 0) captures)"
        }
        rows.append(("Acquire", acq + "  ·  measure over \(model.processing.gate.rawValue.lowercased())", th.secondary))
        if !model.decoders.isEmpty {
            let decs = model.decoders.filter(\.enabled).map { d -> String in
                let summary = model.analysis.decodes[d.id]?.summary ?? ""
                return "\(d.kind.name) (\(summary))"
            }
            if !decs.isEmpty { rows.append(("Decode", decs.joined(separator: "  ·  "), th.secondary)) }
        }
        return rows
    }

    private static func cursorLines(_ model: ScopeModel) -> [(String, String)]? {
        let c = model.cursors
        let mode = model.display.cursorMode
        let trace = model.selectedTrace
        let unit = model.scale(of: trace).unit
        var out: [(String, String)] = []
        let dt = c.t2 - c.t1
        if mode.showsTime {
            out.append(("A", Format.seconds(c.t1)))
            out.append(("B", Format.seconds(c.t2)))
            out.append(("Δt", Format.seconds(abs(dt))))
            out.append(("1/Δt", dt != 0 ? Format.hertz(1 / abs(dt)) : "—"))
        }
        var ys: (Double, Double)?
        switch mode {
        case .amplitude, .both: ys = (c.y1, c.y2)
        case .track: if let a = value(model, trace, at: c.t1), let b = value(model, trace, at: c.t2) { ys = (a, b) }
        default: break
        }
        if let (a, b) = ys {
            out.append((mode == .track ? "Y at A" : "Y1", Format.si(a, unit: unit)))
            out.append((mode == .track ? "Y at B" : "Y2", Format.si(b, unit: unit)))
            out.append(("ΔY", Format.si(b - a, unit: unit)))
            if mode.showsTime && dt != 0 { out.append(("ΔY/Δt", Format.si((b - a) / dt, unit: unit + "/s"))) }
        }
        return out
    }

    private static func drawMeasurements(_ d: inout VDrawing, _ model: ScopeModel, _ th: ExportTheme, top: CGFloat) -> CGFloat {
        let kinds = model.display.measurements.filter { $0.group != .cross }
        let traces = Trace.allCases.filter { model.isVisible($0) }
        guard !kinds.isEmpty, !traces.isEmpty else { return top }
        var y = top
        d.text("MEASUREMENTS", CGPoint(x: margin, y: y + 11), VFont(10, bold: true), th.secondary)
        y += 20

        func values(_ t: Trace) -> (ChannelMeasurements?, String) {
            t == .math ? (model.analysis.mathMeasurements, model.analysis.math?.unit ?? "")
                       : (model.analysis.measurements[t.rawValue], model.settings.channels[t.rawValue].unit.symbol)
        }
        let valueFont = VFont(11, mono: true), headFont = VFont(10, bold: true)
        // column widths
        let firstW: CGFloat = 64
        var widths: [CGFloat] = kinds.map { k in
            var w = VText.width(k.rawValue, headFont)
            for t in traces { let (m, u) = values(t); w = max(w, VText.width(k.format(m?[k], unit: u), valueFont)) }
            return w + 22
        }
        // split into blocks that fit the page width
        var blocks: [[Int]] = [[]]
        var used = firstW
        for (i, w) in widths.enumerated() {
            if used + w > width - 2 * margin, !blocks[blocks.count - 1].isEmpty { blocks.append([]); used = firstW }
            blocks[blocks.count - 1].append(i)
            used += w
        }
        for block in blocks {
            // stretch columns to fill the width
            let total = firstW + block.reduce(0) { $0 + widths[$1] }
            let extra = (width - 2 * margin - total) / CGFloat(max(1, block.count))
            if extra > 0 { for i in block { widths[i] += extra } }
            let rowH: CGFloat = 20
            let tableH = rowH * CGFloat(traces.count + 1)
            d.items.append(.rect(CGRect(x: margin, y: y, width: width - 2 * margin, height: tableH), stroke: th.panelStroke, fill: th.panel, width: 1, radius: 5))
            var x = margin + firstW
            for i in block {
                d.text(kinds[i].rawValue, CGPoint(x: x + 8, y: y + 14), headFont, th.secondary)
                x += widths[i]
            }
            for (r, t) in traces.enumerated() {
                let ry = y + rowH * CGFloat(r + 1)
                d.line(CGPoint(x: margin, y: ry), CGPoint(x: width - margin, y: ry), th.panelStroke, width: 0.5)
                d.text(t.name, CGPoint(x: margin + 10, y: ry + 14), VFont(11, bold: true), th.color(t))
                let (m, u) = values(t)
                var cx = margin + firstW
                for i in block {
                    d.text(kinds[i].format(m?[kinds[i]], unit: u), CGPoint(x: cx + 8, y: ry + 14), valueFont, th.text)
                    cx += widths[i]
                }
            }
            y += tableH + 10
        }

        // CH1 -> CH2
        if model.settings.channels[0].enabled && model.settings.channels[1].enabled,
           model.display.measurements.contains(where: { $0.group == .cross }), let c = model.analysis.cross {
            var parts: [String] = []
            if model.display.measurements.contains(.delay) { parts.append("Delay \(MeasurementKind.delay.format(c.delay, unit: ""))") }
            if model.display.measurements.contains(.phase) { parts.append("Phase \(MeasurementKind.phase.format(c.phase, unit: ""))") }
            d.text("CH1 → CH2", CGPoint(x: margin + 10, y: y + 12), VFont(11, bold: true), th.text)
            d.text(parts.joined(separator: "    "), CGPoint(x: margin + firstW + 30, y: y + 12), valueFont, th.text)
            y += 24
        }
        return y + 6
    }

    private static func drawStatistics(_ d: inout VDrawing, _ model: ScopeModel, _ th: ExportTheme, top: CGFloat) -> CGFloat {
        var rows: [(String, MeasurementKind, String, MeasurementStatistics.Stat, VColor)] = []
        for t in Trace.allCases where model.isVisible(t) {
            let unit = t == .math ? (model.analysis.math?.unit ?? "") : model.settings.channels[t.rawValue].unit.symbol
            for k in model.display.measurements where k.group != .cross {
                if let st = model.statistics[t.name, k], st.count > 1 { rows.append((t.name, k, unit, st, th.color(t))) }
            }
        }
        for k in model.display.measurements where k.group == .cross {
            if let st = model.statistics["CH1→CH2", k], st.count > 1 { rows.append(("CH1→CH2", k, "", st, th.text)) }
        }
        guard !rows.isEmpty else { return top }
        var y = top
        let n = rows.map(\.3.count).max() ?? 0
        d.text("STATISTICS  ·  \(n) acquisitions", CGPoint(x: margin, y: y + 11), VFont(10, bold: true), th.secondary)
        y += 20
        let headers = ["Source", "Measurement", "Current", "Mean", "Min", "Max", "σ", "Count"]
        let fracs: [CGFloat] = [0.11, 0.15, 0.13, 0.13, 0.13, 0.13, 0.13, 0.09]
        let tw = width - 2 * margin
        let rowH: CGFloat = 19
        let h = rowH * CGFloat(rows.count + 1)
        d.items.append(.rect(CGRect(x: margin, y: y, width: tw, height: h), stroke: th.panelStroke, fill: th.panel, width: 1, radius: 5))
        var x = margin
        for (i, hd) in headers.enumerated() {
            d.text(hd, CGPoint(x: x + 10, y: y + 13), VFont(10, bold: true), th.secondary)
            x += tw * fracs[i]
        }
        for (r, row) in rows.enumerated() {
            let ry = y + rowH * CGFloat(r + 1)
            d.line(CGPoint(x: margin, y: ry), CGPoint(x: width - margin, y: ry), th.panelStroke, width: 0.5)
            let (src, k, unit, st, color) = row
            let f: (Double) -> String = { k.format($0, unit: unit) }
            let sigma = k.group == .count ? String(format: "%.2f", st.std) : f(st.std)
            let cells = [src, k.rawValue, f(st.last), f(st.mean), f(st.min), f(st.max), sigma, "\(st.count)"]
            var cx = margin
            for (i, cell) in cells.enumerated() {
                let font = i == 0 ? VFont(10.5, bold: true) : i == 1 ? VFont(10.5) : VFont(10.5, mono: true)
                d.text(cell, CGPoint(x: cx + 10, y: ry + 13), font, i == 0 ? color : th.text)
                cx += tw * fracs[i]
            }
        }
        return y + h + 12
    }

    static func timestamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    private static func timeOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
