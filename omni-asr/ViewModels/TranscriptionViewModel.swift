import CoreML
import Foundation
import SwiftUI

@Observable
@MainActor
final class TranscriptionViewModel {
    enum AppState: Equatable {
        case idle
        case loadingModel
        case ready
        case recording
        case transcribing
        case error(String)
    }

    var state: AppState = .idle
    var transcription: String = ""
    var audioLevel: Float = 0
    var availableModels: [CoreMLASRService.ModelInfo] = []
    var selectedModelId: String?

    private var asrService: CoreMLASRService?
    private let audioCaptureService = AudioCaptureService()

    /// Discover models in the app's Application Support directory and bundle.
    func discoverModels() {
        var models = [CoreMLASRService.ModelInfo]()

        // Check Application Support for downloaded models
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let modelsDir = appSupport.appendingPathComponent("Models")
            discoverModelsIn(directory: modelsDir, into: &models)
        }

        // Check app bundle for bundled models
        if let bundlePath = Bundle.main.resourceURL {
            discoverModelsIn(directory: bundlePath, into: &models)
        }

        availableModels = models
        if selectedModelId == nil {
            selectedModelId = models.first?.id
        }
    }

    private func discoverModelsIn(
        directory: URL,
        into models: inout [CoreMLASRService.ModelInfo]
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        // Look for model_info.json files that describe available models
        for item in contents where item.lastPathComponent == "model_info.json" {
            if let data = try? Data(contentsOf: item),
               let infos = try? JSONDecoder().decode([CoreMLASRService.ModelInfo].self, from: data) {
                models.append(contentsOf: infos)
            }
        }

        // Also look for .mlpackage directories alongside vocabulary.json
        for item in contents where item.pathExtension == "mlpackage" {
            let baseName = item.deletingPathExtension().lastPathComponent
            let vocabURL = directory.appendingPathComponent("vocabulary.json")
            if fm.fileExists(atPath: vocabURL.path) {
                let info = CoreMLASRService.ModelInfo(
                    id: baseName,
                    name: baseName,
                    vocabFile: "vocabulary.json",
                    postProcessorType: baseName.lowercased().contains("syllable") ? .syllable : .identity
                )
                if !models.contains(where: { $0.id == info.id }) {
                    models.append(info)
                }
            }
        }
    }

    func loadModel() async {
        guard let modelId = selectedModelId,
              let modelInfo = availableModels.first(where: { $0.id == modelId }) else {
            state = .error("No model selected")
            return
        }

        state = .loadingModel

        do {
            let (modelURL, vocabURL) = try resolveModelPaths(for: modelInfo)
            let service = try CoreMLASRService(
                modelURL: modelURL,
                vocabularyURL: vocabURL,
                postProcessorType: modelInfo.postProcessorType
            )
            asrService = service
            state = .ready
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
        }
    }

    private func resolveModelPaths(for info: CoreMLASRService.ModelInfo) throws -> (URL, URL) {
        // Check Application Support first
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let modelsDir = appSupport.appendingPathComponent("Models")
            let modelURL = modelsDir.appendingPathComponent("\(info.id).mlmodelc")
            let vocabURL = modelsDir.appendingPathComponent(info.vocabFile)
            if FileManager.default.fileExists(atPath: modelURL.path) {
                return (modelURL, vocabURL)
            }
            // Also try .mlpackage
            let packageURL = modelsDir.appendingPathComponent("\(info.id).mlpackage")
            if FileManager.default.fileExists(atPath: packageURL.path) {
                return (
                    try MLModel.compileModel(at: packageURL),
                    vocabURL
                )
            }
        }

        // Check bundle
        if let modelURL = Bundle.main.url(forResource: info.id, withExtension: "mlmodelc"),
           let vocabURL = Bundle.main.url(forResource: info.vocabFile.replacingOccurrences(of: ".json", with: ""), withExtension: "json") {
            return (modelURL, vocabURL)
        }

        throw ModelError.modelNotFound(info.id)
    }

    func toggleRecording() async {
        switch state {
        case .recording:
            await stopRecordingAndTranscribe()
        case .ready:
            await startRecording()
        default:
            break
        }
    }

    private func startRecording() async {
        do {
            try audioCaptureService.startRecording()
            state = .recording

            // Poll audio level
            Task {
                while state == .recording {
                    audioLevel = audioCaptureService.audioLevel
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecordingAndTranscribe() async {
        let samples = audioCaptureService.stopRecording()
        audioLevel = 0

        guard !samples.isEmpty else {
            state = .ready
            return
        }

        state = .transcribing

        guard let service = asrService else {
            state = .error("Model not loaded")
            return
        }

        do {
            let text = try service.transcribe(audio: samples)
            if transcription.isEmpty {
                transcription = text
            } else {
                transcription += "\n" + text
            }
            state = .ready
        } catch {
            state = .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    func clearTranscription() {
        transcription = ""
    }

    enum ModelError: Error, LocalizedError {
        case modelNotFound(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let id):
                return "Model '\(id)' not found in bundle or Application Support"
            }
        }
    }
}
