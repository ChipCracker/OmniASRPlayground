import SwiftUI

enum AppTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 40
    }

    static let accentGradient = LinearGradient(
        colors: [.indigo, .purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let recordingGradient = LinearGradient(
        colors: [.red, .orange],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let transcribingGradient = LinearGradient(
        colors: [.yellow, .orange],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func stateColor(for state: TranscriptionViewModel.AppState) -> Color {
        switch state {
        case .idle: .gray
        case .loadingModel: .orange
        case .ready: .indigo
        case .recording: .red
        case .liveRecording: .teal
        case .transcribing: .orange
        case .error: .red
        }
    }

    static func stateGradientColors(for state: TranscriptionViewModel.AppState) -> [Color] {
        switch state {
        case .idle: [.gray.opacity(0.3), .indigo.opacity(0.15)]
        case .loadingModel: [.orange.opacity(0.25), .indigo.opacity(0.15)]
        case .ready: [.indigo.opacity(0.25), .purple.opacity(0.15)]
        case .recording: [.red.opacity(0.3), .orange.opacity(0.15)]
        case .liveRecording: [.teal.opacity(0.3), .green.opacity(0.15)]
        case .transcribing: [.orange.opacity(0.25), .yellow.opacity(0.15)]
        case .error: [.red.opacity(0.25), .gray.opacity(0.15)]
        }
    }
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}
