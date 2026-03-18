import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse.byLayer)

            VStack(spacing: 6) {
                Text("Bereit zur Aufnahme")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text("Tippe auf das Mikrofon oder importiere eine Audiodatei")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
    }
}

#Preview {
    EmptyStateView()
}
