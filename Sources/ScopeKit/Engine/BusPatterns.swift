import Foundation

/// Line states over time, repeating forever. Each state is a bit mask: bit 0 is the first
/// line, bit 1 the second. Used to simulate the serial buses.
struct Timeline: Sendable {
    private(set) var ends: [Double] = []
    private(set) var states: [UInt8] = []
    /// State after the last segment (bus idle), until the period repeats.
    var idle: UInt8
    var period: Double = 0

    init(idle: UInt8) { self.idle = idle }

    mutating func add(_ duration: Double, _ state: UInt8) {
        guard duration > 0 else { return }
        if let last = states.last, last == state {
            ends[ends.count - 1] += duration
        } else {
            ends.append((ends.last ?? 0) + duration)
            states.append(state)
        }
        period = ends.last!
    }

    /// Bits at `rate`, each mapped to a state.
    mutating func add(bits: [Bool], rate: Double, _ state: (Bool) -> UInt8) {
        for b in bits { add(1 / rate, state(b)) }
    }

    mutating func gap(_ duration: Double) { add(duration, idle) }

    func state(at t: Double) -> UInt8 {
        guard period > 0 else { return idle }
        var p = t.truncatingRemainder(dividingBy: period)
        if p < 0 { p += period }
        var lo = 0, hi = ends.count
        while lo < hi {
            let m = (lo + hi) / 2
            if ends[m] <= p { lo = m + 1 } else { hi = m }
        }
        return lo < states.count ? states[lo] : idle
    }

    func line(_ i: Int, at t: Double) -> Bool { state(at: t) >> i & 1 == 1 }
}

enum BusPatterns {
    // MARK: Simulator scenarios

    /// 500 kbit/s: a standard frame, a J1939 extended frame and a remote frame.
    static let canScenario: Timeline = {
        var tl = Timeline(idle: 1)
        let rate = 500_000.0
        for f in [canFrame(id: 0x0C1, data: [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]),
                  canFrame(id: 0x18FE_F100, extended: true, data: [0xFF, 0xFF, 0x64, 0x00, 0x2A]),
                  canFrame(id: 0x7DF, rtr: true, data: [], dlc: 8)] {
            tl.add(bits: f, rate: rate) { $0 ? 1 : 0 }
            tl.gap(40e-6)
        }
        tl.gap(300e-6)
        return tl
    }()

    /// 19.2 kBd: an unconditional frame (enhanced checksum), a diagnostic frame (classic),
    /// and a header nobody answers.
    static let linScenario: Timeline = {
        var tl = Timeline(idle: 1)
        let baud = 19_200.0
        for f in [linFrame(id: 0x10, data: [0x01, 0x80, 0x7F, 0xC4], baud: baud),
                  linFrame(id: 0x3C, data: [0x7F, 0x06, 0xB2, 0x00, 0xFF, 0x7F, 0xFF, 0xFF], enhanced: false, baud: baud),
                  linFrame(id: 0x22, data: [], baud: baud)] {
            tl.add(bits: f, rate: baud) { $0 ? 1 : 0 }
            tl.gap(1.5e-3)
        }
        tl.gap(3e-3)
        return tl
    }()

    /// Low speed enumeration: SETUP GET_DESCRIPTOR, then IN with the first 8 bytes of the device descriptor.
    static let usbScenario: Timeline = {
        var tl = Timeline(idle: USBState.dMinus.rawValue)
        let gap = 6 / 1.5e6
        let packets: [[Bool]] = [
            usbToken(pid: 0xD, address: 0, endpoint: 0),
            usbData(pid: 0x3, [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00]),
            usbPacket(pid: 0x2),
            usbToken(pid: 0x9, address: 0, endpoint: 0),
            usbData(pid: 0xB, [0x12, 0x01, 0x10, 0x01, 0x00, 0x00, 0x00, 0x08]),
            usbPacket(pid: 0x2),
        ]
        for (i, p) in packets.enumerated() {
            addUSB(p, fullSpeed: false, to: &tl)
            tl.gap(i % 3 == 2 ? 20e-6 : gap)
        }
        tl.add(2 / 1.5e6, USBState.se0.rawValue) // keep-alive
        tl.gap(60e-6)
        return tl
    }()

    /// DS18B20: Skip ROM + Convert T, then Read ROM, then Skip ROM + Read Scratchpad (25.0625 °C).
    static let oneWireScenario: Timeline = {
        var w = OneWireWriter()
        w.reset(); w.byte(0xCC); w.byte(0x44)
        w.tl.gap(200e-6)
        let rom: [UInt8] = [0x28, 0xFF, 0x4C, 0x1A, 0x6B, 0x05, 0x00]
        w.reset(); w.byte(0x33)
        for b in rom + [CRC.maxim8(rom)] { w.byte(b, read: true) }
        w.tl.gap(200e-6)
        let pad: [UInt8] = [0x91, 0x01, 0x4B, 0x46, 0x7F, 0xFF, 0x0C, 0x10]
        w.reset(); w.byte(0xCC); w.byte(0xBE)
        for b in pad + [CRC.maxim8(pad)] { w.byte(b, read: true) }
        w.tl.gap(2e-3)
        return w.tl
    }()

    // MARK: CAN

    /// Bits of a classic CAN frame (true = recessive), stuffed, through EOF and intermission.
    static func canFrame(id: UInt32, extended: Bool = false, rtr: Bool = false, data: [UInt8], dlc: Int? = nil,
                         ack: Bool = true, corruptCRC: Bool = false) -> [Bool] {
        var b: [Bool] = [false]
        func put(_ v: UInt32, _ n: Int) { for i in (0..<n).reversed() { b.append((v >> UInt32(i)) & 1 == 1) } }
        if extended {
            put(id >> 18, 11); b += [true, true]; put(id & 0x3FFFF, 18); b.append(rtr); b += [false, false]
        } else {
            put(id, 11); b.append(rtr); b += [false, false]
        }
        put(UInt32(dlc ?? data.count), 4)
        if !rtr { for byte in data { put(UInt32(byte), 8) } }
        put(CRC.can15(b) ^ (corruptCRC ? 1 : 0), 15)
        var out: [Bool] = []
        var run = 0
        var last: Bool?
        for bit in b {
            out.append(bit)
            run = bit == last ? run + 1 : 1
            last = bit
            if run == 5 { out.append(!bit); last = !bit; run = 1 }
        }
        out += [true, !ack, true] + Array(repeating: true, count: 7 + 3)
        return out
    }

    // MARK: LIN

    static func uartBits(_ byte: UInt8) -> [Bool] {
        [false] + (0..<8).map { (byte >> $0) & 1 == 1 } + [true]
    }

    /// A LIN frame: break, delimiter, sync, protected ID, data and checksum (low = dominant).
    static func linFrame(id: UInt8, data: [UInt8], enhanced: Bool = true, baud: Double) -> [Bool] {
        let pid = LINDecoder.protectedID(id)
        var bits = Array(repeating: false, count: 13) + [true]
        bits += uartBits(0x55) + uartBits(pid)
        guard !data.isEmpty else { return bits }
        bits += [true, true] // response space
        for d in data { bits += uartBits(d) }
        bits += uartBits(LINDecoder.checksum(enhanced ? [pid] + data : data))
        return bits
    }

    // MARK: USB

    enum USBState: UInt8 {
        // bit 0 = D+, bit 1 = D−
        case se0 = 0, dPlus = 1, dMinus = 2
    }

    /// Bits of a packet (SYNC, PID, payload) in transmission order, before NRZI and stuffing.
    static func usbPacket(pid: UInt8, payload: [Bool] = []) -> [Bool] {
        let sync: [Bool] = [false, false, false, false, false, false, false, true]
        let pidByte = pid & 0xF | (~pid & 0xF) << 4
        return sync + (0..<8).map { (pidByte >> $0) & 1 == 1 } + payload
    }

    static func lsb(_ v: UInt32, _ n: Int) -> [Bool] { (0..<n).map { (v >> UInt32($0)) & 1 == 1 } }

    static func usbToken(pid: UInt8, address: UInt32, endpoint: UInt32) -> [Bool] {
        let body = lsb(address, 7) + lsb(endpoint, 4)
        return usbPacket(pid: pid, payload: body + lsb(CRC.usb5(body), 5))
    }

    static func usbData(pid: UInt8, _ bytes: [UInt8], corruptCRC: Bool = false) -> [Bool] {
        let body = bytes.flatMap { lsb(UInt32($0), 8) }
        return usbPacket(pid: pid, payload: body + lsb(CRC.usb16(bytes) ^ (corruptCRC ? 1 : 0), 16))
    }

    /// Adds a packet to a timeline: NRZI with bit stuffing, then EOP (2 bits SE0, 1 bit J).
    static func addUSB(_ packet: [Bool], fullSpeed: Bool, to tl: inout Timeline) {
        let rate = fullSpeed ? 12e6 : 1.5e6
        let j: UInt8 = fullSpeed ? USBState.dPlus.rawValue : USBState.dMinus.rawValue
        let k: UInt8 = fullSpeed ? USBState.dMinus.rawValue : USBState.dPlus.rawValue
        var level = j
        var ones = 0
        func emit(_ bit: Bool) {
            if !bit { level = level == j ? k : j }
            tl.add(1 / rate, level)
        }
        for bit in packet {
            emit(bit)
            ones = bit ? ones + 1 : 0
            if ones == 6 { emit(false); ones = 0 }
        }
        tl.add(2 / rate, USBState.se0.rawValue)
        tl.add(1 / rate, j)
    }

    // MARK: 1-Wire

    struct OneWireWriter {
        var tl = Timeline(idle: 1)
        /// Standard speed timings.
        mutating func reset(presence: Bool = true) {
            tl.add(480e-6, 0)
            if presence {
                tl.add(30e-6, 1); tl.add(120e-6, 0); tl.add(330e-6, 1)
            } else {
                tl.add(480e-6, 1)
            }
        }
        mutating func bit(_ b: Bool) {
            if b { tl.add(6e-6, 0); tl.add(64e-6, 1) } else { tl.add(60e-6, 0); tl.add(10e-6, 1) }
        }
        /// A read slot answered by the slave: a 0 is held low for 30 µs.
        mutating func readBit(_ b: Bool) {
            if b { tl.add(3e-6, 0); tl.add(67e-6, 1) } else { tl.add(30e-6, 0); tl.add(40e-6, 1) }
        }
        mutating func byte(_ v: UInt8, read: Bool = false) {
            for i in 0..<8 { read ? readBit((v >> i) & 1 == 1) : bit((v >> i) & 1 == 1) }
        }
    }
}
