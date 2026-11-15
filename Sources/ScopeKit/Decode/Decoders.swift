import Foundation

// MARK: - Common types

public enum DataFormat: String, CaseIterable, Codable, Sendable {
    case hex = "Hex", ascii = "ASCII", decimal = "Dec", binary = "Bin"

    public func format(_ value: UInt32, bits: Int = 8) -> String {
        switch self {
        case .hex: return String(format: bits > 8 ? "0x%04X" : "0x%02X", value)
        case .decimal: return String(value)
        case .binary:
            let s = String(value, radix: 2)
            return String(repeating: "0", count: max(0, bits - s.count)) + s
        case .ascii:
            switch value {
            case 0x20..<0x7f: return "'\(Character(UnicodeScalar(UInt8(value))))'"
            case 0x0a: return "\\n"
            case 0x0d: return "\\r"
            case 0x09: return "\\t"
            default: return String(format: "0x%02X", value)
            }
        }
    }
}

public struct DecodedEvent: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case data, address, start, stop, ack, nack, error, info
    }
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var kind: Kind
    public var value: UInt32?
    /// Primary label, already formatted.
    public var label: String
    /// Short label for narrow boxes.
    public var short: String

    public init(start: Double, end: Double, kind: Kind, value: UInt32? = nil, label: String, short: String? = nil) {
        self.start = start
        self.end = end
        self.kind = kind
        self.value = value
        self.label = label
        self.short = short ?? label
    }
}

public enum Threshold: Codable, Equatable, Sendable {
    case auto
    case volts(Double)
}

/// A channel converted to logic levels with a Schmitt trigger.
public struct LogicTrace: Sendable {
    public var bits: [Bool]
    public var t0: Double
    public var dt: Double
    public var threshold: Double

    public func time(_ i: Int) -> Double { t0 + Double(i) * dt }
    public var count: Int { bits.count }

    /// Returns nil if the signal has no usable swing (flat line).
    public static func digitize(_ w: ChannelWaveform, threshold: Threshold, invert: Bool = false) -> LogicTrace? {
        let (base, top) = Measurements.levels(w)
        let amp = top - base
        let mid: Double
        let hyst: Double
        switch threshold {
        case .auto:
            guard amp > w.settings.voltsPerCount * 10 else { return nil }
            mid = base + amp / 2
            hyst = amp * 0.15
        case .volts(let v):
            mid = v
            hyst = max(w.settings.voltsPerCount * 3, abs(amp) * 0.1)
        }
        let hi = Float(mid + hyst / 2), lo = Float(mid - hyst / 2)
        var state = (w.volts.first ?? 0) > Float(mid)
        var bits = [Bool](repeating: false, count: w.count)
        for (i, v) in w.volts.enumerated() {
            if state { if v < lo { state = false } } else if v > hi { state = true }
            bits[i] = state != invert
        }
        return LogicTrace(bits: bits, t0: w.t0, dt: w.dt, threshold: mid)
    }

    /// Indices where the level changes (index of the first sample at the new level).
    public var edges: [Int] {
        var out: [Int] = []
        for i in 1..<max(1, bits.count) where bits[i] != bits[i - 1] { out.append(i) }
        return out
    }
}

// MARK: - Decoder configuration

public struct UARTConfig: Codable, Equatable, Sendable {
    public enum Parity: String, Codable, CaseIterable, Sendable { case none = "None", even = "Even", odd = "Odd" }
    public var channel = 1
    /// 0 = auto detect
    public var baud: Double = 0
    public var dataBits = 8
    public var parity = Parity.none
    public var stopBits = 1.0
    public var invert = false
    public var msbFirst = false
    public var threshold = Threshold.auto
    public var format = DataFormat.ascii
    public init() {}

    public static let standardBauds: [Double] = [300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400, 57600, 76800, 115200, 230400, 250000, 460800, 500000, 921600, 1_000_000, 2_000_000]
}

public struct I2CConfig: Codable, Equatable, Sendable {
    public var scl = 0
    public var sda = 1
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}
}

public struct SPIConfig: Codable, Equatable, Sendable {
    public var sck = 0
    public var data = 1
    /// SPI mode 0-3 (CPOL << 1 | CPHA)
    public var mode = 0
    public var bitsPerWord = 8
    public var msbFirst = true
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}
}

public enum DecoderKind: Codable, Equatable, Sendable {
    case uart(UARTConfig)
    case i2c(I2CConfig)
    case spi(SPIConfig)
    case can(CANConfig)
    case lin(LINConfig)
    case usb(USBConfig)
    case oneWire(OneWireConfig)

    public var name: String {
        switch self {
        case .uart: "UART"; case .i2c: "I²C"; case .spi: "SPI"
        case .can: "CAN"; case .lin: "LIN"; case .usb: "USB"; case .oneWire: "1-Wire"
        }
    }

    /// Stable lower-case identifier (for the CLI, automation and MCP): "uart", "i2c", "spi",
    /// "can", "lin", "usb", "onewire".
    public var protocolID: String {
        switch self {
        case .uart: "uart"; case .i2c: "i2c"; case .spi: "spi"
        case .can: "can"; case .lin: "lin"; case .usb: "usb"; case .oneWire: "onewire"
        }
    }

    public static let allProtocolIDs = ["uart", "i2c", "spi", "can", "lin", "usb", "onewire"]

    /// A decoder with default settings for a protocol id (see `protocolID`).
    public static func defaults(for protocolID: String) -> DecoderKind? {
        switch protocolID.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
        case "uart", "serial", "rs232": .uart(UARTConfig())
        case "i2c", "iic", "twi": .i2c(I2CConfig())
        case "spi": .spi(SPIConfig())
        case "can", "canbus": .can(CANConfig())
        case "lin", "linbus": .lin(LINConfig())
        case "usb": .usb(USBConfig())
        case "onewire", "1wire", "ow": .oneWire(OneWireConfig())
        default: nil
        }
    }

    public var channels: [Int] {
        switch self {
        case .uart(let c): [c.channel]
        case .i2c(let c): [c.scl, c.sda]
        case .spi(let c): [c.sck, c.data]
        case .can(let c): [c.channel]
        case .lin(let c): [c.channel]
        case .usb(let c): [c.dPlus, c.dMinus]
        case .oneWire(let c): [c.channel]
        }
    }

    /// The settings as display strings, keyed like the MCP tool arguments
    /// (channels as "CH1"/"CH2", rates as numbers or "auto").
    public var settingsSummary: [String: String] {
        func ch(_ i: Int) -> String { "CH\(i + 1)" }
        func th(_ t: Threshold) -> String { if case .volts(let v) = t { String(format: "%g", v) } else { "auto" } }
        func rate(_ r: Double) -> String { r > 0 ? String(format: "%g", r) : "auto" }
        switch self {
        case .uart(let c):
            return ["channel": ch(c.channel), "baud": rate(c.baud), "data_bits": "\(c.dataBits)", "parity": c.parity.rawValue,
                    "stop_bits": String(format: "%g", c.stopBits), "invert": "\(c.invert)", "msb_first": "\(c.msbFirst)",
                    "threshold": th(c.threshold), "format": c.format.rawValue]
        case .i2c(let c):
            return ["scl": ch(c.scl), "sda": ch(c.sda), "threshold": th(c.threshold), "format": c.format.rawValue]
        case .spi(let c):
            return ["sck": ch(c.sck), "data": ch(c.data), "mode": "\(c.mode)", "bits_per_word": "\(c.bitsPerWord)",
                    "msb_first": "\(c.msbFirst)", "threshold": th(c.threshold), "format": c.format.rawValue]
        case .can(let c):
            return ["channel": ch(c.channel), "bitrate": rate(c.bitrate), "sample_point": String(format: "%g", c.samplePoint),
                    "signal": c.signal.rawValue, "threshold": th(c.threshold), "format": c.format.rawValue]
        case .lin(let c):
            return ["channel": ch(c.channel), "baud": rate(c.baud), "checksum": c.checksum.rawValue, "invert": "\(c.invert)",
                    "threshold": th(c.threshold), "format": c.format.rawValue]
        case .usb(let c):
            return ["d_plus": ch(c.dPlus), "d_minus": ch(c.dMinus), "speed": c.speed.rawValue,
                    "threshold": th(c.threshold), "format": c.format.rawValue]
        case .oneWire(let c):
            return ["channel": ch(c.channel), "speed": c.speed.rawValue, "threshold": th(c.threshold), "format": c.format.rawValue]
        }
    }
}

public struct DecoderInstance: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var kind: DecoderKind
    public init(kind: DecoderKind) { self.kind = kind }
}

public struct DecodeResult: Sendable {
    public var decoderID: UUID
    public var events: [DecodedEvent]
    public var summary: String
}

public enum ProtocolDecoding {
    public static func run(_ d: DecoderInstance, on acq: Acquisition) -> DecodeResult {
        switch d.kind {
        case .uart(let c): return UARTDecoder.decode(c, acq, id: d.id)
        case .i2c(let c): return I2CDecoder.decode(c, acq, id: d.id)
        case .spi(let c): return SPIDecoder.decode(c, acq, id: d.id)
        case .can(let c): return CANDecoder.decode(c, acq, id: d.id)
        case .lin(let c): return LINDecoder.decode(c, acq, id: d.id)
        case .usb(let c): return USBDecoder.decode(c, acq, id: d.id)
        case .oneWire(let c): return OneWireDecoder.decode(c, acq, id: d.id)
        }
    }
}

// MARK: - UART

public enum UARTDecoder {
    /// Estimates the baud rate from the narrowest pulse, snapped to a standard rate.
    public static func detectBaud(_ t: LogicTrace) -> Double? {
        let e = t.edges
        guard e.count >= 3 else { return nil }
        var widths: [Int] = []
        for (a, b) in zip(e, e.dropFirst()) { widths.append(b - a) }
        widths.sort()
        // ignore glitches: use the 10th percentile of pulse widths
        let w = Double(widths[min(widths.count - 1, widths.count / 10)])
        guard w >= 2 else { return nil }
        let raw = 1 / (w * t.dt)
        if let std = UARTConfig.standardBauds.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(std - raw) / raw < 0.12 {
            return std
        }
        return raw
    }

    public static func decode(_ c: UARTConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let w = acq.channel(c.channel) else {
            return DecodeResult(decoderID: id, events: [], summary: "CH\(c.channel + 1) off")
        }
        guard let t = LogicTrace.digitize(w, threshold: c.threshold, invert: c.invert) else {
            return DecodeResult(decoderID: id, events: [], summary: "no signal")
        }
        guard let baud = c.baud > 0 ? c.baud : detectBaud(t) else {
            return DecodeResult(decoderID: id, events: [], summary: "no edges")
        }
        let bitSamples = 1 / (baud * t.dt)
        guard bitSamples >= 3 else {
            return DecodeResult(decoderID: id, events: [], summary: "sample rate too low for \(Int(baud)) baud (slow the timebase)")
        }
        let parityBits = c.parity == .none ? 0 : 1
        let frameBits = 1 + Double(c.dataBits + parityBits) + c.stopBits
        var events: [DecodedEvent] = []
        var i = 1
        let n = t.count
        var errors = 0
        // A capture that starts low begins mid-frame. Resync on an idle (high) run longer than
        // any frame can contain (data + parity + stop), falling back to the first edge.
        if t.bits.first == false {
            let need = Int(Double(c.dataBits + parityBits + 1) * bitSamples + 1)
            var run = 0
            for k in 0..<n {
                run = t.bits[k] ? run + 1 : 0
                if run >= need { i = k; break }
            }
        }
        // idle = high (after optional inversion)
        while i < n {
            // find start bit: high -> low transition
            guard t.bits[i - 1], !t.bits[i] else { i += 1; continue }
            let s = Double(i)
            let lastSample = Int(s + (frameBits - 0.5) * bitSamples)
            guard lastSample < n else { break }
            // start bit must still be low at its centre
            guard !t.bits[Int(s + 0.5 * bitSamples)] else { i += 1; continue }
            var value: UInt32 = 0
            var ones = 0
            for b in 0..<c.dataBits {
                let bit = t.bits[Int(s + (1.5 + Double(b)) * bitSamples)]
                if bit { ones += 1 }
                if c.msbFirst { value = value << 1 | (bit ? 1 : 0) } else if bit { value |= 1 << UInt32(b) }
            }
            var parityOK = true
            if c.parity != .none {
                let p = t.bits[Int(s + (1.5 + Double(c.dataBits)) * bitSamples)]
                let total = ones + (p ? 1 : 0)
                parityOK = c.parity == .even ? total % 2 == 0 : total % 2 == 1
            }
            let stopIdx = Int(s + (1.5 + Double(c.dataBits + parityBits)) * bitSamples)
            let framingOK = t.bits[min(n - 1, stopIdx)]
            let start = t.time(i)
            let end = t.time(Int(s + frameBits * bitSamples) - 1)
            let text = c.format.format(value, bits: c.dataBits)
            if framingOK && parityOK {
                events.append(DecodedEvent(start: start, end: end, kind: .data, value: value, label: text))
            } else {
                errors += 1
                let why = framingOK ? "parity" : "framing"
                events.append(DecodedEvent(start: start, end: end, kind: .error, value: value, label: "\(text) (\(why) error)", short: "!\(text)"))
            }
            // resume searching from the middle of the stop bit
            i = max(i + 1, stopIdx)
        }
        let summary = "\(events.count) bytes @ \(Int(baud.rounded())) baud" + (c.baud == 0 ? " (auto)" : "") + (errors > 0 ? ", \(errors) errors" : "")
        return DecodeResult(decoderID: id, events: events, summary: summary)
    }

    /// Decoded bytes as a string (for the console view).
    public static func text(_ events: [DecodedEvent]) -> String {
        String(decoding: events.compactMap { $0.kind == .data ? $0.value.map { UInt8(truncatingIfNeeded: $0) } : nil }, as: UTF8.self)
    }
}

// MARK: - I2C

public enum I2CDecoder {
    public static func decode(_ c: I2CConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let ws = acq.channel(c.scl), let wd = acq.channel(c.sda) else {
            return DecodeResult(decoderID: id, events: [], summary: "needs CH\(c.scl + 1) and CH\(c.sda + 1)")
        }
        guard let scl = LogicTrace.digitize(ws, threshold: c.threshold),
              let sda = LogicTrace.digitize(wd, threshold: c.threshold) else {
            return DecodeResult(decoderID: id, events: [], summary: "no signal")
        }
        let n = min(scl.count, sda.count)
        var events: [DecodedEvent] = []
        var inFrame = false
        var bits: [(Bool, Int)] = [] // (sda, sample index at SCL rise)
        var byteIndex = 0
        var transactions = 0

        func flushByte(endAt: Int) {
            guard bits.count == 9 else { return }
            var v: UInt32 = 0
            for b in bits.prefix(8) { v = v << 1 | (b.0 ? 1 : 0) }
            let t0 = scl.time(bits[0].1), t8 = scl.time(bits[7].1), t9 = scl.time(bits[8].1)
            let bitTime = (t9 - t0) / 8
            let byteEnd = t8 + bitTime / 2
            if byteIndex == 0 {
                let addr = v >> 1
                let rw = v & 1 == 1 ? "R" : "W"
                events.append(DecodedEvent(start: t0 - bitTime / 2, end: byteEnd, kind: .address, value: addr,
                                           label: String(format: "Addr 0x%02X %@", addr, rw), short: String(format: "%02X%@", addr, rw)))
            } else {
                events.append(DecodedEvent(start: t0 - bitTime / 2, end: byteEnd, kind: .data, value: v, label: c.format.format(v)))
            }
            let ack = !bits[8].0
            events.append(DecodedEvent(start: byteEnd, end: t9 + bitTime / 2, kind: ack ? .ack : .nack,
                                       label: ack ? "ACK" : "NACK", short: ack ? "A" : "N"))
            bits.removeAll()
            byteIndex += 1
        }

        for i in 1..<n {
            let sclHigh = scl.bits[i] && scl.bits[i - 1]
            if sclHigh && sda.bits[i - 1] && !sda.bits[i] {
                // START or repeated START
                bits.removeAll()
                byteIndex = 0
                inFrame = true
                transactions += 1
                let t = sda.time(i)
                events.append(DecodedEvent(start: t - scl.dt * 2, end: t + scl.dt * 2, kind: .start, label: "Start", short: "S"))
            } else if sclHigh && !sda.bits[i - 1] && sda.bits[i] {
                if inFrame {
                    let t = sda.time(i)
                    events.append(DecodedEvent(start: t - scl.dt * 2, end: t + scl.dt * 2, kind: .stop, label: "Stop", short: "P"))
                }
                inFrame = false
                bits.removeAll()
            } else if inFrame && !scl.bits[i - 1] && scl.bits[i] {
                // sample SDA a little after the rising clock edge
                let at = min(n - 1, i + 1)
                bits.append((sda.bits[at], i))
                if bits.count == 9 { flushByte(endAt: i) }
            }
        }
        let bytes = events.filter { $0.kind == .data || $0.kind == .address }.count
        return DecodeResult(decoderID: id, events: events, summary: "\(transactions) transactions, \(bytes) bytes")
    }
}

// MARK: - SPI

public enum SPIDecoder {
    public static func decode(_ c: SPIConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let wc = acq.channel(c.sck), let wd = acq.channel(c.data) else {
            return DecodeResult(decoderID: id, events: [], summary: "needs CH\(c.sck + 1) and CH\(c.data + 1)")
        }
        guard let sck = LogicTrace.digitize(wc, threshold: c.threshold),
              let mosi = LogicTrace.digitize(wd, threshold: c.threshold) else {
            return DecodeResult(decoderID: id, events: [], summary: "no signal")
        }
        let cpol = c.mode & 2 != 0, cpha = c.mode & 1 != 0
        // sample on the leading edge when CPHA = 0; the leading edge is rising when CPOL = 0
        let sampleOnRising = cpol == cpha
        let n = min(sck.count, mosi.count)

        var clockEdges: [Int] = []
        for i in 1..<n where sck.bits[i - 1] != sck.bits[i] && sck.bits[i] == sampleOnRising {
            clockEdges.append(i)
        }
        guard clockEdges.count >= c.bitsPerWord else {
            return DecodeResult(decoderID: id, events: [], summary: "no clock")
        }
        // Without chip select, frames are separated by idle gaps longer than 4 clock periods.
        var periods: [Int] = []
        for (a, b) in zip(clockEdges, clockEdges.dropFirst()) { periods.append(b - a) }
        let typical = periods.sorted()[periods.count / 2]
        let gap = typical * 4

        var events: [DecodedEvent] = []
        var word: [Int] = []
        // A burst already running when the capture started can't be aligned to word boundaries.
        var skipping = clockEdges[0] < gap
        var previous: Int?
        for (k, e) in clockEdges.enumerated() {
            if let p = previous, e - p > gap { word.removeAll(); skipping = false }
            previous = e
            if skipping { continue }
            word.append(e)
            if word.count == c.bitsPerWord {
                var v: UInt32 = 0
                for (bitIdx, idx) in word.enumerated() {
                    let bit: UInt32 = mosi.bits[min(n - 1, idx + 1)] ? 1 : 0
                    if c.msbFirst { v = v << 1 | bit } else { v |= bit << UInt32(bitIdx) }
                }
                let half = Double(typical) / 2
                let start = sck.time(word.first!) - half * sck.dt
                let end = sck.time(word.last!) + half * sck.dt
                events.append(DecodedEvent(start: start, end: end, kind: .data, value: v, label: c.format.format(v, bits: c.bitsPerWord)))
                word.removeAll()
            }
            _ = k
        }
        let clock = 1 / (Double(typical) * sck.dt)
        return DecodeResult(decoderID: id, events: events, summary: "\(events.count) words, SCK ≈ \(Format.hertz(clock))")
    }
}
