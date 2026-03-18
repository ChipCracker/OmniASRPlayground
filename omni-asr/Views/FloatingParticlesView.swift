import SwiftUI

struct FloatingParticlesView: View {
    let isActive: Bool

    private static let particleCount = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                for i in 0..<Self.particleCount {
                    let seed = Double(i) * 137.508 // Golden angle for distribution

                    // Slow upward drift with horizontal swaying
                    let speed = 0.02 + fmod(seed, 0.03)
                    let yProgress = fmod(time * speed + seed / 10.0, 1.0)
                    let y = size.height * (1.0 - yProgress)
                    let baseX = fmod(seed * 97.0, size.width)
                    let sway = sin(time * 0.5 + seed) * 20.0
                    let x = baseX + sway

                    // Size variation
                    let radius = 3.0 + fmod(seed * 13.0, 8.0)

                    // Opacity: fade in at bottom, fade out at top
                    let fadeIn = min(1.0, yProgress * 5.0)
                    let fadeOut = min(1.0, (1.0 - yProgress) * 5.0)
                    let alpha = fadeIn * fadeOut * 0.25

                    let rect = CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.opacity = alpha
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: 1.0), value: isActive)
    }
}

#Preview {
    ZStack {
        Color.black
        FloatingParticlesView(isActive: true)
    }
    .ignoresSafeArea()
}
