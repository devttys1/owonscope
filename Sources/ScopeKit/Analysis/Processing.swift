import Accelerate
import Foundation

// MARK: - Acquisition modes

/// Waveform acquisition mode. `peak` is done in hardware; `average` and `envelope`
/// combine successive triggered acquisitions in software.
public enum AcquireMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal", peak = "Peak", average = "Average", envelope = "Envelope"
}

/// Which part of the record measurements use.
public enum MeasureGate: String, Codable, CaseIterable, Sendable {
    case record = "Record", screen = "Screen", cursors = "Cursors"
}

public struct ProcessingSettings: Codable, Equatable, Sendable {
    public var mode: AcquireMode = .normal
    /// Number of acquisitions averaged (exponential after the first N).
    public var averages: Int = 16
    public var math = MathSettings()
    public var gate: MeasureGate = .record
    public init() {}

    enum CodingKeys: String, CodingKey { case mode, averages, math, gate }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProcessingSettings()
        mode = c.value(.mode, d.mode)
        averages = c.value(.averages, d.averages)
        math = c.value(.math, d.math)
        gate = c.value(.gate, d.gate)
    }

    public static let averageCounts = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024]
}

/// Averages or envelopes successive acquisitions. Not thread safe: use from one thread.
public final class WaveformProcessor {
    private var key: ScopeSettings?
    private var mode: AcquireMode = .normal
    private var count = 0
    private var avg: [[Double]?] = [nil, nil]
    private var envMin: [[Float]?] = [nil, nil]
    private var envMax: [[Float]?] = [nil, nil]

    public init() {}

    public func reset() {
        key = nil
        count = 0
        avg = [nil, nil]
        envMin = [nil, nil]
        envMax = [nil, nil]
    }

    /// Returns the acquisition to display/measure for the given mode.
    public func process(_ acq: Acquisition, _ p: ProcessingSettings) -> Acquisition {
        guard p.mode == .average || p.mode == .envelope, !acq.settings.timebase.isRollMode else {
            if count > 0 { reset() }
            return acq
        }
        // Untriggered (free-running) frames don't line up: don't accumulate them.
        guard acq.triggerState == .triggered else { return acq }
        if key != acq.settings || mode != p.mode { reset(); key = acq.settings; mode = p.mode }

        count += 1
        let weight = 1 / Double(min(count, max(1, p.averages)))
        var out = acq
        for ch in 0..<acq.channels.count {
            guard let w = acq.channels[ch] else { continue }
            let n = w.count
            let t0 = -Double(VDS1022.samplesPerFrame) * acq.settings.triggerPosition * w.dt
            let grid = Self.resample(w, t0: t0, count: n)
            var r = w
            r.t0 = t0
            r.accumulated = count
            switch p.mode {
            case .average:
                var a = avg[ch] ?? grid.map(Double.init)
                if a.count != n { a = grid.map(Double.init) }
                if count > 1 { for i in 0..<n { a[i] += (Double(grid[i]) - a[i]) * weight } }
                avg[ch] = a
                r.volts = a.map { Float($0) }
            case .envelope:
                var lo = envMin[ch] ?? grid, hi = envMax[ch] ?? grid
                if lo.count != n { lo = grid; hi = grid }
                vDSP_vmin(lo, 1, grid, 1, &lo, 1, vDSP_Length(n))
                vDSP_vmax(hi, 1, grid, 1, &hi, 1, vDSP_Length(n))
                envMin[ch] = lo
                envMax[ch] = hi
                r.volts = grid
                r.envelopeMin = lo
                r.envelopeMax = hi
            default: break
            }
            out.channels[ch] = r
        }
        return out
    }

    /// Linear resampling of a waveform onto the grid t0 + i·dt (the trigger refinement
    /// shifts each frame by a fraction of a sample).
    static func resample(_ w: ChannelWaveform, t0: Double, count n: Int) -> [Float] {
        let shift = (t0 - w.t0) / w.dt
        if abs(shift) < 1e-6 { return w.volts }
        var out = [Float](repeating: 0, count: n)
        let v = w.volts
        let last = v.count - 1
        for i in 0..<n {
            let x = Double(i) + shift
            let j = Int(floor(x))
            if j < 0 { out[i] = v[0]; continue }
            if j >= last { out[i] = v[last]; continue }
            let f = Float(x - Double(j))
            out[i] = v[j] + (v[j + 1] - v[j]) * f
        }
        return out
    }
}

// MARK: - Math channel

public enum MathOperation: String, Codable, CaseIterable, Sendable {
    case add = "A + B", subtract = "A − B", multiply = "A × B", divide = "A ÷ B"
    case differentiate = "d/dt A", integrate = "∫ A dt", invert = "−A"

    public var usesB: Bool { [.add, .subtract, .multiply, .divide].contains(self) }
}

public struct MathSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var operation = MathOperation.multiply
    public var sourceA = 0
    public var sourceB = 1
    /// Index into `Format.scales125` (units per division).
    public var scaleIndex: Int = Format.scales125.firstIndex(of: 1) ?? 27
    public var offsetDivisions: Double = 0
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, operation, sourceA, sourceB, scaleIndex, offsetDivisions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MathSettings()
        enabled = c.value(.enabled, d.enabled)
        operation = c.value(.operation, d.operation)
        sourceA = c.value(.sourceA, d.sourceA)
        sourceB = c.value(.sourceB, d.sourceB)
        scaleIndex = min(max(0, c.value(.scaleIndex, d.scaleIndex)), Format.scales125.count - 1)
        offsetDivisions = c.value(.offsetDivisions, d.offsetDivisions)
    }

    public var unitsPerDivision: Double { Format.scales125[min(max(0, scaleIndex), Format.scales125.count - 1)] }

    public var label: String {
        let a = "CH\(sourceA + 1)", b = "CH\(sourceB + 1)"
        switch operation {
        case .add: return "\(a) + \(b)"
        case .subtract: return "\(a) − \(b)"
        case .multiply: return "\(a) × \(b)"
        case .divide: return "\(a) ÷ \(b)"
        case .differentiate: return "d\(a)/dt"
        case .integrate: return "∫\(a)"
        case .invert: return "−\(a)"
        }
    }
}

/// A computed trace (math or reference).
public struct DerivedWaveform: Sendable {
    public var values: [Float]
    public var t0: Double
    public var dt: Double
    public var unit: String
    public var label: String

    public init(values: [Float], t0: Double, dt: Double, unit: String, label: String) {
        self.values = values
        self.t0 = t0
        self.dt = dt
        self.unit = unit
        self.label = label
    }

    public var count: Int { values.count }
    public func time(at i: Int) -> Double { t0 + Double(i) * dt }
    public func index(at t: Double) -> Int { max(0, min(values.count - 1, Int(((t - t0) / dt).rounded()))) }
}

public enum MathEngine {
    public static func unit(_ op: MathOperation, _ a: SignalUnit, _ b: SignalUnit) -> String {
        switch op {
        case .add, .subtract: return a == b ? a.symbol : "?"
        case .invert: return a.symbol
        case .multiply:
            switch (a, b) {
            case (.volts, .amps), (.amps, .volts): return "W"
            case (.volts, .volts): return "V²"
            case (.amps, .amps): return "A²"
            }
        case .divide:
            switch (a, b) {
            case (.volts, .amps): return "Ω"
            case (.amps, .volts): return "S"
            default: return "×"
            }
        case .differentiate: return a.symbol + "/s"
        case .integrate: return a == .amps ? "C" : "V·s"
        }
    }

    public static func compute(_ s: MathSettings, _ acq: Acquisition) -> DerivedWaveform? {
        guard s.enabled, let a = acq.channel(s.sourceA) else { return nil }
        let b = acq.channel(s.sourceB)
        if s.operation.usesB && b == nil { return nil }
        let n = s.operation.usesB ? min(a.count, b!.count) : a.count
        guard n > 1 else { return nil }
        var out = [Float](repeating: 0, count: n)
        let va = a.volts
        switch s.operation {
        case .add: vDSP_vadd(va, 1, b!.volts, 1, &out, 1, vDSP_Length(n))
        case .subtract: vDSP_vsub(b!.volts, 1, va, 1, &out, 1, vDSP_Length(n)) // A − B
        case .multiply: vDSP_vmul(va, 1, b!.volts, 1, &out, 1, vDSP_Length(n))
        case .divide:
            let vb = b!.volts
            let eps = Float(b!.settings.voltsPerCount)
            for i in 0..<n { out[i] = abs(vb[i]) < eps ? .nan : va[i] / vb[i] }
        case .invert:
            var neg: Float = -1
            vDSP_vsmul(va, 1, &neg, &out, 1, vDSP_Length(n))
        case .differentiate:
            // central difference over ±2 samples to tame ADC quantisation noise
            let k = 2
            for i in 0..<n {
                let lo = max(0, i - k), hi = min(n - 1, i + k)
                out[i] = Float(Double(va[hi] - va[lo]) / (Double(hi - lo) * a.dt))
            }
        case .integrate:
            var acc = 0.0
            for i in 0..<n { acc += Double(va[i]) * a.dt; out[i] = Float(acc) }
        }
        let unitB = b?.unit ?? a.unit
        return DerivedWaveform(values: out, t0: a.t0, dt: a.dt,
                               unit: unit(s.operation, a.unit, unitB), label: s.label)
    }

    /// Picks a 1-2-5 scale that fits the waveform into about 8 divisions, and a centring offset.
    public static func autoScale(_ w: DerivedWaveform) -> (scaleIndex: Int, offset: Double) {
        let finite = w.values.filter { $0.isFinite }
        guard let lo = finite.min(), let hi = finite.max() else { return (Format.scales125.firstIndex(of: 1) ?? 27, 0) }
        let span = max(Double(hi - lo), 1e-9)
        let idx = Format.scales125.firstIndex { $0 * 8 >= span } ?? Format.scales125.count - 1
        let scale = Format.scales125[idx]
        let offset = -Double(hi + lo) / 2 / scale
        return (idx, (offset * 5).rounded() / 5)
    }
}

// MARK: - Gating

public enum Gating {
    /// Restricts a waveform to [start, end] (no-op if the range covers it).
    public static func apply(_ w: ChannelWaveform, start: Double, end: Double) -> ChannelWaveform {
        let a = min(start, end), b = max(start, end)
        guard b - a > w.dt * 4 else { return w }
        return w.slice(from: a, to: b)
    }

    public static func apply(_ w: DerivedWaveform, start: Double, end: Double) -> DerivedWaveform {
        let a = min(start, end), b = max(start, end)
        let i = w.index(at: a), j = w.index(at: b)
        guard j > i + 4 else { return w }
        var out = w
        out.values = Array(w.values[i...j])
        out.t0 = w.time(at: i)
        return out
    }
}
