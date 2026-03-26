import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let isReady: Bool
    let audioLevel: Float
    let isDisabled: Bool
    let action: () -> Void

    @State private var breatheScale: CGFloat = 1.0
    @State private var borderRotation: Angle = .zero
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        Button {
            haptic.impactOccurred()
            action()
        } label: {
            ZStack {
                // Pulse rings (visible during recording)
                if isRecording {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
                        ForEach(0..<3, id: \.self) { i in
                            PulseRing(
                                phase: Double(i) / 3.0,
                                audioLevel: audioLevel
                            )
                        }
                    }
                }

                // Rotating gradient border during recording
                if isRecording {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.red, .orange, .yellow, .orange, .red],
                                center: .center
                            ),
                            lineWidth: 3
                        )
                        .frame(width: 80, height: 80)
                        .rotationEffect(borderRotation)
                }

                // Main circle
                Circle()
                    .fill(isRecording ? AppTheme.recordingGradient : AppTheme.accentGradient)
                    .frame(width: 72, height: 72)
                    .shadow(
                        color: (isRecording ? Color.red : Color.indigo).opacity(0.4),
                        radius: 12,
                        y: 4
                    )
                    .overlay {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                    }
                    .scaleEffect(breatheScale)
            }
        }
        .buttonStyle(RecordButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .onChange(of: isRecording) { _, recording in
            if recording {
                // Stop breathing, start border rotation
                withAnimation(.default) {
                    breatheScale = 1.0
                }
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    borderRotation = .degrees(360)
                }
            } else {
                borderRotation = .zero
                // Restart breathing if ready
                if isReady {
                    startBreathing()
                }
            }
        }
        .onChange(of: isReady) { _, ready in
            if ready && !isRecording {
                startBreathing()
            } else if !ready {
                withAnimation(.default) {
                    breatheScale = 1.0
                }
            }
        }
        .onAppear {
            haptic.prepare()
            if isReady && !isRecording {
                startBreathing()
            }
        }
    }

    private func startBreathing() {
        withAnimation(
            .easeInOut(duration: 2)
            .repeatForever(autoreverses: true)
        ) {
            breatheScale = 1.03
        }
    }
}

// MARK: - Pulse Ring

private struct PulseRing: View {
    let phase: Double
    let audioLevel: Float

    @State private var isAnimating = false

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.3), lineWidth: 2)
            .frame(width: 72, height: 72)
            .scaleEffect(isAnimating ? 1.0 + CGFloat(audioLevel) * 0.6 + CGFloat(phase) * 0.3 : 1.0)
            .opacity(isAnimating ? 0 : 0.6)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
                    .delay(phase * 0.5)
                ) {
                    isAnimating = true
                }
            }
            .onDisappear {
                isAnimating = false
            }
    }
}

// MARK: - Button Style

private struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

#Preview {
    ZStack {
        Color.indigo.opacity(0.2).ignoresSafeArea()
        VStack(spacing: 40) {
            RecordButton(isRecording: false, isReady: true, audioLevel: 0, isDisabled: false) {}
            RecordButton(isRecording: true, isReady: false, audioLevel: 0.5, isDisabled: false) {}
            RecordButton(isRecording: false, isReady: false, audioLevel: 0, isDisabled: true) {}
        }
    }
}
