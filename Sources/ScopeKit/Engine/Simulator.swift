import Foundation

/// Signal scenarios for the built-in simulator (demo mode, UI work, tests).
public enum SimulatorScenario: String, CaseIterable, Sendable, Codable {
    case reference = "1 kHz reference + UART"
    case i2c = "I²C bus (SCL / SDA)"
    case spi = "SPI (SCK / MOSI)"
    case can = "CAN bus (CAN_H / CAN_L)"
    case lin = "LIN bus (bus / RX)"
    case usb = "USB low speed (D+ / D−)"
    case oneWire = "1-Wire (DS18B20)"
    case analog = "Sine + AM"
}

/// Analog signal model: volts as a function of absolute time.
public struct SignalModel: Sendable {
    public var ch1: @Sendable (Double) -> Double
    public var ch2: @Sendable (Double) -> Double

    public static func make(_ scenario: SimulatorScenario) -> SignalModel {
        switch scenario {
        case .reference:
            let uart = SerialPattern.uart(text: "Hello from OwonScope!\r\n", baud: 9600, gap: 1.5e-3)
            return SignalModel(ch1: { t in Edges.square(t, freq: 1000, low: 0, high: 5, rise: 4e-7) },
                               ch2: { t in uart.level(at: t) ? 3.3 : 0 })
        case .i2c:
            let bus = I2CPattern(rate: 100_000, gap: 4e-4,
                                 messages: [[0x50 << 1, 0x00, 0x10], [0x50 << 1 | 1, 0xDE, 0xAD, 0xBE, 0xEF], [0x3C << 1, 0x40, 0x7F]])
            return SignalModel(ch1: { t in bus.scl(at: t) ? 3.3 : 0 }, ch2: { t in bus.sda(at: t) ? 3.3 : 0 })
        case .spi:
            let spi = SPIPattern(rate: 1_000_000, bytes: Array("SPI!".utf8) + [0x00, 0xFF, 0xA5], gap: 2e-5)
            return SignalModel(ch1: { t in spi.sck(at: t) ? 3.3 : 0 }, ch2: { t in spi.mosi(at: t) ? 3.3 : 0 })
        case .can:
            let tl = BusPatterns.canScenario
            return SignalModel(ch1: { t in tl.line(0, at: t) ? 2.5 : 3.5 }, ch2: { t in tl.line(0, at: t) ? 2.5 : 1.5 })
        case .lin:
            let tl = BusPatterns.linScenario
            return SignalModel(ch1: { t in tl.line(0, at: t) ? 12 : 0.9 }, ch2: { t in tl.line(0, at: t) ? 3.3 : 0 })
        case .usb:
            let tl = BusPatterns.usbScenario
            return SignalModel(ch1: { t in tl.line(0, at: t) ? 3.3 : 0 }, ch2: { t in tl.line(1, at: t) ? 3.3 : 0 })
        case .oneWire:
            let tl = BusPatterns.oneWireScenario
            return SignalModel(ch1: { t in tl.line(0, at: t) ? 3.3 : 0 }, ch2: { _ in 0 })
        case .analog:
            return SignalModel(
                ch1: { t in 1.5 * sin(2 * .pi * 10_000 * t) },
                ch2: { t in (1 + 0.5 * sin(2 * .pi * 500 * t)) * sin(2 * .pi * 20_000 * t) })
        }
    }
}

enum Edges {
    /// Square wave with first-order edge rounding and slight overshoot.
    static func square(_ t: Double, freq: Double, low: Double, high: Double, rise: Double) -> Double {
        let period = 1 / freq
        let phase = t.truncatingRemainder(dividingBy: period) + (t < 0 ? period : 0)
        let half = period / 2
        let since = phase < half ? phase : phase - half
        let target = phase < half ? high : low
        let start = phase < half ? low : high
        let tau = rise / 2.2
        let swing = target - start
        let settle = exp(-since / tau)
        let ring = 0.04 * swing * exp(-since / (tau * 3)) * sin(since / tau * 1.3)
        return target - swing * settle + ring
    }
}

/// UART frame sequence repeating forever.
public struct SerialPattern: Sendable {
    let bits: [Bool]
    let bitTime: Double
    let period: Double

    public static func uart(text: String, baud: Double, gap: Double) -> SerialPattern {
        var bits: [Bool] = []
        for byte in Array(text.utf8) {
            bits.append(false)
            for i in 0..<8 { bits.append((byte >> i) & 1 == 1) }
            bits.append(true)
        }
        let bt = 1 / baud
        return SerialPattern(bits: bits, bitTime: bt, period: Double(bits.count) * bt + gap)
    }

    public func level(at t: Double) -> Bool {
        var p = t.truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        let i = Int(p / bitTime)
        return i < bits.count ? bits[i] : true
    }
}

struct I2CPattern: Sendable {
    /// Sequence of (scl, sda) states at quarter-bit resolution.
    let states: [(Bool, Bool)]
    let quarter: Double
    let period: Double

    init(rate: Double, gap: Double, messages: [[UInt8]]) {
        var s: [(Bool, Bool)] = []
        for msg in messages {
            s += [(true, true), (true, false), (false, false)] // START: SDA falls while SCL high
            for byte in msg {
                for i in (0..<8).reversed() {
                    let b = (byte >> i) & 1 == 1
                    s += [(false, b), (true, b), (true, b), (false, b)]
                }
                s += [(false, false), (true, false), (true, false), (false, false)] // ACK
            }
            s += [(false, false), (true, false), (true, true), (true, true)] // STOP
            s += Array(repeating: (true, true), count: 8)
        }
        states = s
        quarter = 1 / rate / 4
        period = Double(s.count) * quarter + gap
    }

    private func state(_ t: Double) -> (Bool, Bool) {
        var p = t.truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        let i = Int(p / quarter)
        return i < states.count ? states[i] : (true, true)
    }

    func scl(at t: Double) -> Bool { state(t).0 }
    func sda(at t: Double) -> Bool { state(t).1 }
}

struct SPIPattern: Sendable {
    let bits: [Bool]
    let bitTime: Double
    let period: Double

    init(rate: Double, bytes: [UInt8], gap: Double) {
        var b: [Bool] = []
        for byte in bytes { for i in (0..<8).reversed() { b.append((byte >> i) & 1 == 1) } }
        bits = b
        bitTime = 1 / rate
        period = Double(b.count) * bitTime + gap
    }

    private func phase(_ t: Double) -> Double {
        var p = t.truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        return p
    }

    /// Mode 0: data changes on falling edge, sampled on rising edge; idle low.
    func sck(at t: Double) -> Bool {
        let p = phase(t)
        let i = Int(p / bitTime)
        guard i < bits.count else { return false }
        return p - Double(i) * bitTime >= bitTime / 2
    }

    func mosi(at t: Double) -> Bool {
        let i = Int(phase(t) / bitTime)
        return i < bits.count ? bits[i] : false
    }
}

/// Simulated VDS1022 that honours the same settings, quantisation and trigger behaviour.
public final class SimulatorBackend: AcquisitionBackend {
    public let info = DeviceInfo(model: "Simulator", serial: "DEMO", hardwareVersion: "—", fpgaVersion: 0, isSimulated: true)
    public var scenario: SimulatorScenario { didSet { model = .make(scenario) } }
    private var model: SignalModel
    private var clock: Double = 0
    private var lastPoll = Date()
    private var armed = true
    private var sequence = 0
    private var forced = false
    private var rng = SystemRandomNumberGeneratorWrapper()

    public init(scenario: SimulatorScenario = .reference) {
        self.scenario = scenario
        model = .make(scenario)
    }

    public func apply(_ settings: ScopeSettings, force: Bool) throws {}
    public func arm(_ settings: ScopeSettings) throws { armed = true }
    public func forceTrigger() throws { forced = true }
    public func keepAlive() throws {}
    public func close() {}

    public func poll(_ settings: ScopeSettings) throws -> Acquisition? {
        let tb = settings.timebase
        let n = VDS1022.samplesPerFrame
        let dt = 1 / tb.sampleRate
        let acqWindow = Double(n) * dt

        // Pace like real hardware: a frame can't arrive faster than it takes to acquire.
        let minInterval = max(1.0 / 60, min(acqWindow, 2.0))
        let now = Date()
        if now.timeIntervalSince(lastPoll) < minInterval { return nil }
        let elapsed = now.timeIntervalSince(lastPoll)
        lastPoll = now
        clock += elapsed + Double.random(in: 0..<1e-3, using: &rng)

        if settings.trigger.sweep == .single && !armed { return nil }

        var t0 = -Double(n) * settings.triggerPosition * dt
        var origin = clock
        var state: TriggerState = .auto

        if tb.isRollMode {
            t0 = -acqWindow
            state = .roll
        } else if let ch = settings.trigger.source.channel, !forced {
            if var tTrig = findTrigger(channel: ch, settings: settings, from: clock, span: max(acqWindow * 4, 3e-3), dt: dt) {
                // Holdoff: after a trigger, edges are ignored for the holdoff time. With a holdoff
                // longer than a burst, this locks onto the first edge of each burst, as on hardware.
                let holdoff = settings.trigger.holdoff
                // Each retrigger moves only part way through a burst, so run the trigger forward
                // many times, as a free-running scope would, until it settles on the burst start.
                // (Evenly spaced edges repeat the same interval mid-burst, so a repeated interval
                // is not proof of lock.)
                if holdoff > 1e-6 {
                    for _ in 0..<96 {
                        guard let next = findTrigger(channel: ch, settings: settings, from: tTrig + holdoff,
                                                     span: holdoff * 2 + acqWindow, dt: dt) else { break }
                        tTrig = next
                    }
                }
                origin = tTrig
                state = .triggered
            } else if settings.trigger.sweep != .auto {
                return nil
            }
        }
        forced = false

        var channels: [ChannelWaveform?] = [nil, nil]
        for ch in 0..<2 where settings.channels[ch].enabled {
            let c = settings.channels[ch]
            let f = ch == 0 ? model.ch1 : model.ch2
            var counts = [Int8](repeating: 0, count: n)
            for i in 0..<n {
                let t = origin + t0 + Double(i) * dt
                var v: Double
                if settings.peakDetect && tb.sampleRate < 1e6 {
                    // alternate min/max over each pair of sample intervals, like the hardware peak mode
                    let base = origin + t0 + Double(i & ~1) * dt
                    var lo = Double.infinity, hi = -Double.infinity
                    for k in 0..<64 {
                        let x = f(base + Double(k) * dt * 2 / 64)
                        lo = min(lo, x); hi = max(hi, x)
                    }
                    v = i % 2 == 0 ? lo : hi
                } else {
                    v = f(t)
                }
                if c.coupling == .gnd { v = 0 }
                v += Double.random(in: -1...1, using: &rng) * c.fullScale * 0.003
                let cnt = c.counts(volts: v).rounded()
                counts[i] = Int8(max(-128, min(127, cnt)))
            }
            if c.coupling == .ac {
                let mean = counts.reduce(0) { $0 + Int($1) } / n
                let shift = Int(c.zeroCounts.rounded()) - mean
                counts = counts.map { Int8(max(-128, min(127, Int($0) + shift))) }
            }
            channels[ch] = ChannelWaveform(channel: ch, counts: counts, t0: t0, dt: dt, frequencyMeter: nil, settings: c)
        }
        if settings.trigger.sweep == .single { armed = false }
        sequence += 1
        return Acquisition(channels: channels, settings: settings, triggerState: state, sequence: sequence)
    }

    private func findTrigger(channel: Int, settings: ScopeSettings, from start: Double, span: Double, dt: Double) -> Double? {
        let f = channel == 0 ? model.ch1 : model.ch2
        let level = settings.trigger.level
        let rising = settings.trigger.slope == .rising
        let step = max(dt, span / 20_000)
        var prev = f(start)
        var t = start + step
        while t < start + span {
            let v = f(t)
            if rising ? (prev < level && v >= level) : (prev > level && v <= level) {
                // refine the crossing by bisection
                var a = t - step, b = t
                for _ in 0..<24 where b - a > dt / 8 {
                    let m = (a + b) / 2
                    let above = f(m) >= level
                    if above == rising { b = m } else { a = m }
                }
                return b
            }
            prev = v
            t += step
        }
        return nil
    }
}

struct SystemRandomNumberGeneratorWrapper: RandomNumberGenerator {
    var base = SystemRandomNumberGenerator()
    mutating func next() -> UInt64 { base.next() }
}
