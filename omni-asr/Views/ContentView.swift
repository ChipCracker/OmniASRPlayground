import SwiftUI

struct ContentView: View {
    @State private var viewModel = TranscriptionViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status bar
                statusBar

                // Transcription area
                transcriptionArea

                Divider()

                // Controls
                controlBar
            }
            .navigationTitle("Omni ASR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    modelPicker
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = viewModel.transcription
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(viewModel.transcription.isEmpty)

                    Button("Clear") {
                        viewModel.clearTranscription()
                    }
                    .disabled(viewModel.transcription.isEmpty)
                }
            }
            .task {
                viewModel.discoverModels()
                if viewModel.selectedModelId != nil {
                    await viewModel.loadModel()
                }
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusText: String {
        switch viewModel.state {
        case .idle: "Kein Modell geladen"
        case .loadingModel: "Modell wird geladen..."
        case .ready: "Bereit"
        case .recording: "Aufnahme..."
        case .transcribing: "Transkribiere..."
        case .error(let msg): msg
        }
    }

    private var statusColor: Color {
        switch viewModel.state {
        case .idle: .gray
        case .loadingModel: .orange
        case .ready: .green
        case .recording: .red
        case .transcribing: .orange
        case .error: .red
        }
    }

    // MARK: - Transcription Area

    private var transcriptionArea: some View {
        ScrollView {
            if viewModel.transcription.isEmpty {
                Text("Tippe auf das Mikrofon, um die Aufnahme zu starten.")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 100)
            } else {
                Text(viewModel.transcription)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 12) {
            // Audio level indicator (visible during recording)
            if viewModel.state == .recording {
                audioLevelView
            }

            // Record button
            Button {
                Task {
                    await viewModel.toggleRecording()
                }
            } label: {
                Image(systemName: viewModel.state == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(viewModel.state == .recording ? Color.red : Color.accentColor)
                    .clipShape(Circle())
            }
            .disabled(!canToggleRecording)
            .padding(.bottom, 8)
        }
        .padding(.top, 12)
    }

    private var canToggleRecording: Bool {
        viewModel.state == .ready || viewModel.state == .recording
    }

    private var audioLevelView: some View {
        GeometryReader { geometry in
            let barWidth = CGFloat(viewModel.audioLevel) * geometry.size.width * 5 // Scale up
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.green)
                .frame(width: min(barWidth, geometry.size.width), height: 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 4)
        .padding(.horizontal)
    }

    // MARK: - Model Picker

    private var modelPicker: some View {
        Menu {
            ForEach(viewModel.availableModels) { model in
                Button {
                    viewModel.selectedModelId = model.id
                    Task { await viewModel.loadModel() }
                } label: {
                    HStack {
                        Text(model.name)
                        if model.id == viewModel.selectedModelId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if viewModel.availableModels.isEmpty {
                Text("Keine Modelle gefunden")
            }
        } label: {
            Image(systemName: "cpu")
        }
    }
}

#Preview {
    ContentView()
}
