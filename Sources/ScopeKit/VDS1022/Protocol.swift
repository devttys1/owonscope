import Foundation

/// Hardware constants and command definitions for the OWON VDS1022 / VDS1022I.
///
/// Protocol reference: florentbr/OWON-VDS1022 (api/python/vds1022/vds1022.py), verified
/// against a VDS1022I with hardware V5.0.1.
///
/// Command packet (little endian): u32 address, u8 value size (1, 2 or 4), value.
/// Response: 5 bytes, u8 status char ('S' ok, 'E' busy, 'D' download, 'V' machine), u32 value.
public enum VDS1022 {
    public static let vendorID: UInt16 = 0x5345
    public static let productID: UInt16 = 0x1234
    public static let usbTimeout: UInt32 = 200

    public static let channelCount = 2

    /// Full ADC frame returned by GET_DATA: 11 header + 100 trigger + 5100 ADC bytes.
    public static let frameSize = 5211
    /// 50 pre + 5000 samples + 50 post.
    public static let adcSize = 5100
    public static let samplesPerFrame = 5000
    public static let adcMax: Int = 125
    public static let adcMin: Int = -125
    /// ADC counts across the full vertical range (10 divisions).
    public static let adcRange: Double = 250
    public static let countsPerDivision: Double = 25
    public static let flashSize = 2002
    /// Horizontal trigger position correction (samples).
    public static let htpError = 11
    /// Volt range index at/above which the input attenuation relay is switched in.
    public static let attenuationThreshold = 6
    /// Below this sample rate (S/s) the hardware runs in roll ("slow move") mode.
    public static let rollModeThreshold: Double = 2500
    public static let maxSampleRate: Double = 100e6

    /// Full-scale (10 div) input ranges at the BNC, x1 probe: 5 mV/div ... 5 V/div.
    public static let voltRanges: [Double] = [50e-3, 100e-3, 200e-3, 500e-3, 1, 2, 5, 10, 20, 50]
    public static var voltsPerDivision: [Double] { voltRanges.map { $0 / 10 } }

    public struct Command: Hashable, Sendable, CustomStringConvertible {
        public let name: String
        public let address: UInt32
        public let size: UInt8

        public init(_ name: String, _ address: UInt32, _ size: UInt8) {
            self.name = name
            self.address = address
            self.size = size
        }

        public func pack(_ value: UInt32) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(5 + Int(size))
            withUnsafeBytes(of: address.littleEndian) { out.append(contentsOf: $0) }
            out.append(size)
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0.prefix(Int(size))) }
            return out
        }

        public var description: String { name }
    }

    public enum Cmd {
        public static let readFlash = Command("READ_FLASH", 0x01b0, 1)
        public static let writeFlash = Command("WRITE_FLASH", 0x01a0, 1)
        public static let queryFPGA = Command("QUERY_FPGA", 0x0223, 1)
        public static let loadFPGA = Command("LOAD_FPGA", 0x4000, 4)
        public static let getMachine = Command("GET_MACHINE", 0x4001, 1)
        public static let getData = Command("GET_DATA", 0x1000, 2)
        public static let getTriggered = Command("GET_TRIGGERED", 0x01, 1)
        public static let setMulti = Command("SET_MULTI", 0x06, 2)
        public static let setPeakMode = Command("SET_PEAKMODE", 0x09, 1)
        public static let setRollMode = Command("SET_ROLLMODE", 0x0a, 1)
        public static let setChannelsOn = Command("SET_CHL_ON", 0x0b, 1)
        public static let setForceTrigger = Command("SET_FORCETRG", 0x0c, 1)
        public static let setPhaseFine = Command("SET_PHASEFINE", 0x18, 2)
        public static let setTrigger = Command("SET_TRIGGER", 0x24, 2)
        public static let setTimebase = Command("SET_TIMEBASE", 0x52, 4)
        public static let setPostTrigger = Command("SET_SUF_TRG", 0x56, 4)
        public static let setPreTrigger = Command("SET_PRE_TRG", 0x5a, 2)
        public static let setDeepMemory = Command("SET_DEEPMEMORY", 0x5c, 2)
        public static let setRunStop = Command("SET_RUNSTOP", 0x61, 1)
        public static let getDataFinished = Command("GET_DATAFINISHED", 0x7a, 1)
        public static let getStopped = Command("GET_STOPPED", 0xb1, 1)

        public static let setChannel = [Command("SET_CHANNEL_CH1", 0x0111, 1), Command("SET_CHANNEL_CH2", 0x0110, 1)]
        public static let setZeroOffset = [Command("SET_ZERO_OFF_CH1", 0x010a, 2), Command("SET_ZERO_OFF_CH2", 0x0108, 2)]
        public static let setVoltGain = [Command("SET_VOLT_GAIN_CH1", 0x0116, 2), Command("SET_VOLT_GAIN_CH2", 0x0114, 2)]
        public static let setSlopeThreshold = [Command("SET_SLOPE_THRED_CH1", 0x10, 2), Command("SET_SLOPE_THRED_CH2", 0x12, 2)]
        public static let setEdgeLevel = [Command("SET_EDGE_LEVEL_CH1", 0x2e, 2), Command("SET_EDGE_LEVEL_CH2", 0x30, 2)]
        public static let setTriggerHoldoff = [Command("SET_TRG_HOLDOFF_CH1", 0x26, 2), Command("SET_TRG_HOLDOFF_CH2", 0x2a, 2)]
        public static let setTriggerCdtEquH = [Command("SET_TRG_CDT_EQU_H_CH1", 0x32, 2), Command("SET_TRG_CDT_EQU_H_CH2", 0x3a, 2)] // FPGA <= V2
        public static let setTriggerCdtEquL = [Command("SET_TRG_CDT_EQU_L_CH1", 0x36, 2), Command("SET_TRG_CDT_EQU_L_CH2", 0x3e, 2)] // FPGA <= V2
        public static let setTriggerCdtGL = [Command("SET_TRG_CDT_GL_CH1", 0x42, 2), Command("SET_TRG_CDT_GL_CH2", 0x46, 2)]
        public static let setTriggerCdtHL = [Command("SET_TRG_CDT_HL_CH1", 0x44, 2), Command("SET_TRG_CDT_HL_CH2", 0x48, 2)]
        public static let setFreqRef = [Command("SET_FREQREF_CH1", 0x4a, 1), Command("SET_FREQREF_CH2", 0x4b, 1)]
    }

    public enum Status: UInt8 {
        case ok = 83 // 'S'
        case busy = 69 // 'E'
        case download = 68 // 'D'
        case machine = 86 // 'V'
        case g = 71 // 'G'
    }

    /// Sample rate for a timebase prescaler.
    public static func sampleRate(prescaler: UInt32) -> Double { maxSampleRate / Double(max(1, prescaler)) }

    /// Packs two signed ADC levels into the 16 bit (lsb, msb) form used by level registers.
    public static func u16(_ lsb: Int, _ msb: Int) -> UInt32 {
        UInt32(lsb & 0xff) | UInt32(msb & 0xff) << 8
    }

    public static func swap16(_ x: UInt32) -> UInt32 { (x & 0xff00) >> 8 | (x & 0x00ff) << 8 }

    /// Unsigned mantissa (<= limit) and base-10 exponent.
    public static func mantissaExponent(_ value: Double, limit: Double) -> (UInt32, UInt32) {
        var m = value, e: UInt32 = 0
        while m > limit { m /= 10; e += 1 }
        return (UInt32(max(0, m.rounded())), e)
    }

    /// Encodes a trigger holdoff time into the register format.
    public static func holdoffRegister(seconds: Double) -> UInt32 {
        let (m, e) = mantissaExponent(seconds * 1e8, limit: 1023)
        return swap16(m << 6 | e & 7)
    }
}

/// Device information and calibration stored in the scope's flash.
public struct VDS1022Flash: Sendable, Equatable {
    public enum CalKind: Int, Sendable { case gain = 0, amplitude = 1, compensation = 2 }

    public var oem: UInt8
    public var version: String
    public var serial: String
    public var phaseFine: UInt16
    /// calibration[kind][channel][voltRangeIndex]
    public var calibration: [[[Int]]]

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 220 else { throw ScopeError.badFlash("flash too short (\(bytes.count) bytes)") }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        let header = u16(0)
        guard header == 0x55AA || header == 0xAA55 else {
            throw ScopeError.badFlash(String(format: "bad header 0x%04X", header))
        }
        guard u32(2) == 2 else { throw ScopeError.badFlash("unsupported flash version \(u32(2))") }

        var cal: [[[Int]]] = []
        var o = 6
        for _ in 0..<3 {
            var perChannel: [[Int]] = []
            for _ in 0..<VDS1022.channelCount {
                perChannel.append((0..<10).map { u16(o + $0 * 2) })
                o += 20
            }
            cal.append(perChannel)
        }
        calibration = cal

        var p = 206
        oem = bytes[p]; p += 1
        func readString() -> String {
            var s: [UInt8] = []
            while p < bytes.count, bytes[p] != 0 { s.append(bytes[p]); p += 1 }
            p += 1
            return String(decoding: s, as: UTF8.self)
        }
        version = readString()
        serial = readString()
        p += 100 // localisations
        phaseFine = p + 1 < bytes.count ? UInt16(u16(p)) : 0
    }

    /// FPGA bitstream generation required by this hardware version.
    public var fpgaVersion: Int? {
        let v = version.uppercased()
        if v.hasPrefix("V2.7.0") { return 3 }
        if v.hasPrefix("V2.4.623") || v.hasPrefix("V2.6.0") { return 2 }
        if v.hasPrefix("V2.") || v.hasPrefix("V1.") { return 1 }
        if v.hasPrefix("V"), let dot = v.firstIndex(of: ".") {
            return Int(v[v.index(after: v.startIndex)..<dot])
        }
        return nil
    }

    public func cal(_ kind: CalKind, channel: Int, range: Int) -> Int {
        calibration[kind.rawValue][channel][range]
    }
}

public enum ScopeError: Error, LocalizedError {
    case notFound
    case badFlash(String)
    case badMachine(UInt32)
    case firmwareMissing(String)
    case firmwareLoad(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "No OWON VDS1022 found on USB."
        case .badFlash(let m): return "Unreadable device flash: \(m)"
        case .badMachine(let v): return "Unexpected device type (\(v))."
        case .firmwareMissing(let m): return "FPGA firmware not found. \(m)"
        case .firmwareLoad(let m): return "FPGA firmware upload failed: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        }
    }
}
