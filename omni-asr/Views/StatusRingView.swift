import SwiftUI

struct StatusRingView: View {
    let progress: Double?
    let color: Color

    @State private var rotation: Angle = .zero

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3)

            if let progress {
                // Determinate
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: progress)
            } else {
                // Indeterminate spinning arc with comet-tail gradient
                Circle()
                    .trim(from: 0, to: 0.35)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0), color],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(rotation)
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = .degrees(360)
                        }
                    }
            }
        }
        .shadow(color: color.opacity(0.3), radius: 2)
        .shadow(color: color.opacity(0.5), radius: 4)
        .frame(width: 24, height: 24)
    }
}

#Preview("Determinate") {
    StatusRingView(progress: 0.65, color: .orange)
}

#Preview("Indeterminate") {
    StatusRingView(progress: nil, color: .indigo)
}
