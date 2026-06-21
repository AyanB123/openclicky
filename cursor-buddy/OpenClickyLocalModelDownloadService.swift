import Combine
import Foundation

enum OpenClickyLocalModelDownloadPhase: Equatable, Sendable {
    case notStarted
    case resolvingManifest
    case downloading(progress: Double)
    case verifying
    case completed
    case cancelled
    case failed(String)

    var label: String {
        switch self {
        case .notStarted:
            return "Not started"
        case .resolvingManifest:
            return "Checking files"
        case .downloading:
            return "Downloading"
        case .verifying:
            return "Verifying"
        case .completed:
            return "Installed"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
}

struct OpenClickyLocalModelDownloadMetrics: Equatable, Sendable {
    let bytesReceived: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let etaSeconds: Double?
    let currentFilePath: String?
    let completedFiles: Int
    let totalFiles: Int

    var formattedLine: String {
        var parts: [String] = []
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        if let totalBytes, totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            parts.append("\(received) / \(total)")
        } else {
            parts.append(received)
        }

        if let bytesPerSecond, bytesPerSecond > 0 {
            let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
            parts.append("\(speed)/s")
        }

        if let etaSeconds, etaSeconds.isFinite, etaSeconds > 0 {
            parts.append("ETA \(Self.formatETA(seconds: etaSeconds))")
        }

        if totalFiles > 0 {
            parts.append("\(completedFiles)/\(totalFiles) files")
        }

        return parts.joined(separator: " - ")
    }

    private static func formatETA(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct OpenClickyLocalModelDownloadState: Equatable, Sendable {
    let modelID: String
    let phase: OpenClickyLocalModelDownloadPhase
    let metrics: OpenClickyLocalModelDownloadMetrics?
    let updatedAt: Date
}

struct OpenClickyLocalModelDownloadFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let modelID: String
    let stage: String
    let message: String
    let filePath: String?

    var diagnosticLine: String {
        var parts = ["model=\(modelID)", "stage=\(stage)"]
        if let filePath { parts.append("file=\(filePath)") }
        parts.append("message=\(message)")
        return parts.joined(separator: " | ")
    }
}

@MainActor
final class OpenClickyLocalModelDownloadService: ObservableObject {
    static let shared = OpenClickyLocalModelDownloadService()

    @Published private(set) var downloadStates: [String: OpenClickyLocalModelDownloadState] = [:]
    @Published private(set) var installStatuses: [String: OpenClickyLocalModelStatus] = [:]
    @Published private(set) var lastFailure: OpenClickyLocalModelDownloadFailure?

    private let fileManager: FileManager
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloaders: [String: OpenClickyLocalModelFileDownloader] = [:]
    private var activeDownloadTokens: [String: UUID] = [:]
    private var downloadStartedAt: [String: Date] = [:]

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        refreshAllStatuses()
    }

    func refreshAllStatuses() {
        for model in OpenClickyLocalModelCatalog.models {
            refreshStatus(for: model)
        }
    }

    func refreshStatus(for model: OpenClickyLocalModel) {
        installStatuses[model.id] = OpenClickyLocalModelStore.status(for: model, fileManager: fileManager)
    }

    func state(for modelID: String) -> OpenClickyLocalModelDownloadState {
        downloadStates[modelID] ?? OpenClickyLocalModelDownloadState(
            modelID: modelID,
            phase: .notStarted,
            metrics: nil,
            updatedAt: Date()
        )
    }

    func status(for model: OpenClickyLocalModel) -> OpenClickyLocalModelStatus {
        if let status = installStatuses[model.id] {
            return status
        }
        let status = OpenClickyLocalModelStore.status(for: model, fileManager: fileManager)
        installStatuses[model.id] = status
        return status
    }

    func download(_ model: OpenClickyLocalModel) {
        if activeTasks[model.id] != nil { return }

        let downloadToken = UUID()
        lastFailure = nil
        activeDownloadTokens[model.id] = downloadToken
        downloadStartedAt[model.id] = Date()
        setState(modelID: model.id, phase: .resolvingManifest, metrics: nil, token: downloadToken)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(model, token: downloadToken)
        }
        activeTasks[model.id] = task
    }

    func cancel(modelID: String) {
        activeDownloadTokens.removeValue(forKey: modelID)
        activeTasks[modelID]?.cancel()
        activeDownloaders[modelID]?.cancel()
        activeTasks[modelID] = nil
        activeDownloaders[modelID] = nil
        downloadStartedAt[modelID] = nil
        setState(modelID: modelID, phase: .cancelled, metrics: downloadStates[modelID]?.metrics)
    }

    private func runDownload(_ model: OpenClickyLocalModel, token: UUID) async {
        let modelID = model.id
        let localDirectory = model.localDirectory

        defer {
            activeTasks[modelID] = nil
            activeDownloaders[modelID] = nil
            if activeDownloadTokens[modelID] == token {
                activeDownloadTokens[modelID] = nil
            }
            downloadStartedAt[modelID] = nil
            if installStatuses[modelID]?.state.isVerifiedInstalled != true {
                refreshStatus(for: model)
            }
        }

        do {
            try await createDirectory(localDirectory)
            let manifest = try await Self.fetchDownloadManifest(repoID: modelID)
            try Task.checkCancellation()

            let totalBytes = manifest.reduce(Int64(0)) { $0 + $1.size }
            var completedBytes: Int64 = 0
            var filesToDownload: [OpenClickyLocalModelRemoteFile] = []

            for file in manifest {
                guard let destination = OpenClickyLocalModelStore.destinationURL(forRemotePath: file.path, under: localDirectory) else {
                    continue
                }
                let attrs = try? fileManager.attributesOfItem(atPath: destination.path)
                let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if existingSize == file.size {
                    completedBytes += file.size
                } else {
                    filesToDownload.append(file)
                }
            }

            try preflightStorage(bytesNeeded: totalBytes - completedBytes, directory: localDirectory)
            updateProgress(
                modelID: modelID,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                currentFilePath: nil,
                completedFiles: manifest.count - filesToDownload.count,
                totalFiles: manifest.count,
                token: token
            )

            for (offset, file) in filesToDownload.enumerated() {
                try Task.checkCancellation()
                guard let destination = OpenClickyLocalModelStore.destinationURL(forRemotePath: file.path, under: localDirectory),
                      let sourceURL = Self.resolveURL(repoID: modelID, path: file.path)
                else {
                    continue
                }

                let completedBeforeFile = completedBytes
                let downloader = OpenClickyLocalModelFileDownloader()
                activeDownloaders[modelID] = downloader

                try await downloader.download(
                    from: sourceURL,
                    to: destination,
                    expectedSize: file.size
                ) { [weak self] bytesWritten, _ in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(
                            modelID: modelID,
                            completedBytes: completedBeforeFile + bytesWritten,
                            totalBytes: totalBytes,
                            currentFilePath: file.path,
                            completedFiles: manifest.count - filesToDownload.count + offset,
                            totalFiles: manifest.count,
                            token: token
                        )
                    }
                }

                completedBytes += file.size
                updateProgress(
                    modelID: modelID,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentFilePath: nil,
                    completedFiles: manifest.count - filesToDownload.count + offset + 1,
                    totalFiles: manifest.count,
                    token: token
                )
            }

            setState(modelID: modelID, phase: .verifying, metrics: downloadStates[modelID]?.metrics, token: token)
            let missingFiles = OpenClickyLocalModelStore.missingDownloadedFiles(from: manifest, under: localDirectory, fileManager: fileManager)
            guard missingFiles.isEmpty else {
                throw DownloadError(stage: "completion-check", message: "Download incomplete: \(missingFiles.count) file(s) are missing or have the wrong size.", filePath: missingFiles.first)
            }

            let status = OpenClickyLocalModelStore.verifiedStatus(
                for: model,
                manifest: manifest,
                fileManager: fileManager
            )
            installStatuses[modelID] = status
            guard status.state.isVerifiedInstalled else {
                throw DownloadError(stage: "bundle-check", message: "Downloaded files do not form a complete MLX bundle.", filePath: nil)
            }

            setState(modelID: modelID, phase: .completed, metrics: downloadStates[modelID]?.metrics, token: token)
        } catch is CancellationError {
            setState(modelID: modelID, phase: .cancelled, metrics: downloadStates[modelID]?.metrics, token: token)
        } catch let error as URLError where error.code == .cancelled {
            setState(modelID: modelID, phase: .cancelled, metrics: downloadStates[modelID]?.metrics, token: token)
        } catch let error as DownloadError {
            recordFailure(modelID: modelID, failure: error, token: token)
        } catch {
            recordFailure(
                modelID: modelID,
                failure: DownloadError(stage: "download", message: error.localizedDescription, filePath: nil),
                token: token
            )
        }
    }

    private func setState(
        modelID: String,
        phase: OpenClickyLocalModelDownloadPhase,
        metrics: OpenClickyLocalModelDownloadMetrics?,
        token: UUID? = nil
    ) {
        if let token, activeDownloadTokens[modelID] != token {
            return
        }
        downloadStates[modelID] = OpenClickyLocalModelDownloadState(
            modelID: modelID,
            phase: phase,
            metrics: metrics,
            updatedAt: Date()
        )
    }

    private func updateProgress(
        modelID: String,
        completedBytes: Int64,
        totalBytes: Int64,
        currentFilePath: String?,
        completedFiles: Int,
        totalFiles: Int,
        token: UUID
    ) {
        guard activeDownloadTokens[modelID] == token else { return }
        let startedAt = downloadStartedAt[modelID] ?? Date()
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        let speed = Double(completedBytes) / elapsed
        let remaining = max(0, totalBytes - completedBytes)
        let eta = speed > 0 ? Double(remaining) / speed : nil
        let progress = totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
        let metrics = OpenClickyLocalModelDownloadMetrics(
            bytesReceived: completedBytes,
            totalBytes: totalBytes,
            bytesPerSecond: speed,
            etaSeconds: eta,
            currentFilePath: currentFilePath,
            completedFiles: completedFiles,
            totalFiles: totalFiles
        )
        setState(modelID: modelID, phase: .downloading(progress: progress), metrics: metrics, token: token)
    }

    private func recordFailure(modelID: String, failure: DownloadError, token: UUID) {
        guard activeDownloadTokens[modelID] == token else { return }
        let publicFailure = OpenClickyLocalModelDownloadFailure(
            modelID: modelID,
            stage: failure.stage,
            message: failure.message,
            filePath: failure.filePath
        )
        lastFailure = publicFailure
        setState(modelID: modelID, phase: .failed(failure.message), metrics: downloadStates[modelID]?.metrics, token: token)
    }

    private func createDirectory(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }.value
    }

    private func preflightStorage(bytesNeeded: Int64, directory: URL) throws {
        guard bytesNeeded > 0,
              let freeBytes = Self.availableBytes(onVolumeContaining: directory),
              bytesNeeded + Self.storageSafetyMarginBytes > freeBytes
        else {
            return
        }
        let needed = ByteCountFormatter.string(fromByteCount: bytesNeeded, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        throw DownloadError(
            stage: "preflight",
            message: "Not enough disk space to finish this download: need \(needed) free, only \(free) available.",
            filePath: nil
        )
    }

    private static let storageSafetyMarginBytes: Int64 = 256 * 1024 * 1024

    private static func availableBytes(onVolumeContaining url: URL) -> Int64? {
        var current = url
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }

        guard let values = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return capacity
    }

    private struct DownloadError: Error {
        let stage: String
        let message: String
        let filePath: String?
    }

    private struct HuggingFaceTreeNode: Decodable {
        struct LFS: Decodable {
            let size: Int64?
        }

        let path: String
        let type: String?
        let size: Int64?
        let lfs: LFS?

        var bestSize: Int64 {
            size ?? lfs?.size ?? 0
        }
    }

    private static func fetchDownloadManifest(repoID: String) async throws -> [OpenClickyLocalModelRemoteFile] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/\(repoID)/tree/main"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components.url else {
            throw DownloadError(stage: "manifest-url", message: "Could not build Hugging Face manifest URL.", filePath: nil)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError(stage: "fetch-manifest", message: "Hugging Face returned a non-HTTP response.", filePath: nil)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw DownloadError(stage: "fetch-manifest", message: "Hugging Face returned HTTP \(http.statusCode).", filePath: nil)
        }

        let nodes = try JSONDecoder().decode([HuggingFaceTreeNode].self, from: data)
        let files = nodes.compactMap { node -> OpenClickyLocalModelRemoteFile? in
            if node.type == "directory" { return nil }
            guard node.bestSize > 0,
                  let safePath = OpenClickyLocalModelStore.normalizedRemoteFilePath(node.path),
                  OpenClickyLocalModelStore.shouldDownloadRemoteFile(path: safePath)
            else {
                return nil
            }
            return OpenClickyLocalModelRemoteFile(path: safePath, size: node.bestSize)
        }

        guard !files.isEmpty else {
            throw DownloadError(stage: "fetch-manifest", message: "No downloadable MLX files were found in this Hugging Face repository.", filePath: nil)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func resolveURL(repoID: String, path: String) -> URL? {
        guard let safePath = OpenClickyLocalModelStore.normalizedRemoteFilePath(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoID)/resolve/main/\(safePath)"
        return components.url
    }
}

private final class OpenClickyLocalModelFileDownloader: NSObject, URLSessionDownloadDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var expectedSize: Int64?
    private var progress: (@Sendable (Int64, Int64) -> Void)?
    private var lastProgressTime: CFAbsoluteTime = 0
    private static let progressInterval: CFAbsoluteTime = 0.25

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    func download(
        from url: URL,
        to destination: URL,
        expectedSize: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            self.destination = destination
            self.expectedSize = expectedSize
            self.progress = onProgress
            self.lastProgressTime = 0
            let task = session.downloadTask(with: url)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let elapsed = now - lastProgressTime
        let complete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard elapsed >= Self.progressInterval || complete else {
            lock.unlock()
            return
        }
        lastProgressTime = now
        let progress = self.progress
        lock.unlock()
        progress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let continuation = self.continuation
        let destination = self.destination
        let expectedSize = self.expectedSize
        clearLocked()
        lock.unlock()

        guard let continuation, let destination else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200 ..< 300).contains(http.statusCode) {
            continuation.resume(
                throwing: URLError(
                    .badServerResponse,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]
                )
            )
            return
        }

        do {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            if let expectedSize, expectedSize > 0 {
                let attrs = try fileManager.attributesOfItem(atPath: destination.path)
                let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard actualSize == expectedSize else {
                    try? fileManager.removeItem(at: destination)
                    continuation.resume(
                        throwing: URLError(
                            .cannotDecodeContentData,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Size mismatch: expected \(expectedSize), got \(actualSize)"
                            ]
                        )
                    )
                    return
                }
            }
            continuation.resume()
        } catch {
            continuation.resume(throwing: error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let continuation = self.continuation
        clearLocked()
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    private func clearLocked() {
        continuation = nil
        task = nil
        destination = nil
        expectedSize = nil
        progress = nil
    }

    deinit {
        session.invalidateAndCancel()
    }
}
