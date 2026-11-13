import AppKit
import ScopeKit
import UniformTypeIdentifiers

/// Save panel and clipboard front end for the vector report.
@MainActor
enum ReportExporter {
    private static let formatKey = "export.format", themeKey = "export.theme", statsKey = "export.statistics"

    static var savedOptions: ExportOptions {
        let d = UserDefaults.standard
        var o = ExportOptions()
        o.format = ExportFormat(rawValue: d.string(forKey: formatKey) ?? "") ?? .svg
        o.theme = d.string(forKey: themeKey) == "Dark" ? .dark : .light
        o.includeStatistics = d.object(forKey: statsKey) as? Bool ?? true
        return o
    }

    private static func remember(_ o: ExportOptions) {
        let d = UserDefaults.standard
        d.set(o.format.rawValue, forKey: formatKey)
        d.set(o.theme.name, forKey: themeKey)
        d.set(o.includeStatistics, forKey: statsKey)
    }

    static func data(_ model: ScopeModel, _ o: ExportOptions) -> Data? {
        let drawing = ReportBuilder.build(model, options: o)
        switch o.format {
        case .svg: return SVGWriter.render(drawing).data(using: .utf8)
        case .pdf: return CGVectorRenderer.pdf(drawing)
        case .png: return CGVectorRenderer.png(drawing, scale: 2)
        }
    }

    static func type(_ f: ExportFormat) -> UTType {
        switch f { case .svg: .svg; case .pdf: .pdf; case .png: .png }
    }

    static func write(_ model: ScopeModel, to url: URL, options: ExportOptions) throws {
        guard let d = data(model, options) else { throw CocoaError(.fileWriteUnknown) }
        try d.write(to: url, options: .atomic)
    }

    /// Save panel with Format / Theme / Statistics options.
    static func exportInteractively(_ model: ScopeModel) {
        var options = savedOptions
        let panel = NSSavePanel()
        panel.title = "Export Report"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let stamp = ReportBuilder.timestamp(Date()).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: " at ")
        panel.nameFieldStringValue = "Scope \(stamp)"
        panel.allowedContentTypes = [type(options.format)]

        let accessory = AccessoryView(options: options) { new in
            options = new
            panel.allowedContentTypes = [type(new.format)]
        }
        panel.accessoryView = accessory.view

        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            remember(options)
            do { try write(model, to: url, options: options) } catch {
                NSAlert(error: error).runModal()
            }
            _ = accessory // keep the target alive until the panel closes
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Puts PDF (vector, pastes into Pages/Keynote/Word), PNG and SVG on the clipboard.
    static func copyToPasteboard(_ model: ScopeModel) {
        var o = savedOptions
        let drawing = ReportBuilder.build(model, options: o)
        o.format = .pdf
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(CGVectorRenderer.pdf(drawing), forType: .pdf)
        if let png = CGVectorRenderer.png(drawing, scale: 2) { item.setData(png, forType: .png) }
        item.setString(SVGWriter.render(drawing), forType: NSPasteboard.PasteboardType(UTType.svg.identifier))
        pb.writeObjects([item])
    }

    /// AppKit accessory controls for the save panel.
    final class AccessoryView: NSObject {
        let view: NSView
        private var options: ExportOptions
        private let onChange: (ExportOptions) -> Void
        private let format = NSPopUpButton(), theme = NSPopUpButton()
        private let stats = NSButton(checkboxWithTitle: "Include measurement statistics", target: nil, action: nil)

        init(options: ExportOptions, onChange: @escaping (ExportOptions) -> Void) {
            self.options = options
            self.onChange = onChange
            format.addItems(withTitles: ["SVG (web, vector)", "PDF (reports, vector)", "PNG (bitmap, 2×)"])
            format.selectItem(at: ExportFormat.allCases.firstIndex(of: options.format) ?? 0)
            theme.addItems(withTitles: ["Light (print)", "Dark (screen)"])
            theme.selectItem(at: options.theme.name == "Dark" ? 1 : 0)
            stats.state = options.includeStatistics ? .on : .off
            func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
            let grid = NSGridView(views: [[label("Format:"), format], [label("Theme:"), theme], [NSGridCell.emptyContentView, stats]])
            grid.rowSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            let container = NSView()
            grid.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
                grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            ])
            view = container
            super.init()
            for c in [format, theme, stats] as [NSControl] { c.target = self; c.action = #selector(changed) }
        }

        @objc private func changed() {
            options.format = ExportFormat.allCases[max(0, format.indexOfSelectedItem)]
            options.theme = theme.indexOfSelectedItem == 1 ? .dark : .light
            options.includeStatistics = stats.state == .on
            onChange(options)
        }
    }
}
