import SwiftUI
import MurmurCore

/// Translucent pill HUD. Eight bars that breathe during recording,
/// dim during processing, red on error. Reduced motion: bars become
/// dots that gently fade.
struct HUDView: View {

    @ObservedObject var state: HUDViewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 8

    var body: some View {
        HStack(spacing: 14) {
            indicator
            label
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }

    private var indicator: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(for: i))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.05),
                        value: state.state
                    )
            }
        }
        .frame(width: 56, height: 36)
    }

    private var label: some View {
        Text(stateLabel)
            .font(.system(size: 13, weight: .medium, design: .default))
            .foregroundColor(.white.opacity(0.92))
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
    }

    private var stateLabel: String {
        switch state.state {
        case .idle: return "Ready"
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        case .error(let msg): return msg
        }
    }

    private var barColor: Color {
        switch state.state {
        case .recording: return Color(red: 0.91, green: 0.72, blue: 0.43)
        case .processing: return .white.opacity(0.6)
        case .error: return Color(red: 0.89, green: 0.34, blue: 0.29)
        case .idle: return .clear
        }
    }

    private func barHeight(for i: Int) -> CGFloat {
        let mid = Double(barCount - 1) / 2
        let env = 1 - abs(Double(i) - mid) / mid
        let base: CGFloat = 8 + CGFloat(env) * 24
        switch state.state {
        case .recording: return base
        case .processing: return base * 0.5
        case .error: return base * 0.7
        case .idle: return 4
        }
    }
}

/// Small NSViewRepresentable wrapper around `NSVisualEffectView` for the
/// translucent material. Apple still hasn't shipped a SwiftUI-native
/// equivalent.
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
