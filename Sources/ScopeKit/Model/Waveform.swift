import Foundation

/// A calibrated capture of one channel.
public struct ChannelWaveform: Sendable {
    public var channel: Int
    /// Samples in volts at the probe tip.
    public var volts: [Float]
    /// Raw ADC counts (signed), parallel to `volts`.
    public var counts: [Int8]
    /// Time of the first sample relative to the trigger point, in seconds.
    public var t0: Double
    /// Sample interval in seconds.
    public var dt: Double
    /// Hardware frequency meter reading, if available.
    public var frequencyMeter: Double?
    public var clipped: Bool
    public var settings: ChannelSettings
    /// Envelope (min/max over accumulated acquisitions), parallel to `volts`, when enabled.
    public var envelopeMin: [Float]?
    public var envelopeMax: [Float]?
    /// Number of acquisitions combined into this waveform (averaging/envelope), 1 otherwise.
    public var accumulated = 1

    public var unit: SignalUnit { settings.unit }

    public init(channel: Int, counts: [Int8], t0: Double, dt: Double, frequencyMeter: Double?, settings: ChannelSettings) {
        self.channel = channel
        self.counts = counts
        self.t0 = t0
        self.dt = dt
        self.frequencyMeter = frequencyMeter
        self.settings = settings
        let vpc = Float(settings.voltsPerCount)
        let zero = Float(settings.zeroCounts)
        var clip = false
        volts = counts.map { c in
            let v = max(Int(VDS1022.adcMin), min(Int(VDS1022.adcMax), Int(c)))
            if v >= VDS1022.adcMax || v <= VDS1022.adcMin { clip = true }
            return (Float(v) - zero) * vpc
        }
        clipped = clip
    }

    public var count: Int { volts.count }
    public var duration: Double { Double(volts.count) * dt }
    public var sampleRate: Double { 1 / dt }

    public func time(at index: Int) -> Double { t0 + Double(index) * dt }

    /// Index nearest to time `t` (clamped).
    public func index(at t: Double) -> Int {
        max(0, min(volts.count - 1, Int(((t - t0) / dt).rounded())))
    }

    /// Sub-range covering [start, end] seconds.
    public func slice(from start: Double, to end: Double) -> ChannelWaveform {
        let i = index(at: start), j = index(at: end)
        guard j > i else { return self }
        var w = self
        w.volts = Array(volts[i...j])
        w.counts = Array(counts[min(i, counts.count - 1)...min(j, counts.count - 1)])
        w.envelopeMin = envelopeMin.map { Array($0[i...j]) }
        w.envelopeMax = envelopeMax.map { Array($0[i...j]) }
        w.t0 = time(at: i)
        return w
    }
}

public enum TriggerState: String, Sendable {
    case stopped = "Stop"
    case waiting = "Wait"
    case triggered = "Trig'd"
    case auto = "Auto"
    case roll = "Roll"
}

/// A set of channel captures taken together.
public struct Acquisition: Sendable {
    public var channels: [ChannelWaveform?]
    public var settings: ScopeSettings
    public var timestamp: Date
    public var triggerState: TriggerState
    public var sequence: Int

    public init(channels: [ChannelWaveform?], settings: ScopeSettings, timestamp: Date = Date(), triggerState: TriggerState, sequence: Int) {
        self.channels = channels
        self.settings = settings
        self.timestamp = timestamp
        self.triggerState = triggerState
        self.sequence = sequence
    }

    public func channel(_ i: Int) -> ChannelWaveform? { i < channels.count ? channels[i] : nil }
}
