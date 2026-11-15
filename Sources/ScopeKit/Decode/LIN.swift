import Foundation

public struct LINConfig: Codable, Equatable, Sendable {
    public enum Checksum: String, Codable, CaseIterable, Sendable {
        /// Accept either; the label says which one matched.
        case auto = "Auto"
        /// LIN 1.x: data bytes only.
        case classic = "Classic"
        /// LIN 2.x: protected ID and data bytes.
        case enhanced = "Enhanced"
    }
    public var channel = 0
    /// 0 = measure from each frame's sync field.
    public var baud: Double = 0
    public var checksum = Checksum.auto
    public var invert = false
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}

    public static let standardBauds: [Double] = [2400, 4800, 9600, 10_400, 19_200, 20_000]
}

/// LIN frames: break, sync (baud measured from it), protected ID with parity check, the
/// response bytes, and the classic or enhanced checksum.
public enum LINDecoder {
    /// The 6-bit frame ID with its two parity bits.
    public static func protectedID(_ id: UInt8) -> UInt8 {
        let b = { (i: Int) in (id >> i) & 1 }
        let p0 = b(0) ^ b(1) ^ b(2) ^ b(4)
        let p1 = ~(b(1) ^ b(3) ^ b(4) ^ b(5)) & 1
        return id & 0x3F | p0 << 6 | p1 << 7
    }

    /// Inverted 8-bit sum with end-around carry.
    public static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var sum: UInt32 = 0
        for b in bytes {
            sum += UInt32(b)
            if sum > 0xFF { sum -= 0xFF }
        }
        return ~UInt8(sum)
    }

    public static func decode(_ c: LINConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let w = acq.channel(c.channel) else { return .failed(id, "CH\(c.channel + 1) off") }
        guard let t = LogicTrace.digitize(w, threshold: c.threshold, invert: c.invert) else { return .failed(id, "no signal") }
        let edges = t.edges
        guard edges.count >= 10 else { return .failed(id, "no edges") }
        let n = t.count
        var out = EventSink(t)
        var frames = 0
        var lastBaud: Double?

        // Each frame starts with a break: dominant (low) for at least 13 bits, much longer
        // than any low run in a byte (9 bits at most for 0x00).
        let fixedBit = c.baud > 0 ? 1 / (c.baud * t.dt) : nil
        // Low runs: (start, length)
        var lows: [(Int, Int)] = []
        var k = 0
        while k < n {
            if !t.bits[k] {
                let s = k
                while k < n, !t.bits[k] { k += 1 }
                lows.append((s, k - s))
            } else { k += 1 }
        }
        // The narrowest low runs are one bit (the sync field has four); breaks are 11+ times that.
        let sortedLows = lows.map(\.1).sorted()
        let narrowest = sortedLows.isEmpty ? 0 : sortedLows[sortedLows.count / 10]
        guard narrowest > 0 else { return .failed(id, "no edges") }
        let breakMin = Double(fixedBit.map { $0 * 11 } ?? Double(narrowest) * 11)

        for (li, low) in lows.enumerated() {
            guard Double(low.1) >= breakMin, low.0 > 0 else { continue }
            let breakEnd = low.0 + low.1
            // sync field: 0x55 = start bit + 01010101 + stop: five falling edges two bits apart
            guard li + 5 < lows.count else {
                out.add(Double(low.0), Double(breakEnd), .start, "Break", short: "Brk")
                break
            }
            let syncStart = lows[li + 1].0
            let fifthFall = lows[li + 5].0
            // measured over 8 bits, then snapped to a standard rate within 3 %
            var measured = Double(fifthFall - syncStart) / 8
            let raw = 1 / (measured * t.dt)
            if let std = LINConfig.standardBauds.min(by: { abs($0 - raw) < abs($1 - raw) }), abs(std - raw) / raw < 0.03 {
                measured = 1 / (std * t.dt)
            }
            let bs = fixedBit ?? measured
            guard bs >= 3 else { return .failed(id, "sample rate too low (slow the timebase)") }
            let baud = 1 / (bs * t.dt)
            lastBaud = baud
            out.add(Double(low.0), Double(breakEnd), .start, "Break", short: "Brk")
            // the break delimiter must be at least one bit
            guard Double(syncStart - breakEnd) >= bs * 0.6 else {
                out.add(Double(breakEnd), Double(syncStart), .error, "Short break delimiter", short: "!")
                continue
            }
            var pos = Double(syncStart)
            func byte() -> (value: UInt8, start: Double, end: Double, ok: Bool)? {
                // align to the falling edge of the start bit
                guard let e = LogicTrace.firstEdge(edges, atOrAfter: Int(pos)), !t.bits[edges[e]] else { return nil }
                let s = Double(edges[e])
                guard Int(s + 9.5 * bs) < n else { return nil }
                var v: UInt8 = 0
                for b in 0..<8 where t.bits[Int(s + (1.5 + Double(b)) * bs)] { v |= 1 << b }
                let ok = t.bits[Int(s + 9.5 * bs)] && !t.bits[Int(s + 0.5 * bs)]
                pos = s + 9.6 * bs
                return (v, s, s + 10 * bs, ok)
            }
            guard let sync = byte() else { break }
            if sync.value == 0x55 && sync.ok {
                out.add(sync.start, sync.end, .info, value: 0x55, "Sync \(bitRateText(baud, unit: "Bd"))", short: "Sync")
            } else {
                out.add(sync.start, sync.end, .error, value: UInt32(sync.value), String(format: "Sync 0x%02X ≠ 0x55", sync.value), short: "!Sync")
                continue
            }
            guard let pid = byte() else { break }
            let ident = pid.value & 0x3F
            let parityOK = protectedID(ident) == pid.value && pid.ok
            out.add(pid.start, pid.end, parityOK ? .address : .error, value: UInt32(ident),
                    String(format: "ID 0x%02X", ident) + (parityOK ? "" : " (parity error)"),
                    short: String(format: parityOK ? "%02X" : "!%02X", ident))
            // response: bytes until a gap, the next break or the end; the last byte is the checksum
            let nextBreak = lows[(li + 1)...].first { Double($0.1) >= breakMin }?.0 ?? n
            var response: [(value: UInt8, start: Double, end: Double, ok: Bool)] = []
            while response.count < 9 {
                guard let e = LogicTrace.firstEdge(edges, atOrAfter: Int(pos)), edges[e] < nextBreak,
                      Double(edges[e]) - pos < bs * 14 else { break } // inter-byte space up to ~1.4 bytes
                guard let b = byte(), Int(b.end) <= nextBreak else { break }
                response.append(b)
            }
            // The capture ended inside the response: show the bytes, but no checksum verdict.
            if nextBreak == n, Int(pos + bs * 14) >= n, !response.isEmpty {
                for b in response {
                    out.add(b.start, b.end, b.ok ? .data : .error, value: UInt32(b.value), c.format.format(UInt32(b.value)))
                }
                continue
            }
            guard let check = response.last, response.count >= 2 else {
                if response.isEmpty {
                    out.add(pid.end, pid.end + bs * 10, .info, "No response", short: "—")
                    frames += 1
                } else {
                    let b = response[0]
                    out.add(b.start, b.end, .error, value: UInt32(b.value), c.format.format(UInt32(b.value)) + " (no checksum)", short: "!")
                }
                continue
            }
            let data = response.dropLast().map(\.value)
            for b in response.dropLast() {
                let text = c.format.format(UInt32(b.value))
                out.add(b.start, b.end, b.ok ? .data : .error, value: UInt32(b.value), b.ok ? text : text + " (framing error)",
                        short: b.ok ? nil : "!" + text)
            }
            let classic = checksum(data), enhanced = checksum([pid.value] + data)
            let which: String?
            switch c.checksum {
            case .classic: which = check.value == classic ? "classic" : nil
            case .enhanced: which = check.value == enhanced ? "enhanced" : nil
            case .auto: which = check.value == enhanced ? "enhanced" : check.value == classic ? "classic" : nil
            }
            if let which, check.ok {
                out.add(check.start, check.end, .info, value: UInt32(check.value),
                        String(format: "Checksum 0x%02X (%@)", check.value, which), short: "✓")
                frames += 1
            } else {
                let want = c.checksum == .classic ? classic : enhanced
                out.add(check.start, check.end, .error, value: UInt32(check.value),
                        String(format: "Checksum 0x%02X ≠ 0x%02X", check.value, want), short: "!Σ")
            }
        }
        guard let baud = lastBaud else { return .failed(id, "no break found") }
        let summary = "\(frames) frame\(frames == 1 ? "" : "s") @ \(bitRateText(baud, unit: "Bd"))" + (c.baud == 0 ? " (sync)" : "")
            + (out.errors > 0 ? ", \(out.errors) error\(out.errors == 1 ? "" : "s")" : "")
        return DecodeResult(decoderID: id, events: out.events, summary: summary)
    }
}
