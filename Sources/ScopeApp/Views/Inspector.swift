import ScopeKit
import SwiftUI

struct InspectorSection<Content: View, Trailing: View>: View {
    var title: String
    var color: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(color)
                Spacer()
                trailing()
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(color == .secondary ? 0.12 : 0.35), lineWidth: 1))
    }
}

extension InspectorSection where Trailing == EmptyView {
    init(title: String, color: Color = .secondary, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, color: color, trailing: { EmptyView() }, content: content)
    }
}

/// "−  value  +" control.
struct ValueStepper: View {
    var label: String
    var value: String
    var minus: () -> Void
    var plus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: InspectorMetrics.labelWidth, alignment: .leading)
            Button(action: minus) { Image(systemName: "minus") }.buttonStyle(StepButtonStyle())
                .accessibilityLabel("\(label) down")
            Text(value)
                .font(.system(size: Platform.isTouch ? 15 : 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("\(label) value")
            Button(action: plus) { Image(systemName: "plus") }.buttonStyle(StepButtonStyle())
                .accessibilityLabel("\(label) up")
        }
    }
}

struct StepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Platform.isTouch ? 15 : 11, weight: .bold))
            .frame(width: Platform.isTouch ? 44 : 24, height: Platform.isTouch ? 36 : 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.25 : 0.1)))
            .contentShape(Rectangle())
    }
}

enum InspectorMetrics {
    static let labelWidth: CGFloat = Platform.isTouch ? 66 : 52
}

struct LabeledRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: InspectorMetrics.labelWidth, alignment: .leading)
            content()
        }
    }
}

struct InspectorView: View {
    @Bindable var model: ScopeModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AcquireSection(model: model)
                AcquisitionSection(model: model)
                ChannelSection(model: model, channel: 0)
                ChannelSection(model: model, channel: 1)
                HorizontalSection(model: model)
                TriggerSection(model: model)
                MathSection(model: model)
                CursorSection(model: model)
                ReferenceSection(model: model)
                DecoderSection(model: model)
                DisplaySection(model: model)
            }
            .padding(10)
            .font(.system(size: 12))
            .controlSize(.small)
        }
    }
}

struct AcquireSection: View {
    var model: ScopeModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleRun) {
                Label(model.running ? "Stop" : "Run", systemImage: model.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.running ? .red : .green)
            .help("Run / Stop (⌘R)")

            Button(action: model.single) { Text("Single").frame(minHeight: 30) }
                .buttonStyle(.bordered).help("Single capture (⌘⇧R)")
            Button(action: model.autoset) { Text("Auto").frame(minHeight: 30) }
                .buttonStyle(.bordered).help("Autoset (⌘⇧A)")
            Button(action: model.forceTrigger) { Image(systemName: "bolt.fill").frame(minHeight: 30) }
                .buttonStyle(.bordered).help("Force trigger (⌘⇧F)")
        }
        .controlSize(.regular)
    }
}

struct ChannelSection: View {
    @Bindable var model: ScopeModel
    var channel: Int

    var body: some View {
        let color = Theme.channelColor(channel)
        let c = model.settings.channels[channel]
        InspectorSection(title: "Channel \(channel + 1)", color: color, trailing: {
            Toggle("", isOn: $model.settings.channels[channel].enabled)
                .toggleStyle(.switch).labelsHidden().tint(color)
        }) {
            if c.enabled {
                ValueStepper(label: "Scale", value: "\(Format.volts(c.voltsPerDivision))/div",
                             minus: { model.stepVoltage(channel: channel, -1) },
                             plus: { model.stepVoltage(channel: channel, 1) })
                LabeledRow(label: "Offset") {
                    Slider(value: $model.settings.channels[channel].offsetDivisions, in: -5...5)
                    Text(c.format(c.offsetDivisions * c.unitsPerDivision))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                        .onTapGesture(count: 2) { model.settings.channels[channel].offsetDivisions = 0 }
                        .help("Double-click to centre")
                }
                LabeledRow(label: "Coupling") {
                    Picker("", selection: $model.settings.channels[channel].coupling) {
                        ForEach(Coupling.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                LabeledRow(label: "Probe") {
                    Picker("", selection: Binding(get: { c.unit }, set: { model.setProbe(channel: channel, unit: $0) })) {
                        Text("Voltage").tag(SignalUnit.volts); Text("Current").tag(SignalUnit.amps)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                LabeledRow(label: c.unit == .volts ? "Atten." : "V/A") {
                    if c.unit == .volts {
                        Picker("", selection: $model.settings.channels[channel].probe) {
                            ForEach(ChannelSettings.voltageProbes, id: \.self) { Text("×" + Format.number($0)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    } else {
                        Picker("", selection: $model.settings.channels[channel].probe) {
                            ForEach(ChannelSettings.currentSensitivities, id: \.self) { sens in
                                Text(Format.si(sens, unit: "V/A")).tag(1 / sens)
                            }
                        }.labelsHidden()
                        .help("Current probe output per amp (check the probe's range switch)")
                    }
                }
            }
        }
        .onTapGesture { model.selectTrace(Trace(rawValue: channel)!) }
    }
}

struct HorizontalSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        let tb = model.settings.timebase
        InspectorSection(title: "Horizontal") {
            ValueStepper(label: "Time", value: tb.label, minus: { model.stepTimebase(-1) }, plus: { model.stepTimebase(1) })
            if !tb.isRollMode {
                LabeledRow(label: "Position") {
                    Slider(value: $model.settings.triggerPosition, in: 0...1)
                    Text(Format.seconds((0.5 - model.settings.triggerPosition) * tb.window))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                        .onTapGesture(count: 2) { model.settings.triggerPosition = 0.5 }
                        .help("Double-click to centre")
                }
            }
            HStack {
                Text(Format.si(tb.sampleRate, unit: "Sa/s"))
                Text("·").foregroundStyle(.tertiary)
                Text("5k pts")
                Text("·").foregroundStyle(.tertiary)
                Text(tb.isRollMode ? "Roll" : tb.isZoomed ? "Zoom (sin x/x)" : "Normal")
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

struct TriggerSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        let t = model.settings.trigger
        InspectorSection(title: "Trigger", color: Theme.triggerColor(t.source)) {
            LabeledRow(label: "Source") {
                Picker("", selection: $model.settings.trigger.source) {
                    ForEach(TriggerSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            LabeledRow(label: "Type") {
                Picker("", selection: $model.settings.trigger.mode) {
                    ForEach(TriggerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                .disabled(t.source == .ext)
            }
            if t.mode == .pulse && t.source != .ext {
                LabeledRow(label: "Polarity") {
                    Picker("", selection: $model.settings.trigger.slope) {
                        Text("+ pulse").tag(TriggerSlope.rising)
                        Text("− pulse").tag(TriggerSlope.falling)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                LabeledRow(label: "When") {
                    Picker("", selection: $model.settings.trigger.pulseCondition) {
                        Text("width >").tag(PulseCondition.greater)
                        Text("width <").tag(PulseCondition.less)
                        Text("width =").tag(PulseCondition.equal)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                ValueStepper(label: "Width", value: Format.seconds(t.pulseWidth),
                             minus: { stepWidth(-1) }, plus: { stepWidth(1) })
            } else {
                LabeledRow(label: "Slope") {
                    Picker("", selection: $model.settings.trigger.slope) {
                        Image(systemName: "arrow.up.forward").tag(TriggerSlope.rising)
                        Image(systemName: "arrow.down.forward").tag(TriggerSlope.falling)
                    }.pickerStyle(.segmented).labelsHidden()
                }
            }
            LabeledRow(label: "Sweep") {
                Picker("", selection: $model.settings.trigger.sweep) {
                    ForEach(SweepMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if let ch = t.source.channel {
                let c = model.settings.channels[ch]
                let lo = (-5 - c.offsetDivisions) * c.voltsPerDivision
                let hi = (5 - c.offsetDivisions) * c.voltsPerDivision
                LabeledRow(label: "Level") {
                    Slider(value: $model.settings.trigger.level, in: min(lo, t.level)...max(hi, t.level))
                    Text(c.format(t.level))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button("Set to 50 %", action: model.triggerFiftyPercent)
                        .help("Put the trigger level at the middle of the signal")
                }
            }
        }
    }
}

extension TriggerSection {
    /// 1-2-5 steps for the pulse width (20 ns ... 10 s).
    func stepWidth(_ d: Int) {
        let scales = Format.scales125.filter { $0 >= 20e-9 && $0 <= 10 }
        let i = scales.firstIndex { $0 >= model.settings.trigger.pulseWidth * 0.999 } ?? 0
        model.settings.trigger.pulseWidth = scales[max(0, min(scales.count - 1, i + d))]
    }
}

struct AcquisitionSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        InspectorSection(title: "Acquisition") {
            Picker("", selection: Binding(get: { model.acquireMode }, set: { model.acquireMode = $0 })) {
                ForEach(AcquireMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .help("Normal · Peak detect (hardware min/max) · Average of N triggered captures · Envelope (min/max over captures)")
            switch model.acquireMode {
            case .average:
                LabeledRow(label: "Average") {
                    Picker("", selection: $model.processing.averages) {
                        ForEach(ProcessingSettings.averageCounts, id: \.self) { Text("\($0)").tag($0) }
                    }.labelsHidden()
                    Toggle("Show raw", isOn: $model.display.showRawUnderAverage).checkboxToggle()
                }
            case .envelope:
                Text("Min/max of every triggered capture since the last reset.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .peak:
                Text("Hardware min/max sampling: catches narrow glitches at slow timebases.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .normal:
                EmptyView()
            }
            if model.acquireMode == .average || model.acquireMode == .envelope {
                HStack {
                    Text("Only triggered captures are combined.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset", action: model.resetAccumulation)
                }
            }
        }
    }
}

struct MathSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        let m = model.processing.math
        InspectorSection(title: "Math", color: m.enabled ? Theme.math : .secondary, trailing: {
            Toggle("", isOn: $model.processing.math.enabled)
                .toggleStyle(.switch).labelsHidden().tint(Theme.math)
                .onChange(of: model.processing.math.enabled) { _, on in
                    if on { model.selectTrace(.math); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.mathAutoScale() } }
                }
        }) {
            if m.enabled {
                LabeledRow(label: "Function") {
                    Picker("", selection: $model.processing.math.operation) {
                        ForEach(MathOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                }
                LabeledRow(label: "A") {
                    Picker("", selection: $model.processing.math.sourceA) { Text("CH1").tag(0); Text("CH2").tag(1) }
                        .pickerStyle(.segmented).labelsHidden()
                }
                if m.operation.usesB {
                    LabeledRow(label: "B") {
                        Picker("", selection: $model.processing.math.sourceB) { Text("CH1").tag(0); Text("CH2").tag(1) }
                            .pickerStyle(.segmented).labelsHidden()
                    }
                }
                let unit = model.analysis.math?.unit ?? ""
                ValueStepper(label: "Scale", value: Format.si(m.unitsPerDivision, unit: unit) + "/div",
                             minus: { model.processing.math.scaleIndex = max(0, m.scaleIndex - 1) },
                             plus: { model.processing.math.scaleIndex = min(Format.scales125.count - 1, m.scaleIndex + 1) })
                LabeledRow(label: "Offset") {
                    Slider(value: $model.processing.math.offsetDivisions, in: -5...5)
                    Button("Auto", action: model.mathAutoScale).help("Fit the math trace on screen")
                }
                if model.analysis.math == nil {
                    Text("Enable the source channel(s) to compute \(m.label).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if unit == "W" {
                    Text("Instantaneous power. Mean = average power.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct CursorSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        InspectorSection(title: "Cursors & Measure") {
            LabeledRow(label: "Cursors") {
                Picker("", selection: $model.display.cursorMode) {
                    ForEach(CursorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if model.display.cursorMode.showsAmplitude {
                Text("Amplitude cursors follow the selected trace (\(model.selectedTrace.name)). Click a trace or its label to select it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LabeledRow(label: "Measure") {
                Picker("", selection: $model.processing.gate) {
                    ForEach(MeasureGate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                .help("Measure over the whole record, the visible screen, or between the time cursors")
            }
        }
    }
}

struct ReferenceSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        InspectorSection(title: "References") {
            ForEach(0..<2, id: \.self) { slot in
                HStack(spacing: 8) {
                    Circle().fill(Theme.ref[slot]).frame(width: 8, height: 8)
                    Text("R\(slot + 1)").font(.system(size: 12, weight: .semibold))
                    if let r = model.references[slot] {
                        Text(r.waveform.label).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.references[slot]?.visible ?? false },
                                                 set: { model.references[slot]?.visible = $0 }))
                            .checkboxToggle().labelsHidden().help("Show R\(slot + 1)")
                        Button { model.clearReference(slot: slot) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Clear R\(slot + 1)")
                    } else {
                        Text("empty").foregroundStyle(.tertiary)
                        Spacer()
                    }
                    Menu("Save") {
                        ForEach(Trace.allCases, id: \.self) { t in
                            Button(t.name) { model.saveReference(slot: slot, from: t) }.disabled(!model.isVisible(t))
                        }
                    }
                    .fixedSize()
                    .help("Store the current trace as R\(slot + 1)")
                }
            }
        }
    }
}

struct DisplaySection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        InspectorSection(title: "Display") {
            LabeledRow(label: "Persist") {
                Picker("", selection: $model.display.persistence) {
                    ForEach(Persistence.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            LabeledRow(label: "Trace") {
                Slider(value: $model.display.traceWidth, in: 0.8...4)
            }
            LabeledRow(label: "Format") {
                Picker("", selection: $model.display.format) {
                    Text("YT").tag(DisplayFormat.yt); Text("XY (CH1→X, CH2→Y)").tag(DisplayFormat.xy)
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Spacer()
                Button("Clear Display", action: model.resetAccumulation)
            }
        }
    }
}

struct DecoderSection: View {
    @Bindable var model: ScopeModel

    var body: some View {
        InspectorSection(title: "Protocol Decoders", trailing: {
            Menu {
                Button("UART / RS-232") { model.addDecoder(.uart(UARTConfig())) }
                Button("I²C") { model.addDecoder(.i2c(I2CConfig())) }
                Button("SPI") { model.addDecoder(.spi(SPIConfig())) }
                Divider()
                Button("CAN") { model.addDecoder(.can(CANConfig())) }
                Button("LIN") { model.addDecoder(.lin(LINConfig())) }
                Button("USB 1.x (low / full speed)") { model.addDecoder(.usb(USBConfig())) }
                Button("1-Wire") { model.addDecoder(.oneWire(OneWireConfig())) }
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: Platform.isTouch ? 24 : 13)).accessibilityLabel("Add decoder")
            }
            .borderlessMenu()
            .menuIndicator(.hidden)
            .fixedSize()
        }) {
            if model.decoders.isEmpty {
                Text("Add a decoder to turn CH1/CH2 into UART, I²C, SPI, CAN, LIN, USB or 1-Wire data.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(model.decoders.enumerated()), id: \.element.id) { index, d in
                DecoderEditor(model: model, id: d.id, color: Theme.decoderPalette[index % Theme.decoderPalette.count])
                if index < model.decoders.count - 1 { Divider() }
            }
        }
    }
}

struct DecoderEditor: View {
    @Bindable var model: ScopeModel
    var id: UUID
    var color: Color

    /// Looked up by id on every access: the row may outlive its decoder during removal.
    private var index: Int? { model.decoders.firstIndex { $0.id == id } }

    var body: some View {
        if let i = index { editor(model.decoders[i]) }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { index.map { model.decoders[$0].enabled } ?? false },
                set: { v in if let i = index { model.decoders[i].enabled = v } })
    }

    @ViewBuilder private func editor(_ decoder: DecoderInstance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(decoder.kind.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
                Button { model.removeDecoder(decoder.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            switch decoder.kind {
            case .uart: uartEditor
            case .i2c: i2cEditor
            case .spi: spiEditor
            case .can: canEditor
            case .lin: linEditor
            case .usb: usbEditor
            case .oneWire: oneWireEditor
            }
            if let r = model.analysis.decodes[decoder.id] {
                Text(r.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func binding<T>(_ get: @escaping (DecoderKind) -> T?, _ set: @escaping (T) -> DecoderKind, default def: T) -> Binding<T> {
        Binding(get: { index.flatMap { get(model.decoders[$0].kind) } ?? def },
                set: { v in if let i = index { model.decoders[i].kind = set(v) } })
    }

    private var uart: Binding<UARTConfig> {
        binding({ if case .uart(let c) = $0 { c } else { nil } }, { .uart($0) }, default: UARTConfig())
    }
    private var i2c: Binding<I2CConfig> {
        binding({ if case .i2c(let c) = $0 { c } else { nil } }, { .i2c($0) }, default: I2CConfig())
    }
    private var spi: Binding<SPIConfig> {
        binding({ if case .spi(let c) = $0 { c } else { nil } }, { .spi($0) }, default: SPIConfig())
    }
    private var can: Binding<CANConfig> {
        binding({ if case .can(let c) = $0 { c } else { nil } }, { .can($0) }, default: CANConfig())
    }
    private var lin: Binding<LINConfig> {
        binding({ if case .lin(let c) = $0 { c } else { nil } }, { .lin($0) }, default: LINConfig())
    }
    private var usb: Binding<USBConfig> {
        binding({ if case .usb(let c) = $0 { c } else { nil } }, { .usb($0) }, default: USBConfig())
    }
    private var oneWire: Binding<OneWireConfig> {
        binding({ if case .oneWire(let c) = $0 { c } else { nil } }, { .oneWire($0) }, default: OneWireConfig())
    }

    private static func rateLabel(_ r: Double) -> String {
        r >= 1e6 ? String(format: "%gM", r / 1e6) : r >= 1e3 ? String(format: "%gk", (r / 10).rounded() / 100) : "\(Int(r))"
    }

    private func channelPicker(_ label: String, _ b: Binding<Int>) -> some View {
        LabeledRow(label: label) {
            Picker("", selection: b) { Text("CH1").tag(0); Text("CH2").tag(1) }
                .pickerStyle(.segmented).labelsHidden()
        }
    }

    private func formatPicker(_ b: Binding<DataFormat>) -> some View {
        LabeledRow(label: "Format") {
            Picker("", selection: b) { ForEach(DataFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
    }

    @ViewBuilder private var uartEditor: some View {
        channelPicker("Input", uart.channel)
        LabeledRow(label: "Baud") {
            Picker("", selection: uart.baud) {
                Text("Auto").tag(0.0)
                ForEach(UARTConfig.standardBauds, id: \.self) { Text("\(Int($0))").tag($0) }
            }.labelsHidden()
        }
        LabeledRow(label: "Frame") {
            Picker("", selection: uart.dataBits) { ForEach(5...9, id: \.self) { Text("\($0)").tag($0) } }
                .labelsHidden().frame(width: 52)
            Picker("", selection: uart.parity) {
                ForEach(UARTConfig.Parity.allCases, id: \.self) { Text(String($0.rawValue.prefix(1))).tag($0) }
            }.labelsHidden().frame(width: 52)
            Picker("", selection: uart.stopBits) { Text("1").tag(1.0); Text("1.5").tag(1.5); Text("2").tag(2.0) }
                .labelsHidden().frame(width: 52)
        }
        formatPicker(uart.format)
        HStack {
            Toggle("Inverted (RS-232)", isOn: uart.invert)
            Toggle("MSB first", isOn: uart.msbFirst)
        }.checkboxToggle()
    }

    @ViewBuilder private var i2cEditor: some View {
        channelPicker("SCL", i2c.scl)
        channelPicker("SDA", i2c.sda)
        formatPicker(i2c.format)
    }

    @ViewBuilder private var spiEditor: some View {
        channelPicker("SCK", spi.sck)
        channelPicker("Data", spi.data)
        LabeledRow(label: "Mode") {
            Picker("", selection: spi.mode) { ForEach(0..<4, id: \.self) { Text("\($0)").tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
        LabeledRow(label: "Word") {
            Picker("", selection: spi.bitsPerWord) { Text("8").tag(8); Text("16").tag(16) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 80)
            Toggle("MSB first", isOn: spi.msbFirst).checkboxToggle()
        }
        formatPicker(spi.format)
    }

    @ViewBuilder private var canEditor: some View {
        channelPicker("Input", can.channel)
        LabeledRow(label: "Signal") {
            Picker("", selection: can.signal) { ForEach(CANConfig.Signal.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .labelsHidden()
        }
        LabeledRow(label: "Bit rate") {
            Picker("", selection: can.bitrate) {
                Text("Auto").tag(0.0)
                ForEach(CANConfig.standardBitrates, id: \.self) { Text(Self.rateLabel($0) + "bit/s").tag($0) }
            }.labelsHidden()
        }
        LabeledRow(label: "Sample pt") {
            Picker("", selection: can.samplePoint) {
                ForEach([0.5, 0.625, 0.75, 0.8, 0.875], id: \.self) { Text(String(format: "%g %%", $0 * 100)).tag($0) }
            }.labelsHidden()
        }
        formatPicker(can.format)
    }

    @ViewBuilder private var linEditor: some View {
        channelPicker("Input", lin.channel)
        LabeledRow(label: "Baud") {
            Picker("", selection: lin.baud) {
                Text("From sync").tag(0.0)
                ForEach(LINConfig.standardBauds, id: \.self) { Text("\(Int($0))").tag($0) }
            }.labelsHidden()
        }
        LabeledRow(label: "Checksum") {
            Picker("", selection: lin.checksum) { ForEach(LINConfig.Checksum.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
        formatPicker(lin.format)
        Toggle("Inverted", isOn: lin.invert).checkboxToggle()
    }

    @ViewBuilder private var usbEditor: some View {
        channelPicker("D+", usb.dPlus)
        channelPicker("D−", usb.dMinus)
        LabeledRow(label: "Speed") {
            Picker("", selection: usb.speed) { ForEach(USBConfig.Speed.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
        formatPicker(usb.format)
    }

    @ViewBuilder private var oneWireEditor: some View {
        channelPicker("Input", oneWire.channel)
        LabeledRow(label: "Speed") {
            Picker("", selection: oneWire.speed) { ForEach(OneWireConfig.Speed.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
        }
        formatPicker(oneWire.format)
    }
}
