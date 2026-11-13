import Foundation

public enum ConnectionState: Equatable, Sendable {
    case searching
    case connecting
    case loadingFirmware(Double)
    case connected(DeviceInfo)
    case failed(String)

    public var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

public enum EngineEvent: Sendable {
    case connection(ConnectionState)
    case acquisition(Acquisition)
    /// Run state changed by the engine (single capture finished, autoset started acquiring).
    /// `generation` identifies the run/stop command it belongs to; stale ones can be ignored.
    case running(Bool, generation: Int)
    /// Settings changed by the engine (autoset).
    case settings(ScopeSettings)
    case log(String)
}

/// Owns the USB conversation on a dedicated thread. Thread safe; events are delivered
/// on the engine thread via `onEvent`.
public final class ScopeEngine: @unchecked Sendable {
    public enum Source: Equatable, Sendable {
        case hardware
        case simulator(SimulatorScenario)
    }

    public var onEvent: (@Sendable (EngineEvent) -> Void)?

    private let cond = NSCondition()
    private var thread: Thread?
    private var cancelled = false

    // shared state, guarded by `cond`
    private var settings: ScopeSettings
    private var settingsDirty = true
    private var running = true
    private var rearm = true
    private var forcePending = false
    private var autosetPending = false
    private var source: Source
    private var sourceDirty = true
    /// Incremented by every run/stop/single/autoset command.
    private var generation = 0

    public init(settings: ScopeSettings, source: Source = .hardware) {
        self.settings = settings
        self.source = source
    }

    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "OwonScope.engine"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    public func update(_ s: ScopeSettings) {
        cond.lock()
        if s != settings {
            let sweepChanged = s.trigger.sweep != settings.trigger.sweep
            settings = s
            settingsDirty = true
            if sweepChanged { rearm = true }
        }
        cond.broadcast(); cond.unlock()
    }

    /// Starts or stops acquisition. Returns the command generation; the caller owns the
    /// resulting run state (no event is emitted for it).
    @discardableResult
    public func setRunning(_ run: Bool) -> Int {
        cond.lock()
        running = run
        if run { rearm = true }
        generation += 1
        let g = generation
        cond.broadcast(); cond.unlock()
        return g
    }

    /// Arms a single acquisition. The engine emits `.running(false)` when it has captured.
    @discardableResult
    public func single() -> Int {
        cond.lock()
        settings.trigger.sweep = .single
        settingsDirty = true
        running = true
        rearm = true
        generation += 1
        let g = generation
        cond.broadcast(); cond.unlock()
        return g
    }

    public func forceTrigger() { cond.lock(); forcePending = true; cond.broadcast(); cond.unlock() }

    /// Runs autoset, which leaves the scope running in Auto sweep.
    @discardableResult
    public func autoset() -> Int {
        cond.lock()
        autosetPending = true
        generation += 1
        let g = generation
        cond.broadcast(); cond.unlock()
        return g
    }

    public func setSource(_ s: Source) {
        cond.lock()
        if s != source { source = s; sourceDirty = true }
        cond.broadcast(); cond.unlock()
    }

    /// Drops the current connection and connects again (e.g. after installing firmware).
    public func reconnect() {
        cond.lock(); sourceDirty = true; cond.broadcast(); cond.unlock()
    }

    // MARK: - Engine thread

    private var backend: AcquisitionBackend?
    private var lastConnectAttempt = Date.distantPast
    private var lastPublish = Date.distantPast
    private var lastFailure: String?

    private func emit(_ e: EngineEvent) { onEvent?(e) }

    private func run() {
        while true {
            cond.lock()
            if cancelled { cond.unlock(); break }
            let src = source
            let srcChanged = sourceDirty
            sourceDirty = false
            cond.unlock()

            if srcChanged {
                backend?.close()
                backend = nil
                lastConnectAttempt = .distantPast
                lastFailure = nil
            }
            if backend == nil {
                connect(src)
                if backend == nil { idleWait(0.5); continue }
            }
            do {
                try step()
            } catch {
                handle(error)
            }
        }
        backend?.close()
        backend = nil
    }

    private func connect(_ src: Source) {
        switch src {
        case .simulator(let scenario):
            let sim = SimulatorBackend(scenario: scenario)
            backend = sim
            markAllDirty()
            emit(.connection(.connected(sim.info)))
        case .hardware:
            guard Date().timeIntervalSince(lastConnectAttempt) > 1 else { return }
            lastConnectAttempt = Date()
            guard USBDevice.isPresent(vendorID: VDS1022.vendorID, productID: VDS1022.productID) else {
                if lastFailure != "absent" { emit(.connection(.searching)); lastFailure = "absent" }
                return
            }
            emit(.connection(.connecting))
            do {
                let hw = try HardwareBackend(log: { [weak self] in self?.emit(.log($0)) },
                                             progress: { [weak self] p in self?.emit(.connection(.loadingFirmware(p))) })
                backend = hw
                lastFailure = nil
                markAllDirty()
                emit(.connection(.connected(hw.info)))
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if lastFailure != msg { emit(.connection(.failed(msg))); emit(.log(msg)) }
                lastFailure = msg
                lastConnectAttempt = Date().addingTimeInterval(2) // back off
            }
        }
    }

    private func markAllDirty() {
        cond.lock(); settingsDirty = true; forceResend = true; rearm = true; cond.unlock()
    }

    private var forceResend = true

    private func step() throws {
        guard let backend else { return }
        cond.lock()
        var s = settings
        let dirty = settingsDirty, force = forceResend, doRearm = rearm
        let doForce = forcePending, doAutoset = autosetPending
        let isRunning = running
        let gen = generation
        settingsDirty = false; forceResend = false; rearm = false
        forcePending = false; autosetPending = false
        cond.unlock()

        if doAutoset {
            s = try runAutoset(backend, from: s)
            cond.lock()
            let current = generation == gen
            if current { settings = s; running = true }
            cond.unlock()
            if current {
                emit(.settings(s))
                emit(.running(true, generation: gen))
            }
            return
        }
        if dirty || force { try backend.apply(s, force: force) }
        if doRearm && s.trigger.sweep == .single { try backend.arm(s) }
        if doForce { try backend.forceTrigger() }

        guard isRunning else {
            try backend.keepAlive()
            idleWait(0.25)
            return
        }

        // Cap the UI update rate at ~60 fps.
        let since = Date().timeIntervalSince(lastPublish)
        if since < 1.0 / 60 { idleWait(1.0 / 60 - since); return }

        if let acq = try backend.poll(s) {
            lastPublish = Date()
            emit(.acquisition(acq))
            if s.trigger.sweep == .single {
                // Only stop if no newer run/stop command arrived while we were capturing.
                cond.lock()
                let current = generation == gen
                if current { running = false }
                cond.unlock()
                if current { emit(.running(false, generation: gen)) }
            }
        } else {
            idleWait(0.004)
        }
    }

    private func handle(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        emit(.log("Engine error: \(msg)"))
        if let usb = error as? USBError, !usb.isDisconnected, !usb.isTimeout {
            idleWait(0.05)
            return
        }
        // Treat anything else as a lost device: reconnect.
        backend?.close()
        backend = nil
        emit(.connection(.failed(msg)))
        lastFailure = msg
        idleWait(0.5)
    }

    /// Waits until poked or the timeout elapses.
    private func idleWait(_ seconds: Double) {
        cond.lock()
        if !cancelled && !settingsDirty && !forcePending && !autosetPending && !sourceDirty {
            cond.wait(until: Date().addingTimeInterval(seconds))
        }
        cond.unlock()
    }

    // MARK: - Autoset

    private func acquireBlocking(_ backend: AcquisitionBackend, _ s: ScopeSettings, timeout: Double) throws -> Acquisition? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let a = try backend.poll(s) { return a }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    private func runAutoset(_ backend: AcquisitionBackend, from start: ScopeSettings) throws -> ScopeSettings {
        emit(.log("Autoset…"))
        var s = start
        s.trigger.sweep = .auto
        s.triggerPosition = 0.5
        // Peak detect while ranging so fast/bursty signals don't alias away at the slow overview rate.
        s.peakDetect = true
        // 25 kS/s overview (20 ms/div) to see slow signals; the frequency meter covers fast ones.
        s.timebaseIndex = Timebase.all.firstIndex { abs($0.secondsPerDivision - 20e-3) < 1e-9 } ?? s.timebaseIndex
        for ch in 0..<2 {
            s.channels[ch].enabled = true
            s.channels[ch].offsetDivisions = 0
            s.channels[ch].coupling = s.channels[ch].coupling == .gnd ? .dc : s.channels[ch].coupling
        }

        var hasSignal = [false, false]
        var mids = [0.0, 0.0]   // signal midpoint (volts)
        var amps = [0.0, 0.0]   // peak-peak (volts)
        var freqs: [Double?] = [nil, nil]

        // 1. Range each channel so the whole signal fits.
        for _ in 0..<12 {
            try backend.apply(s, force: false)
            Thread.sleep(forTimeInterval: 0.08)
            _ = try acquireBlocking(backend, s, timeout: 0.6) // flush a frame from the old settings
            guard let acq = try acquireBlocking(backend, s, timeout: 1.0) else { break }
            var stable = true
            for ch in 0..<2 {
                guard let w = acq.channel(ch) else { continue }
                var lo = Int8.max, hi = Int8.min
                for c in w.counts { lo = min(lo, c); hi = max(hi, c) }
                let c = s.channels[ch]
                if Int(hi) >= VDS1022.adcMax || Int(lo) <= VDS1022.adcMin {
                    if c.rangeIndex < VDS1022.voltRanges.count - 1 {
                        s.channels[ch].rangeIndex = min(VDS1022.voltRanges.count - 1, c.rangeIndex + 2)
                        stable = false
                    }
                    hasSignal[ch] = true
                    continue
                }
                // Small or no swing: look again on a more sensitive range before giving up.
                if Int(hi) - Int(lo) < 12 {
                    hasSignal[ch] = false
                    if c.rangeIndex > 1 {
                        s.channels[ch].rangeIndex = max(1, c.rangeIndex - 3)
                        stable = false
                    }
                    continue
                }
                let vLo = c.volts(counts: Double(lo)), vHi = c.volts(counts: Double(hi))
                amps[ch] = vHi - vLo
                mids[ch] = (vHi + vLo) / 2
                freqs[ch] = w.frequencyMeter
                let span = max(abs(vHi), abs(vLo)) * 2 // keep 0 V on screen while ranging
                hasSignal[ch] = Int(hi) - Int(lo) >= 12
                // smallest range where the signal (around centre) uses <= 80% of full scale
                let want = VDS1022.voltRanges.firstIndex { $0 * c.probe * 0.8 >= span } ?? VDS1022.voltRanges.count - 1
                if want != c.rangeIndex && hasSignal[ch] {
                    s.channels[ch].rangeIndex = want
                    stable = false
                }
            }
            if stable { break }
        }

        // 2. Lay the channels out: one active => full screen, two => split top/bottom.
        let active = (0..<2).filter { hasSignal[$0] }
        for ch in 0..<2 where hasSignal[ch] {
            let c = s.channels[ch]
            let divsAvailable = active.count == 2 ? 4.0 : 8.0
            let want = VDS1022.voltRanges.firstIndex { $0 / 10 * c.probe * divsAvailable >= amps[ch] * 1.05 } ?? VDS1022.voltRanges.count - 1
            s.channels[ch].rangeIndex = want
            let vdiv = s.channels[ch].voltsPerDivision
            let centre = active.count == 2 ? (ch == 0 ? 2.5 : -2.5) : 0
            s.channels[ch].offsetDivisions = max(-4.5, min(4.5, centre - mids[ch] / vdiv))
        }
        for ch in 0..<2 where !hasSignal[ch] && !active.isEmpty { s.channels[ch].enabled = false }

        s.peakDetect = false

        // 3. Trigger on the strongest channel at its midpoint.
        if let best = active.max(by: { amps[$0] / s.channels[$0].fullScale < amps[$1] / s.channels[$1].fullScale }) {
            s.trigger.source = best == 0 ? .ch1 : .ch2
            s.trigger.level = mids[best]
            s.trigger.slope = .rising

            // 4. Re-measure frequency with the meter threshold at the midpoint, then pick ~2.5 periods.
            try backend.apply(s, force: false)
            Thread.sleep(forTimeInterval: 0.25)
            _ = try acquireBlocking(backend, s, timeout: 0.6)
            if let acq = try acquireBlocking(backend, s, timeout: 1.0), let w = acq.channel(best) {
                let f = w.frequencyMeter ?? Measurements.frequency(w) ?? freqs[best]
                if let f, f > 0.5 {
                    let period = 1 / f
                    if let idx = Timebase.all.firstIndex(where: { $0.window >= period * 2.5 }) {
                        s.timebaseIndex = idx
                    }
                }
            }
        }
        try backend.apply(s, force: false)
        emit(.log("Autoset done"))
        return s
    }
}
