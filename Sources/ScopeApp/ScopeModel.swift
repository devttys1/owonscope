import Foundation
import Observation
#if os(macOS)
import AppKit
#endif
import ScopeKit
import UniformTypeIdentifiers

enum Persistence: String, CaseIterable, Codable {
    case off = "Off", short = "Short", long = "Long", infinite = "Infinite"
    var decay: Float {
        switch self { case .off: 0; case .short: 0.72; case .long: 0.93; case .infinite: 1 }
    }
}

enum SourceChoice: Hashable, Codable {
    case hardware
    case demo(SimulatorScenario)
    /// A scope shared over the network by another computer.
    case remote(RemoteTarget)

    var engineSource: ScopeEngine.Source {
        switch self {
        case .hardware: .hardware
        case .demo(let s): .simulator(s)
        case .remote(let t): .remote(t)
        }
    }

    var isRemote: Bool { if case .remote = self { true } else { false } }
}

enum CursorMode: String, CaseIterable, Codable {
    case off = "Off", time = "Time", amplitude = "Ampl", both = "Both", track = "Track"
    var showsTime: Bool { self != .off && self != .amplitude }
    var showsAmplitude: Bool { self != .off && self != .time }
}

enum DisplayFormat: String, CaseIterable, Codable { case yt = "YT", xy = "XY" }

enum BottomTab: String, CaseIterable, Codable {
    case decode = "Decode", measure = "Measure", spectrum = "Spectrum", log = "Log"
}

struct DisplayPrefs: Codable, Equatable {
    var persistence: Persistence = .off
    var traceWidth: Double = 1.6
    var spectrumChannel = 0
    var spectrumWindow: FFTWindow = .hann
    var spectrumLogFrequency = true
    var cursorMode: CursorMode = .off
    var measurements: [MeasurementKind] = MeasurementKind.defaults
    var bottomTab: BottomTab = .decode
    var showRawUnderAverage = true
    var format: DisplayFormat = .yt
    /// Centre of the cursor readout as a fraction of the screen size (nil = default spot).
    var cursorReadout: CGPoint?

    init() {}

    enum CodingKeys: String, CodingKey {
        case persistence, traceWidth, spectrumChannel, spectrumWindow, spectrumLogFrequency, cursorMode
        case measurements, bottomTab, showRawUnderAverage, format, cursorReadout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DisplayPrefs()
        func v<T: Decodable>(_ k: CodingKeys, _ f: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? f }
        persistence = v(.persistence, d.persistence)
        traceWidth = v(.traceWidth, d.traceWidth)
        spectrumChannel = v(.spectrumChannel, d.spectrumChannel)
        spectrumWindow = v(.spectrumWindow, d.spectrumWindow)
        spectrumLogFrequency = v(.spectrumLogFrequency, d.spectrumLogFrequency)
        cursorMode = v(.cursorMode, d.cursorMode)
        // unknown (renamed) measurement kinds are dropped rather than failing the whole decode
        // map names saved by earlier versions (Vpp, Vrms, ...) onto the current ones
        let renamed = ["Vpp": "Pk-Pk", "Vmax": "Max", "Vmin": "Min", "Vavg": "Mean", "Vrms": "RMS",
                       "Vtop": "Top", "Vbase": "Base", "Vamp": "Amplitude"]
        let names = v(.measurements, [String]()).map { renamed[$0] ?? $0 }
        var kinds: [MeasurementKind] = []
        for k in names.compactMap(MeasurementKind.init(rawValue:)) where !kinds.contains(k) { kinds.append(k) }
        measurements = kinds.isEmpty ? d.measurements : kinds
        bottomTab = v(.bottomTab, d.bottomTab)
        showRawUnderAverage = v(.showRawUnderAverage, d.showRawUnderAverage)
        format = v(.format, d.format)
        cursorReadout = try? c.decodeIfPresent(CGPoint.self, forKey: .cursorReadout)
    }
}

/// Traces that can be selected (for scroll gestures, cursors, offset dragging).
enum Trace: Int, CaseIterable, Codable {
    case ch1 = 0, ch2 = 1, math = 2
    var channel: Int? { self == .math ? nil : rawValue }
    var name: String { self == .math ? "MATH" : "CH\(rawValue + 1)" }
}

struct Cursors: Equatable {
    /// Times relative to trigger.
    var t1: Double = -1e-4
    var t2: Double = 1e-4
    /// Amplitudes in the units of the selected trace.
    var y1: Double = 1
    var y2: Double = -1
}

/// A stored reference waveform with the vertical scale it was saved with.
struct ReferenceWaveform {
    var waveform: DerivedWaveform
    var unitsPerDivision: Double
    var offsetDivisions: Double
    var visible = true
    var saved = Date()
}

/// One received acquisition, as handed to `ScopeModel.frames()` listeners.
struct Frame: @unchecked Sendable {
    /// After averaging / envelope (what is displayed and measured).
    var acquisition: Acquisition
    /// As captured (what the decoders see).
    var raw: Acquisition
    var analysis: Analysis
    /// Taken with the model's settings at the time it arrived.
    var matchesSettings: Bool
    /// 1 for the first capture with the current settings, 2 for the next... (0 if it doesn't match).
    var matchingIndex: Int
}

/// Result of the per-acquisition analysis done off the main thread.
struct Analysis: @unchecked Sendable {
    /// Acquisition after averaging / envelope.
    var processed: Acquisition?
    var measurements: [ChannelMeasurements?] = [nil, nil]
    var math: DerivedWaveform?
    var mathMeasurements: ChannelMeasurements?
    var cross: CrossMeasurements?
    var decodes: [UUID: DecodeResult] = [:]
    var spectrum: Spectrum?
}

@MainActor
@Observable
final class ScopeModel {
    // MARK: Published state
    var settings: ScopeSettings { didSet { settingsChanged(oldValue) } }
    var display: DisplayPrefs { didSet { displayChanged(oldValue) } }
    var processing: ProcessingSettings { didSet { processingChanged(oldValue) } }
    var decoders: [DecoderInstance] { didSet { save(decoders, "decoders"); analysisConfig.update(decoders: decoders) } }
    var source: SourceChoice {
        didSet {
            save(source, "source")
            if case .remote(let t) = source { RecentRemotes.add(t) }
            #if os(macOS)
            if sharing != nil { stopSharing() }
            #endif
            engine.setSource(source.engineSource)
        }
    }

    private(set) var running = true
    private(set) var connection: ConnectionState = .searching
    /// Displayed acquisition (after averaging/envelope).
    private(set) var acquisition: Acquisition?
    /// The latest acquisition as captured.
    private(set) var rawAcquisition: Acquisition?
    private(set) var analysis = Analysis()
    private(set) var statistics = MeasurementStatistics()
    private(set) var framesPerSecond: Double = 0
    private(set) var log: [String] = []
    var cursors = Cursors() { didSet { updateGate() } }
    var references: [ReferenceWaveform?] = [nil, nil]
    /// Trace adjusted by scroll gestures, offset drags and amplitude cursors.
    var selectedTrace: Trace = .ch1
    var selectedChannel: Int {
        get { selectedTrace.channel ?? 0 }
        set { selectedTrace = Trace(rawValue: newValue) ?? .ch1 }
    }
    /// Touch UI: the scope chooser sheet is showing.
    var showSourcePicker = false
    /// Bumped to clear the persistence buffer.
    private(set) var displayGeneration = 0
    /// Acquisitions received since launch.
    private(set) var frameCount = 0
    /// Acquisitions received since the settings last changed that were taken with the
    /// current settings (the first of them may hold samples from before the change).
    private(set) var matchingFrames = 0
    /// Settings updates that came from the engine (autoset, other clients of a shared scope).
    private(set) var engineSettingsUpdates = 0
    @ObservationIgnored private var frameListeners: [UUID: AsyncStream<Frame>.Continuation] = [:]

    let engine: ScopeEngine
    private let analysisConfig = AnalysisConfig()
    private var applyingEngineSettings = false
    /// Generation of the last run/stop command sent to the engine.
    private var runGeneration = 0
    private var frameTimes: [Date] = []

    init() {
        // UI tests: -OwonScopeReset starts from defaults; -OwonScopeSource demo|host[:port]
        // picks the signal source.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-OwonScopeReset") {
            for k in ["settings", "display", "processing", "decoders", "source", "mobile.controlTab", "mobile.showControls", "mobile.showResults"] { UserDefaults.standard.removeObject(forKey: k) }
        }
        if let i = args.firstIndex(of: "-OwonScopeSource"), i + 1 < args.count {
            let v = args[i + 1]
            let choice: SourceChoice
            if v == "demo" {
                choice = .demo(.reference)
            } else {
                let parts = v.split(separator: ":")
                let host = String(parts[0])
                choice = .remote(RemoteTarget(name: host, host: host, port: parts.count > 1 ? UInt16(parts[1]) : nil))
            }
            if let d = try? JSONEncoder().encode(choice) { UserDefaults.standard.set(d, forKey: "source") }
        }
        let s = Self.load(ScopeSettings.self, "settings") ?? ScopeSettings()
        settings = s
        display = Self.load(DisplayPrefs.self, "display") ?? DisplayPrefs()
        processing = Self.load(ProcessingSettings.self, "processing") ?? ProcessingSettings()
        decoders = Self.load([DecoderInstance].self, "decoders") ?? []
        var src = Self.load(SourceChoice.self, "source") ?? (ScopeTransport.isAvailable ? .hardware : .demo(.reference))
        if src == .hardware && !ScopeTransport.isAvailable { src = .demo(.reference) }
        source = src
        engine = ScopeEngine(settings: s, source: src.engineSource)
        analysisConfig.update(display: display)
        analysisConfig.update(decoders: decoders)
        analysisConfig.update(processing: processing)
        updateGate()

        let config = analysisConfig
        engine.onEvent = { [weak self] event in
            // Heavy work (averaging, measurements, decoding, FFT) runs here on the engine
            // thread. DispatchQueue.main keeps events in the order the engine sent them.
            switch event {
            case .acquisition(let acq):
                let a = config.analyse(acq)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(acq, a) } }
            default:
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }
        }
        engine.start()
    }

    // MARK: Engine events

    private func receive(_ acq: Acquisition, _ a: Analysis) {
        rawAcquisition = acq
        acquisition = a.processed ?? acq
        analysis = a
        frameCount += 1
        if Self.sameCapture(acq.settings, settings) { matchingFrames += 1 }
        let frame = Frame(acquisition: a.processed ?? acq, raw: acq, analysis: a,
                          matchesSettings: Self.sameCapture(acq.settings, settings), matchingIndex: matchingFrames)
        for c in frameListeners.values { c.yield(frame) }
        for ch in 0..<2 {
            if let m = a.measurements[ch] { statistics.add(source: Trace(rawValue: ch)!.name, m) }
        }
        if let m = a.mathMeasurements { statistics.add(source: Trace.math.name, m) }
        if let c = a.cross {
            statistics.add(source: "CH1→CH2", kind: .delay, c.delay)
            statistics.add(source: "CH1→CH2", kind: .phase, c.phase)
        }
        let now = Date()
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 1 }
        framesPerSecond = Double(frameTimes.count)
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .connection(let c):
            connection = c
            if case .connected(let info) = c { appendLog("Connected: \(info.model) \(info.serial) (hw \(info.hardwareVersion))") }
        case .running(let r, let generation):
            // Ignore reports that belong to an older Run/Stop/Single command.
            if generation == runGeneration { running = r }
        case .settings(let s):
            applyingEngineSettings = true
            settings = s
            applyingEngineSettings = false
            engineSettingsUpdates += 1
        case .log(let m): appendLog(m)
        case .acquisition: break
        }
    }

    private func appendLog(_ m: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(m)")
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func settingsChanged(_ old: ScopeSettings) {
        save(settings, "settings")
        if !applyingEngineSettings { engine.update(settings) }
        if old != settings { statistics.reset() }
        if !Self.sameCapture(old, settings) { matchingFrames = 0 }
        // geometry change => old persistence no longer lines up
        if old.timebaseIndex != settings.timebaseIndex || old.channels != settings.channels || old.triggerPosition != settings.triggerPosition {
            displayGeneration += 1
        }
        updateGate()
    }

    private func displayChanged(_ old: DisplayPrefs) {
        save(display, "display")
        analysisConfig.update(display: display)
        if old.format != display.format { displayGeneration += 1 }
    }

    private func processingChanged(_ old: ProcessingSettings) {
        save(processing, "processing")
        analysisConfig.update(processing: processing)
        if old.mode != processing.mode || old.averages != processing.averages {
            analysisConfig.requestReset()
            displayGeneration += 1
        }
        if old != processing { statistics.reset() }
    }

    private func updateGate() {
        let start = settings.screenStart
        analysisConfig.update(screen: (start, start + settings.timebase.window), cursors: (cursors.t1, cursors.t2))
    }

    /// Whether captures taken with `a` and `b` are alike (the sweep mode doesn't change the samples).
    static func sameCapture(_ a: ScopeSettings, _ b: ScopeSettings) -> Bool {
        var a = a, b = b
        a.trigger.sweep = .auto
        b.trigger.sweep = .auto
        return a == b
    }

    /// Every displayed acquisition (after averaging) from now on, for at most `timeout`
    /// seconds. Call the returned `end` when done; only the newest few frames are buffered.
    func frames(timeout: Double) -> (stream: AsyncStream<Frame>, end: () -> Void) {
        let id = UUID()
        let (stream, c) = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(4))
        frameListeners[id] = c
        c.onTermination = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { _ = self?.frameListeners.removeValue(forKey: id) } }
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            c.finish()
        }
        return (stream, { timer.cancel(); c.finish() })
    }

    // MARK: Actions

    func toggleRun() { setRunning(!running) }

    func setRunning(_ r: Bool) {
        if r && settings.trigger.sweep == .single { settings.trigger.sweep = .auto }
        running = r
        runGeneration = engine.setRunning(r)
    }

    func single() {
        displayGeneration += 1
        settings.trigger.sweep = .single
        running = true
        runGeneration = engine.single()
    }

    func forceTrigger() { engine.forceTrigger() }

    func autoset() {
        running = true
        runGeneration = engine.autoset()
    }

    func reconnect() { engine.reconnect() }

    func clearPersistence() { displayGeneration += 1 }

    /// Clears persistence, averaging/envelope accumulation and statistics.
    func resetAccumulation() {
        displayGeneration += 1
        analysisConfig.requestReset()
        statistics.reset()
    }

    func resetStatistics() { statistics.reset() }

    var acquireMode: AcquireMode {
        get { settings.peakDetect ? .peak : processing.mode }
        set {
            settings.peakDetect = newValue == .peak
            processing.mode = newValue == .peak ? .normal : newValue
        }
    }

    func stepTimebase(_ delta: Int) {
        settings.timebaseIndex = max(0, min(Timebase.all.count - 1, settings.timebaseIndex + delta))
    }

    func stepVoltage(channel: Int, _ delta: Int) {
        let c = settings.channels[channel]
        settings.channels[channel].rangeIndex = max(0, min(VDS1022.voltRanges.count - 1, c.rangeIndex + delta))
    }

    /// Scale step for the selected trace (channel V/div or math units/div).
    func stepSelectedScale(_ delta: Int) {
        if selectedTrace == .math {
            processing.math.scaleIndex = max(0, min(Format.scales125.count - 1, processing.math.scaleIndex + delta))
        } else {
            stepVoltage(channel: selectedChannel, delta)
        }
    }

    func offset(of trace: Trace) -> Double {
        trace == .math ? processing.math.offsetDivisions : settings.channels[trace.rawValue].offsetDivisions
    }

    func setOffset(of trace: Trace, _ divs: Double) {
        let v = min(5, max(-5, divs))
        if trace == .math { processing.math.offsetDivisions = v } else { settings.channels[trace.rawValue].offsetDivisions = v }
    }

    /// Units per division and unit symbol of a trace.
    func scale(of trace: Trace) -> (perDiv: Double, unit: String) {
        switch trace {
        case .math: return (processing.math.unitsPerDivision, analysis.math?.unit ?? "")
        default:
            let c = settings.channels[trace.rawValue]
            return (c.unitsPerDivision, c.unit.symbol)
        }
    }

    func isVisible(_ trace: Trace) -> Bool {
        trace == .math ? processing.math.enabled : settings.channels[trace.rawValue].enabled
    }

    func selectTrace(_ t: Trace) {
        guard isVisible(t) else { return }
        selectedTrace = t
    }

    /// Sets the trigger level to the midpoint of the source channel's signal.
    func triggerFiftyPercent() {
        guard let ch = settings.trigger.source.channel, let w = acquisition?.channel(ch) else { return }
        let (base, top) = Measurements.levels(w)
        settings.trigger.level = (base + top) / 2
    }

    func mathAutoScale() {
        guard let m = analysis.math else { return }
        let (idx, off) = MathEngine.autoScale(m)
        processing.math.scaleIndex = idx
        processing.math.offsetDivisions = off
    }

    func setProbe(channel: Int, unit: SignalUnit) {
        guard settings.channels[channel].unit != unit else { return }
        settings.channels[channel].unit = unit
        settings.channels[channel].probe = unit == .volts ? 10 : 10 // ×10 or 100 mV/A
    }

    // MARK: References

    func saveReference(slot: Int, from trace: Trace) {
        guard slot < references.count else { return }
        let w: DerivedWaveform?
        switch trace {
        case .math: w = analysis.math
        default:
            w = acquisition?.channel(trace.rawValue).map {
                DerivedWaveform(values: $0.volts, t0: $0.t0, dt: $0.dt, unit: $0.unit.symbol, label: trace.name)
            }
        }
        guard let w else { return }
        let s = scale(of: trace)
        references[slot] = ReferenceWaveform(waveform: w, unitsPerDivision: s.perDiv, offsetDivisions: offset(of: trace))
    }

    func clearReference(slot: Int) { references[slot] = nil }

    // MARK: Decoders

    func addDecoder(_ kind: DecoderKind) {
        decoders.append(DecoderInstance(kind: kind))
        if display.bottomTab != .decode { display.bottomTab = .decode }
    }

    func removeDecoder(_ id: UUID) { decoders.removeAll { $0.id == id } }

    // MARK: Files

    #if os(macOS)
    func chooseFirmwareFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Firmware"
        panel.message = "Choose a folder containing VDS1022_FPGAV*.bin (e.g. the 'fwr' folder of the OWON software)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let n = try FirmwareLocator.importFirmware(from: url)
            appendLog("Imported \(n) firmware file(s) to \(FirmwareLocator.userDirectory.path)")
            reconnect()
        } catch {
            appendLog("Firmware import failed: \(error.localizedDescription)")
        }
    }

    func exportCSV() {
        guard let out = csvText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = csvFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { appendLog("Export failed: \(error.localizedDescription)") }
    }

    // MARK: Sharing on the network

    /// The server sharing this Mac's scope, while sharing is on.
    private(set) var sharing: ScopeServer?
    private(set) var sharingClients = 0

    /// Shares the scope (or the demo signal) with OwonScope on an iPhone, iPad or another
    /// Mac. The scope moves to a server in this process and this window becomes one of its
    /// clients, so every screen shows the same settings.
    func startSharing() {
        guard sharing == nil, !source.isRemote else { return }
        let server = ScopeServer(source: source.engineSource, settings: settings)
        server.onLog = { [weak self] m in DispatchQueue.main.async { self?.appendLog("Sharing: \(m)") } }
        server.onClientsChanged = { [weak self] n in DispatchQueue.main.async { self?.sharingClients = max(0, n - 1) } }
        // Release the scope before the server opens it.
        engine.setSource(.simulator(.reference))
        do {
            try server.start()
        } catch {
            appendLog("Sharing failed: \(error.localizedDescription)")
            engine.setSource(source.engineSource)
            return
        }
        sharing = server
        engine.setSource(.remote(RemoteTarget(name: "This Mac", host: "127.0.0.1", port: server.port)))
    }

    func stopSharing() {
        guard let server = sharing else { return }
        sharing = nil
        sharingClients = 0
        server.stop()
        engine.setSource(source.engineSource)
        appendLog("Stopped sharing")
    }
    #endif

    var csvFileName: String { "waveform-\(Int(Date().timeIntervalSince1970)).csv" }

    /// The displayed waveforms (and math) as CSV.
    func csvText() -> String? {
        guard let acq = acquisition else { return nil }
        var out = "time_s"
        let chans = acq.channels.compactMap { $0 }
        guard !chans.isEmpty else { return nil }
        for w in chans { out += ",CH\(w.channel + 1)_\(w.unit.symbol)" }
        let math = analysis.math
        if let m = math { out += ",MATH_\(m.unit)" }
        out += "\n"
        let n = chans.map(\.count).max() ?? 0
        for i in 0..<n {
            out += String(format: "%.10g", chans[0].time(at: i))
            for w in chans { out += i < w.count ? String(format: ",%.6g", w.volts[i]) : "," }
            if let m = math { out += i < m.count ? String(format: ",%.6g", m.values[i]) : "," }
            out += "\n"
        }
        return out
    }

    func copyDecodedText() {
        var lines: [String] = []
        for d in decoders {
            guard let r = analysis.decodes[d.id] else { continue }
            lines.append("# \(d.kind.name): \(r.summary)")
            for e in r.events { lines.append(String(format: "%.9f\t%@", e.start, e.label)) }
        }
        Clipboard.copy(lines.joined(separator: "\n"))
    }

    // MARK: Persistence

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Remote scopes used before, newest first (for hosts typed in by hand, which Bonjour
/// won't list).
enum RecentRemotes {
    private static let key = "recentRemotes"

    static var all: [RemoteTarget] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RemoteTarget].self, from: d) else { return [] }
        return list
    }

    static func add(_ t: RemoteTarget) {
        var list = all.filter { $0 != t }
        list.insert(t, at: 0)
        if let d = try? JSONEncoder().encode(Array(list.prefix(6))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Analysis state shared with the engine thread. Configuration is set from the main
/// thread under a lock; the waveform processor is only touched on the engine thread.
final class AnalysisConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var decoders: [DecoderInstance] = []
    private var display = DisplayPrefs()
    private var processing = ProcessingSettings()
    private var screen: (Double, Double) = (0, 0)
    private var cursorRange: (Double, Double) = (0, 0)
    private var resetPending = false
    private let processor = WaveformProcessor()

    func update(decoders d: [DecoderInstance]) { lock.lock(); decoders = d; lock.unlock() }
    func update(display d: DisplayPrefs) { lock.lock(); display = d; lock.unlock() }
    func update(processing p: ProcessingSettings) { lock.lock(); processing = p; lock.unlock() }
    func update(screen s: (Double, Double), cursors c: (Double, Double)) { lock.lock(); screen = s; cursorRange = c; lock.unlock() }
    func requestReset() { lock.lock(); resetPending = true; lock.unlock() }

    func analyse(_ acq: Acquisition) -> Analysis {
        lock.lock()
        let decs = decoders, disp = display, proc = processing
        let screenRange = screen, cursorsRange = cursorRange
        let reset = resetPending
        resetPending = false
        lock.unlock()

        if reset { processor.reset() }
        let processed = processor.process(acq, proc)
        var a = Analysis()
        a.processed = processed

        let gate: (Double, Double)? = {
            switch proc.gate {
            case .record: return nil
            case .screen: return screenRange
            case .cursors: return cursorsRange
            }
        }()
        func gated(_ w: ChannelWaveform) -> ChannelWaveform {
            gate.map { Gating.apply(w, start: $0.0, end: $0.1) } ?? w
        }

        a.measurements = processed.channels.map { $0.map { Measurements.compute(gated($0)) } }
        if let a1 = processed.channel(0), let b1 = processed.channel(1) {
            a.cross = Measurements.cross(gated(a1), gated(b1))
        }
        if let m = MathEngine.compute(proc.math, processed) {
            a.math = m
            let g = gate.map { Gating.apply(m, start: $0.0, end: $0.1) } ?? m
            let finite = g.values.map { $0.isFinite ? $0 : 0 }
            a.mathMeasurements = Measurements.compute(values: finite, dt: g.dt, resolution: proc.math.unitsPerDivision / 25)
        }
        // Decoders work on the raw capture (averaging would smear edges).
        for d in decs where d.enabled {
            a.decodes[d.id] = ProtocolDecoding.run(d, on: acq)
        }
        if disp.bottomTab == .spectrum, let w = processed.channel(disp.spectrumChannel) {
            a.spectrum = SpectrumAnalyzer.compute(w, window: disp.spectrumWindow)
        }
        return a
    }
}
