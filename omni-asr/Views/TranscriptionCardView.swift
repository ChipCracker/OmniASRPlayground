import SwiftUI

struct TranscriptionCardView: View {
    let confirmedText: String
    let liveText: String
    let isTranscribing: Bool
    var accentColor: Color = .clear
    var wordCount: Int = 0
    var charCount: Int = 0

    @State private var cursorVisible = true
    @State private var borderRotation: Angle = .zero

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        (Text(confirmedText).bold()
                         + Text(confirmedText.isEmpty || liveText.isEmpty ? "" : " ")
                         + Text(liveText))
                            .font(.title3)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        // Live cursor during transcription
                        if isTranscribing {
                            let cursorColor = accentColor == .clear ? Color.orange : accentColor
                            RoundedRectangle(cornerRadius: 1)
                                .fill(cursorColor)
                                .frame(width: 2, height: 18)
                                .opacity(cursorVisible ? 1 : 0.3)
                                .shadow(color: cursorColor.opacity(0.5), radius: 4)
                                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: cursorVisible)
                                .onAppear { cursorVisible.toggle() }
                                .padding(.leading, 2)
                        }
                    }
                    .padding(20)

                    // Invisible anchor at the bottom
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .mask(
                    VStack(spacing: 0) {
                        // Top fade
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 20)
                        Color.black
                        // Bottom fade
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 20)
                    }
                )
                .onChange(of: liveText) {
                    if isTranscribing {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Footer metadata
            if wordCount > 0 {
                Divider()
                    .padding(.horizontal, 20)
                HStack {
                    Text("\(wordCount) Wörter · \(charCount) Zeichen")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .glassCard()
        // Rotating angular gradient border during transcription
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    AngularGradient(
                        colors: isTranscribing
                            ? [accentColor, accentColor.opacity(0.3), .clear, accentColor.opacity(0.3), accentColor]
                            : [Color.clear],
                        center: .center,
                        angle: borderRotation
                    ),
                    lineWidth: 1.5
                )
        )
        // Top-edge glow
        .overlay(alignment: .top) {
            Ellipse()
                .fill(accentColor.opacity(0.15))
                .frame(height: 80)
                .frame(maxWidth: .infinity)
                .blur(radius: 24)
                .offset(y: -24)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        // State-colored glow shadow
        .shadow(
            color: accentColor.opacity(isTranscribing ? 0.15 : 0),
            radius: 16, y: 6
        )
        .animation(.easeInOut(duration: 0.5), value: accentColor)
        .onChange(of: isTranscribing) { _, transcribing in
            if transcribing {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    borderRotation = .degrees(360)
                }
            } else {
                borderRotation = .zero
            }
        }
    }
}

#Preview {
    ZStack {
        Color.indigo.opacity(0.2).ignoresSafeArea()
        TranscriptionCardView(
            confirmedText: "Dies ist ein Beispieltext für die Transkription.",
            liveText: "Er zeigt, wie der Text in der Glasmorphismus-Karte dargestellt wird.",
            isTranscribing: true,
            accentColor: .orange,
            wordCount: 17,
            charCount: 112
        )
        .padding()
    }
}
