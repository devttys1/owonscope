#if os(macOS)
import AppKit
import ScopeKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: ScopeModel
    @State private var showInspector = true

    var body: some View {
        // A plain split view rather than .inspector: the inspector column extends under the
        // toolbar and its drawn position and hit-test position disagreed by the toolbar
        // height, so clicks missed the controls.
        HSplitView {
            VSplitView {
                VStack(spacing: 0) {
                    ScopeDisplay(model: model)
                        .frame(minHeight: 280)
                    Divider()
                    MeasurementsBar(model: model)
                }
                .layoutPriority(1)
                BottomPanel(model: model)
                    .frame(minHeight: 120, idealHeight: 200)
            }
            .frame(minWidth: 600)
            .layoutPriority(1)
            if showInspector {
                InspectorView(model: model)
                    .frame(minWidth: 290, idealWidth: 310, maxWidth: 380)
                    .background(.background)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionStatus(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Source", selection: $model.source) {
                        Label("OWON VDS1022 (USB)", systemImage: "cable.connector").tag(SourceChoice.hardware)
                        Divider()
                        ForEach(SimulatorScenario.allCases, id: \.self) { s in
                            Label("Demo: \(s.rawValue)", systemImage: "waveform").tag(SourceChoice.demo(s))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Source", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("Choose the hardware or a simulated signal")

                Menu {
                    Button("Export Report (SVG / PDF / PNG)…") { ReportExporter.exportInteractively(model) }
                    Button("Copy Report to Clipboard") { ReportExporter.copyToPasteboard(model) }
                    Divider()
                    Button("Export Waveform Data (CSV)…", action: model.exportCSV)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                } primaryAction: {
                    ReportExporter.exportInteractively(model)
                }
                .disabled(model.acquisition == nil)
                .help("Export a vector report of the screen with settings, measurements and cursors")

                Toggle(isOn: Binding(get: { model.sharing != nil },
                                     set: { $0 ? model.startSharing() : model.stopSharing() })) {
                    Label("Share", systemImage: "iphone.radiowaves.left.and.right")
                }
                .disabled(model.source.isRemote)
                .help("Share the scope on the network, for OwonScope on iPhone and iPad")

                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the controls")
            }
        }
        .navigationTitle("OwonScope")
        // Note: no .focusable() here - on macOS a focusable container swallows clicks meant
        // for the controls inside it. Shortcuts use an app-level key monitor instead.
        .onAppear { KeyboardShortcuts.install(model: model) }
    }
}

/// Single-key scope shortcuts (Space, arrows, 1/2) that work whatever has focus,
/// except while typing in a text field.
@MainActor
enum KeyboardShortcuts {
    private static var monitor: Any?

    static func install(model: ScopeModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return event }
            if let responder = event.window?.firstResponder as? NSText, responder.isEditable { return event }
            switch event.keyCode {
            case 49: model.toggleRun()                                           // space
            case 126: model.stepSelectedScale(-1)                                // up
            case 125: model.stepSelectedScale(1)                                 // down
            case 123: model.stepTimebase(1)                                      // left
            case 124: model.stepTimebase(-1)                                     // right
            default:
                switch event.charactersIgnoringModifiers {
                case "1": model.selectTrace(.ch1)
                case "2": model.selectTrace(.ch2)
                case "m", "M": model.selectTrace(.math)
                default: return event
                }
            }
            return nil
        }
    }
}

struct ConnectionStatus: View {
    var model: ScopeModel

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: 3)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 8)
    }

    private var color: Color {
        switch model.connection {
        case .connected(let i): i.isSimulated ? .purple : .green
        case .searching, .connecting, .loadingFirmware: .orange
        case .failed: .red
        }
    }

    private var text: String {
        let base = connectionText
        guard model.sharing != nil else { return base }
        let n = model.sharingClients
        return base + "  ·  Sharing" + (n > 0 ? " with \(n) device\(n == 1 ? "" : "s")" : "")
    }

    private var connectionText: String {
        switch model.connection {
        case .connected(let i):
            i.isSimulated ? "Demo signals" : "\(i.model)  ·  \(i.serial)  ·  HW \(i.hardwareVersion)" + (i.host.map { model.sharing == nil ? "  ·  on \($0)" : "" } ?? "")
        case .searching: "No scope connected"
        case .connecting: "Connecting…"
        case .loadingFirmware(let p): "Loading FPGA \(Int(p * 100)) %"
        case .failed: "Connection problem"
        }
    }
}
#endif
