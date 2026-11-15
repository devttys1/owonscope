import Foundation

public struct OneWireConfig: Codable, Equatable, Sendable {
    public enum Speed: String, Codable, CaseIterable, Sendable {
        /// Standard if the capture has a reset pulse, overdrive if every low pulse is short.
        case auto = "Auto"
        case standard = "Standard"
        case overdrive = "Overdrive"
    }
    public var channel = 0
    public var speed = Speed.auto
    public var threshold = Threshold.auto
    public var format = DataFormat.hex
    public init() {}
}

/// Dallas/Maxim 1-Wire: reset and presence pulses, time slots read as bits (LSB first), ROM
/// commands, 64-bit ROM codes with their CRC-8, function commands and data bytes.
public enum OneWireDecoder {
    public static let romCommands: [UInt8: String] = [
        0x33: "Read ROM", 0x55: "Match ROM", 0xCC: "Skip ROM", 0xF0: "Search ROM", 0xEC: "Alarm Search",
        0x3C: "Overdrive Skip ROM", 0x69: "Overdrive Match ROM", 0xA5: "Resume",
    ]
    /// Function commands of the DS18B20/DS18S20 family, the most common 1-Wire parts.
    public static let ds18x20Commands: [UInt8: String] = [
        0x44: "Convert T", 0xBE: "Read Scratchpad", 0x4E: "Write Scratchpad", 0x48: "Copy Scratchpad",
        0xB8: "Recall E²", 0xB4: "Read Power Supply",
    ]

    struct Timing {
        var reset: Double, bitZero: Double, presenceWait: Double, presenceMin: Double, slot: Double
        static let standard = Timing(reset: 400e-6, bitZero: 15e-6, presenceWait: 75e-6, presenceMin: 30e-6, slot: 70e-6)
        static let overdrive = Timing(reset: 40e-6, bitZero: 2e-6, presenceWait: 10e-6, presenceMin: 5e-6, slot: 10e-6)
    }

    public static func decode(_ c: OneWireConfig, _ acq: Acquisition, id: UUID) -> DecodeResult {
        guard let w = acq.channel(c.channel) else { return .failed(id, "CH\(c.channel + 1) off") }
        guard let t = LogicTrace.digitize(w, threshold: c.threshold) else { return .failed(id, "no signal") }
        let n = t.count
        // low pulses (start, end) in samples; one cut by the start of the capture is dropped
        var lows: [(start: Int, end: Int)] = []
        var k = 0
        while k < n, !t.bits[k] { k += 1 }
        while k < n {
            if t.bits[k] { k += 1; continue }
            let s = k
            while k < n, !t.bits[k] { k += 1 }
            if k < n { lows.append((s, k)) }
        }
        guard !lows.isEmpty else { return .failed(id, "no pulses") }
        let width = { (p: (start: Int, end: Int)) in Double(p.end - p.start) * t.dt }
        let longest = lows.map(width).max() ?? 0
        // Standard-speed zeros are 60-120 µs long and resets 480 µs; at overdrive nothing but a
        // reset (48-80 µs) is longer than 16 µs. A capture of overdrive bits with no reset in it
        // (longest < 30 µs) is the case auto detection can tell apart.
        let speed: OneWireConfig.Speed = c.speed != .auto ? c.speed : (longest >= 30e-6 ? .standard : .overdrive)
        let tm = speed == .overdrive ? Timing.overdrive : .standard
        guard t.dt < tm.bitZero / 3 else { return .failed(id, "sample rate too low for \(speed.rawValue.lowercased()) speed (speed up the timebase)") }

        var out = EventSink(t)
        var resets = 0
        // per transaction (from one reset to the next)
        var slots: [(bit: Bool, start: Int, end: Int)] = []
        var romCommand: UInt8?
        var function: UInt8?
        var scratch: [UInt8] = []

        func slotEnd(_ i: Int) -> Int {
            let limit = lows[i].start + Int(tm.slot / t.dt)
            return i + 1 < lows.count ? min(lows[i + 1].start, max(limit, lows[i].end)) : max(limit, lows[i].end)
        }
        func flushBits() {
            guard !slots.isEmpty else { return }
            let label = "\(slots.count) bit\(slots.count == 1 ? "" : "s"): " + slots.map { $0.bit ? "1" : "0" }.joined()
            out.add(Double(slots[0].start), Double(slots.last!.end), .info, label, short: "\(slots.count)b")
            slots.removeAll()
        }
        func byteDone() {
            var v: UInt8 = 0
            for (b, s) in slots.enumerated() where s.bit { v |= 1 << b }
            let s = Double(slots[0].start), e = Double(slots[7].end)
            slots.removeAll()
            if romCommand == nil {
                romCommand = v
                let name = romCommands[v]
                out.add(s, e, name == nil ? .data : .address, value: UInt32(v),
                        name.map { String(format: "%@ (0x%02X)", $0, v) } ?? c.format.format(UInt32(v)),
                        short: name.map { String($0.split(separator: " ").map { $0.prefix(1) }.joined()) } ?? nil)
                return
            }
            let rom = romCommand!
            let takesROM = rom == 0x33 || rom == 0x55 || rom == 0x69
            if takesROM && scratch.count < 8 && function == nil {
                scratch.append(v)
                out.add(s, e, .data, value: UInt32(v), c.format.format(UInt32(v)))
                if scratch.count == 8 {
                    // replace the 8 byte events with one ROM code event
                    let start = out.events[out.events.count - 8].start
                    out.events.removeLast(8)
                    let crcOK = CRC.maxim8(Array(scratch.prefix(7))) == scratch[7]
                    let serial = scratch[1...6].reversed().map { String(format: "%02X", $0) }.joined()
                    let text = String(format: "ROM %02X-%@ ", scratch[0], serial) + (crcOK ? "✓" : String(format: "CRC ≠ 0x%02X", scratch[7]))
                    out.events.append(DecodedEvent(start: start, end: t.time(Int(e)), kind: crcOK ? .data : .error,
                                                   value: UInt32(scratch[0]), label: text, short: String(format: "%02X-%@", scratch[0], serial)))
                    if !crcOK { out.errors += 1 }
                    scratch.removeAll()
                }
                return
            }
            if function == nil {
                function = v
                let name = ds18x20Commands[v]
                out.add(s, e, .address, value: UInt32(v),
                        String(format: "Function 0x%02X", v) + (name.map { " (DS18x20 \($0))" } ?? ""),
                        short: String(format: "Fn 0x%02X", v))
                return
            }
            scratch.append(v)
            // a DS18x20 scratchpad read: 8 bytes + CRC-8
            if function == 0xBE, scratch.count == 9 {
                let ok = CRC.maxim8(Array(scratch.prefix(8))) == v
                out.add(s, e, ok ? .info : .error, value: UInt32(v),
                        String(format: ok ? "CRC 0x%02X ✓" : "CRC 0x%02X ≠ 0x%02X", v, CRC.maxim8(Array(scratch.prefix(8)))),
                        short: ok ? "CRC" : "!CRC")
                return
            }
            out.add(s, e, .data, value: UInt32(v), c.format.format(UInt32(v)))
        }

        var synced = false
        var i = 0
        while i < lows.count {
            let p = lows[i]
            let wd = width(p)
            if wd >= tm.reset {
                if romCommand != 0xF0 && romCommand != 0xEC { flushBits() } else if !slots.isEmpty {
                    out.add(Double(slots[0].start), Double(slots.last!.end), .info, "Search (\(slots.count) slots)", short: "Search")
                    slots.removeAll()
                }
                resets += 1
                synced = true
                romCommand = nil; function = nil; scratch.removeAll()
                out.add(Double(p.start), Double(p.end), .start, "Reset", short: "R")
                // presence: the next low starts soon after the reset ends
                let window = Int(tm.presenceWait / t.dt)
                if i + 1 < lows.count, lows[i + 1].start - p.end <= window, width(lows[i + 1]) >= tm.presenceMin {
                    out.add(Double(lows[i + 1].start), Double(lows[i + 1].end), .ack, "Presence", short: "P")
                    i += 2
                } else {
                    let end = p.end + Int(tm.reset * 1.2 / t.dt)
                    out.add(Double(p.end), Double(min(n - 1, end)), .nack, "No presence", short: "N")
                    i += 1
                }
                continue
            }
            slots.append((wd >= tm.bitZero ? false : true, p.start, slotEnd(i)))
            // a search is triplets of (bit, complement, direction) up to the next reset, not bytes
            // before the first reset the byte boundaries are unknown, so those slots stay bits
            if synced && romCommand != 0xF0 && romCommand != 0xEC && slots.count == 8 { byteDone() }
            i += 1
        }
        if romCommand == 0xF0 || romCommand == 0xEC, !slots.isEmpty {
            out.add(Double(slots[0].start), Double(slots.last!.end), .info, "Search (\(slots.count) slots)", short: "Search")
        } else {
            flushBits()
        }
        let bytes = out.events.filter { $0.kind == .data || $0.kind == .address }.count
        let summary = "\(resets) reset\(resets == 1 ? "" : "s"), \(bytes) byte\(bytes == 1 ? "" : "s"), \(speed.rawValue.lowercased())"
            + (c.speed == .auto ? " (auto)" : "") + (out.errors > 0 ? ", \(out.errors) error\(out.errors == 1 ? "" : "s")" : "")
        return DecodeResult(decoderID: id, events: out.events, summary: summary)
    }
}
