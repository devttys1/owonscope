import Foundation

public struct DeviceInfo: Sendable, Equatable {
    public var model: String
    public var serial: String
    public var hardwareVersion: String
    public var fpgaVersion: Int
    public var isSimulated: Bool
}

/// A source of acquisitions: the real scope or the simulator.
public protocol AcquisitionBackend: AnyObject {
    var info: DeviceInfo { get }
    /// Pushes settings to the device (only changed registers). `force` resends everything.
    func apply(_ settings: ScopeSettings, force: Bool) throws
    /// Re-arms a single-shot capture.
    func arm(_ settings: ScopeSettings) throws
    /// Returns an acquisition if one is ready, nil while waiting.
    func poll(_ settings: ScopeSettings) throws -> Acquisition?
    func forceTrigger() throws
    /// Called periodically while idle to keep the USB link alive.
    func keepAlive() throws
    func close()
}

/// Real hardware backend.
public final class HardwareBackend: AcquisitionBackend {
    public let info: DeviceInfo
    private let driver: VDS1022Driver
    private var sent: [VDS1022.Command: UInt32] = [:]
    private var freqRefs: [Int?] = [nil, nil]
    private var sequence = 0

    public init(log: ((String) -> Void)?, progress: ((Double) -> Void)?) throws {
        let d = try VDS1022Driver(log: log)
        driver = d
        if try !d.isFPGALoaded() {
            guard let fw = FirmwareLocator.find(fpgaVersion: d.fpgaVersion) else {
                d.close()
                throw ScopeError.firmwareMissing(
                    "Need VDS1022_FPGAV\(d.fpgaVersion)_*.bin in \(FirmwareLocator.userDirectory.path)")
            }
            do { try d.loadFPGAIfNeeded(firmware: fw, progress: progress) } catch { d.close(); throw error }
        }
        info = DeviceInfo(model: d.flash.serial.hasPrefix("VDS1022I") ? "VDS1022I" : "VDS1022",
                          serial: d.flash.serial, hardwareVersion: d.flash.version,
                          fpgaVersion: d.fpgaVersion, isSimulated: false)
    }

    public func apply(_ settings: ScopeSettings, force: Bool) throws {
        if force { sent.removeAll() }
        for (cmd, value) in RegisterMap.writes(for: settings, flash: driver.flash,
                                               fpgaVersion: driver.fpgaVersion, freqRefCounts: freqRefs)
        where sent[cmd] != value {
            try driver.send(cmd, value)
            sent[cmd] = value
        }
    }

    public func arm(_ settings: ScopeSettings) throws {
        sent[VDS1022.Cmd.setTrigger] = nil
        try apply(settings, force: false)
    }

    public func poll(_ settings: ScopeSettings) throws -> Acquisition? {
        let tb = settings.timebase
        var triggered = false
        if !tb.isRollMode {
            if settings.trigger.sweep != .auto {
                guard try driver.dataFinished(), try driver.triggered() != 0 else { return nil }
                triggered = true
            } else {
                triggered = try driver.triggered() != 0
            }
        }
        guard let raw = try driver.fetchFrames(enabled: settings.enabledMask) else { return nil }

        var channels: [ChannelWaveform?] = [nil, nil]
        let dt = 1 / tb.sampleRate
        let n = VDS1022.samplesPerFrame
        for f in raw where f.channel < 2 {
            let c = settings.channels[f.channel]
            let counts: [Int8]
            let t0: Double
            if tb.isRollMode {
                // Right aligned: the valid samples are the last `cursor` of the 5000 window.
                let valid = min(Int(f.cursor), n)
                counts = Array(f.adc[(100 + n - valid)..<(100 + n)])
                t0 = -Double(valid) * dt
            } else {
                counts = Array(f.adc[50..<(50 + n)])
                t0 = -Double(n) * settings.triggerPosition * dt
            }
            let w = ChannelWaveform(channel: f.channel, counts: counts, t0: t0, dt: dt,
                                    frequencyMeter: f.frequency, settings: c)
            channels[f.channel] = w
            updateFreqRef(channel: f.channel, waveform: w, settings: settings)
        }
        sequence += 1
        let state: TriggerState = tb.isRollMode ? .roll : (triggered ? .triggered : .auto)
        var acq = Acquisition(channels: channels, settings: settings, triggerState: state, sequence: sequence)
        TriggerRefiner.refine(&acq)
        return acq
    }

    /// Keep the frequency meter threshold of non-trigger channels at the signal midpoint.
    private func updateFreqRef(channel: Int, waveform: ChannelWaveform, settings: ScopeSettings) {
        guard settings.trigger.source.channel != channel, !waveform.counts.isEmpty else { return }
        var lo = Int8.max, hi = Int8.min
        for c in waveform.counts { lo = min(lo, c); hi = max(hi, c) }
        guard Int(hi) - Int(lo) > 16 else { return }
        let mid = (Int(lo) + Int(hi)) / 2
        if let old = freqRefs[channel], abs(old - mid) < 4 { return }
        freqRefs[channel] = mid
    }

    public func forceTrigger() throws { try driver.forceTrigger() }

    public func keepAlive() throws {
        if Date().timeIntervalSince(driver.lastIO) > 2 {
            try driver.send(VDS1022.Cmd.getMachine, UInt32(VDS1022.Status.machine.rawValue))
        }
    }

    public func close() { driver.close() }
}
