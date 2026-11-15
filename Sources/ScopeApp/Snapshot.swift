#if os(macOS)
import AppKit
import ScopeKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Window screenshots via ScreenCaptureKit. `SCShareableContent.currentProcess` captures the
/// app's own windows without needing the Screen Recording permission.
enum Snapshot {
    @MainActor
    static func capture(to url: URL) async throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            throw NSError(domain: "Snapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no window"])
        }
        let image: CGImage
        do {
            image = try await captureWithScreenCaptureKit(window)
        } catch {
            guard let fallback = renderInProcess(window) else { throw error }
            image = fallback
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "Snapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Composites the Metal trace layer under a cached rendering of the AppKit/SwiftUI views.
    @MainActor
    static func renderInProcess(_ window: NSWindow, scale requested: CGFloat? = nil, chrome cachedChrome: CGImage? = nil) -> CGImage? {
        guard let content = window.contentView else { return nil }
        let frameView = content.superview ?? content
        let scale = requested ?? window.backingScaleFactor
        let bounds = frameView.bounds
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        func cache(_ v: NSView) -> CGImage? {
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            if requested != nil {
                // render at the requested scale rather than the backing scale
                rep.pixelsWide = Int(v.bounds.width * scale)
                rep.pixelsHigh = Int(v.bounds.height * scale)
                guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
                r.size = v.bounds.size
                v.cacheDisplay(in: v.bounds, to: r)
                return r.cgImage
            }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep.cgImage
        }
        func rect(of v: NSView) -> CGRect {
            let f = v.convert(v.bounds, to: frameView)
            let y = frameView.isFlipped ? bounds.height - f.maxY : f.minY
            return CGRect(x: f.minX * scale, y: y * scale, width: f.width * scale, height: f.height * scale)
        }

        // 1. window chrome (title bar, background)
        if let chrome = cachedChrome ?? cache(frameView) { ctx.draw(chrome, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        // 2. Metal traces
        for mtk in findMetalViews(content) {
            guard let renderer = mtk.renderer,
                  let img = renderer.snapshot(size: mtk.drawableSize, pixelFormat: mtk.colorPixelFormat) else { continue }
            ctx.draw(img, in: rect(of: mtk))
        }
        // 3. SwiftUI content (transparent over the scope screen), with Metal views hidden
        let mtks = findMetalViews(content)
        mtks.forEach { $0.isHidden = true }
        if let ui = cache(content) { ctx.draw(ui, in: rect(of: content)) }
        mtks.forEach { $0.isHidden = false }
        return ctx.makeImage()
    }

    private static func findMetalViews(_ v: NSView) -> [ScopeMTKView] {
        var out: [ScopeMTKView] = []
        if let m = v as? ScopeMTKView { out.append(m) }
        for s in v.subviews { out += findMetalViews(s) }
        return out
    }

    @MainActor
    private static func captureWithScreenCaptureKit(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Snapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "window not shareable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    static func saveInteractively() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "OwonScope \(f.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await capture(to: url) }
    }
}

/// Local automation for scripted testing, enabled only with OWONSCOPE_AUTOMATION=1.
/// Post the distributed notification "io.github.owonscope.command" with a command string
/// as the object, e.g. "snapshot:/tmp/a.png", "demo:i2c", "hardware", "add:uart",
/// "tab:spectrum", "timebase:<s/div>", "autoset", "cursors:on", "persist:long", "clear-decoders".
@MainActor
final class Automation {
    static var shared: Automation?
    private let model: ScopeModel

    static func installIfEnabled(model: ScopeModel) {
        guard ProcessInfo.processInfo.environment["OWONSCOPE_AUTOMATION"] == "1", shared == nil else { return }
        let a = Automation(model: model)
        shared = a
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            let hit = e.window?.contentView?.superview?.hitTest(e.locationInWindow)
            print("mouse \(e.type == .leftMouseDown ? "down" : "up") at \(e.locationInWindow) hit=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            return e
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.github.owonscope.command"),
                                                            object: nil, queue: .main) { note in
            let cmd = note.object as? String ?? ""
            print("automation: \(cmd)")
            MainActor.assumeIsolated { a.run(cmd) }
        }
    }

    init(model: ScopeModel) { self.model = model }

    /// The vertical stack split (scope above, bottom panel below).
    static func findSplit(_ v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView, !s.isVertical { return s }
        for sub in v.subviews { if let s = findSplit(sub) { return s } }
        return nil
    }

    static func findMTK(_ v: NSView) -> ScopeMTKView? {
        if let m = v as? ScopeMTKView { return m }
        for s in v.subviews { if let m = findMTK(s) { return m } }
        return nil
    }

    func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let verb = parts.first ?? "", arg = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "snapshot":
            Task {
                do { try await Snapshot.capture(to: URL(fileURLWithPath: arg)); print("snapshot saved \(arg)") }
                catch { print("snapshot failed: \(error)") }
            }
        case "demo":
            let s = SimulatorScenario.allCases.first { "\($0)".lowercased() == arg.lowercased() } ?? .reference
            model.source = .demo(s)
        case "hardware": model.source = .hardware
        case "share":
            if arg == "off" { model.stopSharing() } else { model.startSharing() }
            print("sharing \(model.sharing != nil ? "on, port \(model.sharing?.port ?? 0)" : "off")")
        case "add":
            model.addDecoder(DecoderKind.defaults(for: arg) ?? .uart(UARTConfig()))
        case "clear-decoders": model.decoders = []
        case "tab": model.display.bottomTab = BottomTab.allCases.first { $0.rawValue.lowercased() == arg } ?? .decode
        case "timebase":
            if let v = Double(arg), let i = Timebase.all.firstIndex(where: { $0.secondsPerDivision >= v * 0.999 }) {
                model.settings.timebaseIndex = i
            }
        case "vdiv":
            // vdiv:<channel>:<volts>
            let p = arg.split(separator: ":")
            if p.count == 2, let ch = Int(p[0]), let v = Double(p[1]) {
                let probe = model.settings.channels[ch].probe
                if let i = VDS1022.voltsPerDivision.firstIndex(where: { $0 * probe >= v * 0.999 }) {
                    model.settings.channels[ch].rangeIndex = i
                }
            }
        case "offset":
            let p = arg.split(separator: ":")
            if p.count == 2, let ch = Int(p[0]), let v = Double(p[1]) { model.settings.channels[ch].offsetDivisions = v }
        case "holdoff": if let v = Double(arg) { model.settings.trigger.holdoff = v }
        case "slope": model.settings.trigger.slope = arg == "falling" ? .falling : .rising
        case "level": if let v = Double(arg) { model.settings.trigger.level = v }
        case "source": model.settings.trigger.source = TriggerSource(rawValue: arg.uppercased()) ?? .ch1
        case "autoset": model.autoset()
        case "run": model.setRunning(true)
        case "stop": model.setRunning(false)
        case "single": model.single()
        case "toggle": model.toggleRun()
        case "status":
            let ch = model.settings.channels.map { "\($0.enabled ? "on" : "off")/\($0.coupling.rawValue)/\(Format.volts($0.voltsPerDivision))" }.joined(separator: ",")
            let ms = model.analysis.measurements.map { m in m.map { "pp=\(Format.number($0[.pkpk] ?? .nan)) rms=\(Format.number($0[.rms] ?? .nan)) f=\(Format.number($0[.frequency] ?? .nan))" } ?? "-" }
            let mm = model.analysis.mathMeasurements.map { "math[\(model.analysis.math?.unit ?? "")] mean=\(Format.number($0[.mean] ?? .nan)) pp=\(Format.number($0[.pkpk] ?? .nan))" } ?? "math -"
            print("status running=\(model.running) sweep=\(model.settings.trigger.sweep.rawValue) trig=\(model.acquisition?.triggerState.rawValue ?? "-") seq=\(model.acquisition?.sequence ?? -1) acc=\(model.acquisition?.channels.compactMap { $0 }.first?.accumulated ?? 0) ch=\(ch) tb=\(model.settings.timebase.label) src=\(model.settings.trigger.source.rawValue) sel=\(model.selectedTrace.name) cursors=\(model.display.cursorMode.rawValue) | \(ms.joined(separator: " / ")) | \(mm) | delay=\(model.analysis.cross?.delay.map(Format.seconds) ?? "-")")
        case "cursors": model.display.cursorMode = CursorMode.allCases.first { $0.rawValue.lowercased() == arg.lowercased() } ?? (arg == "on" ? .both : .off)
        case "geom":
            // prints the scope view's rect in global (top-left origin) screen coordinates and the
            // y of each trace's zero line, for click testing
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = win.contentView,
               let mtk = Self.findMTK(content) {
                let r = win.convertToScreen(mtk.convert(mtk.bounds, to: nil))
                let screenH = NSScreen.screens.first?.frame.height ?? 0
                let top = screenH - r.maxY
                let zeros = Trace.allCases.map { t in "\(t.name)=\(Int(top + r.height / 2 - CGFloat(model.offset(of: t)) * r.height / 10))" }
                print("geom x=\(Int(r.minX)) y=\(Int(top)) w=\(Int(r.width)) h=\(Int(r.height)) zeros \(zeros.joined(separator: " "))")
            }
        case "report":
            // report:<path>[:dark][:nostats] — format from the extension
            let p = arg.split(separator: ":").map(String.init)
            var o = ExportOptions()
            o.format = ExportFormat.allCases.first { $0.rawValue.lowercased() == (p[0] as NSString).pathExtension.lowercased() } ?? .svg
            o.theme = p.contains("dark") ? .dark : .light
            o.includeStatistics = !p.contains("nostats")
            do { try ReportExporter.write(model, to: URL(fileURLWithPath: p[0]), options: o); print("report ok \(p[0])") }
            catch { print("report failed \(error)") }
        case "cursorpos":
            // cursorpos:t1,t2,y1,y2 (any may be empty to keep)
            let v = arg.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
            if v.count > 0, let x = v[0] { model.cursors.t1 = x }
            if v.count > 1, let x = v[1] { model.cursors.t2 = x }
            if v.count > 2, let x = v[2] { model.cursors.y1 = x }
            if v.count > 3, let x = v[3] { model.cursors.y2 = x }
        case "readout": model.display.cursorReadout = arg == "reset" ? nil : {
            let p = arg.split(separator: ",").compactMap { Double($0) }
            return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil }()
        case "rec-start":
            // rec-start:<fps>:<width>
            let p = arg.split(separator: ":").compactMap { Double($0) }
            GIFRecorder.shared.start(fps: p.first ?? 10, width: Int(p.count > 1 ? p[1] : 960))
        case "rec-caption": GIFRecorder.shared.caption = arg.isEmpty ? nil : arg
        case "rec-stop":
            let n = GIFRecorder.shared.stop(to: URL(fileURLWithPath: arg))
            print("recorded \(n) frames to \(arg)")
        case "bottomheight":
            // sets the height of the bottom (decode / measure / spectrum) panel
            if let h = Double(arg), let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
               let content = w.contentView, let split = Self.findSplit(content) {
                split.setPosition(split.bounds.height - CGFloat(h) - split.dividerThickness, ofDividerAt: 0)
            }
        case "winsize":
            let p = arg.split(separator: ":").compactMap { Double($0) }
            if p.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let screen = w.screen {
                let f = screen.visibleFrame
                w.setFrame(CGRect(x: f.minX + 40, y: f.maxY - p[1] - 20, width: p[0], height: p[1]), display: true)
            }
        case "copyreport": ReportExporter.copyToPasteboard(model)
        case "measurements": model.display.measurements = MeasurementKind.defaults
        case "select": if let i = Int(arg), let t = Trace(rawValue: i) { model.selectTrace(t) }
        case "acquire": model.acquireMode = AcquireMode.allCases.first { $0.rawValue.lowercased() == arg } ?? .normal
        case "avg": if let n = Int(arg) { model.processing.averages = n }
        case "math":
            if arg == "off" { model.processing.math.enabled = false } else {
                model.processing.math.operation = MathOperation.allCases.first { "\($0)" == arg } ?? .multiply
                model.processing.math.enabled = true
                model.selectTrace(.math)
            }
        case "mathauto": model.mathAutoScale()
        case "probe":
            // probe:<ch>:volts:<x> or probe:<ch>:amps:<V/A>
            let p = arg.split(separator: ":").map(String.init)
            if p.count == 3, let ch = Int(p[0]), let v = Double(p[2]) {
                model.setProbe(channel: ch, unit: p[1] == "amps" ? .amps : .volts)
                model.settings.channels[ch].probe = p[1] == "amps" ? 1 / v : v
            }
        case "format": model.display.format = arg == "xy" ? .xy : .yt
        case "gate": model.processing.gate = MeasureGate.allCases.first { $0.rawValue.lowercased() == arg } ?? .record
        case "ref":
            let p = arg.split(separator: ":")
            if p.count == 2, let slot = Int(p[0]), let t = Int(p[1]), let tr = Trace(rawValue: t) { model.saveReference(slot: slot, from: tr) }
        case "pulse":
            // pulse:off | pulse:<gt|lt|eq>:<seconds>[:neg]
            let p = arg.split(separator: ":").map(String.init)
            if p.first == "off" { model.settings.trigger.mode = .edge } else if p.count >= 2, let w = Double(p[1]) {
                model.settings.trigger.mode = .pulse
                model.settings.trigger.pulseCondition = p[0] == "lt" ? .less : p[0] == "eq" ? .equal : .greater
                model.settings.trigger.pulseWidth = w
                model.settings.trigger.slope = p.count > 2 && p[2] == "neg" ? .falling : .rising
            }
        case "sweep": model.settings.trigger.sweep = SweepMode.allCases.first { $0.rawValue.lowercased() == arg } ?? .auto
        case "channel":
            let p = arg.split(separator: ":")
            if p.count == 2, let ch = Int(p[0]) { model.settings.channels[ch].enabled = p[1] == "on" }
        case "persist": model.display.persistence = Persistence.allCases.first { $0.rawValue.lowercased() == arg } ?? .off
        case "position": if let v = Double(arg) { model.settings.triggerPosition = v }
        default: break
        }
    }
}
#endif
