import ScopeKit
import SwiftUI

struct MeasurementsBar: View {
    @Bindable var model: ScopeModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Trace.allCases, id: \.self) { trace in
                    if model.isVisible(trace) { row(trace) }
                }
                if model.settings.channels[0].enabled && model.settings.channels[1].enabled,
                   model.display.measurements.contains(where: { $0.group == .cross }) {
                    crossRow
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(MeasurementKind.Group.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(MeasurementKind.allCases.filter { $0.group == group }) { k in
                            Toggle(k.rawValue, isOn: Binding(
                                get: { model.display.measurements.contains(k) },
                                set: { on in
                                    if on { model.display.measurements.append(k) } else { model.display.measurements.removeAll { $0 == k } }
                                    model.display.measurements.sort { MeasurementKind.allCases.firstIndex(of: $0)! < MeasurementKind.allCases.firstIndex(of: $1)! }
                                }))
                        }
                    }
                }
                Divider()
                Button("Reset to Defaults") { model.display.measurements = MeasurementKind.defaults }
            } label: {
                Image(systemName: "ruler")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose measurements")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func values(_ trace: Trace) -> (ChannelMeasurements?, String) {
        switch trace {
        case .math: return (model.analysis.mathMeasurements, model.analysis.math?.unit ?? "")
        default: return (model.analysis.measurements[trace.rawValue], model.settings.channels[trace.rawValue].unit.symbol)
        }
    }

    private func row(_ trace: Trace) -> some View {
        let color = Theme.traceColor(trace)
        let (m, unit) = values(trace)
        return HStack(spacing: 4) {
            Button { model.selectTrace(trace) } label: {
                Text(trace.name)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .frame(minWidth: 40)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(model.selectedTrace == trace ? 1 : 0.75)))
            }
            .buttonStyle(.plain)
            ForEach(model.display.measurements.filter { $0.group != .cross }) { k in
                cell(k.rawValue, k.format(m?[k], unit: unit), color, help: k.help)
            }
        }
    }

    private var crossRow: some View {
        let c = model.analysis.cross
        return HStack(spacing: 4) {
            Text("1→2")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .frame(minWidth: 40)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.7)))
            if model.display.measurements.contains(.delay) {
                cell("Delay", MeasurementKind.delay.format(c?.delay, unit: ""), .white, help: MeasurementKind.delay.help)
            }
            if model.display.measurements.contains(.phase) {
                cell("Phase", MeasurementKind.phase.format(c?.phase, unit: ""), .white, help: MeasurementKind.phase.help)
            }
        }
    }

    private func cell(_ name: String, _ value: String, _ color: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(minWidth: 78, alignment: .leading)
        .padding(.horizontal, 4)
        .help(help)
    }
}

struct StatRow: Identifiable {
    var id: String { source + kind.rawValue }
    var source: String
    var kind: MeasurementKind
    var unit: String
    var stat: MeasurementStatistics.Stat
    var color: Color
}

/// Measurement statistics (premium-scope style): current, mean, min, max, σ, count.
struct MeasureTable: View {
    var model: ScopeModel

    var rows: [StatRow] {
        var out: [StatRow] = []
        let kinds = model.display.measurements
        for trace in Trace.allCases where model.isVisible(trace) {
            let unit = trace == .math ? (model.analysis.math?.unit ?? "") : model.settings.channels[trace.rawValue].unit.symbol
            for k in kinds where k.group != .cross {
                if let st = model.statistics[trace.name, k] {
                    out.append(StatRow(source: trace.name, kind: k, unit: unit, stat: st, color: Theme.traceColor(trace)))
                }
            }
        }
        for k in kinds where k.group == .cross {
            if let st = model.statistics["CH1→CH2", k] {
                out.append(StatRow(source: "CH1→CH2", kind: k, unit: "", stat: st, color: .white))
            }
        }
        return out
    }

    var body: some View {
        Table(rows) {
            TableColumn("Source") { r in Text(r.source).foregroundStyle(r.color).font(.system(size: 11, weight: .semibold)) }
                .width(min: 60, ideal: 70)
            TableColumn("Measurement") { r in Text(r.kind.rawValue).font(.system(size: 11)).help(r.kind.help) }
                .width(min: 80, ideal: 100)
            TableColumn("Current") { r in mono(r.kind.format(r.stat.last, unit: r.unit)) }
            TableColumn("Mean") { r in mono(r.kind.format(r.stat.mean, unit: r.unit)) }
            TableColumn("Min") { r in mono(r.kind.format(r.stat.min, unit: r.unit)) }
            TableColumn("Max") { r in mono(r.kind.format(r.stat.max, unit: r.unit)) }
            TableColumn("σ") { r in mono(r.kind.group == .count ? String(format: "%.2f", r.stat.std) : r.kind.format(r.stat.std, unit: r.unit)) }
            TableColumn("Count") { r in mono("\(r.stat.count)") }.width(min: 50, ideal: 60)
        }
    }

    private func mono(_ s: String) -> some View { Text(s).font(.system(size: 11, design: .monospaced)) }
}

struct BottomPanel: View {
    @Bindable var model: ScopeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.display.bottomTab) {
                    ForEach(BottomTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
                Spacer()
                switch model.display.bottomTab {
                case .decode:
                    Button("Copy", systemImage: "doc.on.doc", action: model.copyDecodedText)
                        .disabled(model.decoders.isEmpty)
                case .spectrum:
                    Picker("", selection: $model.display.spectrumChannel) { Text("CH1").tag(0); Text("CH2").tag(1) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 100)
                    Picker("", selection: $model.display.spectrumWindow) {
                        ForEach(FFTWindow.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 110)
                    Toggle("Log f", isOn: $model.display.spectrumLogFrequency).toggleStyle(.checkbox)
                case .measure:
                    Text("Statistics since the last settings change").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Reset", systemImage: "arrow.counterclockwise", action: model.resetStatistics)
                case .log:
                    EmptyView()
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            switch model.display.bottomTab {
            case .decode: DecodeTable(model: model)
            case .measure: MeasureTable(model: model)
            case .spectrum: SpectrumView(model: model)
            case .log: LogView(lines: model.log)
            }
        }
    }
}

struct DecodeRow: Identifiable {
    var id: UUID
    var time: Double
    var decoder: String
    var kind: String
    var label: String
    var color: Color
}

struct DecodeTable: View {
    var model: ScopeModel

    var rows: [DecodeRow] {
        var out: [DecodeRow] = []
        for (i, d) in model.decoders.enumerated() where d.enabled {
            guard let r = model.analysis.decodes[d.id] else { continue }
            let color = Theme.decoderPalette[i % Theme.decoderPalette.count]
            for e in r.events where e.kind != .ack {
                out.append(DecodeRow(id: e.id, time: e.start, decoder: d.kind.name, kind: e.kind.rawValue, label: e.label, color: color))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    var body: some View {
        if model.decoders.isEmpty {
            ContentUnavailableView("No decoders", systemImage: "waveform.path.badge.plus",
                                   description: Text("Add UART, I²C or SPI in the inspector."))
        } else {
            HStack(spacing: 0) {
                Table(rows) {
                    TableColumn("Time") { r in
                        Text(Format.seconds(r.time)).font(.system(size: 11, design: .monospaced))
                    }.width(min: 80, ideal: 100)
                    TableColumn("Decoder") { r in
                        Text(r.decoder).foregroundStyle(r.color).font(.system(size: 11, weight: .semibold))
                    }.width(min: 50, ideal: 60)
                    TableColumn("Type") { r in Text(r.kind).font(.system(size: 11)).foregroundStyle(.secondary) }
                        .width(min: 50, ideal: 60)
                    TableColumn("Value") { r in Text(r.label).font(.system(size: 11, design: .monospaced)) }
                }
                if let text = uartText, !text.isEmpty {
                    Divider()
                    ScrollView {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(width: 260)
                    .background(Color.black.opacity(0.25))
                }
            }
        }
    }

    /// Text of the first UART decoder, as a mini terminal.
    private var uartText: String? {
        for d in model.decoders where d.enabled {
            if case .uart = d.kind, let r = model.analysis.decodes[d.id] {
                return UARTDecoder.text(r.events)
            }
        }
        return nil
    }
}

struct SpectrumView: View {
    var model: ScopeModel

    var body: some View {
        let ch = model.display.spectrumChannel
        let color = Theme.channelColor(ch)
        let logF = model.display.spectrumLogFrequency
        ZStack(alignment: .topTrailing) {
            Canvas { ctx, size in
                let plot = CGRect(x: 44, y: 8, width: size.width - 54, height: size.height - 28)
                let dbTop: Float = 20, dbBottom: Float = -100
                func y(_ db: Float) -> CGFloat { plot.minY + CGFloat((dbTop - max(dbBottom, min(dbTop, db))) / (dbTop - dbBottom)) * plot.height }

                // grid
                var grid = Path()
                for db in stride(from: dbTop, through: dbBottom, by: -20) {
                    grid.move(to: CGPoint(x: plot.minX, y: y(db))); grid.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                    ctx.draw(Text("\(Int(db))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                             at: CGPoint(x: plot.minX - 4, y: y(db)), anchor: .trailing)
                }
                ctx.stroke(grid, with: .color(.white.opacity(0.08)))
                ctx.draw(Text("dBV").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 4, y: plot.minY), anchor: .topLeading)

                guard let s = model.analysis.spectrum, s.dbv.count > 2 else { return }
                let fMax = s.maxFrequency
                let fMin = logF ? max(s.binWidth, fMax / 1e4) : 0
                func x(_ f: Double) -> CGFloat {
                    if logF { return plot.minX + CGFloat(log10(max(f, fMin) / fMin) / log10(fMax / fMin)) * plot.width }
                    return plot.minX + CGFloat(f / fMax) * plot.width
                }
                // frequency labels
                for k in 0...5 {
                    let f = logF ? fMin * pow(fMax / fMin, Double(k) / 5) : fMax * Double(k) / 5
                    ctx.draw(Text(Format.hertz(f)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(f), y: plot.maxY + 4), anchor: .top)
                }
                var path = Path()
                for (i, db) in s.dbv.enumerated() {
                    let p = CGPoint(x: x(Double(i) * s.binWidth), y: y(db))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                var fill = path
                fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                fill.closeSubpath()
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
                ctx.stroke(path, with: .color(color), lineWidth: 1.2)
                if let pf = s.peakFrequency, let pdb = s.peakDBV {
                    let pt = CGPoint(x: x(pf), y: y(pdb))
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)), with: .color(.white))
                }
            }
            if let s = model.analysis.spectrum, let pf = s.peakFrequency, let pdb = s.peakDBV {
                Text("Peak \(Format.hertz(pf))  \(String(format: "%.1f", pdb)) dBV   RBW \(Format.hertz(s.binWidth))")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.4)))
                    .padding(8)
            }
        }
        .background(Theme.screen)
    }
}

struct LogView: View {
    var lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                        Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}
