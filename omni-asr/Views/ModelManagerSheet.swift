import SwiftUI

struct ModelManagerSheet: View {
    @Bindable var viewModel: TranscriptionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.availableModels) { model in
                        modelRow(model)
                    }
                }

                Section {
                    Picker("Compute Units", selection: $viewModel.selectedComputeUnits) {
                        ForEach(CoreMLASRService.ComputeUnitOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                }
            }
            .navigationTitle("Modelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func modelRow(_ model: CoreMLASRService.ModelInfo) -> some View {
        let isDownloaded = viewModel.isModelAvailableLocally(model)
        let isActive = model.id == viewModel.selectedModelId && viewModel.state != .idle
        let isDownloading = {
            if let state = viewModel.downloadService.downloadStates[model.id],
               case .downloading = state { return true }
            return false
        }()
        let progress: Double? = viewModel.downloadService.downloadStates[model.id].flatMap {
            if case .downloading(let p) = $0 { return p }
            return nil
        }
        let isFailed = {
            if let state = viewModel.downloadService.downloadStates[model.id],
               case .failed = state { return true }
            return false
        }()
        let failedMessage: String? = viewModel.downloadService.downloadStates[model.id].flatMap {
            if case .failed(let msg) = $0 { return msg }
            return nil
        }

        Button {
            if isDownloading { return }
            if isDownloaded {
                guard !isActive else { return }
                viewModel.selectedModelId = model.id
                Task {
                    await viewModel.loadModel()
                    dismiss()
                }
            } else {
                Task { await viewModel.downloadModel(model) }
            }
        } label: {
            HStack {
                // Left: status dot + text
                Circle()
                    .fill(isActive ? .green : (isDownloaded ? .indigo : .gray.opacity(0.3)))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.body)
                        .fontWeight(isActive ? .semibold : .regular)
                        .foregroundStyle(.primary)

                    // Subtitle: progress or status
                    if isDownloading, let progress {
                        ProgressView(value: progress)
                            .tint(.indigo)
                        Text("\(Int(progress * 100))% von \(ModelDownloadService.formattedSize(model.downloadSize ?? 0))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if isFailed, let failedMessage {
                        Text(failedMessage)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text(subtitleText(model: model, isDownloaded: isDownloaded, isActive: isActive))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Right: single action/indicator
                if isDownloading {
                    Button {
                        viewModel.downloadService.cancelDownload(model.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isDownloaded {
                    Text("Laden")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.indigo.opacity(0.15), in: Capsule())
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if viewModel.downloadedModelIds.contains(model.id) {
                Button(role: .destructive) {
                    viewModel.deleteModel(model.id)
                } label: {
                    Label("Download löschen", systemImage: "trash")
                }
            }
        }
    }

    private func subtitleText(model: CoreMLASRService.ModelInfo, isDownloaded: Bool, isActive: Bool) -> String {
        let size = model.downloadSize.map { ModelDownloadService.formattedSize($0) } ?? ""
        if isActive {
            return size.isEmpty ? "Aktiv" : "\(size) · Aktiv"
        } else if isDownloaded {
            return size.isEmpty ? "Heruntergeladen" : "\(size) · Heruntergeladen"
        } else {
            return size
        }
    }
}

#Preview {
    ModelManagerSheet(viewModel: TranscriptionViewModel())
}
