import Foundation

public struct CANConfig: Codable, Equatable, Sendable {
    /// What the probe is on, which sets which level is dominant.
    public enum Signal: String, Codable, CaseIterable, Sendable {
        /// Recessive is the level of the longest constant run (the idle bus).
        case auto = "Auto"
        /// Controller RX/TX pin or CAN_L: dominant low.
        case rx = "RX/TX"
        /// CAN_H: dominant high.
        case canH = "CAN_H"
        case canL = "CAN_L"
    }
    public var channel = 0
    /// Bits per second; 0 = detect.
    public var bitrate: Double = 0
    /// Where in each bit the level is read, as a fraction of the bit (CAN controllers use 0.75-0.875).
    public var samplePoint = 0.75
    public var signal = Signal.auto
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}

    public static let standardBitrates: [Double] = [10_000, 20_000, 33_333, 50_000, 62_500, 83_333, 100_000, 125_000,
                                                    250_000, 500_000, 800_000, 1_000_000]
}

func bitRateText(_ r: Double, unit: String = "bit/s") -> String {
    if r >= 1e6 { return String(format: "%g M\(unit)", (r / 1e4).rounded() / 100) }
    if r >= 1e3 { return String(format: "%g k\(unit)", (r / 10).rounded() / 100) }
    return "\(Int(r.rounded())) \(unit)"
}

/// Classic CAN 2.0A/B frames: bit de-stuffing, standard and extended IDs, remote frames,
/// CRC-15 check, ACK slot, and stuff/form errors. CAN FD frames are detected and skipped.
public enum CANDecoder {
    public static func decode(_ c: CANConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let w = acq.channel(c.channel) else { return .failed(id, "CH\(c.channel + 1) off") }
        guard var t = LogicTrace.digitize(w, threshold: c.threshold) else { return .failed(id, "no signal") }
        // Normalise to recessive = true (like an idle UART line).
        let dominantHigh: Bool
        switch c.signal {
        case .rx, .canL: dominantHigh = false
        case .canH: dominantHigh = true
        case .auto:
            let runs = t.longestRuns
            dominantHigh = runs.low > runs.high
        }
        if dominantHigh { t.bits = t.bits.map { !$0 } }
        guard let rate = c.bitrate > 0 ? c.bitrate : LogicTrace.detectBitRate(t, standards: CANConfig.standardBitrates) else {
            return .failed(id, "no edges")
        }
        let bs = 1 / (rate * t.dt)
        guard bs >= 3 else { return .failed(id, "sample rate too low for \(bitRateText(rate)) (slow the timebase)") }

        let edges = t.edges
        var out = EventSink(t)
        var frames = 0
        let n = t.count
        // A SOF is a dominant bit after bus idle. Inside a frame, stuffing keeps runs to 5 bits, so
        // a recessive run of 10 bits (ACK delimiter + EOF + intermission) means idle. The capture's
        // first run needs 7, and after a good frame's EOF only the 3-bit intermission is left.
        var searchFrom = 0
        var idleBits = 7.0
        while searchFrom < n {
            var sof: Int?
            var run = 0
            for k in searchFrom..<n {
                if t.bits[k] { run += 1; continue }
                if Double(run) >= (idleBits - 0.5) * bs { sof = k; break }
                run = 0
                idleBits = 10
            }
            guard let s = sof else { break }
            var f = FrameReader(sampler: BitSampler(t, edges: edges, bitSamples: bs, start: Double(s), samplePoint: c.samplePoint))
            let result = f.read(c, into: &out)
            if result == .truncated { break }
            if result == .ok { frames += 1 }
            searchFrom = max(s + 1, Int(f.sampler.position))
            idleBits = result == .ok ? 2 : 10
        }
        let summary = "\(frames) frame\(frames == 1 ? "" : "s") @ \(bitRateText(rate))" + (c.bitrate == 0 ? " (auto)" : "")
            + (out.errors > 0 ? ", \(out.errors) error\(out.errors == 1 ? "" : "s")" : "")
        return DecodeResult(decoderID: id, events: out.events, summary: summary)
    }

    enum Outcome { case ok, error, truncated }

    struct FrameReader {
        var sampler: BitSampler
        private var last: Bool?
        private var run = 0
        /// De-stuffed bits from SOF, for the CRC.
        private(set) var bits: [Bool] = []
        private var stuffError: Double?

        init(sampler: BitSampler) { self.sampler = sampler }

        /// Next de-stuffed bit; nil at the end of the capture or on a stuff error.
        mutating func bit() -> (bit: Bool, start: Double, end: Double)? {
            if run == 5 {
                guard let s = sampler.next() else { return nil }
                if s.bit == last { stuffError = s.start; return nil }
                last = s.bit
                run = 1
            }
            guard let b = sampler.next() else { return nil }
            if b.bit == last { run += 1 } else { last = b.bit; run = 1 }
            bits.append(b.bit)
            return b
        }

        /// Next `count` bits MSB first, with the start of the first and end of the last.
        mutating func field(_ count: Int) -> (value: UInt32, start: Double, end: Double)? {
            var v: UInt32 = 0
            var start = 0.0, end = 0.0
            for k in 0..<count {
                guard let b = bit() else { return nil }
                if k == 0 { start = b.start }
                end = b.end
                v = v << 1 | (b.bit ? 1 : 0)
            }
            return (v, start, end)
        }

        mutating func read(_ c: CANConfig, into out: inout EventSink) -> Outcome {
            func fail(_ out: inout EventSink, _ at: Double, _ what: String) -> Outcome {
                out.add(at, at + sampler.bitSamples * 6, .error, what, short: "!")
                return .error
            }
            // SOF
            guard let sof = bit() else { return .truncated }
            out.add(sof.start, sof.end, .start, "SOF", short: "S")
            guard let idA = field(11), let srr = bit(), let ide = bit() else { return endOfData(&out) }
            var ident = idA.value
            var extended = false
            var rtr = srr.bit
            var idEnd = srr.end
            if ide.bit {
                extended = true
                guard let idB = field(18), let r = bit() else { return endOfData(&out) }
                ident = ident << 18 | idB.value
                rtr = r.bit
                idEnd = r.end
                guard let fdf = bit() else { return endOfData(&out) }
                if fdf.bit { return fd(&out, at: fdf.start) }
                guard bit() != nil else { return endOfData(&out) } // r0
            } else {
                guard let fdf = bit() else { return endOfData(&out) }
                if fdf.bit { return fd(&out, at: fdf.start) }
            }
            let idText = extended ? String(format: "0x%08X", ident) : String(format: "0x%03X", ident)
            out.add(idA.start, idEnd, .address, value: ident,
                    "ID \(idText)\(extended ? " ext" : "")\(rtr ? " RTR" : "")",
                    short: (extended ? String(format: "%X", ident) : String(format: "%03X", ident)) + (rtr ? "R" : ""))
            guard let dlc = field(4) else { return endOfData(&out) }
            out.add(dlc.start, dlc.end, .info, value: dlc.value, "DLC \(dlc.value)", short: "\(dlc.value)")
            let length = rtr ? 0 : Int(min(dlc.value, 8))
            for _ in 0..<length {
                guard let byte = field(8) else { return endOfData(&out) }
                out.add(byte.start, byte.end, .data, value: byte.value, c.format.format(byte.value))
            }
            let expected = CRC.can15(bits)
            guard let crc = field(15) else { return endOfData(&out) }
            if crc.value == expected {
                out.add(crc.start, crc.end, .info, value: crc.value, String(format: "CRC 0x%04X", crc.value), short: "CRC")
            } else {
                out.add(crc.start, crc.end, .error, value: crc.value,
                        String(format: "CRC 0x%04X ≠ 0x%04X", crc.value, expected), short: "!CRC")
            }
            // a stuff bit can follow the last CRC bit; nothing after it is stuffed
            if run == 5 {
                guard let s = sampler.next() else { return .truncated }
                if s.bit == last { return fail(&out, s.start, "Stuff error") }
            }
            guard let delim = sampler.next() else { return .truncated }
            guard delim.bit else { return fail(&out, delim.start, "Form error (CRC delimiter)") }
            guard let ack = sampler.next(), let ackDelim = sampler.next() else { return .truncated }
            if ack.bit {
                out.add(ack.start, ackDelim.end, .nack, "No ACK", short: "N")
            } else {
                out.add(ack.start, ackDelim.end, .ack, "ACK", short: "A")
            }
            var eofEnd = ackDelim.end
            for k in 0..<7 {
                guard let b = sampler.next() else { return .truncated }
                if !b.bit { return fail(&out, b.start, k == 0 && !ackDelim.bit ? "Form error (ACK delimiter)" : "Error frame") }
                eofEnd = b.end
            }
            out.add(ackDelim.end, eofEnd, .stop, "EOF", short: "E")
            return crc.value == expected ? .ok : .error
        }

        private mutating func fd(_ out: inout EventSink, at: Double) -> Outcome {
            out.add(at, at + sampler.bitSamples * 4, .info, "CAN FD frame (not decoded)", short: "FD")
            return .error
        }

        /// A field couldn't be read: a stuff error (often an error frame) or the end of the capture.
        private mutating func endOfData(_ out: inout EventSink) -> Outcome {
            guard let at = stuffError else { return .truncated }
            out.add(at, at + sampler.bitSamples * 6, .error, "Stuff error", short: "!")
            return .error
        }
    }
}
