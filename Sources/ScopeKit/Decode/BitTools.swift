import Foundation

// Helpers shared by the bit-serial decoders (CAN, LIN, USB, 1-Wire).

extension LogicTrace {
    /// Estimates the bit rate from the narrowest pulse (10th percentile, to ignore glitches),
    /// snapped to the nearest of `standards` when one is within 12 %.
    static func detectBitRate(_ t: LogicTrace, standards: [Double]) -> Double? {
        let e = t.edges
        guard e.count >= 3 else { return nil }
        var widths: [Int] = []
        widths.reserveCapacity(e.count)
        for (a, b) in zip(e, e.dropFirst()) { widths.append(b - a) }
        widths.sort()
        let w = Double(widths[min(widths.count - 1, widths.count / 10)])
        guard w >= 2 else { return nil }
        let raw = 1 / (w * t.dt)
        if let std = standards.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(std - raw) / raw < 0.12 { return std }
        return raw
    }

    /// Length of the longest run of each level, in samples.
    var longestRuns: (low: Int, high: Int) {
        var low = 0, high = 0, run = 0
        for i in 0..<count {
            run = i > 0 && bits[i] == bits[i - 1] ? run + 1 : 1
            if bits[i] { high = max(high, run) } else { low = max(low, run) }
        }
        return (low, high)
    }

    /// Index of the first edge at or after sample `from`, using the sorted `edges` list.
    static func firstEdge(_ edges: [Int], atOrAfter from: Int) -> Int? {
        var lo = 0, hi = edges.count
        while lo < hi {
            let m = (lo + hi) / 2
            if edges[m] < from { lo = m + 1 } else { hi = m }
        }
        return lo < edges.count ? lo : nil
    }
}

/// Samples NRZ bits one at a time, resynchronising its bit clock on every edge, as a
/// CAN controller or UART receiver does. Positions are in samples.
struct BitSampler {
    let trace: LogicTrace
    let edges: [Int]
    let bitSamples: Double
    /// Where in the bit the level is read, 0..1.
    let samplePoint: Double
    /// Start of the next bit.
    private(set) var position: Double
    private var edgeIndex: Int

    init(_ trace: LogicTrace, edges: [Int], bitSamples: Double, start: Double, samplePoint: Double = 0.5) {
        self.trace = trace
        self.edges = edges
        self.bitSamples = bitSamples
        self.samplePoint = samplePoint
        position = start
        edgeIndex = LogicTrace.firstEdge(edges, atOrAfter: Int(start)) ?? edges.count
    }

    /// Reads the next bit: (level, start sample, end sample), or nil past the end of the capture.
    mutating func next() -> (bit: Bool, start: Double, end: Double)? {
        // An edge within ±40 % of a bit of the expected boundary marks the real boundary.
        let window = bitSamples * 0.4
        while edgeIndex < edges.count, Double(edges[edgeIndex]) < position - window { edgeIndex += 1 }
        if edgeIndex < edges.count, abs(Double(edges[edgeIndex]) - position) <= window {
            position = Double(edges[edgeIndex])
            edgeIndex += 1
        }
        let at = Int(position + bitSamples * samplePoint)
        guard at < trace.count else { return nil }
        let start = position
        position += bitSamples
        return (trace.bits[at], start, position)
    }

    /// Moves the next bit's start to `sample`.
    mutating func seek(_ sample: Double) {
        position = sample
        edgeIndex = LogicTrace.firstEdge(edges, atOrAfter: Int(sample - bitSamples * 0.4)) ?? edges.count
    }
}

/// Bitwise CRCs used by the decoders. `reflected` CRCs take bits LSB first.
enum CRC {
    /// CRC-15/CAN over bits in transmission order: poly 0x4599, init 0.
    static func can15(_ bits: [Bool]) -> UInt32 {
        var crc: UInt32 = 0
        for b in bits {
            let top = (crc >> 14) & 1 == 1
            crc = (crc << 1) & 0x7FFF
            if top != b { crc ^= 0x4599 }
        }
        return crc
    }

    /// CRC-5/USB over bits in transmission order (LSB first): poly 0x05, init 0x1F, xorout 0x1F.
    static func usb5(_ bits: [Bool]) -> UInt32 {
        var crc: UInt32 = 0x1F
        for b in bits {
            let x = (crc & 1 == 1) != b
            crc >>= 1
            if x { crc ^= 0x14 }
        }
        return crc ^ 0x1F
    }

    /// CRC-16/USB over bytes: poly 0x8005 reflected, init 0xFFFF, xorout 0xFFFF.
    static func usb16(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc ^ 0xFFFF
    }

    /// Dallas/Maxim CRC-8 (1-Wire ROM codes and scratchpads): poly 0x31 reflected, init 0.
    static func maxim8(_ bytes: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            var b = byte
            for _ in 0..<8 {
                let mix = (crc ^ b) & 1
                crc >>= 1
                if mix == 1 { crc ^= 0x8C }
                b >>= 1
            }
        }
        return crc
    }
}

/// Builds decoder events from sample positions.
struct EventSink {
    let trace: LogicTrace
    var events: [DecodedEvent] = []
    var errors = 0

    init(_ trace: LogicTrace) { self.trace = trace }

    mutating func add(_ start: Double, _ end: Double, _ kind: DecodedEvent.Kind, value: UInt32? = nil, _ label: String, short: String? = nil) {
        if kind == .error { errors += 1 }
        events.append(DecodedEvent(start: trace.t0 + start * trace.dt, end: trace.t0 + end * trace.dt,
                                   kind: kind, value: value, label: label, short: short))
    }
}

extension DecodeResult {
    static func failed(_ id: UUID, _ summary: String) -> DecodeResult {
        DecodeResult(decoderID: id, events: [], summary: summary)
    }
}
