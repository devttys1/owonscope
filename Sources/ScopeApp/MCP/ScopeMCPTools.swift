#if os(macOS)
import Foundation
import ScopeKit

/// The oscilloscope's MCP tools. They drive the app's own model, so everything an agent
/// does shows on screen, and every result is JSON text.
@MainActor
final class ScopeMCPTools: MCPToolProvider {
    static let defaultPort: UInt16 = 8908

    private let model: ScopeModel

    init(model: ScopeModel) { self.model = model }

    let instructions = """
    OwonScope: an OWON VDS1022I two-channel USB oscilloscope (25 MHz, 8-bit ADC, 100 MS/s max, \
    5000 samples per capture; the I model has isolated USB). It is wired to a circuit under test, \
    often alongside the mdp-bench supply and load. The scope only observes, so its settings are \
    safe to change, but the user is watching the same screen.
    - Channels are CH1 and CH2. Probe factor, V/div, offset and trigger level are all in the units at \
    the probe tip (V, or A for a current probe). V/div snaps to the hardware ranges (5 mV-5 V per div \
    at the BNC, times the probe factor). The screen is 10 x 8 divisions and the ADC clips at +/-5 \
    divisions from centre, so a clipped trace means every amplitude reading is wrong: raise V/div.
    - For resolution, make the signal fill 4-8 divisions (25 ADC counts per division). Use AC coupling \
    to look at small ripple on a large DC level.
    - DC accuracy is a few percent: take efficiency and DC levels from the bench instruments, and use \
    the scope for ripple, switching frequency, duty cycle, edges, transients and protocol decoding.
    - measure collects statistics over many fresh captures (taken after the call, with the current \
    settings); capture returns one capture with all measurements. Gate measurements to a time window \
    (seconds from the trigger) with gate_start_s/gate_end_s.
    - To catch a one-off event (start-up, load step, fault): configure the trigger, call \
    run_control action=single, cause the event (e.g. with mdp-bench), then capture (waits for the \
    trigger). capture single=true arms and waits in one call when the event will come by itself.
    - get_waveform returns decimated samples; export_report or capture image=true shows the screen.
    """

    // MARK: Schemas

    private static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }
    private static func num(_ d: String, min: Double? = nil, max: Double? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "number", "description": d]
        if let min { s["minimum"] = min }
        if let max { s["maximum"] = max }
        return s
    }
    private static func bool(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func str(_ d: String, _ values: [String]? = nil) -> [String: Any] {
        var s: [String: Any] = ["type": "string", "description": d]
        if let values { s["enum"] = values }
        return s
    }
    private static let channelArg = str("CH1 or CH2", ["CH1", "CH2"])
    private static let measurementList: [String: Any] = [
        "type": "array", "items": ["type": "string", "enum": MeasurementKind.allCases.map { name($0) }],
        "description": "Measurements to report (default: all). delay and phase are CH1 to CH2.",
    ]
    private static let gateArgs: [String: Any] = [
        "gate_start_s": num("Measure only from this time (seconds from the trigger, negative = before it)"),
        "gate_end_s": num("...to this time. Default: the whole record"),
        "gate_screen": bool("Measure only what is on screen (default false: the whole record)"),
    ]

    let definitions: [[String: Any]] = [
        ["name": "scope_status",
         "description": "Connection, run state, every channel's settings (units, probe, V/div, coupling, offset, on-screen range), timebase (s/div, sample rate, record length), trigger, acquisition mode, math, decoders, and the latest capture's age and clipping.",
         "inputSchema": obj([:]),
         "annotations": ["readOnlyHint": true]],
        ["name": "configure_channel",
         "description": "Set up one channel. Order applied: probe, then V/div, then offset. V/div snaps to the nearest hardware range at or above the value. Returns the settings applied.",
         "inputSchema": obj(["channel": channelArg,
                             "enabled": bool("Show and acquire the channel"),
                             "probe_x": num("Voltage probe attenuation (1, 10, 100, 1000); the channel reads volts", min: 0.001, max: 10000),
                             "current_probe_v_per_a": num("Current probe sensitivity in V/A (e.g. 0.1 for 100 mV/A); the channel reads amps", min: 1e-5, max: 100),
                             "volts_per_div": num("Scale in channel units per division (V or A at the probe tip)", min: 0),
                             "coupling": str("Input coupling", ["DC", "AC", "GND"]),
                             "offset_div": num("Zero line position in divisions from screen centre (+ is up)", min: -5, max: 5),
                             "center_value": num("Alternative to offset_div: the value (V or A) to put at screen centre")],
                            required: ["channel"])],
        ["name": "configure_timebase",
         "description": "Set the horizontal scale (20 ns/div to 100 s/div, 1-2-5 steps; 10 divisions) and where the trigger point sits. 500 ms/div and slower is roll mode (untriggered). Returns the sample rate and record length.",
         "inputSchema": obj(["seconds_per_div": num("Time per division (snaps to the nearest step)", min: 1e-9, max: 100),
                             "trigger_position": num("Trigger point as a fraction of the screen width from the left (0.5 = centre, 0.1 = mostly after the trigger)", min: 0, max: 1)])],
        ["name": "configure_trigger",
         "description": "Set up the trigger. Level is in the source channel's units. For a one-shot capture use run_control single or capture single=true.",
         "inputSchema": obj(["source": str("Trigger source", ["CH1", "CH2", "EXT"]),
                             "mode": str("Edge, or Pulse (pulse width)", ["Edge", "Pulse"]),
                             "slope": str("Edge direction; for Pulse, Rising = positive pulse", ["Rising", "Falling"]),
                             "level": num("Trigger level (V or A)"),
                             "level_50_percent": bool("Set the level to the middle of the source signal's latest capture"),
                             "sweep": str("Auto (free-runs without a trigger) or Normal (waits for one)", ["Auto", "Normal"]),
                             "holdoff_s": num("Holdoff", min: 1e-7, max: 10),
                             "pulse_condition": str("Pulse mode: width greater than, less than or equal to pulse_width_s", [">", "<", "="]),
                             "pulse_width_s": num("Pulse mode: width", min: 2e-8, max: 10)])],
        ["name": "configure_acquisition",
         "description": "Acquisition mode: Normal, Peak (hardware peak detect, catches narrow glitches at slow timebases), Average (of triggered captures, lowers noise) or Envelope (min/max over captures).",
         "inputSchema": obj(["mode": str("Acquisition mode", AcquireMode.allCases.map(\.rawValue)),
                             "averages": num("Captures averaged in Average mode: 2-1024 (powers of 2)", min: 2, max: 1024)])],
        ["name": "configure_math",
         "description": "The math trace: CH1 x CH2 (e.g. volts x current probe = watts), A+B, A-B, A/B, d/dt, integral or -A. Units follow the inputs. Measured as trace MATH.",
         "inputSchema": obj(["enabled": bool("Show and measure the math trace"),
                             "operation": str("Operation", ["add", "subtract", "multiply", "divide", "differentiate", "integrate", "invert"]),
                             "source_a": channelArg, "source_b": channelArg,
                             "auto_scale": bool("Fit the math trace to the screen (default true)")])],
        ["name": "run_control",
         "description": "run, stop, single (arm a one-shot capture and return at once; collect it with capture), force_trigger, or autoset (finds and scales the signals; waits for it to finish).",
         "inputSchema": obj(["action": str("What to do", ["run", "stop", "single", "force_trigger", "autoset"])], required: ["action"])],
        ["name": "capture",
         "description": "One capture with measurements for every trace (CH1, CH2, MATH) and CH1 to CH2 delay/phase. Waits for a capture taken after the call with the current settings (in Average mode, a full average). If a single shot is armed, waits for its trigger; if the scope is stopped, returns the held capture. single=true arms a one-shot capture first.",
         "inputSchema": obj(["single": bool("Arm a one-shot capture and wait for its trigger"),
                             "timeout_s": num("How long to wait for a trigger (default 5 s, longer at slow timebases)", min: 0.1, max: 300),
                             "force_on_timeout": bool("Force a trigger if none came in time (default false)"),
                             "measurements": measurementList,
                             "image": bool("Also return a picture of the screen (the report plot)")]
                            .merging(gateArgs) { a, _ in a })],
        ["name": "measure",
         "description": "Statistics (mean, min, max, standard deviation, count) of measurements over several fresh captures, per trace. The scope must be running.",
         "inputSchema": obj(["captures": num("Captures to collect (default 10)", min: 1, max: 1000),
                             "timeout_s": num("Most time to spend (default 30 s, longer at slow timebases)", min: 0.5, max: 600),
                             "traces": ["type": "array", "items": ["type": "string", "enum": ["CH1", "CH2", "MATH"]],
                                        "description": "Traces to measure (default: all shown)"],
                             "measurements": measurementList]
                            .merging(gateArgs) { a, _ in a }),
         "annotations": ["readOnlyHint": true]],
        ["name": "get_waveform",
         "description": "Samples of the latest capture between two times (default: the screen), decimated to max_points rows. minmax keeps peaks and glitches (two columns per trace); mean averages each bucket; sample takes every n-th point. csv_path writes the window at full resolution.",
         "inputSchema": obj(["traces": ["type": "array", "items": ["type": "string", "enum": ["CH1", "CH2", "MATH"]],
                                        "description": "Default: all shown"],
                             "start_s": num("Window start, seconds from the trigger"),
                             "end_s": num("Window end"),
                             "max_points": num("Most rows (default 500)", min: 2, max: 5000),
                             "decimation": str("How rows are reduced (default minmax)", ["minmax", "mean", "sample"]),
                             "interpolate": bool("sin(x)/x interpolate to max_points when the window holds fewer samples"),
                             "fresh": bool("Wait for a new capture first (default false: the latest one)"),
                             "csv_path": str("Write the window at full resolution to this CSV file")]),
         "annotations": ["readOnlyHint": true]],
        ["name": "spectrum",
         "description": "FFT of a channel's latest capture (up to 4096 samples, DC removed): the strongest peaks (at least 10 dB above the median noise floor) in dBV RMS and RMS units, bin width and Nyquist frequency. Frequency resolution is the bin width: use a slower timebase to resolve closer tones.",
         "inputSchema": obj(["channel": channelArg,
                             "window": str("FFT window (default Hann; Flat top for accurate amplitudes)", FFTWindow.allCases.map(\.rawValue)),
                             "peaks": num("Peaks to list (default 10)", min: 1, max: 100),
                             "min_hz": num("Ignore peaks below this frequency", min: 0),
                             "fresh": bool("Wait for a new capture first")]),
         "annotations": ["readOnlyHint": true]],
        ["name": "configure_decoder",
         "description": "Add, remove, clear or list protocol decoders: UART, I2C, SPI, CAN, LIN, USB 1.x (low/full speed) and 1-Wire. Decoders run on every capture and show as lanes on screen; read them with get_decoded. Unset arguments take the protocol's defaults; rates of 0 or none are detected, and a threshold of 0 or none is automatic (mid level). Timebases that suit: CAN ~100 µs/div at 500 kbit/s, LIN ~1 ms/div, 1-Wire 0.5-1 ms/div, USB low speed 5-20 µs/div (full speed needs 100 MS/s, 5 µs/div or faster).",
         "inputSchema": obj(["action": str("What to do", ["add", "remove", "clear", "list"]),
                             "protocol": str("For add", DecoderKind.allProtocolIDs),
                             "id": str("For remove: the decoder id"),
                             "channel": channelArg,
                             "baud": num("UART or LIN baud (0 or none = detect)", min: 0),
                             "data_bits": num("UART data bits (default 8)", min: 5, max: 9),
                             "parity": str("UART parity", ["None", "Even", "Odd"]),
                             "stop_bits": num("UART stop bits (1, 1.5, 2)", min: 1, max: 2),
                             "invert": bool("UART or LIN: inverted signal (RS-232 level; LIN on a TX/RX logic pin)"),
                             "msb_first": bool("Bit order (UART default LSB first, SPI default MSB first)"),
                             "scl": channelArg, "sda": channelArg, "sck": channelArg, "data": channelArg,
                             "spi_mode": num("SPI mode 0-3", min: 0, max: 3),
                             "bits_per_word": num("SPI word size, 8 or 16", min: 8, max: 16),
                             "bitrate": num("CAN bit rate (0 or none = detect, snapped to 10k...1M)", min: 0),
                             "sample_point": num("CAN sample point as a fraction of the bit (default 0.75)", min: 0.3, max: 0.95),
                             "signal": str("CAN: what the probe is on, which sets the dominant level (default Auto)", CANConfig.Signal.allCases.map(\.rawValue)),
                             "checksum": str("LIN checksum (default Auto: either, the label says which)", LINConfig.Checksum.allCases.map(\.rawValue)),
                             "d_plus": channelArg, "d_minus": channelArg,
                             "speed": str("USB: Auto, Low or Full. 1-Wire: Auto, Standard or Overdrive",
                                          Array(Set(USBConfig.Speed.allCases.map(\.rawValue) + OneWireConfig.Speed.allCases.map(\.rawValue))).sorted()),
                             "threshold_v": num("Logic threshold in channel units (default automatic)"),
                             "format": str("How data values are shown", DataFormat.allCases.map(\.rawValue))],
                            required: ["action"])],
        ["name": "get_decoded",
         "description": "Decoded events of every enabled decoder on the latest capture: time, kind, value and label, plus decoded text for UART. Kinds: start (CAN SOF, LIN break, USB SYNC, 1-Wire reset, I2C start), address (I2C address, CAN/LIN ID, USB address+endpoint, 1-Wire ROM/function command), data, info (DLC, CRC, PIDs, sync, checksum), ack/nack (I2C, CAN ACK slot, USB handshake, 1-Wire presence), stop, error (CRC, stuff, form, parity, checksum).",
         "inputSchema": obj(["max_events": num("Most events per decoder (default 200)", min: 1, max: 5000),
                             "fresh": bool("Wait for a new capture first (default true while running)")]),
         "annotations": ["readOnlyHint": true]],
        ["name": "export_report",
         "description": "Save a report of the screen (plot with cursors and decode lanes, settings, measurements, statistics) as SVG, PDF or PNG. Returns the path, and optionally the picture.",
         "inputSchema": obj(["path": str("File to write (default: ~/Documents/OwonScope/<timestamp>.<format>)"),
                             "format": str("Default SVG", ["SVG", "PDF", "PNG"]),
                             "theme": str("Default Light", ["Light", "Dark"]),
                             "statistics": bool("Include the statistics table (default true)"),
                             "return_image": bool("Also return the report as an image")])],
        ["name": "set_source",
         "description": "Switch between the USB scope and the built-in simulator (for trying things without hardware). Stops network sharing.",
         "inputSchema": obj(["source": str("hardware or demo", ["hardware", "demo"]),
                             "scenario": str("Demo signal (default reference: 1 kHz square + UART)", SimulatorScenario.allCases.map(scenarioID))],
                            required: ["source"])],
    ]

    // MARK: Dispatch

    func call(_ name: String, _ a: [String: Any]) async -> MCPToolResult {
        do {
            switch name {
            case "scope_status": return json(status())
            case "configure_channel": return json(try configureChannel(a))
            case "configure_timebase": return json(try await configureTimebase(a))
            case "configure_trigger": return json(try configureTrigger(a))
            case "configure_acquisition": return json(try configureAcquisition(a))
            case "configure_math": return json(try await configureMath(a))
            case "run_control": return json(try await runControl(a))
            case "capture": return try await capture(a)
            case "measure": return json(try await measure(a))
            case "get_waveform": return json(try await waveform(a), pretty: false)
            case "spectrum": return json(try await spectrum(a))
            case "configure_decoder": return json(try configureDecoder(a))
            case "get_decoded": return json(try await decoded(a))
            case "export_report": return try exportReport(a)
            case "set_source": return json(try await setSource(a))
            default: throw ToolError("Unknown tool \(name)")
            }
        } catch {
            return .text((error as? LocalizedError)?.errorDescription ?? "\(error)", isError: true)
        }
    }

    struct ToolError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func json(_ o: Any, pretty: Bool = true) -> MCPToolResult { .text(Self.jsonText(o, pretty: pretty)) }

    static func jsonText(_ o: Any, pretty: Bool = true) -> String {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: opts)
        else { return "\(o)" }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: Argument helpers

    private func number(_ a: [String: Any], _ k: String) -> Double? {
        if let n = a[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return (a[k] as? String).flatMap(Double.init)
    }

    private func flag(_ a: [String: Any], _ k: String) -> Bool? {
        if let n = a[k] as? NSNumber { return n.boolValue }
        if let s = a[k] as? String { return ["true", "on", "1", "yes"].contains(s.lowercased()) }
        return nil
    }

    private func string(_ a: [String: Any], _ k: String) -> String? { a[k] as? String }

    /// "CH1", "ch2", "1", 2 -> channel index.
    private func channel(_ a: [String: Any], _ k: String) throws -> Int? {
        guard let v = a[k] else { return nil }
        let s = (v as? String ?? "\(v)").uppercased().replacingOccurrences(of: "CH", with: "")
        guard let n = Int(s), n == 1 || n == 2 else { throw ToolError("\(k) must be CH1 or CH2") }
        return n - 1
    }

    private func choice<T: RawRepresentable>(_ a: [String: Any], _ k: String, _ type: T.Type) throws -> T?
    where T.RawValue == String, T: CaseIterable {
        guard let s = a[k] as? String else { return nil }
        guard let v = T.allCases.first(where: { $0.rawValue.lowercased() == s.lowercased() }) else {
            throw ToolError("\(k) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return v
    }

    private func traceList(_ a: [String: Any]) throws -> [Trace]? {
        guard let list = a["traces"] as? [Any] else { return nil }
        return try list.map { v in
            switch "\(v)".uppercased() {
            case "CH1", "1": return .ch1
            case "CH2", "2": return .ch2
            case "MATH", "M": return .math
            default: throw ToolError("Unknown trace \(v): use CH1, CH2 or MATH")
            }
        }
    }

    private func measurementKinds(_ a: [String: Any]) throws -> [MeasurementKind] {
        guard let list = a["measurements"] as? [Any] else { return MeasurementKind.allCases }
        return try list.map { v in
            let s = "\(v)".lowercased()
            guard let k = MeasurementKind.allCases.first(where: { Self.name($0) == s || $0.rawValue.lowercased() == s }) else {
                throw ToolError("Unknown measurement \(v). Known: \(MeasurementKind.allCases.map { Self.name($0) }.joined(separator: ", "))")
            }
            return k
        }
    }

    private func gate(_ a: [String: Any]) -> (Double, Double)? {
        if let s = number(a, "gate_start_s"), let e = number(a, "gate_end_s") { return (s, e) }
        if let s = number(a, "gate_start_s") { return (s, .infinity) }
        if let e = number(a, "gate_end_s") { return (-.infinity, e) }
        if flag(a, "gate_screen") == true { return screenRange }
        return nil
    }

    private var screenRange: (Double, Double) {
        let s = model.settings
        return (s.screenStart, s.screenStart + s.timebase.window)
    }

    // MARK: Number formatting

    /// Six significant digits, as a decimal so the JSON reads 0.0012 rather than 0.00119999...
    static func n6(_ x: Double?, digits: Int = 6) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.\(digits)g", x))
    }
    private func n6(_ x: Double?, digits: Int = 6) -> Any { Self.n6(x, digits: digits) }

    // MARK: Measurement names and units

    static func name(_ k: MeasurementKind) -> String {
        switch k {
        case .frequency: "frequency"
        case .period: "period"
        case .posWidth: "pos_width"
        case .negWidth: "neg_width"
        case .duty: "duty"
        case .rise: "rise"
        case .fall: "fall"
        case .pkpk: "pk_pk"
        case .peak: "peak"
        case .max: "max"
        case .min: "min"
        case .amplitude: "amplitude"
        case .top: "top"
        case .base: "base"
        case .mean: "mean"
        case .cycleMean: "cycle_mean"
        case .rms: "rms"
        case .acRMS: "ac_rms"
        case .cycleRMS: "cycle_rms"
        case .crest: "crest"
        case .overshoot: "overshoot"
        case .preshoot: "preshoot"
        case .area: "area"
        case .posPulses: "pos_pulses"
        case .negPulses: "neg_pulses"
        case .risingEdges: "rising_edges"
        case .fallingEdges: "falling_edges"
        case .delay: "delay"
        case .phase: "phase"
        }
    }

    /// The unit a measurement is reported in, and the factor from the stored value.
    static func unit(_ k: MeasurementKind, trace unit: String) -> (String, Double) {
        switch k {
        case .frequency: ("Hz", 1)
        case .period, .posWidth, .negWidth, .rise, .fall, .delay: ("s", 1)
        case .duty, .overshoot, .preshoot: ("%", 100)
        case .phase: ("deg", 1)
        case .crest: ("ratio", 1)
        case .posPulses, .negPulses, .risingEdges, .fallingEdges: ("count", 1)
        case .area: (unit + "·s", 1)
        default: (unit, 1)
        }
    }

    // MARK: Status

    private var connectionInfo: [String: Any] {
        switch model.connection {
        case .searching: return ["state": "searching", "note": "No scope found on USB"]
        case .connecting: return ["state": "connecting"]
        case .loadingFirmware(let p): return ["state": "loading FPGA firmware", "progress": n6(p, digits: 3)]
        case .failed(let m): return ["state": "failed", "error": m]
        case .connected(let i):
            var o: [String: Any] = ["state": "connected", "model": i.model, "serial": i.serial,
                                    "hardware_version": i.hardwareVersion, "fpga_version": i.fpgaVersion,
                                    "simulated": i.isSimulated]
            if let h = i.host { o["shared_by"] = h }
            return o
        }
    }

    private var sourceText: String {
        switch model.source {
        case .hardware: "hardware (USB)"
        case .demo(let s): "demo: \(s.rawValue)"
        case .remote(let t): "remote: \(t.name)"
        }
    }

    private func channelInfo(_ ch: Int) -> [String: Any] {
        let c = model.settings.channels[ch]
        let perDiv = c.unitsPerDivision
        var o: [String: Any] = [
            "channel": "CH\(ch + 1)", "enabled": c.enabled, "unit": c.unit.symbol,
            "probe": c.probeLabel, "coupling": c.coupling.rawValue,
            "volts_per_div": n6(perDiv), "offset_div": n6(c.offsetDivisions, digits: 4),
            "center_value": n6(-c.offsetDivisions * perDiv),
            "screen_min": n6((-5 - c.offsetDivisions) * perDiv), "screen_max": n6((5 - c.offsetDivisions) * perDiv),
            "resolution": n6(c.voltsPerCount, digits: 3),
            "available_volts_per_div": VDS1022.voltsPerDivision.map { n6($0 * c.probe) },
        ]
        if c.unit == .amps { o["current_probe_v_per_a"] = n6(1 / c.probe) } else { o["probe_x"] = n6(c.probe) }
        return o
    }

    private var timebaseInfo: [String: Any] {
        let s = model.settings, tb = s.timebase
        return ["seconds_per_div": n6(tb.secondsPerDivision), "window_s": n6(tb.window),
                "sample_rate_hz": n6(tb.sampleRate), "record_s": n6(tb.acquisitionWindow),
                "record_samples": VDS1022.samplesPerFrame, "roll_mode": tb.isRollMode,
                "trigger_position": n6(s.triggerPosition, digits: 4),
                "screen_start_s": n6(s.screenStart), "screen_end_s": n6(s.screenStart + tb.window)]
    }

    private var triggerInfo: [String: Any] {
        let t = model.settings.trigger
        var o: [String: Any] = ["source": t.source.rawValue, "mode": t.mode.rawValue, "slope": t.slope.rawValue,
                                "level": n6(t.level), "sweep": t.sweep.rawValue, "holdoff_s": n6(t.holdoff)]
        if let ch = t.source.channel { o["level_unit"] = model.settings.channels[ch].unit.symbol }
        if t.mode == .pulse { o["pulse_condition"] = t.pulseCondition.rawValue; o["pulse_width_s"] = n6(t.pulseWidth) }
        return o
    }

    private var mathInfo: [String: Any] {
        let m = model.processing.math
        var o: [String: Any] = ["enabled": m.enabled, "operation": Self.mathName(m.operation), "label": m.label,
                                "units_per_div": n6(m.unitsPerDivision), "offset_div": n6(m.offsetDivisions, digits: 4)]
        if let u = model.analysis.math?.unit { o["unit"] = u }
        return o
    }

    private func decoderInfo(_ d: DecoderInstance) -> [String: Any] {
        var o: [String: Any] = ["id": d.id.uuidString, "protocol": d.kind.protocolID, "name": d.kind.name, "enabled": d.enabled]
        // The settings, keyed like configure_decoder's arguments; numbers and flags typed.
        for (k, v) in d.kind.settingsSummary {
            if v == "true" || v == "false" { o[k] = v == "true" } else if let x = Double(v) { o[k] = n6(x) } else { o[k] = v }
        }
        if let r = model.analysis.decodes[d.id] { o["summary"] = r.summary }
        return o
    }

    private func status() -> [String: Any] {
        var out: [String: Any] = [
            "connection": connectionInfo,
            "source": sourceText,
            "running": model.running,
            "armed_single": model.running && model.settings.trigger.sweep == .single,
            "captures_per_second": n6(model.framesPerSecond, digits: 3),
            "channels": [channelInfo(0), channelInfo(1)],
            "timebase": timebaseInfo,
            "trigger": triggerInfo,
            "acquisition": ["mode": model.acquireMode.rawValue, "averages": model.processing.averages],
            "math": mathInfo,
            "decoders": model.decoders.map(decoderInfo),
            "sharing_on_network": model.sharing != nil,
        ]
        if let acq = model.acquisition {
            var latest: [String: Any] = ["age_s": n6(Date().timeIntervalSince(acq.timestamp), digits: 3),
                                         "trigger_state": acq.triggerState.rawValue,
                                         "taken_with_current_settings": ScopeModel.sameCapture(acq.settings, model.settings)]
            for case let w? in acq.channels { latest["CH\(w.channel + 1)_clipped"] = w.clipped }
            out["latest_capture"] = latest
        }
        return out
    }

    // MARK: Configuration

    private func configureChannel(_ a: [String: Any]) throws -> [String: Any] {
        guard let ch = try channel(a, "channel") else { throw ToolError("channel is required") }
        var c = model.settings.channels[ch]
        var notes: [String] = []
        if let e = flag(a, "enabled") { c.enabled = e }
        if number(a, "probe_x") != nil && number(a, "current_probe_v_per_a") != nil {
            throw ToolError("Give probe_x (voltage probe) or current_probe_v_per_a, not both")
        }
        if let p = number(a, "probe_x") { guard p > 0 else { throw ToolError("probe_x must be positive") }; c.unit = .volts; c.probe = p }
        if let s = number(a, "current_probe_v_per_a") { guard s > 0 else { throw ToolError("current_probe_v_per_a must be positive") }; c.unit = .amps; c.probe = 1 / s }
        if let cp = try choice(a, "coupling", Coupling.self) { c.coupling = cp }
        if let v = number(a, "volts_per_div") {
            let options = VDS1022.voltsPerDivision.map { $0 * c.probe }
            let i = options.firstIndex { $0 >= v * 0.999 } ?? options.count - 1
            c.rangeIndex = i
            if abs(options[i] - v) > v * 0.001 {
                notes.append("volts_per_div \(Format.number(v)) is not a hardware range: using \(Format.si(options[i], unit: c.unit.symbol))/div")
            }
        }
        if number(a, "offset_div") != nil && number(a, "center_value") != nil { throw ToolError("Give offset_div or center_value, not both") }
        if let o = number(a, "offset_div") { c.offsetDivisions = min(5, max(-5, o)) }
        if let v = number(a, "center_value") {
            let o = -v / c.unitsPerDivision
            if abs(o) > 5 { notes.append("center_value is more than 5 divisions from zero at this V/div: the offset is clamped. Use AC coupling or a larger V/div.") }
            c.offsetDivisions = min(5, max(-5, o))
        }
        model.settings.channels[ch] = c
        var out = channelInfo(ch)
        if !notes.isEmpty { out["notes"] = notes }
        return out
    }

    private func configureTimebase(_ a: [String: Any]) async throws -> [String: Any] {
        var notes: [String] = []
        if let v = number(a, "seconds_per_div") {
            guard v > 0 else { throw ToolError("seconds_per_div must be positive") }
            let i = Timebase.all.indices.min { abs(log(Timebase.all[$0].secondsPerDivision / v)) < abs(log(Timebase.all[$1].secondsPerDivision / v)) }!
            model.settings.timebaseIndex = i
            let got = Timebase.all[i].secondsPerDivision
            if abs(got - v) > v * 0.001 { notes.append("Using \(Format.seconds(got))/div, the nearest step") }
        }
        if let p = number(a, "trigger_position") { model.settings.triggerPosition = min(1, max(0, p)) }
        var out = timebaseInfo
        if model.settings.timebase.isZoomed { notes.append("Faster than 5 µs/div the record (\(Format.seconds(model.settings.timebase.acquisitionWindow))) is wider than the screen; the screen is interpolated") }
        if model.settings.timebase.isRollMode { notes.append("Roll mode: the trigger is not used; captures scroll") }
        if !notes.isEmpty { out["notes"] = notes }
        return out
    }

    private func configureTrigger(_ a: [String: Any]) throws -> [String: Any] {
        var t = model.settings.trigger
        if let s = try choice(a, "source", TriggerSource.self) { t.source = s }
        if let m = try choice(a, "mode", TriggerMode.self) { t.mode = m }
        if let s = try choice(a, "slope", TriggerSlope.self) { t.slope = s }
        if let l = number(a, "level") { t.level = l }
        if let s = try choice(a, "sweep", SweepMode.self) {
            guard s != .single else { throw ToolError("For a one-shot capture use run_control action=single or capture single=true") }
            t.sweep = s
        }
        if let h = number(a, "holdoff_s") { t.holdoff = min(10, max(1e-7, h)) }
        if let c = try choice(a, "pulse_condition", PulseCondition.self) { t.pulseCondition = c }
        if let w = number(a, "pulse_width_s") { t.pulseWidth = min(10, max(2e-8, w)) }
        model.settings.trigger = t
        var notes: [String] = []
        if flag(a, "level_50_percent") == true {
            if t.source.channel == nil { throw ToolError("level_50_percent needs a channel source") }
            guard model.acquisition != nil else { throw ToolError("No capture yet to take the 50% level from") }
            model.triggerFiftyPercent()
        }
        if let ch = model.settings.trigger.source.channel {
            let c = model.settings.channels[ch]
            let lo = (-5 - c.offsetDivisions) * c.unitsPerDivision, hi = (5 - c.offsetDivisions) * c.unitsPerDivision
            if model.settings.trigger.level < lo || model.settings.trigger.level > hi {
                notes.append("The level is off screen for CH\(ch + 1) (\(Format.si(lo, unit: c.unit.symbol)) to \(Format.si(hi, unit: c.unit.symbol))): it will never trigger")
            }
        }
        var out = triggerInfo
        if !notes.isEmpty { out["notes"] = notes }
        return out
    }

    private func configureAcquisition(_ a: [String: Any]) throws -> [String: Any] {
        if let m = try choice(a, "mode", AcquireMode.self) { model.acquireMode = m }
        if let n = number(a, "averages") {
            let want = Int(n)
            model.processing.averages = ProcessingSettings.averageCounts.min { abs($0 - want) < abs($1 - want) } ?? 16
        }
        return ["mode": model.acquireMode.rawValue, "averages": model.processing.averages]
    }

    private static func mathName(_ op: MathOperation) -> String {
        switch op {
        case .add: "add"
        case .subtract: "subtract"
        case .multiply: "multiply"
        case .divide: "divide"
        case .differentiate: "differentiate"
        case .integrate: "integrate"
        case .invert: "invert"
        }
    }

    private func configureMath(_ a: [String: Any]) async throws -> [String: Any] {
        var m = model.processing.math
        if let e = flag(a, "enabled") { m.enabled = e }
        if let s = string(a, "operation") {
            guard let op = MathOperation.allCases.first(where: { Self.mathName($0) == s.lowercased() }) else {
                throw ToolError("operation must be add, subtract, multiply, divide, differentiate, integrate or invert")
            }
            m.operation = op
            if a["enabled"] == nil { m.enabled = true }
        }
        if let s = try channel(a, "source_a") { m.sourceA = s }
        if let s = try channel(a, "source_b") { m.sourceB = s }
        model.processing.math = m
        if m.enabled && flag(a, "auto_scale") != false, model.running {
            _ = await freshFrames(1, timeout: 3) { $0.analysis.math != nil }
            model.mathAutoScale()
        }
        return mathInfo
    }

    // MARK: Run control

    private func requireConnected() throws {
        guard model.connection.isConnected else {
            let i = connectionInfo
            let detail = (i["error"] ?? i["note"]).map { ": \($0)" } ?? ""
            throw ToolError("The scope is not connected (\(i["state"] as? String ?? "?")\(detail)). Plug it in, or set_source demo to use the simulator.")
        }
    }

    private func runControl(_ a: [String: Any]) async throws -> [String: Any] {
        guard let action = string(a, "action")?.lowercased() else { throw ToolError("action is required") }
        switch action {
        case "run": model.setRunning(true)
        case "stop": model.setRunning(false)
        case "single":
            try requireConnected()
            model.single()
            return ["armed": true, "trigger": triggerInfo,
                    "next": "Cause the event, then call capture to wait for the trigger and read the result."]
        case "force_trigger":
            try requireConnected()
            model.forceTrigger()
        case "autoset":
            try requireConnected()
            let before = model.engineSettingsUpdates
            model.autoset()
            let deadline = Date().addingTimeInterval(20)
            while model.engineSettingsUpdates == before && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if model.engineSettingsUpdates == before { throw ToolError("Autoset didn't finish within 20 s") }
            _ = await freshFrames(1, timeout: 3)
            var out = status()
            out["autoset"] = "done"
            return out
        default: throw ToolError("action must be run, stop, single, force_trigger or autoset")
        }
        try? await Task.sleep(for: .milliseconds(100))
        return ["running": model.running, "sweep": model.settings.trigger.sweep.rawValue]
    }

    // MARK: Waiting for captures

    /// Captures that arrive within `timeout` and were taken entirely with the current settings
    /// (the first capture after a change is skipped: it may have started before it). A
    /// one-shot capture counts as soon as it arrives.
    private func freshFrames(_ count: Int, timeout: Double, accept: ((Frame) -> Bool)? = nil) async -> [Frame] {
        let (stream, end) = model.frames(timeout: timeout)
        defer { end() }
        var out: [Frame] = []
        for await f in stream {
            guard f.matchesSettings && ScopeModel.sameCapture(f.acquisition.settings, model.settings) else { continue }
            let single = f.raw.settings.trigger.sweep == .single
            guard single || f.matchingIndex >= 2 else { continue }
            if let accept, !accept(f) { continue }
            out.append(f)
            if out.count >= count { break }
        }
        return out
    }

    /// The latest capture as a Frame (for a stopped scope).
    private var heldFrame: Frame? {
        guard let acq = model.acquisition, let raw = model.rawAcquisition else { return nil }
        return Frame(acquisition: acq, raw: raw, analysis: model.analysis,
                     matchesSettings: ScopeModel.sameCapture(acq.settings, model.settings), matchingIndex: model.matchingFrames)
    }

    /// Time one capture takes to fill (at least a frame at the UI rate).
    private var recordSeconds: Double { max(1.0 / 60, model.settings.timebase.acquisitionWindow) }

    private var averaging: Bool { model.processing.mode == .average }

    private func averagedEnough(_ f: Frame) -> Bool {
        guard averaging else { return true }
        let n = f.acquisition.channels.compactMap { $0?.accumulated }.min() ?? 1
        return n >= model.processing.averages
    }

    // MARK: Measurements

    private struct TraceData {
        var name: String
        var unit: String
        var values: [Float]
        var t0: Double
        var dt: Double
        var clipped: Bool
        var perDiv: Double
    }

    private func traces(_ acq: Acquisition, analysisMath: DerivedWaveform?, only: [Trace]? = nil) -> [Trace: TraceData] {
        var out: [Trace: TraceData] = [:]
        for ch in 0..<2 {
            let t = Trace(rawValue: ch)!
            guard only?.contains(t) ?? model.settings.channels[ch].enabled, let w = acq.channel(ch) else { continue }
            out[t] = TraceData(name: t.name, unit: w.unit.symbol, values: w.volts, t0: w.t0, dt: w.dt,
                               clipped: w.clipped, perDiv: w.settings.unitsPerDivision)
        }
        if only?.contains(.math) ?? model.processing.math.enabled,
           let m = analysisMath ?? MathEngine.compute(model.processing.math, acq) {
            out[.math] = TraceData(name: "MATH", unit: m.unit, values: m.values, t0: m.t0, dt: m.dt,
                                   clipped: false, perDiv: model.processing.math.unitsPerDivision)
        }
        return out
    }

    /// Measurements of every trace in a capture, gated to a time window.
    private func measurements(_ f: Frame, gate: (Double, Double)?, only: [Trace]? = nil) -> (traces: [Trace: (TraceData, ChannelMeasurements)], cross: CrossMeasurements?) {
        var out: [Trace: (TraceData, ChannelMeasurements)] = [:]
        let acq = f.acquisition
        for ch in 0..<2 {
            let t = Trace(rawValue: ch)!
            guard only?.contains(t) ?? model.settings.channels[ch].enabled, var w = acq.channel(ch) else { continue }
            if let g = gate { w = Gating.apply(w, start: max(g.0, w.t0), end: min(g.1, w.time(at: w.count - 1))) }
            let d = TraceData(name: t.name, unit: w.unit.symbol, values: w.volts, t0: w.t0, dt: w.dt,
                              clipped: w.counts.contains { Int($0) >= VDS1022.adcMax || Int($0) <= VDS1022.adcMin }, perDiv: w.settings.unitsPerDivision)
            out[t] = (d, Measurements.compute(w))
        }
        if only?.contains(.math) ?? model.processing.math.enabled, var m = f.analysis.math ?? MathEngine.compute(model.processing.math, acq) {
            if let g = gate { m = Gating.apply(m, start: max(g.0, m.t0), end: min(g.1, m.time(at: m.count - 1))) }
            let finite = m.values.map { $0.isFinite ? $0 : 0 }
            let d = TraceData(name: "MATH", unit: m.unit, values: finite, t0: m.t0, dt: m.dt, clipped: false,
                              perDiv: model.processing.math.unitsPerDivision)
            out[.math] = (d, Measurements.compute(values: finite, dt: m.dt, resolution: model.processing.math.unitsPerDivision / 25))
        }
        var cross: CrossMeasurements?
        if var a = acq.channel(0), var b = acq.channel(1), only == nil || (only!.contains(.ch1) && only!.contains(.ch2)) {
            if let g = gate {
                a = Gating.apply(a, start: max(g.0, a.t0), end: min(g.1, a.time(at: a.count - 1)))
                b = Gating.apply(b, start: max(g.0, b.t0), end: min(g.1, b.time(at: b.count - 1)))
            }
            cross = Measurements.cross(a, b)
        }
        return (out, cross)
    }

    /// Warnings an agent should act on: clipping, too little vertical resolution.
    private func warnings(_ traces: [Trace: (TraceData, ChannelMeasurements)]) -> [String] {
        var out: [String] = []
        for t in Trace.allCases {
            guard let (d, m) = traces[t], t != .math else { continue }
            if d.clipped {
                out.append("\(d.name) is clipped (off the top or bottom of the screen): amplitude readings are wrong. Raise volts_per_div or move the offset.")
            } else if let pp = m[.pkpk], pp / d.perDiv < 1.0 {
                out.append(String(format: "%@ spans only %.2f divisions: lower volts_per_div for resolution (25 ADC counts per division)", d.name, pp / d.perDiv))
            }
        }
        return out
    }

    private func captureInfo(_ f: Frame) -> [String: Any] {
        let acq = f.acquisition, s = acq.settings
        var o: [String: Any] = [
            "age_s": n6(Date().timeIntervalSince(acq.timestamp), digits: 3),
            "trigger_state": acq.triggerState.rawValue,
            "sample_rate_hz": n6(s.timebase.sampleRate),
            "seconds_per_div": n6(s.timebase.secondsPerDivision),
        ]
        if let w = acq.channels.compactMap({ $0 }).first {
            o["record_start_s"] = n6(w.t0)
            o["record_end_s"] = n6(w.time(at: w.count - 1))
            if w.accumulated > 1 { o["averaged_captures"] = w.accumulated }
        }
        o["screen_start_s"] = n6(s.screenStart)
        o["screen_end_s"] = n6(s.screenStart + s.timebase.window)
        return o
    }

    private func measurementDict(_ d: TraceData, _ m: ChannelMeasurements, kinds: [MeasurementKind]) -> [String: Any] {
        var values: [String: Any] = [:], units: [String: Any] = [:]
        for k in kinds where k.group != .cross {
            let (u, scale) = Self.unit(k, trace: d.unit)
            values[Self.name(k)] = n6(m[k].map { $0 * scale })
            units[Self.name(k)] = u
        }
        return ["unit": d.unit, "clipped": d.clipped, "units_per_div": n6(d.perDiv), "values": values, "units": units]
    }

    private func capture(_ a: [String: Any]) async throws -> MCPToolResult {
        try requireConnected()
        let timeout = min(300, max(0.1, number(a, "timeout_s") ?? max(5, 3 * recordSeconds + 1)))
        let kinds = try measurementKinds(a)
        let g = gate(a)
        var note: String?
        var frame: Frame?

        if flag(a, "single") == true {
            model.single()
            frame = await freshFrames(1, timeout: timeout) { $0.raw.settings.trigger.sweep == .single }.first
            if frame == nil, flag(a, "force_on_timeout") == true {
                model.forceTrigger()
                frame = await freshFrames(1, timeout: 2) { $0.raw.settings.trigger.sweep == .single }.first
                note = "No trigger came in time: forced one"
            }
            if frame == nil {
                throw ToolError("No trigger within \(Format.number(timeout)) s; the scope is still armed (\(triggerSummary)). Call capture again to keep waiting, or run_control force_trigger.")
            }
        } else if !model.running {
            frame = heldFrame
            guard let f = frame else { throw ToolError("The scope is stopped and holds no capture: run_control run or single first") }
            note = "The scope is stopped: this is the capture it holds, taken \(Format.seconds(Date().timeIntervalSince(f.acquisition.timestamp))) ago"
            if !f.matchesSettings { note! += ", with settings that have changed since" }
        } else if model.settings.trigger.sweep == .single {
            frame = await freshFrames(1, timeout: timeout) { $0.raw.settings.trigger.sweep == .single }.first
            if frame == nil {
                throw ToolError("No trigger within \(Format.number(timeout)) s; the single shot is still armed (\(triggerSummary)). Call capture again to keep waiting, or run_control force_trigger.")
            }
        } else {
            frame = await freshFrames(1, timeout: timeout, accept: averagedEnough).first
            if frame == nil {
                if model.settings.trigger.sweep == .normal {
                    throw ToolError("No trigger within \(Format.number(timeout)) s in Normal sweep (\(triggerSummary)). Check the level, or use Auto sweep.")
                }
                throw ToolError("No new capture within \(Format.number(timeout)) s\(averaging ? " (Average mode waits for \(model.processing.averages) triggered captures)" : "")")
            }
        }
        let f = frame!
        let (traces, cross) = measurements(f, gate: g)
        var out: [String: Any] = ["capture": captureInfo(f)]
        var tr: [String: Any] = [:]
        for (t, (d, m)) in traces { tr[t.name] = measurementDict(d, m, kinds: kinds) }
        out["traces"] = tr
        if let c = cross, kinds.contains(.delay) || kinds.contains(.phase) {
            out["ch1_to_ch2"] = ["delay_s": n6(c.delay), "phase_deg": n6(c.phase, digits: 4)]
        }
        if let g { out["gate"] = ["start_s": n6(g.0), "end_s": n6(g.1)] }
        let w = warnings(traces)
        if !w.isEmpty { out["warnings"] = w }
        if let note { out["note"] = note }
        out["sweep_after"] = model.running ? model.settings.trigger.sweep.rawValue : "stopped"
        var result = json(out)
        if flag(a, "image") == true, let png = reportPNG(theme: .dark, statistics: false) { result = result.adding(image: png) }
        return result
    }

    private var triggerSummary: String {
        let t = model.settings.trigger
        let unit = t.source.channel.map { model.settings.channels[$0].unit.symbol } ?? "V"
        return "\(t.source.rawValue) \(t.mode == .pulse ? "pulse" : t.slope.rawValue.lowercased()) at \(Format.si(t.level, unit: unit))"
    }

    private func measure(_ a: [String: Any]) async throws -> [String: Any] {
        try requireConnected()
        guard model.running, model.settings.trigger.sweep != .single else {
            throw ToolError("The scope is \(model.running ? "armed for a single shot" : "stopped"): call run_control run first (capture reads a held capture)")
        }
        let n = Int(min(1000, max(1, number(a, "captures") ?? 10)))
        let timeout = min(600, max(0.5, number(a, "timeout_s") ?? max(30, Double(n + 2) * recordSeconds * 1.5 + 5)))
        let kinds = try measurementKinds(a)
        let only = try traceList(a)
        let g = gate(a)
        let start = Date()
        var samples: [Trace: [MeasurementKind: [Double]]] = [:]
        var meta: [Trace: TraceData] = [:]
        var crossDelay: [Double] = [], crossPhase: [Double] = []
        var clippedCaptures: [Trace: Int] = [:]
        var lastTraces: [Trace: (TraceData, ChannelMeasurements)] = [:]
        var triggered = 0
        let (frames, end) = model.frames(timeout: timeout)
        defer { end() }
        var got = 0
        for await f in frames {
            guard f.matchesSettings, ScopeModel.sameCapture(f.acquisition.settings, model.settings), f.matchingIndex >= 2,
                  averagedEnough(f) else { continue }
            let (traces, cross) = measurements(f, gate: g, only: only)
            lastTraces = traces
            if f.acquisition.triggerState == .triggered { triggered += 1 }
            for (t, (d, m)) in traces {
                meta[t] = d
                if d.clipped { clippedCaptures[t, default: 0] += 1 }
                for k in kinds where k.group != .cross { if let v = m[k], v.isFinite { samples[t, default: [:]][k, default: []].append(v) } }
            }
            if let c = cross {
                if let d = c.delay, d.isFinite { crossDelay.append(d) }
                if let p = c.phase, p.isFinite { crossPhase.append(p) }
            }
            got += 1
            if got >= n { break }
        }
        guard got > 0 else { throw ToolError("No fresh capture within \(Format.number(timeout)) s\(model.settings.trigger.sweep == .normal ? " (Normal sweep: is it triggering? \(triggerSummary))" : "")") }

        func stats(_ xs: [Double], scale: Double = 1) -> [String: Any] {
            guard !xs.isEmpty else { return ["n": 0] }
            let v = xs.map { $0 * scale }
            let mean = v.reduce(0, +) / Double(v.count)
            let sd = v.count > 1 ? sqrt(v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count - 1)) : 0
            return ["mean": n6(mean), "min": n6(v.min()), "max": n6(v.max()), "std": n6(sd, digits: 3), "n": v.count]
        }
        var tr: [String: Any] = [:]
        for (t, d) in meta {
            var st: [String: Any] = [:], units: [String: Any] = [:]
            for k in kinds where k.group != .cross {
                let (u, scale) = Self.unit(k, trace: d.unit)
                st[Self.name(k)] = stats(samples[t]?[k] ?? [], scale: scale)
                units[Self.name(k)] = u
            }
            var o: [String: Any] = ["unit": d.unit, "units_per_div": n6(d.perDiv), "statistics": st, "units": units]
            if let c = clippedCaptures[t] { o["clipped_captures"] = c }
            tr[t.name] = o
        }
        var out: [String: Any] = ["captures": got, "triggered_captures": triggered,
                                  "elapsed_s": n6(Date().timeIntervalSince(start), digits: 3),
                                  "sample_rate_hz": n6(model.settings.timebase.sampleRate),
                                  "traces": tr]
        if kinds.contains(.delay) || kinds.contains(.phase), !crossDelay.isEmpty || !crossPhase.isEmpty {
            out["ch1_to_ch2"] = ["delay_s": stats(crossDelay), "phase_deg": stats(crossPhase)]
        }
        if let g { out["gate"] = ["start_s": n6(g.0), "end_s": n6(g.1)] }
        if got < n { out["note"] = "Timed out after \(got) of \(n) captures" }
        let w = warnings(lastTraces)
        if !w.isEmpty { out["warnings"] = w }
        return out
    }

    // MARK: Waveform data

    private func waveform(_ a: [String: Any]) async throws -> [String: Any] {
        var f = heldFrame
        if flag(a, "fresh") == true {
            try requireConnected()
            guard model.running else { throw ToolError("The scope is stopped: there is no new capture to wait for") }
            f = await freshFrames(1, timeout: max(10, 3 * recordSeconds + 1)) { [unowned self] in self.averagedEnough($0) }.first
            if f == nil { throw ToolError("No new capture in time") }
        }
        guard let f else { throw ToolError("No capture yet") }
        let only = try traceList(a)
        let td = traces(f.acquisition, analysisMath: f.analysis.math, only: only)
        let order = Trace.allCases.filter { td[$0] != nil }
        guard !order.isEmpty else { throw ToolError("None of those traces is in the capture") }
        let screen = screenRange
        let start = number(a, "start_s") ?? screen.0, end = number(a, "end_s") ?? screen.1
        guard end > start else { throw ToolError("end_s must be after start_s") }
        let maxPoints = Int(min(5000, max(2, number(a, "max_points") ?? 500)))
        let mode = string(a, "decimation")?.lowercased() ?? "minmax"
        guard ["minmax", "mean", "sample"].contains(mode) else { throw ToolError("decimation must be minmax, mean or sample") }

        func range(_ d: TraceData) -> Range<Int> {
            let i = max(0, Int(((start - d.t0) / d.dt).rounded(.up)))
            let j = min(d.values.count, Int(((end - d.t0) / d.dt).rounded(.down)) + 1)
            return i..<max(i, j)
        }
        var info: [String: Any] = [:]
        for t in order {
            let d = td[t]!
            info[d.name] = ["unit": d.unit, "dt_s": n6(d.dt), "samples_in_window": range(d).count, "clipped": d.clipped]
        }

        // Full-resolution CSV of the window.
        var csvFile: String?
        if let p = string(a, "csv_path") {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let ref = td[order[0]]!
            var text = "time_s," + order.map { "\(td[$0]!.name)_\(td[$0]!.unit)" }.joined(separator: ",") + "\n"
            for i in range(ref) {
                let t = ref.t0 + Double(i) * ref.dt
                text += String(format: "%.10g", t)
                for tr in order {
                    let d = td[tr]!
                    let k = Int(((t - d.t0) / d.dt).rounded())
                    text += k >= 0 && k < d.values.count ? String(format: ",%.6g", d.values[k]) : ","
                }
                text += "\n"
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            csvFile = url.path
        }

        let ref = td[order[0]]!
        let refRange = range(ref)
        var columns = ["t_s"]
        var rows: [[Any]] = []
        var decimationText = "none"
        if refRange.count < maxPoints / 4 && flag(a, "interpolate") == true {
            let pts = maxPoints
            let series = order.map { t -> [Float] in
                let d = td[t]!
                return Interpolator.sinc(values: d.values, t0: d.t0, dt: d.dt, from: start, to: end, points: pts)
            }
            columns += order.map { td[$0]!.name }
            for i in 0..<pts {
                var r: [Any] = [n6(start + (end - start) * Double(i) / Double(pts - 1))]
                for s in series { r.append(n6(Double(s[i]), digits: 5)) }
                rows.append(r)
            }
            decimationText = "sin(x)/x interpolated from \(refRange.count) samples"
        } else {
            let perRow = max(1, Int((Double(refRange.count) / Double(mode == "minmax" ? maxPoints : maxPoints)).rounded(.up)))
            let minmax = mode == "minmax" && perRow > 1
            for t in order { columns += minmax ? ["\(td[t]!.name)_min", "\(td[t]!.name)_max"] : [td[t]!.name] }
            var i = refRange.lowerBound
            while i < refRange.upperBound {
                let j = min(refRange.upperBound, i + perRow)
                let t0 = ref.t0 + Double(i) * ref.dt, t1 = ref.t0 + Double(j) * ref.dt
                var r: [Any] = [n6(mode == "sample" ? t0 : (t0 + t1 - ref.dt) / 2)]
                for t in order {
                    let d = td[t]!
                    let a = max(0, Int(((t0 - d.t0) / d.dt).rounded())), b = min(d.values.count, max(a + 1, Int(((t1 - d.t0) / d.dt).rounded())))
                    guard a < d.values.count else { r += minmax ? [NSNull(), NSNull()] : [NSNull()]; continue }
                    let s = d.values[a..<b]
                    if minmax {
                        r += [n6(Double(s.min()!), digits: 5), n6(Double(s.max()!), digits: 5)]
                    } else if mode == "mean" {
                        r.append(n6(Double(s.reduce(0, +)) / Double(s.count), digits: 5))
                    } else {
                        r.append(n6(Double(s.first!), digits: 5))
                    }
                }
                rows.append(r)
                i = j
            }
            decimationText = perRow == 1 ? "none" : "\(mode) of \(perRow) samples per row"
        }
        var out: [String: Any] = ["capture": captureInfo(f), "traces": info, "window": ["start_s": n6(start), "end_s": n6(end)],
                                  "decimation": decimationText, "columns": columns, "rows": rows]
        if refRange.count < maxPoints / 4 && flag(a, "interpolate") != true {
            out["note"] = "Only \(refRange.count) samples in the window: pass interpolate=true for a smooth curve, or widen the window"
        }
        if let csvFile { out["csv_file"] = csvFile }
        return out
    }

    // MARK: Spectrum

    private func spectrum(_ a: [String: Any]) async throws -> [String: Any] {
        let ch = try channel(a, "channel") ?? 0
        var f = heldFrame
        if flag(a, "fresh") == true, model.running {
            f = await freshFrames(1, timeout: 10).first ?? f
        }
        guard let w = f?.acquisition.channel(ch) else { throw ToolError("No capture of CH\(ch + 1)") }
        let window = try choice(a, "window", FFTWindow.self) ?? .hann
        guard let sp = SpectrumAnalyzer.compute(w, window: window) else { throw ToolError("Too few samples for an FFT") }
        let minHz = number(a, "min_hz") ?? 0
        let count = Int(min(100, max(1, number(a, "peaks") ?? 10)))
        let db = sp.dbv
        let floor = db.dropFirst(2).sorted()[max(0, db.count - 2) / 2]
        var cands: [Int] = []
        // Peaks at least 10 dB above the median noise floor.
        for i in 2..<max(2, db.count - 1) where db[i] >= db[i - 1] && db[i] > db[i + 1]
            && Double(i) * sp.binWidth >= minHz && db[i] > floor + 10 {
            cands.append(i)
        }
        cands.sort { db[$0] > db[$1] }
        var picked: [Int] = []
        for i in cands where !picked.contains(where: { abs($0 - i) < 4 }) {
            picked.append(i)
            if picked.count >= count { break }
        }
        let unit = w.unit.symbol
        let peaks: [[String: Any]] = picked.map { i in
            // Parabolic interpolation of the peak bin for a better frequency estimate.
            let y0 = Double(db[i - 1]), y1 = Double(db[i]), y2 = Double(db[i + 1])
            let den = y0 - 2 * y1 + y2
            let off = den != 0 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) : 0
            return ["frequency_hz": n6((Double(i) + off) * sp.binWidth), "dbv": n6(y1, digits: 4),
                    "rms": n6(pow(10, y1 / 20)), "rms_unit": unit]
        }
        return ["channel": "CH\(ch + 1)", "window": window.rawValue, "bin_width_hz": n6(sp.binWidth),
                "nyquist_hz": n6(sp.maxFrequency), "median_floor_dbv": n6(Double(floor), digits: 4),
                "peaks": peaks, "capture": f.map(captureInfo) ?? NSNull()]
    }

    // MARK: Decoders

    private func configureDecoder(_ a: [String: Any]) throws -> [String: Any] {
        guard let action = string(a, "action")?.lowercased() else { throw ToolError("action is required") }
        switch action {
        case "list": break
        case "clear": model.decoders = []
        case "remove":
            guard let s = string(a, "id"), let id = UUID(uuidString: s), model.decoders.contains(where: { $0.id == id }) else {
                throw ToolError("remove needs the id of a decoder (see action=list)")
            }
            model.removeDecoder(id)
        case "add":
            let threshold: Threshold = number(a, "threshold_v").map { $0 == 0 ? .auto : .volts($0) } ?? .auto
            let format = try choice(a, "format", DataFormat.self)
            guard let id = string(a, "protocol"), var kind = DecoderKind.defaults(for: id) else {
                throw ToolError("add needs protocol: \(DecoderKind.allProtocolIDs.joined(separator: ", "))")
            }
            func pair(_ a1: String, _ b1: String, _ x: inout Int, _ y: inout Int) throws {
                x = try channel(a, a1) ?? x
                y = try channel(a, b1) ?? y
                guard x != y else { throw ToolError("\(a1) and \(b1) must be different channels") }
            }
            switch kind {
            case .uart(var c):
                c.channel = try channel(a, "channel") ?? c.channel
                c.baud = number(a, "baud") ?? c.baud
                c.dataBits = Int(number(a, "data_bits") ?? Double(c.dataBits))
                if let p = try choice(a, "parity", UARTConfig.Parity.self) { c.parity = p }
                c.stopBits = number(a, "stop_bits") ?? c.stopBits
                c.invert = flag(a, "invert") ?? c.invert
                c.msbFirst = flag(a, "msb_first") ?? c.msbFirst
                c.threshold = threshold
                if let format { c.format = format }
                kind = .uart(c)
            case .i2c(var c):
                try pair("scl", "sda", &c.scl, &c.sda)
                c.threshold = threshold
                if let format { c.format = format }
                kind = .i2c(c)
            case .spi(var c):
                try pair("sck", "data", &c.sck, &c.data)
                c.mode = Int(number(a, "spi_mode") ?? Double(c.mode))
                if let b = number(a, "bits_per_word") { c.bitsPerWord = b > 8 ? 16 : 8 }
                c.msbFirst = flag(a, "msb_first") ?? c.msbFirst
                c.threshold = threshold
                if let format { c.format = format }
                kind = .spi(c)
            case .can(var c):
                c.channel = try channel(a, "channel") ?? c.channel
                c.bitrate = number(a, "bitrate") ?? c.bitrate
                c.samplePoint = number(a, "sample_point") ?? c.samplePoint
                if let v = try choice(a, "signal", CANConfig.Signal.self) { c.signal = v }
                c.threshold = threshold
                if let format { c.format = format }
                kind = .can(c)
            case .lin(var c):
                c.channel = try channel(a, "channel") ?? c.channel
                c.baud = number(a, "baud") ?? c.baud
                if let v = try choice(a, "checksum", LINConfig.Checksum.self) { c.checksum = v }
                c.invert = flag(a, "invert") ?? c.invert
                c.threshold = threshold
                if let format { c.format = format }
                kind = .lin(c)
            case .usb(var c):
                try pair("d_plus", "d_minus", &c.dPlus, &c.dMinus)
                if let v = try choice(a, "speed", USBConfig.Speed.self) { c.speed = v }
                c.threshold = threshold
                if let format { c.format = format }
                kind = .usb(c)
            case .oneWire(var c):
                c.channel = try channel(a, "channel") ?? c.channel
                if let v = try choice(a, "speed", OneWireConfig.Speed.self) { c.speed = v }
                c.threshold = threshold
                if let format { c.format = format }
                kind = .oneWire(c)
            }
            model.addDecoder(kind)
            var out = decoderInfo(model.decoders.last!)
            out["next"] = "Read the decoded events with get_decoded"
            return out
        default: throw ToolError("action must be add, remove, clear or list")
        }
        return ["decoders": model.decoders.map(decoderInfo)]
    }

    private func decoded(_ a: [String: Any]) async throws -> [String: Any] {
        let enabled = model.decoders.filter(\.enabled)
        guard !enabled.isEmpty else { throw ToolError("No decoders: add one with configure_decoder") }
        let maxEvents = Int(min(5000, max(1, number(a, "max_events") ?? 200)))
        var f = heldFrame
        if flag(a, "fresh") ?? model.running, model.running {
            let ids = Set(enabled.map(\.id))
            f = await freshFrames(1, timeout: 10) { ids.isSubset(of: Set($0.analysis.decodes.keys)) }.first ?? f
        }
        guard let f else { throw ToolError("No capture yet") }
        var list: [[String: Any]] = []
        for d in enabled {
            var o = decoderInfo(d)
            guard let r = f.analysis.decodes[d.id] else {
                o["note"] = "Not decoded yet: the capture came before the decoder was added"
                list.append(o)
                continue
            }
            o["summary"] = r.summary
            o["event_count"] = r.events.count
            let clipped = d.kind.channels.filter { f.raw.channel($0)?.clipped == true }.map { "CH\($0 + 1)" }
            if !clipped.isEmpty {
                o["warning"] = "\(clipped.joined(separator: " and ")) clipped: the signal runs off screen, so its levels may not decode. Raise volts_per_div or move the offset."
            }
            o["events"] = r.events.prefix(maxEvents).map { e -> [String: Any] in
                var x: [String: Any] = ["t_s": n6(e.start, digits: 7), "end_s": n6(e.end, digits: 7), "kind": e.kind.rawValue, "label": e.label]
                if let v = e.value { x["value"] = v }
                return x
            }
            if r.events.count > maxEvents { o["truncated"] = true }
            if case .uart = d.kind {
                let bytes = r.events.filter { $0.kind == .data }.compactMap(\.value)
                o["text"] = String(decoding: bytes.map { UInt8(truncatingIfNeeded: $0) }, as: UTF8.self)
            }
            list.append(o)
        }
        return ["capture": captureInfo(f), "decoders": list]
    }

    // MARK: Report

    private func reportPNG(theme: ExportTheme, statistics: Bool) -> Data? {
        var o = ExportOptions()
        o.format = .png
        o.theme = theme
        o.includeStatistics = statistics
        return CGVectorRenderer.png(ReportBuilder.build(model, options: o), scale: 1)
    }

    private func exportReport(_ a: [String: Any]) throws -> MCPToolResult {
        guard model.acquisition != nil else { throw ToolError("No capture to report yet") }
        var o = ExportOptions()
        o.format = try choice(a, "format", ExportFormat.self) ?? .svg
        o.theme = string(a, "theme")?.lowercased() == "dark" ? .dark : .light
        o.includeStatistics = flag(a, "statistics") ?? true
        let url: URL
        if let p = string(a, "path") {
            url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OwonScope")
            url = docs.appendingPathComponent(ReportExporter.suggestedName).appendingPathExtension(o.format.rawValue.lowercased())
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReportExporter.write(model, to: url, options: o)
        var result = json(["file": url.path, "format": o.format.rawValue])
        if flag(a, "return_image") == true, let png = reportPNG(theme: o.theme, statistics: o.includeStatistics) {
            result = result.adding(image: png)
        }
        return result
    }

    // MARK: Source

    private func setSource(_ a: [String: Any]) async throws -> [String: Any] {
        switch string(a, "source")?.lowercased() {
        case "hardware":
            model.source = .hardware
        case "demo":
            let want = string(a, "scenario")?.lowercased() ?? "reference"
            guard let s = SimulatorScenario.allCases.first(where: { scenarioID($0) == want }) else {
                throw ToolError("scenario must be one of \(SimulatorScenario.allCases.map(scenarioID).joined(separator: ", "))")
            }
            model.source = .demo(s)
        default: throw ToolError("source must be hardware or demo")
        }
        // Wait until the connection reflects the new source (the old one's state lingers briefly).
        let wantSimulated = model.source != .hardware
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .connected(let i) = model.connection, i.isSimulated == wantSimulated { break }
            if !wantSimulated, case .failed = model.connection { break }
            if !wantSimulated, model.connection == .searching { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ["source": sourceText, "connection": connectionInfo]
    }
}

/// A simulator scenario's MCP name: "reference", "i2c", "can", "onewire"...
func scenarioID(_ s: SimulatorScenario) -> String { "\(s)".lowercased() }
#endif
