#if os(macOS)
import AppKit
import ScopeKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opts out of App Nap: a scope must keep acquiring (and collecting statistics) while its
    /// window is behind other windows, and App Nap throttles both the engine thread and timers.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Continuous oscilloscope acquisition")
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The macOS app. Started by the OwonScope executable's main.swift.
public struct OwonScopeMacApp: App {
    /// The MCP server starts with the app unless it was switched off in the Acquire menu.
    /// OWONSCOPE_MCP_PORT changes the port (default 8908).
    private func startMCP() {
        guard mcp == nil else { return }
        let port = ProcessInfo.processInfo.environment["OWONSCOPE_MCP_PORT"].flatMap(UInt16.init) ?? ScopeMCPTools.defaultPort
        let server = MCPServer(name: "owonscope", title: "OwonScope", version: Self.version, port: port,
                               provider: ScopeMCPTools(model: model))
        mcp = server
        if UserDefaults.standard.object(forKey: "mcp.enabled") as? Bool ?? true { server.start() }
    }

    private static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ScopeModel()
    @State private var mcp: MCPServer?

    public init() {}

    public var body: some Scene {
        WindowGroup("OwonScope") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    Automation.installIfEnabled(model: model)
                    startMCP()
                }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandMenu("Acquire") {
                Button(model.running ? "Stop" : "Run") { model.toggleRun() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Single") { model.single() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Force Trigger") { model.forceTrigger() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Autoset") { model.autoset() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                Button("Faster Timebase") { model.stepTimebase(-1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Slower Timebase") { model.stepTimebase(1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Toggle("Share on Network", isOn: Binding(get: { model.sharing != nil },
                                                         set: { $0 ? model.startSharing() : model.stopSharing() }))
                    .disabled(model.source.isRemote)
                if let mcp {
                    Toggle("MCP Server for AI Agents", isOn: Binding(get: { mcp.running }, set: { on in
                        UserDefaults.standard.set(on, forKey: "mcp.enabled")
                        on ? mcp.start() : mcp.stop()
                    }))
                    Button("Copy MCP Server Setup Command") {
                        Clipboard.copy("claude mcp add --transport http owonscope \(mcp.url)")
                    }
                    .disabled(!mcp.running)
                }
                Divider()
                Button("Reconnect") { model.reconnect() }
                Button("Install FPGA Firmware…") { model.chooseFirmwareFolder() }
            }
            CommandGroup(after: .saveItem) {
                Button("Export Waveform as CSV…") { model.exportCSV() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Export Report (SVG / PDF / PNG)…") { ReportExporter.exportInteractively(model) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.acquisition == nil)
                Button("Copy Report to Clipboard") { ReportExporter.copyToPasteboard(model) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.acquisition == nil)
                Button("Save Window Screenshot (bitmap)…") { Snapshot.saveInteractively() }
            }
            CommandGroup(after: .toolbar) {
                Picker("Persistence", selection: $model.display.persistence) {
                    ForEach(Persistence.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Cursors", selection: $model.display.cursorMode) {
                    ForEach(CursorMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Cycle Cursors") {
                    let all = CursorMode.allCases
                    model.display.cursorMode = all[(all.firstIndex(of: model.display.cursorMode)! + 1) % all.count]
                }
                .keyboardShortcut("k", modifiers: .command)
                Picker("Format", selection: $model.display.format) {
                    ForEach(DisplayFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Divider()
            }
        }
    }
}
#endif
