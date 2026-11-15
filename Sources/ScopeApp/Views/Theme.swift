import ScopeKit
import SwiftUI

enum Theme {
    static let ch = [Color(red: 1.0, green: 0.82, blue: 0.18), Color(red: 0.22, green: 0.84, blue: 1.0)]
    static let chSIMD: [SIMD4<Float>] = [SIMD4(1.0, 0.80, 0.16, 1), SIMD4(0.20, 0.82, 1.0, 1)]
    static let math = Color(red: 0.98, green: 0.42, blue: 0.95)
    static let mathSIMD = SIMD4<Float>(0.98, 0.42, 0.95, 1)
    static let ref = [Color(white: 0.85), Color(red: 0.55, green: 1.0, blue: 0.6)]
    static let refSIMD: [SIMD4<Float>] = [SIMD4(0.85, 0.85, 0.85, 1), SIMD4(0.55, 1.0, 0.6, 1)]
    static let xy = Color(red: 0.55, green: 1.0, blue: 0.55)
    static let xySIMD = SIMD4<Float>(0.55, 1.0, 0.55, 1)
    static let ext = Color(red: 0.75, green: 0.55, blue: 1.0)
    static let trigger = Color(red: 1.0, green: 0.55, blue: 0.2)
    static let screen = Color(red: 0.03, green: 0.037, blue: 0.05)
    static let grid = Color.white.opacity(0.10)
    static let gridStrong = Color.white.opacity(0.22)
    static let decoderPalette = [Color(red: 0.62, green: 0.48, blue: 1.0), Color(red: 0.35, green: 0.9, blue: 0.55),
                                 Color(red: 1.0, green: 0.45, blue: 0.65), Color(red: 1.0, green: 0.65, blue: 0.3)]

    static func channelColor(_ ch: Int) -> Color { ch < Self.ch.count ? Self.ch[ch] : .white }

    static func traceColor(_ t: Trace) -> Color { t == .math ? math : channelColor(t.rawValue) }

    static func triggerColor(_ s: TriggerSource) -> Color {
        switch s { case .ch1: ch[0]; case .ch2: ch[1]; case .ext: ext }
    }

    static func eventColor(_ kind: DecodedEvent.Kind, base: Color) -> Color {
        switch kind {
        case .data: base
        case .address: Color(red: 1.0, green: 0.75, blue: 0.3)
        case .start, .stop: Color(red: 0.45, green: 0.8, blue: 1.0)
        case .ack: Color(red: 0.4, green: 0.85, blue: 0.45)
        case .nack, .error: Color(red: 1.0, green: 0.35, blue: 0.35)
        case .info: .gray
        }
    }

    static func stateColor(_ s: TriggerState) -> Color {
        switch s {
        case .triggered: .green
        case .auto: .yellow
        case .waiting: .orange
        case .stopped: .red
        case .roll: Color(red: 0.4, green: 0.7, blue: 1.0)
        }
    }
}

/// Small rounded pill label.
struct Pill: View {
    var text: String
    var color: Color
    var filled = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(filled ? Color.black : color)
            .background(Capsule().fill(filled ? color : color.opacity(0.16)))
            .overlay(Capsule().strokeBorder(color.opacity(filled ? 0 : 0.45), lineWidth: 0.75))
    }
}
