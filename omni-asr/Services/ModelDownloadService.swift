import Foundation
import os

/// Downloads CoreML models from HuggingFace and manages local storage.
@Observable
@MainActor
final class ModelDownloadService {
    private static let log = Logger(subsystem: "omni-asr", category: "ModelDownloadService")

    enum DownloadState: Equatable {
        case idle
        case downloading(progress: Double)
        case failed(String)
    }

    /// Per-model download state, keyed by model ID.
    var downloadStates: [String: DownloadState] = [:]

    private static let repoBaseURL = "https://huggingface.co/ChipCracker/omni-asr-coreml/resolve/main"

    let modelsDirectory: URL
    private var activeDownloadTask: Task<Void, any Error>?
    private let downloader = FileDownloader()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        modelsDirectory = appSupport.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Remote Registry

    /// Fetch model_info.json from HuggingFace.
    func fetchRemoteModelInfo() async throws -> [CoreMLASRService.ModelInfo] {
        let url = URL(string: "\(Self.repoBaseURL)/model_info.json")!
        Self.log.debug("Fetching remote model info from \(url)")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.fetchFailed
        }
        let localCache = modelsDirectory.appendingPathComponent("model_info.json")
        try? data.write(to: localCache)

        return try JSONDecoder().decode([CoreMLASRService.ModelInfo].self, from: data)
    }

    // MARK: - Download

    /// Download all files for a model from HuggingFace.
    func downloadModel(_ model: CoreMLASRService.ModelInfo) async throws {
        guard let files = model.files, !files.isEmpty else {
            throw DownloadError.noFilesSpecified
        }

        downloadStates[model.id] = .downloading(progress: 0)

        let totalSize = model.downloadSize ?? 0
        var downloadedBytes: Int64 = 0

        do {
            for relativePath in files {
                try Task.checkCancellation()

                guard let remoteURL = URL(string: "\(Self.repoBaseURL)/\(relativePath)") else {
                    continue
                }
                let localURL = modelsDirectory.appendingPathComponent(relativePath)

                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                Self.log.debug("Downloading \(relativePath)")

                let completedBefore = downloadedBytes
                let modelId = model.id

                // Download runs on URLSession's queue; progress callback dispatches to main actor
                let tempURL = try await downloader.download(from: remoteURL) { [weak self] bytesWritten, _ in
                    guard totalSize > 0 else { return }
                    let overall = Double(completedBefore + bytesWritten) / Double(totalSize)
                    Task { @MainActor in
                        self?.downloadStates[modelId] = .downloading(progress: min(overall, 1.0))
                    }
                }

                try Task.checkCancellation()

                let fm = FileManager.default
                if fm.fileExists(atPath: localURL.path) {
                    try fm.removeItem(at: localURL)
                }
                try fm.moveItem(at: tempURL, to: localURL)

                let fileSize = (try? fm.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
                downloadedBytes += fileSize
            }

            // Download vocabulary if not present
            let vocabURL = modelsDirectory.appendingPathComponent(model.vocabFile)
            if !FileManager.default.fileExists(atPath: vocabURL.path) {
                Self.log.debug("Downloading shared vocabulary")
                guard let remoteVocab = URL(string: "\(Self.repoBaseURL)/\(model.vocabFile)") else {
                    throw DownloadError.httpError(model.vocabFile)
                }
                let (vocabData, _) = try await URLSession.shared.data(from: remoteVocab)
                try vocabData.write(to: vocabURL)
            }

            downloadStates[model.id] = .idle
            Self.log.info("Download complete: \(model.id)")
        } catch is CancellationError {
            downloadStates[model.id] = .idle
            cleanupPartialDownload(modelId: model.id)
            Self.log.info("Download cancelled: \(model.id)")
        } catch {
            downloadStates[model.id] = .failed(error.localizedDescription)
            cleanupPartialDownload(modelId: model.id)
            throw error
        }
    }

    /// Cancel an active download.
    func cancelDownload(_ modelId: String) {
        downloader.cancelActiveTask()
        downloadStates[modelId] = .idle
        cleanupPartialDownload(modelId: modelId)
    }

    private func cleanupPartialDownload(modelId: String) {
        let modelDir = modelsDirectory.appendingPathComponent("\(modelId).mlmodelc")
        try? FileManager.default.removeItem(at: modelDir)
    }

    // MARK: - Local Model Management

    func isModelDownloaded(_ modelId: String) -> Bool {
        let modelDir = modelsDirectory.appendingPathComponent("\(modelId).mlmodelc")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    func deleteModel(_ modelId: String) throws {
        let modelDir = modelsDirectory.appendingPathComponent("\(modelId).mlmodelc")
        guard FileManager.default.fileExists(atPath: modelDir.path) else { return }
        try FileManager.default.removeItem(at: modelDir)
        Self.log.info("Deleted model: \(modelId)")
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    enum DownloadError: Error, LocalizedError {
        case fetchFailed
        case noFilesSpecified
        case httpError(String)

        var errorDescription: String? {
            switch self {
            case .fetchFailed: "Modell-Registry konnte nicht geladen werden"
            case .noFilesSpecified: "Keine Dateien für Download spezifiziert"
            case .httpError(let file): "Download fehlgeschlagen: \(file)"
            }
        }
    }
}

// MARK: - File Downloader

/// URLSession-delegate-based downloader with reliable progress callbacks.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var session: URLSession!
    private var activeTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, any Error>?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock {
                self.continuation = cont
                self.onProgress = onProgress
                let task = session.downloadTask(with: url)
                self.activeTask = task
                task.resume()
            }
        }
    }

    func cancelActiveTask() {
        lock.withLock {
            activeTask?.cancel()
            activeTask = nil
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let handler = lock.withLock { onProgress }
        handler?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            finish(with: .success(tempURL))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<URL, any Error>) {
        let cont = lock.withLock {
            let c = continuation
            continuation = nil
            activeTask = nil
            onProgress = nil
            return c
        }
        switch result {
        case .success(let url): cont?.resume(returning: url)
        case .failure(let err): cont?.resume(throwing: err)
        }
    }
}
