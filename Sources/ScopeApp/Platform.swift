import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

/// Small platform differences, so the shared views read the same on both.
enum Platform {
    #if os(iOS)
    static let isTouch = true
    /// iPhone (compact) vs iPad.
    @MainActor static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    #else
    static let isTouch = false
    @MainActor static var isPhone: Bool { false }
    #endif

    /// Minimum size of a tap target: Apple's 44 pt on touch screens.
    static let hitTarget: CGFloat = isTouch ? 44 : 22
}

extension View {
    /// A checkbox on the Mac, a compact check toggle on touch screens.
    @ViewBuilder func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(CheckToggleStyle())
        #endif
    }

    @ViewBuilder func borderlessMenu() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        self
        #endif
    }

    /// Open-hand pointer over draggable things (Mac only).
    @ViewBuilder func openHandCursor() -> some View {
        #if os(macOS)
        onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Checkbox look for touch: a tappable check square and label.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                    .font(.system(size: 17))
                configuration.label
            }
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif

/// The pasteboard, for plain text.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
