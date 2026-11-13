import Foundation

/// One raw channel capture as returned by GET_DATA.
public struct RawChannelFrame: Sendable {
    public var channel: Int
    public var timeSum: UInt32
    public var periodNum: UInt32
    /// Number of valid samples counted from the right (roll mode) or >= 5000 when full.
    public var cursor: UInt16
    /// All 5100 ADC bytes (50 pre + 5000 + 50 post), signed.
    public var adc: [Int8]

    /// Frequency meter reading in Hz, if any.
    public var frequency: Double? {
        guard timeSum > 0, periodNum > 0 else { return nil }
        return Double(periodNum) / Double(timeSum) * VDS1022.maxSampleRate
    }
}

/// Low-level synchronous driver. All calls block on USB; confine to a single thread.
public final class VDS1022Driver {
    public let flash: VDS1022Flash
    public private(set) var fpgaVersion: Int
    private let usb: USBDevice
    private var buffer = [UInt8](repeating: 0, count: 6000)
    public var log: ((String) -> Void)?
    public private(set) var lastIO = Date()

    /// Opens the first VDS1022 found. Throws `ScopeError.notFound` if absent.
    public init(log: ((String) -> Void)? = nil) throws {
        self.log = log
        guard let dev = try USBDevice(vendorID: VDS1022.vendorID, productID: VDS1022.productID) else {
            throw ScopeError.notFound
        }
        usb = dev
        do {
            flash = try Self.handshake(dev)
        } catch {
            dev.close()
            throw error
        }
        guard let fv = flash.fpgaVersion else {
            dev.close()
            throw ScopeError.badFlash("bad version \(flash.version)")
        }
        fpgaVersion = fv
        log?("Connected \(flash.serial) hw \(flash.version) fpga v\(fv)")
    }

    /// Identifies the machine and reads the flash (calibration, serial, version).
    private static func handshake(_ usb: USBDevice) throws -> VDS1022Flash {
        var buf = [UInt8](repeating: 0, count: 6000)
        func read(_ timeout: UInt32) throws -> Int {
            try buf.withUnsafeMutableBufferPointer { try usb.bulkRead(into: $0, timeout: timeout) }
        }
        // Drain any stale response left from a previous session.
        _ = try? read(20)

        try usb.bulkWrite(VDS1022.Cmd.getMachine.pack(UInt32(VDS1022.Status.machine.rawValue)), timeout: VDS1022.usbTimeout)
        guard try read(VDS1022.usbTimeout) == 5 else { throw ScopeError.protocolError("GET_MACHINE") }
        let machine = UInt32(buf[1]) | UInt32(buf[2]) << 8
        guard machine == 1 else { throw ScopeError.badMachine(machine) }

        try usb.bulkWrite(VDS1022.Cmd.readFlash.pack(1), timeout: VDS1022.usbTimeout)
        let n = try read(VDS1022.usbTimeout)
        guard n >= VDS1022.flashSize else { throw ScopeError.badFlash("read \(n) bytes") }
        return try VDS1022Flash(bytes: Array(buf[0..<VDS1022.flashSize]))
    }

    public func close() { usb.close() }

    // MARK: - Commands

    @discardableResult
    public func send(_ cmd: VDS1022.Command, _ value: UInt32) throws -> UInt32 {
        var failures = 0
        while true {
            do {
                try usb.bulkWrite(cmd.pack(value), timeout: VDS1022.usbTimeout)
                let n = try readRaw()
                guard n == 5 else { throw ScopeError.protocolError("\(cmd) returned \(n) bytes") }
                lastIO = Date()
                return UInt32(buffer[1]) | UInt32(buffer[2]) << 8 | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            } catch let e as USBError where !e.isDisconnected && failures < 2 {
                failures += 1
                usleep(UInt32(10_000 * failures))
            }
        }
    }

    @discardableResult
    private func readRaw(timeout: UInt32 = VDS1022.usbTimeout) throws -> Int {
        try buffer.withUnsafeMutableBufferPointer { try usb.bulkRead(into: $0, timeout: timeout) }
    }

    // MARK: - FPGA

    public func isFPGALoaded() throws -> Bool { try send(VDS1022.Cmd.queryFPGA, 0) == 1 }

    /// Uploads the FPGA bitstream if the device reports none loaded.
    /// `progress` receives a fraction in 0...1.
    public func loadFPGAIfNeeded(firmware: URL, progress: ((Double) -> Void)? = nil) throws {
        if try isFPGALoaded() { return }
        let dump: [UInt8]
        do { dump = Array(try Data(contentsOf: firmware)) } catch {
            throw ScopeError.firmwareMissing(firmware.path)
        }
        log?("Loading FPGA \(firmware.lastPathComponent) (\(dump.count) bytes)")
        let frameSize = Int(try send(VDS1022.Cmd.loadFPGA, UInt32(dump.count)))
        guard frameSize > 4 else { throw ScopeError.firmwareLoad("bad frame size \(frameSize)") }
        let payload = frameSize - 4
        let parts = (dump.count + payload - 1) / payload
        for i in 0..<parts {
            var packet = [UInt8]()
            packet.reserveCapacity(frameSize)
            withUnsafeBytes(of: UInt32(i).littleEndian) { packet.append(contentsOf: $0) }
            packet.append(contentsOf: dump[(i * payload)..<min(dump.count, (i + 1) * payload)])
            try usb.bulkWrite(packet, timeout: 1000)
            let n = try readRaw(timeout: 1000)
            let status = buffer[0]
            let value = UInt32(buffer[1]) | UInt32(buffer[2]) << 8 | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            guard n == 5, status == VDS1022.Status.ok.rawValue, value == UInt32(i) else {
                throw ScopeError.firmwareLoad("part \(i): status \(status) value \(value)")
            }
            progress?(Double(i + 1) / Double(parts))
        }
        guard try isFPGALoaded() else { throw ScopeError.firmwareLoad("device did not report FPGA loaded") }
    }

    // MARK: - Acquisition

    public func dataFinished() throws -> Bool { try send(VDS1022.Cmd.getDataFinished, 0) != 0 }
    public func triggered() throws -> UInt32 { try send(VDS1022.Cmd.getTriggered, 0) }
    public func forceTrigger() throws { try send(VDS1022.Cmd.setForceTrigger, 0x3) }

    /// Requests frames for the enabled channels. Returns nil when the device is busy.
    public func fetchFrames(enabled: [Bool]) throws -> [RawChannelFrame]? {
        let arg = UInt32(enabled[0] ? 5 : 4) | UInt32(enabled[1] ? 5 : 4) << 8
        let count = enabled.filter { $0 }.count
        guard count > 0 else { return [] }
        try usb.bulkWrite(VDS1022.Cmd.getData.pack(arg), timeout: VDS1022.usbTimeout)
        var frames: [RawChannelFrame] = []
        for i in 0..<count {
            let n = try readRaw()
            if n != VDS1022.frameSize {
                if i == 0, n == 5 { return nil } // 'E' BUSY
                throw ScopeError.protocolError("GET_DATA returned \(n) bytes")
            }
            frames.append(parseFrame())
        }
        lastIO = Date()
        return frames
    }

    private func parseFrame() -> RawChannelFrame {
        func u32(_ o: Int) -> UInt32 {
            UInt32(buffer[o]) | UInt32(buffer[o + 1]) << 8 | UInt32(buffer[o + 2]) << 16 | UInt32(buffer[o + 3]) << 24
        }
        let adcStart = 111
        let adc = buffer[adcStart..<(adcStart + VDS1022.adcSize)].map { Int8(bitPattern: $0) }
        return RawChannelFrame(
            channel: Int(buffer[0]),
            timeSum: u32(1),
            periodNum: u32(5),
            cursor: UInt16(buffer[9]) | UInt16(buffer[10]) << 8,
            adc: adc
        )
    }
}
