import Foundation

public struct USBConfig: Codable, Equatable, Sendable {
    public enum Speed: String, Codable, CaseIterable, Sendable {
        /// From the idle state: D+ pulled up = full speed, D− pulled up = low speed.
        case auto = "Auto"
        case low = "Low"
        case full = "Full"

        public var bitrate: Double { self == .full ? 12e6 : 1.5e6 }
    }
    public var dPlus = 0
    public var dMinus = 1
    public var speed = Speed.auto
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}
}

/// USB 1.x low and full speed packets on D+ and D−: NRZI and bit-stuffing removed, SYNC,
/// PID (with its check nibble), token address/endpoint, SOF frame number, data payload,
/// CRC5/CRC16 checks, handshakes, EOP, keep-alives and bus reset.
public enum USBDecoder {
    public static let pidNames: [UInt8: String] = [
        0x1: "OUT", 0x9: "IN", 0x5: "SOF", 0xD: "SETUP",
        0x3: "DATA0", 0xB: "DATA1", 0x7: "DATA2", 0xF: "MDATA",
        0x2: "ACK", 0xA: "NAK", 0xE: "STALL", 0x6: "NYET",
        0xC: "PRE", 0x8: "SPLIT", 0x4: "PING",
    ]

    public static func decode(_ c: USBConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let wp = acq.channel(c.dPlus), let wm = acq.channel(c.dMinus) else {
            return .failed(id, "needs CH\(c.dPlus + 1) and CH\(c.dMinus + 1)")
        }
        guard let dp = LogicTrace.digitize(wp, threshold: c.threshold),
              let dm = LogicTrace.digitize(wm, threshold: c.threshold) else { return .failed(id, "no signal") }
        let n = min(dp.count, dm.count)
        var se0 = [Bool](repeating: false, count: n)
        var dplusHigh = [Bool](repeating: false, count: n)
        for i in 0..<n {
            se0[i] = !dp.bits[i] && !dm.bits[i]
            dplusHigh[i] = dp.bits[i] && !dm.bits[i]
        }
        let speed: USBConfig.Speed
        if c.speed != .auto {
            speed = c.speed
        } else {
            // The idle (J) state is the longest steady differential state.
            var best = 0, bestIsDPlus = true, run = 0
            for i in 0..<n where !se0[i] {
                run = i > 0 && !se0[i - 1] && dplusHigh[i] == dplusHigh[i - 1] ? run + 1 : 1
                if run > best { best = run; bestIsDPlus = dplusHigh[i] }
            }
            speed = bestIsDPlus ? .full : .low
        }
        // J = true: D+ high at full speed, D− high at low speed
        let j = LogicTrace(bits: speed == .full ? dplusHigh : (0..<n).map { dm.bits[$0] && !dp.bits[$0] },
                           t0: dp.t0, dt: dp.dt, threshold: dp.threshold)
        let bs = 1 / (speed.bitrate * j.dt)
        guard bs >= 3 else {
            return .failed(id, "sample rate too low for \(speed.rawValue.lowercased()) speed (\(bitRateText(speed.bitrate)))")
        }
        let edges = j.edges
        var out = EventSink(j)
        var packets = 0
        var i = 1
        // A packet starts with J → K, either after an EOP or out of an idle J longer than any
        // run inside a packet (six 1s plus a stuffed 0 = 7 bits), so a capture that begins
        // mid-packet is skipped rather than decoded as garbage.
        var afterEOP = false
        var jRun = 0
        while i < n {
            if j.bits[i - 1] && !se0[i - 1] { jRun += 1 } else { jRun = 0 }
            if se0[i] && !se0[i - 1] {
                // SE0 outside a packet: keep-alive (low speed) or bus reset (> 2.5 µs)
                var k = i
                while k < n, se0[k] { k += 1 }
                let width = Double(k - i) * j.dt
                if k < n || width > 2.5e-6 {
                    if width > 2.5e-6 {
                        out.add(Double(i), Double(k), .info, "Bus reset", short: "RST")
                    } else if speed == .low {
                        out.add(Double(i), Double(k), .info, "Keep-alive", short: "KA")
                    }
                }
                i = k + 1
                afterEOP = true
                jRun = 0
                continue
            }
            guard j.bits[i - 1], !j.bits[i], !se0[i], afterEOP || Double(jRun) >= 7.5 * bs else { i += 1; continue }
            let (result, end) = packet(at: i, j: j, se0: se0, edges: edges, bs: bs, format: c.format, out: &out)
            if result == .truncated { break }
            if result == .ok { packets += 1 }
            i = max(i + 1, end)
            afterEOP = result != .error || out.events.last?.kind == .stop
            jRun = 0
        }
        let summary = "\(packets) packet\(packets == 1 ? "" : "s"), \(speed.rawValue.lowercased()) speed"
            + (c.speed == .auto ? " (auto)" : "") + (out.errors > 0 ? ", \(out.errors) error\(out.errors == 1 ? "" : "s")" : "")
        return DecodeResult(decoderID: id, events: out.events, summary: summary)
    }

    enum Outcome { case ok, error, truncated }

    private static func packet(at start: Int, j: LogicTrace, se0: [Bool], edges: [Int], bs: Double,
                               format: DataFormat, out: inout EventSink) -> (Outcome, Int) {
        var sampler = BitSampler(j, edges: edges, bitSamples: bs, start: Double(start))
        var level = true // idle J
        var ones = 0
        var bits: [(bit: Bool, start: Double, end: Double)] = []
        var eop: (start: Double, end: Double)?
        var stuffError: Double?
        while let b = sampler.next() {
            let at = Int(b.start + bs / 2)
            if se0[at] {
                // EOP: SE0 then J
                var k = at
                while k < se0.count, se0[k] { k += 1 }
                guard k < se0.count else { return (.truncated, k) }
                eop = (b.start, Double(k) + bs)
                break
            }
            let bit = b.bit == level // NRZI: no transition = 1
            level = b.bit
            if ones == 6 {
                // a stuffed 0 follows six 1s
                if bit { stuffError = b.start; break }
                ones = 0
                continue
            }
            ones = bit ? ones + 1 : 0
            bits.append((bit, b.start, b.end))
            if bits.count > 8 * 1100 { break } // longer than any packet: not USB
        }
        guard let eop else {
            if let at = stuffError {
                out.add(at, at + bs * 7, .error, "Bit-stuffing error", short: "!")
                return (.error, Int(at + bs * 7))
            }
            return (.truncated, j.count)
        }
        let endIndex = Int(eop.end)
        func field(_ from: Int, _ count: Int) -> UInt32 {
            var v: UInt32 = 0
            for k in 0..<count where bits[from + k].bit { v |= 1 << UInt32(k) }
            return v
        }
        // SYNC: 00000001 (KJKJKJKK)
        guard bits.count >= 16, field(0, 8) == 0x80 else {
            let end = bits.last?.end ?? eop.start
            out.add(Double(start), end, .error, "Bad SYNC", short: "!")
            out.add(eop.start, eop.end, .stop, "EOP", short: "E")
            return (.error, endIndex)
        }
        out.add(bits[0].start, bits[7].end, .start, "SYNC", short: "S")
        let pidByte = UInt8(field(8, 8))
        let pid = pidByte & 0xF
        let name = pidNames[pid] ?? "PID?"
        let pidOK = pidByte >> 4 == ~pid & 0xF
        let pidKind: DecodedEvent.Kind
        switch pid {
        case _ where !pidOK: pidKind = .error
        case 0x2: pidKind = .ack
        case 0xA, 0xE, 0x6: pidKind = .nack
        default: pidKind = .info
        }
        out.add(bits[8].start, bits[15].end, pidKind, value: UInt32(pidByte), pidOK ? name : String(format: "PID 0x%02X (check error)", pidByte),
                short: pidOK ? String(name.prefix(5)) : "!PID")
        var ok = pidOK
        let payload = bits.count - 16
        switch pid {
        case 0x1, 0x9, 0xD, 0x4, 0x5:
            // tokens and SOF: 11 bits + CRC5
            guard payload == 16 else { ok = false; lengthError(bits, from: 16, &out); break }
            let v = field(16, 11)
            if pid == 0x5 {
                out.add(bits[16].start, bits[26].end, .data, value: v, "Frame \(v)", short: "\(v)")
            } else {
                let addr = v & 0x7F, ep = v >> 7
                out.add(bits[16].start, bits[26].end, .address, value: addr, "Addr \(addr) EP \(ep)", short: "\(addr).\(ep)")
            }
            let crc = field(27, 5), want = CRC.usb5(bits[16..<27].map(\.bit))
            ok = crcEvent(crc, want, width: 5, bits[27].start, bits[31].end, &out) && ok
        case 0x3, 0xB, 0x7, 0xF:
            guard payload >= 16, payload % 8 == 0 else { ok = false; lengthError(bits, from: 16, &out); break }
            var bytes: [UInt8] = []
            for k in stride(from: 16, to: bits.count - 16, by: 8) {
                let v = field(k, 8)
                bytes.append(UInt8(v))
                out.add(bits[k].start, bits[k + 7].end, .data, value: v, format.format(v))
            }
            let crcAt = bits.count - 16
            ok = crcEvent(field(crcAt, 16), CRC.usb16(bytes), width: 16, bits[crcAt].start, bits[crcAt + 15].end, &out) && ok
        case 0x8:
            // SPLIT: hub address, SC, port, S, E/U, ET, CRC5 (decoded as fields of the 19-bit body)
            guard payload == 24 else { ok = false; lengthError(bits, from: 16, &out); break }
            let hub = field(16, 7), port = field(24, 7)
            out.add(bits[16].start, bits[37].end, .address, value: hub, "Hub \(hub) port \(port)", short: "\(hub):\(port)")
            ok = crcEvent(field(35, 5), CRC.usb5(bits[16..<35].map(\.bit)), width: 5, bits[35].start, bits[39].end, &out) && ok
        default:
            if payload != 0 { ok = false; lengthError(bits, from: 16, &out) }
        }
        out.add(eop.start, eop.end, .stop, "EOP", short: "E")
        return (ok ? .ok : .error, endIndex)
    }

    private static func crcEvent(_ got: UInt32, _ want: UInt32, width: Int, _ start: Double, _ end: Double,
                                 _ out: inout EventSink) -> Bool {
        let f = width == 5 ? "0x%02X" : "0x%04X"
        if got == want {
            out.add(start, end, .info, value: got, "CRC\(width) " + String(format: f, got), short: "CRC")
            return true
        }
        out.add(start, end, .error, value: got, "CRC\(width) " + String(format: f + " ≠ " + f, got, want), short: "!CRC")
        return false
    }

    private static func lengthError(_ bits: [(bit: Bool, start: Double, end: Double)], from: Int, _ out: inout EventSink) {
        guard from < bits.count else { return }
        out.add(bits[from].start, bits[bits.count - 1].end, .error, "Bad length (\(bits.count - from) bits)", short: "!len")
    }
}
