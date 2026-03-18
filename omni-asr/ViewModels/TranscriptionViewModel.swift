import CoreML
import Foundation
import os
import SwiftUI

@Observable
@MainActor
final class TranscriptionViewModel {
    private static let log = Logger(subsystem: "omni-asr", category: "TranscriptionViewModel")
    enum AppState: Equatable {
        case idle
        case loadingModel
        case ready
        case recording          // Record only, transcribe after stop
        case liveRecording      // Record + live transcription
        case transcribing
        case error(String)
    }

    var state: AppState = .idle
    var transcription: String = ""
    private var pendingChunks: [String] = []
    var audioLevel: Float = 0
    var availableModels: [CoreMLASRService.ModelInfo] = []
    var selectedModelId: String?
    var selectedComputeUnits: CoreMLASRService.ComputeUnitOption = .cpuAndNeuralEngine
    var isFileImporterPresented: Bool = false
    var transcriptionProgress: Double = 0
    var modelLoadProgress: Double = 0

    private var asrService: CoreMLASRService?
    private let audioCaptureService = AudioCaptureService()
    private var liveTranscriptionTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    /// Frozen text for audio before the live window (recordings >40s)
    private(set) var frozenTranscription: String = ""
    /// Sample offset where the frozen transcription ends
    private var frozenSampleCount: Int = 0
    /// Buffer size at last inference (gate for new inference)
    private var lastTranscribedSampleCount: Int = 0
    /// The unconfirmed (live) portion of the transcription, derived from the full transcription minus the frozen prefix.
    var liveTranscription: String {
        guard state == .liveRecording, !frozenTranscription.isEmpty else { return transcription }
        let prefix = frozenTranscription + " "
        return transcription.hasPrefix(prefix) ? String(transcription.dropFirst(prefix.count)) : transcription
    }

    /// Minimum new audio samples before triggering a live transcription pass (~2s at 16kHz).
    private static let liveMinNewSamples = 32_000

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
            selectedModelId = models.first(where: { $0.id == "OmniASR_CTC_300M_int8" })?.id
                ?? models.first?.id
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

        // Also look for .mlmodelc / .mlpackage directories alongside vocabulary.json
        let modelExtensions: Set<String> = ["mlmodelc", "mlpackage"]
        for item in contents where modelExtensions.contains(item.pathExtension) {
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
        modelLoadProgress = 0

        do {
            let postProcessorType = modelInfo.postProcessorType
            let computeUnits = selectedComputeUnits.mlComputeUnits
            let service = try await Task.detached(priority: .userInitiated) { [weak self] in
                let (modelURL, vocabURL) = try Self.resolveModelPaths(for: modelInfo)
                let svc = try await CoreMLASRService.load(
                    modelURL: modelURL,
                    vocabularyURL: vocabURL,
                    postProcessorType: postProcessorType,
                    computeUnits: computeUnits
                )
                try svc.warmUp { progress in
                    Task { @MainActor in self?.modelLoadProgress = progress }
                }
                return svc
            }.value
            asrService = service
            state = .ready
        } catch {
            state = .error("Failed to load model: \(error.localizedDescription)")
        }
    }

    nonisolated private static func resolveModelPaths(for info: CoreMLASRService.ModelInfo) throws -> (URL, URL) {
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
            // .mlpackage: compile once, cache the .mlmodelc for faster subsequent loads
            let packageURL = modelsDir.appendingPathComponent("\(info.id).mlpackage")
            if FileManager.default.fileExists(atPath: packageURL.path) {
                let compiledURL = modelsDir.appendingPathComponent("\(info.id).mlmodelc")
                if !FileManager.default.fileExists(atPath: compiledURL.path) {
                    let tempCompiled = try MLModel.compileModel(at: packageURL)
                    try FileManager.default.moveItem(at: tempCompiled, to: compiledURL)
                }
                return (compiledURL, vocabURL)
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

    func toggleLiveRecording() async {
        switch state {
        case .liveRecording:
            await stopLiveRecording()
        case .ready:
            await startLiveRecording()
        default:
            break
        }
    }

    private func startLiveRecording() async {
        do {
            try audioCaptureService.startRecording()
            state = .liveRecording
            transcription = ""
            frozenTranscription = ""
            frozenSampleCount = 0
            lastTranscribedSampleCount = 0

            // Poll audio level
            audioLevelTask = Task {
                while state == .liveRecording, !Task.isCancelled {
                    audioLevel = audioCaptureService.audioLevel
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }

            startLiveTranscription()
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopLiveRecording() async {
        state = .transcribing
        transcriptionProgress = 0

        // Cancel and wait for in-flight tasks to complete
        audioLevelTask?.cancel()
        liveTranscriptionTask?.cancel()
        if let task = liveTranscriptionTask {
            await task.value
            liveTranscriptionTask = nil
        }

        let samples = audioCaptureService.stopRecording()
        audioLevel = 0

        // Final pass: transcribe everything after frozen prefix
        let remainingCount = samples.count - frozenSampleCount
        if remainingCount >= 16_000 {
            guard let service = asrService else {
                state = .error("Kein Modell geladen")
                return
            }

            let segment = Array(samples[frozenSampleCount...])
            do {
                let finalText = try await Task.detached(priority: .userInitiated) {
                    try await service.transcribe(audio: segment)
                }.value

                if frozenTranscription.isEmpty {
                    transcription = finalText
                } else {
                    transcription = frozenTranscription + " " + finalText
                }
            } catch {
                state = .error("Transkription fehlgeschlagen: \(error.localizedDescription)")
                return
            }
        }

        state = .ready
    }

    private func startRecording() async {
        do {
            try audioCaptureService.startRecording()
            state = .recording

            // Poll audio level
            audioLevelTask = Task {
                while state == .recording, !Task.isCancelled {
                    audioLevel = audioCaptureService.audioLevel
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch {
            state = .error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    private struct BufferSnapshot: Sendable {
        let liveSegment: [Float]
        let freezeSegment: [Float]?
        let newFrozenEnd: Int
        let bufferCount: Int
    }

    /// Snapshot buffer state on @MainActor — called from detached live-transcription loop.
    private func takeBufferSnapshot(maxInput: Int) -> BufferSnapshot? {
        guard state == .liveRecording else { return nil }

        let bufferCount = audioCaptureService.buffer.count
        guard bufferCount - lastTranscribedSampleCount >= Self.liveMinNewSamples else { return nil }

        var freezeSegment: [Float]?
        var newFrozenEnd = frozenSampleCount

        // Freeze check: if live window would exceed maxInputLength, freeze older audio
        if bufferCount - frozenSampleCount > maxInput {
            newFrozenEnd = bufferCount - maxInput
            freezeSegment = Array(audioCaptureService.buffer[frozenSampleCount..<newFrozenEnd])
        }

        let liveSegment = Array(audioCaptureService.buffer[newFrozenEnd..<bufferCount])
        return BufferSnapshot(
            liveSegment: liveSegment,
            freezeSegment: freezeSegment,
            newFrozenEnd: newFrozenEnd,
            bufferCount: bufferCount
        )
    }

    /// Apply freeze transcription result on @MainActor.
    private func applyFreezeResult(_ text: String, newFrozenEnd: Int) {
        if !text.isEmpty {
            frozenTranscription += (frozenTranscription.isEmpty ? "" : " ") + text
        }
        frozenSampleCount = newFrozenEnd
    }

    /// Apply live transcription result on @MainActor.
    private func applyLiveResult(_ text: String, processedCount: Int) {
        if frozenTranscription.isEmpty {
            transcription = text
        } else {
            transcription = frozenTranscription + " " + text
        }
        lastTranscribedSampleCount = processedCount
    }

    private func startLiveTranscription() {
        guard let service = asrService else { return }
        let maxInput = service.maxInputLength

        liveTranscriptionTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }

                // Brief main-actor hop: state check + buffer snapshot
                guard let snapshot = await self?.takeBufferSnapshot(maxInput: maxInput) else {
                    // nil means either self is gone or state/gate check failed
                    let stillRecording = await self?.state == .liveRecording
                    if !stillRecording { break }
                    continue
                }

                do {
                    // Freeze inference (if needed) — runs entirely off main actor
                    if let freezeSegment = snapshot.freezeSegment {
                        let freezeText = try await service.transcribe(audio: freezeSegment)
                        guard !Task.isCancelled else { break }
                        await self?.applyFreezeResult(freezeText, newFrozenEnd: snapshot.newFrozenEnd)
                    }

                    // Live inference — runs entirely off main actor
                    let liveText = try await service.transcribe(audio: snapshot.liveSegment)
                    guard !Task.isCancelled else { break }
                    await self?.applyLiveResult(liveText, processedCount: snapshot.bufferCount)
                } catch {
                    Self.log.error("Live transcription error: \(error)")
                }
            }
        }
    }

    private func stopRecordingAndTranscribe() async {
        state = .transcribing
        transcriptionProgress = 0
        audioLevelTask?.cancel()
        pendingChunks = []
        transcription = ""

        let samples = audioCaptureService.stopRecording()
        audioLevel = 0
        Self.log.debug("stopRecordingAndTranscribe: samples.count=\(samples.count)")

        guard !samples.isEmpty else {
            state = .ready
            return
        }

        guard let service = asrService else {
            state = .error("Kein Modell geladen")
            return
        }

        do {
            _ = try await Task.detached(priority: .userInitiated) { [weak self] in
                return try await service.transcribe(audio: samples,
                    onProgress: { progress in
                        await MainActor.run { self?.transcriptionProgress = progress }
                    },
                    onChunkResult: { text in
                        await MainActor.run {
                            guard let self else { return }
                            self.pendingChunks.append(text)
                            self.transcription = self.pendingChunks.joined(separator: " ")
                        }
                    }
                )
            }.value
            state = .ready
        } catch {
            state = .error("Transkription fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func importAndTranscribe(url: URL) async {
        state = .transcribing
        transcriptionProgress = 0
        Self.log.debug("importAndTranscribe: url=\(url.lastPathComponent)")

        guard let service = asrService else {
            state = .error("Kein Modell geladen")
            return
        }

        pendingChunks = []
        Self.log.debug("importAndTranscribe: pendingChunks reset, starting transcription")
        do {
            _ = try await Task.detached(priority: .userInitiated) { [weak self] in
                let samples = try AudioFileService.loadAudioFile(url: url)
                Self.log.debug("importAndTranscribe: loaded \(samples.count) samples")
                return try await service.transcribe(audio: samples,
                    onProgress: { progress in
                        await MainActor.run {
                            Self.log.debug("onProgress: \(progress)")
                            self?.transcriptionProgress = progress
                        }
                    },
                    onChunkResult: { text in
                        await MainActor.run {
                            guard let self else {
                                Self.log.error("onChunkResult: self is nil!")
                                return
                            }
                            self.pendingChunks.append(text)
                            let joined = self.pendingChunks.joined(separator: " ")
                            Self.log.debug("onChunkResult: pendingChunks.count=\(self.pendingChunks.count), newChunk=\"\(text.prefix(80))\", transcription=\"\(joined.prefix(120))\"")
                            self.transcription = joined
                        }
                    }
                )
            }.value
            Self.log.debug("importAndTranscribe: .value returned, transcription=\"\(self.transcription.prefix(120))\"")
            state = .ready
        } catch {
            state = .error("Import fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func clearTranscription() {
        transcription = ""
        frozenTranscription = ""
        frozenSampleCount = 0
        lastTranscribedSampleCount = 0
        if case .error = state, asrService != nil {
            state = .ready
        }
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
