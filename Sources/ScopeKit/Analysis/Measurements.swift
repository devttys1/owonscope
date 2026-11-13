import Accelerate
import Foundation

public enum MeasurementKind: String, CaseIterable, Codable, Sendable, Identifiable {
    // horizontal
    case frequency = "Freq", period = "Period"
    case posWidth = "+Width", negWidth = "−Width", duty = "Duty"
    case rise = "Rise", fall = "Fall"
    // vertical
    case pkpk = "Pk-Pk", peak = "Peak", max = "Max", min = "Min"
    case amplitude = "Amplitude", top = "Top", base = "Base"
    case mean = "Mean", cycleMean = "Cycle Mean"
    case rms = "RMS", acRMS = "AC RMS", cycleRMS = "Cycle RMS"
    case crest = "Crest", overshoot = "Overshoot", preshoot = "Preshoot"
    case area = "Area"
    // counts
    case posPulses = "+Pulses", negPulses = "−Pulses", risingEdges = "↑Edges", fallingEdges = "↓Edges"
    // between channels (CH1 → CH2)
    case delay = "Delay", phase = "Phase"

    public var id: String { rawValue }

    public static let defaults: [MeasurementKind] = [.frequency, .pkpk, .peak, .rms, .mean, .duty, .rise]

    public enum Group: String, CaseIterable { case horizontal = "Time", vertical = "Amplitude", count = "Count", cross = "CH1 → CH2" }

    /// Measurements that apply to a single trace.
    public static let perTrace = allCases.filter { $0.group != .cross }

    public var group: Group {
        switch self {
        case .frequency, .period, .posWidth, .negWidth, .duty, .rise, .fall: .horizontal
        case .posPulses, .negPulses, .risingEdges, .fallingEdges: .count
        case .delay, .phase: .cross
        default: .vertical
        }
    }

    public var help: String {
        switch self {
        case .pkpk: "Peak-to-peak: Max − Min"
        case .peak: "Largest absolute value, max(|Max|, |Min|)"
        case .rms: "True RMS including DC"
        case .acRMS: "RMS of the AC component (DC removed)"
        case .cycleRMS: "RMS over a whole number of periods"
        case .cycleMean: "Mean over a whole number of periods"
        case .crest: "Crest factor: Peak / AC RMS"
        case .overshoot: "(Max − Top) / Amplitude"
        case .preshoot: "(Base − Min) / Amplitude"
        case .top, .base: "Histogram-based high / low level"
        case .area: "Integral of the signal over the record"
        case .delay: "Time from a CH1 rising edge to the next CH2 rising edge"
        case .phase: "Phase of CH2 relative to CH1"
        default: rawValue
        }
    }

    public func format(_ v: Double?, unit: String) -> String {
        guard let v, v.isFinite else { return "—" }
        switch self {
        case .frequency: return Format.hertz(v)
        case .period, .posWidth, .negWidth, .rise, .fall, .delay: return Format.seconds(v)
        case .phase: return String(format: "%.1f°", v)
        case .duty, .overshoot, .preshoot: return String(format: "%.1f %%", v * 100)
        case .crest: return String(format: "%.2f", v)
        case .posPulses, .negPulses, .risingEdges, .fallingEdges: return String(Int(v))
        case .area: return Format.si(v, unit: unit + "·s")
        default: return Format.si(v, unit: unit)
        }
    }
}

public struct ChannelMeasurements: Sendable {
    public var values: [MeasurementKind: Double] = [:]
    public subscript(_ k: MeasurementKind) -> Double? { values[k] }
    public init() {}
}

/// Measurements between two channels.
public struct CrossMeasurements: Sendable {
    /// Time from a rising edge of A to the next rising edge of B (averaged).
    public var delay: Double?
    /// Phase of B relative to A in degrees (−180...180).
    public var phase: Double?
    public init() {}
}

public enum Measurements {
    /// Measurements of a channel waveform.
    public static func compute(_ w: ChannelWaveform) -> ChannelMeasurements {
        compute(values: w.volts, dt: w.dt, resolution: w.settings.voltsPerCount, frequencyMeter: w.frequencyMeter)
    }

    /// Measurements of any sampled signal. `resolution` is the smallest meaningful step
    /// (used to decide whether there is a signal at all).
    public static func compute(values v: [Float], dt: Double, resolution: Double, frequencyMeter: Double? = nil) -> ChannelMeasurements {
        var m = ChannelMeasurements()
        let n = v.count
        guard n > 2 else { return m }

        var mx: Float = 0, mn: Float = 0, mean: Float = 0, rms: Float = 0
        vDSP_maxv(v, 1, &mx, vDSP_Length(n))
        vDSP_minv(v, 1, &mn, vDSP_Length(n))
        vDSP_meanv(v, 1, &mean, vDSP_Length(n))
        vDSP_rmsqv(v, 1, &rms, vDSP_Length(n))
        let acRMS = sqrt(max(0, Double(rms) * Double(rms) - Double(mean) * Double(mean)))
        m.values[.max] = Double(mx)
        m.values[.min] = Double(mn)
        m.values[.pkpk] = Double(mx - mn)
        m.values[.peak] = Double(Swift.max(abs(mx), abs(mn)))
        m.values[.mean] = Double(mean)
        m.values[.rms] = Double(rms)
        m.values[.acRMS] = acRMS
        m.values[.area] = Double(mean) * Double(n) * dt
        if acRMS > resolution { m.values[.crest] = Double(Swift.max(abs(mx - mean), abs(mn - mean))) / acRMS }

        let (base, top) = levels(values: v, resolution: resolution)
        m.values[.top] = top
        m.values[.base] = base
        let amp = top - base
        m.values[.amplitude] = amp

        guard amp > resolution * 8 else { return m }
        m.values[.overshoot] = Swift.max(0, (Double(mx) - top) / amp)
        m.values[.preshoot] = Swift.max(0, (base - Double(mn)) / amp)

        let mid = base + amp * 0.5
        let crossings = edges(v, level: mid, hysteresis: amp * 0.1)
        let rises = crossings.filter { $0.rising }.map(\.position)
        let falls = crossings.filter { !$0.rising }.map(\.position)
        m.values[.risingEdges] = Double(rises.count)
        m.values[.fallingEdges] = Double(falls.count)

        if let f = frequencyMeter, f > 0 {
            m.values[.frequency] = f
            m.values[.period] = 1 / f
        }
        var pulsesPos = 0, pulsesNeg = 0
        var pos: [Double] = [], neg: [Double] = []
        for c in zip(crossings, crossings.dropFirst()) {
            let width = (c.1.position - c.0.position) * dt
            if c.0.rising && !c.1.rising { pos.append(width); pulsesPos += 1 }
            if !c.0.rising && c.1.rising { neg.append(width); pulsesNeg += 1 }
        }
        m.values[.posPulses] = Double(pulsesPos)
        m.values[.negPulses] = Double(pulsesNeg)

        if rises.count >= 2 || falls.count >= 2 {
            let r = rises.count >= 2 ? rises : falls
            let periodSamples = (r.last! - r.first!) / Double(r.count - 1)
            if m.values[.frequency] == nil {
                m.values[.period] = periodSamples * dt
                m.values[.frequency] = 1 / (periodSamples * dt)
            }
            if !pos.isEmpty { m.values[.posWidth] = pos.reduce(0, +) / Double(pos.count) }
            if !neg.isEmpty { m.values[.negWidth] = neg.reduce(0, +) / Double(neg.count) }
            if let p = m.values[.posWidth], let q = m.values[.negWidth] { m.values[.duty] = p / (p + q) }

            // cycle mean / RMS over the whole periods between the first and last crossing
            let a = Int(r.first!.rounded()), b = Int(r.last!.rounded())
            if b > a + 2 {
                let cycle = Array(v[a..<b])
                var cm: Float = 0, cr: Float = 0
                vDSP_meanv(cycle, 1, &cm, vDSP_Length(cycle.count))
                vDSP_rmsqv(cycle, 1, &cr, vDSP_Length(cycle.count))
                m.values[.cycleMean] = Double(cm)
                m.values[.cycleRMS] = Double(cr)
            }
        }

        m.values[.rise] = transition(v, dt: dt, from: base + amp * 0.1, to: base + amp * 0.9, rising: true, at: rises)
        m.values[.fall] = transition(v, dt: dt, from: base + amp * 0.9, to: base + amp * 0.1, rising: false, at: falls)
        return m
    }

    /// Delay and phase from channel `a` to channel `b` (rising edges at the 50 % levels).
    public static func cross(_ a: ChannelWaveform, _ b: ChannelWaveform) -> CrossMeasurements {
        var out = CrossMeasurements()
        guard a.count > 2, b.count > 2, abs(a.dt - b.dt) < a.dt * 1e-6 else { return out }
        func risingTimes(_ w: ChannelWaveform) -> [Double]? {
            let (lo, hi) = levels(values: w.volts, resolution: w.settings.voltsPerCount)
            guard hi - lo > w.settings.voltsPerCount * 8 else { return nil }
            return edges(w.volts, level: (lo + hi) / 2, hysteresis: (hi - lo) * 0.1)
                .filter(\.rising).map { w.t0 + $0.position * w.dt }
        }
        guard let ra = risingTimes(a), let rb = risingTimes(b), !ra.isEmpty, !rb.isEmpty else { return out }
        var delays: [Double] = []
        for t in ra { if let next = rb.first(where: { $0 >= t }) { delays.append(next - t) } }
        guard !delays.isEmpty else { return out }
        delays.sort()
        let d = delays[delays.count / 2]
        out.delay = d
        if ra.count >= 2 {
            let period = (ra.last! - ra.first!) / Double(ra.count - 1)
            var ph = d / period * 360
            if ph > 180 { ph -= 360 }
            out.phase = ph
        }
        return out
    }

    /// Base and top levels from the histogram modes of the lower and upper halves.
    public static func levels(_ w: ChannelWaveform) -> (Double, Double) {
        levels(values: w.volts, resolution: w.settings.voltsPerCount)
    }

    public static func levels(values v: [Float], resolution: Double) -> (Double, Double) {
        guard let lo = v.min(), let hi = v.max() else { return (0, 0) }
        let span = Double(hi - lo)
        guard span > resolution * 2 else { return (Double(lo), Double(hi)) }
        // bins of about one ADC count (finer for averaged data is pointless for the mode)
        let bins = Swift.max(16, Swift.min(512, Int(span / Swift.max(resolution, 1e-12))))
        var hist = [Int](repeating: 0, count: bins + 1)
        let scale = Double(bins) / span
        var sum = 0.0
        for x in v {
            hist[Int((Double(x - lo) * scale))] += 1
            sum += Double(x)
        }
        let meanIdx = Swift.min(bins, Swift.max(0, Int((sum / Double(v.count) - Double(lo)) * scale)))
        let loIdx = (0...meanIdx).max { hist[$0] < hist[$1] } ?? 0
        let hiIdx = (meanIdx...bins).max { hist[$0] < hist[$1] } ?? bins
        // a flat (sine-like) histogram has no clear levels: use min/max
        if hist[loIdx] < v.count / 50 || hist[hiIdx] < v.count / 50 { return (Double(lo), Double(hi)) }
        return (Double(lo) + (Double(loIdx) + 0.5) / scale, Double(lo) + (Double(hiIdx) + 0.5) / scale)
    }

    public struct Edge: Sendable { public var position: Double; public var rising: Bool }

    /// Level crossings with hysteresis, interpolated to sub-sample position.
    public static func edges(_ v: [Float], level: Double, hysteresis: Double) -> [Edge] {
        var out: [Edge] = []
        let hi = Float(level + hysteresis / 2), lo = Float(level - hysteresis / 2), l = Float(level)
        guard let first = v.first else { return out }
        var state = first > l
        for i in 1..<v.count {
            if !state && v[i] > hi {
                state = true
                out.append(Edge(position: interpolate(v, before: i, level: l), rising: true))
            } else if state && v[i] < lo {
                state = false
                out.append(Edge(position: interpolate(v, before: i, level: l), rising: false))
            }
        }
        return out
    }

    private static func interpolate(_ v: [Float], before i: Int, level: Float) -> Double {
        var j = i
        while j > 0 && (v[j - 1] - level) * (v[i] - level) > 0 { j -= 1 }
        guard j > 0 else { return Double(i) }
        let a = v[j - 1], b = v[j]
        let frac = b == a ? 0 : Double((level - a) / (b - a))
        return Double(j - 1) + frac
    }

    private static func transition(_ v: [Float], dt: Double, from: Double, to: Double, rising: Bool, at mids: [Double]) -> Double? {
        var times: [Double] = []
        let f = Float(from), t = Float(to)
        for m in mids {
            let c = Int(m)
            guard c > 0, c < v.count - 1 else { continue }
            // interpolated threshold crossings either side of the mid crossing
            var a = c, b = c
            while a > 0 && (rising ? v[a] > f : v[a] < f) { a -= 1 }
            while b < v.count - 1 && (rising ? v[b] < t : v[b] > t) { b += 1 }
            guard a > 0, b < v.count - 1 else { continue }
            let ta = Double(a) + Double((f - v[a]) / (v[a + 1] - v[a] == 0 ? 1 : v[a + 1] - v[a]))
            let tb = Double(b - 1) + Double((t - v[b - 1]) / (v[b] - v[b - 1] == 0 ? 1 : v[b] - v[b - 1]))
            times.append(Swift.max(0, tb - ta) * dt)
        }
        guard !times.isEmpty else { return nil }
        return times.sorted()[times.count / 2]
    }

    /// Software frequency estimate (used when the hardware meter is unavailable).
    public static func frequency(_ w: ChannelWaveform) -> Double? {
        compute(values: w.volts, dt: w.dt, resolution: w.settings.voltsPerCount)[.frequency]
    }
}

/// Running statistics (Welford) for each measurement.
public struct MeasurementStatistics: Sendable {
    public struct Key: Hashable, Sendable { public var source: String; public var kind: MeasurementKind }
    public struct Stat: Sendable {
        public var count = 0
        public var mean = 0.0
        public var m2 = 0.0
        public var min = Double.infinity
        public var max = -Double.infinity
        public var last = 0.0
        public var std: Double { count > 1 ? sqrt(m2 / Double(count - 1)) : 0 }

        mutating func add(_ x: Double) {
            count += 1
            let d = x - mean
            mean += d / Double(count)
            m2 += d * (x - mean)
            min = Swift.min(min, x)
            max = Swift.max(max, x)
            last = x
        }
    }

    public private(set) var stats: [Key: Stat] = [:]
    public init() {}

    public mutating func add(source: String, _ m: ChannelMeasurements) {
        for (k, v) in m.values where v.isFinite { stats[Key(source: source, kind: k), default: Stat()].add(v) }
    }

    public mutating func add(source: String, kind: MeasurementKind, _ v: Double?) {
        guard let v, v.isFinite else { return }
        stats[Key(source: source, kind: kind), default: Stat()].add(v)
    }

    public subscript(source: String, kind: MeasurementKind) -> Stat? { stats[Key(source: source, kind: kind)] }

    public mutating func reset() { stats.removeAll() }
}
