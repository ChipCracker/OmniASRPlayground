import SwiftUI

struct AudioWaveformView: View {
    let audioLevel: Float

    @State private var targetSamples: [Float] = []
    @State private var displaySamples: [Float] = []
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            let barWidth: CGFloat = 8
            let barCount = max(1, Int(geo.size.width / barWidth))

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { context, size in
                    let gap: CGFloat = 2
                    let actualBarWidth = size.width / CGFloat(barCount)
                    let midY = size.height * 0.45 // Shifted up for reflection space

                    for i in 0..<min(barCount, displaySamples.count) {
                        let amplitude = CGFloat(displaySamples[i])
                        let barHeight = max(2, amplitude * midY * 1.8)
                        let x = CGFloat(i) * actualBarWidth

                        // Main bar with vertical gradient
                        let rect = CGRect(
                            x: x + gap / 2,
                            y: midY - barHeight / 2,
                            width: max(1, actualBarWidth - gap),
                            height: barHeight
                        )
                        let path = Path(roundedRect: rect, cornerRadius: (actualBarWidth - gap) / 2)

                        let topColor = Color(
                            red: 0.95 + 0.05 * Double(amplitude),
                            green: 0.5 - 0.15 * Double(amplitude),
                            blue: 0.15
                        )
                        let bottomColor = Color(
                            red: 0.6 + 0.1 * Double(amplitude),
                            green: 0.25,
                            blue: 0.1
                        )

                        context.fill(path, with: .linearGradient(
                            Gradient(colors: [topColor, bottomColor]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        ))

                        // Reflection below
                        let reflectionHeight = barHeight * 0.4
                        let reflectionRect = CGRect(
                            x: x + gap / 2,
                            y: midY + barHeight / 2 + 2,
                            width: max(1, actualBarWidth - gap),
                            height: reflectionHeight
                        )
                        let reflectionPath = Path(roundedRect: reflectionRect, cornerRadius: (actualBarWidth - gap) / 2)
                        context.opacity = 0.15
                        context.fill(reflectionPath, with: .linearGradient(
                            Gradient(colors: [bottomColor, bottomColor.opacity(0)]),
                            startPoint: CGPoint(x: reflectionRect.midX, y: reflectionRect.minY),
                            endPoint: CGPoint(x: reflectionRect.midX, y: reflectionRect.maxY)
                        ))
                        context.opacity = 1
                    }
                }
                .onChange(of: timeline.date) {
                    ensureSampleCount(barCount)

                    // Shift target samples left, add new
                    targetSamples.removeFirst()
                    let jitter = Float.random(in: 0.85...1.15)
                    targetSamples.append(audioLevel * jitter)

                    // Smooth interpolation
                    for i in 0..<min(displaySamples.count, targetSamples.count) {
                        displaySamples[i] += (targetSamples[i] - displaySamples[i]) * 0.3
                    }
                }
            }
            .onAppear {
                ensureSampleCount(barCount)
                withAnimation(.easeOut(duration: 0.5)) {
                    appeared = true
                }
            }
        }
        .frame(height: 64)
        .scaleEffect(y: appeared ? 1 : 0, anchor: .center)
        .padding(.horizontal, 20)
        .glassCard()
    }

    private func ensureSampleCount(_ count: Int) {
        if targetSamples.count != count {
            targetSamples = Array(repeating: 0, count: count)
            displaySamples = Array(repeating: 0, count: count)
        }
    }
}

#Preview {
    ZStack {
        Color.indigo.opacity(0.2).ignoresSafeArea()
        AudioWaveformView(audioLevel: 0.5)
            .padding()
    }
}
