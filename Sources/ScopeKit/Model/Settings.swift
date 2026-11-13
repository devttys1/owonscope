import Foundation

public enum Coupling: String, Codable, CaseIterable, Sendable {
    case dc = "DC", ac = "AC", gnd = "GND"
    // Note: the hardware uses 0 = AC, 1 = DC (the reference driver comment says otherwise).
    var register: UInt32 { switch self { case .ac: 0; case .dc: 1; case .gnd: 2 } }
}

/// What a channel measures. A current probe outputs a voltage proportional to current.
public enum SignalUnit: String, Codable, CaseIterable, Sendable {
    case volts = "V", amps = "A"
    public var symbol: String { rawValue }
}

public enum TriggerSource: String, Codable, CaseIterable, Sendable {
    case ch1 = "CH1", ch2 = "CH2", ext = "EXT"
    public var channel: Int? { switch self { case .ch1: 0; case .ch2: 1; case .ext: nil } }
}

public enum TriggerSlope: String, Codable, CaseIterable, Sendable {
    case rising = "Rising", falling = "Falling"
}

public enum TriggerMode: String, Codable, CaseIterable, Sendable {
    case edge = "Edge", pulse = "Pulse"
}

/// Pulse-width trigger condition.
public enum PulseCondition: String, Codable, CaseIterable, Sendable {
    case greater = ">", less = "<", equal = "="
}

public enum SweepMode: String, Codable, CaseIterable, Sendable {
    case auto = "Auto", normal = "Normal", single = "Single"
    var register: UInt32 { switch self { case .auto: 0; case .normal: 1; case .single: 2 } }
}

/// Decoding helper that falls back to defaults for keys missing in older saved settings.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

public struct ChannelSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    /// Index into `VDS1022.voltRanges` (hardware range, before probe scaling).
    public var rangeIndex: Int = 4
    /// Probe factor: measured units per volt at the BNC. A ×10 voltage probe is 10 (V/V);
    /// a 100 mV/A current probe is 10 (A/V).
    public var probe: Double = 10
    public var unit: SignalUnit = .volts
    public var coupling: Coupling = .dc
    /// Position of the zero line in divisions from screen centre (+ is up).
    public var offsetDivisions: Double = 0

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, rangeIndex, probe, unit, coupling, offsetDivisions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChannelSettings()
        enabled = c.value(.enabled, d.enabled)
        rangeIndex = min(max(0, c.value(.rangeIndex, d.rangeIndex)), VDS1022.voltRanges.count - 1)
        probe = c.value(.probe, d.probe)
        unit = c.value(.unit, d.unit)
        coupling = c.value(.coupling, d.coupling)
        offsetDivisions = c.value(.offsetDivisions, d.offsetDivisions)
    }

    /// Units (V or A) per division at the probe tip.
    public var unitsPerDivision: Double { VDS1022.voltsPerDivision[rangeIndex] * probe }
    /// Alias kept for voltage-centric call sites (it is in channel units).
    public var voltsPerDivision: Double { unitsPerDivision }
    /// Full-scale units (10 divisions) at the probe tip.
    public var fullScale: Double { VDS1022.voltRanges[rangeIndex] * probe }
    /// Units represented by one ADC count.
    public var voltsPerCount: Double { fullScale / VDS1022.adcRange }
    /// Zero position in ADC counts.
    public var zeroCounts: Double { offsetDivisions * VDS1022.countsPerDivision }

    public func volts(counts: Double) -> Double { (counts - zeroCounts) * voltsPerCount }
    public func counts(volts: Double) -> Double { volts / voltsPerCount + zeroCounts }

    /// "×10" for voltage probes, "100 mV/A" for current probes.
    public var probeLabel: String {
        unit == .volts ? "×" + Format.number(probe) : Format.si(1 / probe, unit: "V/A")
    }

    /// Formats a value in this channel's unit.
    public func format(_ v: Double) -> String { Format.si(v, unit: unit.symbol) }

    /// Common current-probe sensitivities (V per A).
    public static let currentSensitivities: [Double] = [1, 0.5, 0.2, 0.1, 0.05, 0.01, 0.001]
    public static let voltageProbes: [Double] = [1, 10, 100, 1000]
}

public struct TriggerSettings: Codable, Equatable, Sendable {
    public var source: TriggerSource = .ch1
    public var mode: TriggerMode = .edge
    /// Edge direction; in pulse mode rising = positive pulse, falling = negative pulse.
    public var slope: TriggerSlope = .rising
    /// Level in channel units at the probe tip.
    public var level: Double = 1.0
    public var sweep: SweepMode = .auto
    public var holdoff: Double = 100e-9
    public var pulseCondition: PulseCondition = .greater
    public var pulseWidth: Double = 100e-6
    public init() {}

    enum CodingKeys: String, CodingKey { case source, mode, slope, level, sweep, holdoff, pulseCondition, pulseWidth }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TriggerSettings()
        source = c.value(.source, d.source)
        mode = c.value(.mode, d.mode)
        slope = c.value(.slope, d.slope)
        level = c.value(.level, d.level)
        sweep = c.value(.sweep, d.sweep)
        holdoff = c.value(.holdoff, d.holdoff)
        pulseCondition = c.value(.pulseCondition, d.pulseCondition)
        pulseWidth = c.value(.pulseWidth, d.pulseWidth)
    }
}

/// One entry of the horizontal scale.
public struct Timebase: Equatable, Sendable, Hashable {
    public let secondsPerDivision: Double

    public static let divisions: Double = 10

    /// 1-2-5 sequence from 20 ns/div to 100 s/div.
    public static let all: [Timebase] = {
        var out: [Timebase] = []
        var decade = 1e-8
        while decade < 1000 {
            for m in [1.0, 2.0, 5.0] {
                let s = (m * decade * 1e12).rounded() / 1e12
                if s >= 20e-9 && s <= 100 { out.append(Timebase(secondsPerDivision: s)) }
            }
            decade *= 10
        }
        return out
    }()

    public static let defaultIndex = all.firstIndex { abs($0.secondsPerDivision - 200e-6) < 1e-12 } ?? 0

    /// Time across the visible screen.
    public var window: Double { secondsPerDivision * Self.divisions }

    /// Hardware timebase prescaler for 5000 samples spanning the window (capped at 100 MS/s).
    public var prescaler: UInt32 {
        let rate = Double(VDS1022.samplesPerFrame) / window
        return UInt32(max(1, (VDS1022.maxSampleRate / max(3, rate)).rounded()))
    }

    public var sampleRate: Double { VDS1022.sampleRate(prescaler: prescaler) }
    /// Acquired window may be wider than the displayed one at the fastest timebases.
    public var acquisitionWindow: Double { Double(VDS1022.samplesPerFrame) / sampleRate }
    public var isZoomed: Bool { acquisitionWindow > window * 1.001 }
    public var isRollMode: Bool { sampleRate < VDS1022.rollModeThreshold }

    public var label: String { Format.seconds(secondsPerDivision) + "/div" }
}

public struct ScopeSettings: Codable, Equatable, Sendable {
    public var channels: [ChannelSettings]
    public var timebaseIndex: Int = Timebase.defaultIndex
    /// Trigger point as a fraction of screen width from the left (0...1).
    public var triggerPosition: Double = 0.5
    public var trigger = TriggerSettings()
    public var peakDetect = false

    public init() {
        var ch2 = ChannelSettings()
        ch2.offsetDivisions = -2
        var ch1 = ChannelSettings()
        ch1.offsetDivisions = 1
        channels = [ch1, ch2]
    }

    enum CodingKeys: String, CodingKey { case channels, timebaseIndex, triggerPosition, trigger, peakDetect }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScopeSettings()
        let chans = c.value(.channels, d.channels)
        channels = chans.count == 2 ? chans : d.channels
        timebaseIndex = min(max(0, c.value(.timebaseIndex, d.timebaseIndex)), Timebase.all.count - 1)
        triggerPosition = c.value(.triggerPosition, d.triggerPosition)
        trigger = c.value(.trigger, d.trigger)
        peakDetect = c.value(.peakDetect, d.peakDetect)
    }

    public var timebase: Timebase {
        Timebase.all[min(max(0, timebaseIndex), Timebase.all.count - 1)]
    }

    public var enabledMask: [Bool] { channels.map(\.enabled) }

    /// Time of the left screen edge relative to the trigger.
    public var screenStart: Double {
        timebase.isRollMode ? -timebase.window : -triggerPosition * timebase.window
    }
}

public enum Format {
    public static func si(_ value: Double, unit: String, digits: Int = 3) -> String {
        if value == 0 { return "0 \(unit)".trimmingCharacters(in: .whitespaces) }
        if !value.isFinite { return "— \(unit)" }
        let prefixes: [(Double, String)] = [(1e9, "G"), (1e6, "M"), (1e3, "k"), (1, ""), (1e-3, "m"), (1e-6, "µ"), (1e-9, "n"), (1e-12, "p")]
        let a = abs(value)
        let (scale, prefix) = prefixes.first { a >= $0.0 * 0.9995 } ?? prefixes.last!
        let scaled = value / scale
        let intDigits = max(1, Int(floor(log10(max(abs(scaled), 1)))) + 1)
        let decimals = max(0, digits - intDigits)
        var s = String(format: "%.\(decimals)f", scaled)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return "\(s) \(prefix)\(unit)".trimmingCharacters(in: .whitespaces)
    }

    public static func seconds(_ v: Double) -> String { si(v, unit: "s") }
    public static func volts(_ v: Double) -> String { si(v, unit: "V") }
    public static func hertz(_ v: Double) -> String { si(v, unit: "Hz", digits: 5) }

    /// Plain number without trailing zeros ("10", "0.5").
    public static func number(_ v: Double) -> String {
        var s = String(format: "%.4g", v)
        if s.contains(".") && !s.contains("e") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// 1-2-5 sequence of scales from 1e-9 to 1e9.
    public static let scales125: [Double] = {
        var out: [Double] = []
        var d = 1e-9
        while d <= 1e9 { for m in [1.0, 2.0, 5.0] { out.append((m * d * 1e12).rounded() / 1e12) }; d *= 10 }
        return out
    }()
}
