import Foundation

enum OpenClickyLocalModelBundleRequirement: String, CaseIterable, Equatable, Sendable {
    case config
    case tokenizer
    case weights

    var label: String {
        switch self {
        case .config:
            return "config.json"
        case .tokenizer:
            return "tokenizer assets"
        case .weights:
            return "safetensors weights"
        }
    }
}

enum OpenClickyLocalModelInstallState: Equatable, Sendable {
    case notInstalled
    case partial(missing: [OpenClickyLocalModelBundleRequirement])
    case present
    case verified

    var isInstalled: Bool {
        switch self {
        case .present, .verified:
            return true
        case .notInstalled, .partial:
            return false
        }
    }

    var isVerifiedInstalled: Bool {
        if case .verified = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .partial:
            return "Incomplete"
        case .present:
            return "Looks present"
        case .verified:
            return "Installed"
        }
    }
}

struct OpenClickyLocalModelStatus: Equatable, Sendable {
    let modelID: String
    let localDirectory: URL
    let state: OpenClickyLocalModelInstallState
    let bytesOnDisk: Int64
    let checkedAt: Date
    let runtimeRequirement: OpenClickyLocalModelRuntimeRequirement

    var formattedBytesOnDisk: String {
        ByteCountFormatter.string(fromByteCount: bytesOnDisk, countStyle: .file)
    }
}

struct OpenClickyLocalModelRuntimeReadiness: Equatable, Sendable {
    let canSelectInstalledModelsInAgentMode: Bool
    let blockers: [String]
    let nextImplementationSteps: [String]

    static let current = OpenClickyLocalModelRuntimeReadiness(
        canSelectInstalledModelsInAgentMode: false,
        blockers: [
            "OpenClicky does not bundle a vMLX/MLX inference runtime.",
            "OpenClicky does not launch or supervise a local OpenAI-compatible model server.",
            "ClickyCodexConfigTemplate can point Codex at a custom OpenAI-compatible endpoint, but no local endpoint/model binding is wired for installed MLX bundles yet."
        ],
        nextImplementationSteps: [
            "Add a runtime bridge that can discover, launch, health-check, and stop a local OpenAI-compatible vMLX/MLX server.",
            "Map an installed bundle path to that server's model identifier and expose only health-checked models in OpenClicky's selectable Agent Mode model catalog.",
            "Update Codex config generation to route local selections to the local server endpoint with a truthful failure state when the server is unavailable."
        ]
    )
}

struct OpenClickyLocalModelRemoteFile: Equatable, Sendable {
    let path: String
    let size: Int64
}

enum OpenClickyLocalModelStore {
    static let openClickyModelsDirectoryEnvironmentKey = "OPENCLICKY_LOCAL_MODELS_DIR"
    static let osaurusModelsDirectoryEnvironmentKey = "OSU_MODELS_DIR"

    static let downloadFilenameExtensions: Set<String> = [
        "json",
        "jinja",
        "txt",
        "model",
        "safetensors"
    ]

    static let excludedDownloadFilenames: Set<String> = [
        "README.md",
        ".gitattributes"
    ]

    static func modelsDirectory(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environmentDirectory(for: openClickyModelsDirectoryEnvironmentKey, environment: environment) {
            return override
        }
        if let override = environmentDirectory(for: osaurusModelsDirectoryEnvironmentKey, environment: environment) {
            return override
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let preferred = home.appendingPathComponent("MLXModels", isDirectory: true)
        let legacy = home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("MLXModels", isDirectory: true)

        if directoryHasVisibleContents(preferred, fileManager: fileManager) { return preferred }
        if directoryHasVisibleContents(legacy, fileManager: fileManager) { return legacy }
        if fileManager.fileExists(atPath: preferred.path) { return preferred }
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        return preferred
    }

    static func localDirectory(
        for modelID: String,
        rootDirectory: URL = modelsDirectory()
    ) -> URL {
        modelID
            .split(separator: "/")
            .map(String.init)
            .reduce(rootDirectory) { partial, component in
                partial.appendingPathComponent(component, isDirectory: true)
            }
    }

    static func status(
        for model: OpenClickyLocalModel,
        rootDirectory: URL = modelsDirectory(),
        fileManager: FileManager = .default,
        checkedAt: Date = Date()
    ) -> OpenClickyLocalModelStatus {
        let directory = localDirectory(for: model.id, rootDirectory: rootDirectory)
        let missing = missingRequirements(in: directory, fileManager: fileManager)
        let hasAnyModelFiles = directoryHasVisibleContents(directory, fileManager: fileManager)
        let state: OpenClickyLocalModelInstallState
        if missing.isEmpty {
            state = .present
        } else if hasAnyModelFiles {
            state = .partial(missing: missing)
        } else {
            state = .notInstalled
        }

        return OpenClickyLocalModelStatus(
            modelID: model.id,
            localDirectory: directory,
            state: state,
            bytesOnDisk: directoryAllocatedSize(at: directory, fileManager: fileManager),
            checkedAt: checkedAt,
            runtimeRequirement: model.runtimeRequirement
        )
    }

    static func verifiedStatus(
        for model: OpenClickyLocalModel,
        manifest: [OpenClickyLocalModelRemoteFile],
        rootDirectory: URL = modelsDirectory(),
        fileManager: FileManager = .default,
        checkedAt: Date = Date()
    ) -> OpenClickyLocalModelStatus {
        let baseStatus = status(
            for: model,
            rootDirectory: rootDirectory,
            fileManager: fileManager,
            checkedAt: checkedAt
        )
        let missingFiles = missingDownloadedFiles(
            from: manifest,
            under: baseStatus.localDirectory,
            fileManager: fileManager
        )

        guard missingFiles.isEmpty, baseStatus.state.isInstalled else {
            return baseStatus
        }

        return OpenClickyLocalModelStatus(
            modelID: baseStatus.modelID,
            localDirectory: baseStatus.localDirectory,
            state: .verified,
            bytesOnDisk: baseStatus.bytesOnDisk,
            checkedAt: checkedAt,
            runtimeRequirement: baseStatus.runtimeRequirement
        )
    }

    static func normalizedRemoteFilePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.contains("\\"),
              !path.contains("\0"),
              !(path as NSString).isAbsolutePath
        else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        var normalized: [String] = []
        for component in components {
            guard !component.isEmpty,
                  component != ".",
                  component != ".."
            else {
                return nil
            }
            normalized.append(String(component))
        }
        return normalized.joined(separator: "/")
    }

    static func destinationURL(forRemotePath path: String, under directory: URL) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        let base = directory.standardizedFileURL
        let destination = safePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component))
            }
            .standardizedFileURL

        guard isContained(destination, in: base),
              existingParentChainIsContained(for: destination, under: base)
        else {
            return nil
        }
        return destination
    }

    static func shouldDownloadRemoteFile(path: String) -> Bool {
        guard let safePath = normalizedRemoteFilePath(path) else { return false }
        let filename = (safePath as NSString).lastPathComponent
        if excludedDownloadFilenames.contains(filename) { return false }
        let ext = (filename as NSString).pathExtension.lowercased()
        return downloadFilenameExtensions.contains(ext)
    }

    static func missingDownloadedFiles(
        from manifest: [OpenClickyLocalModelRemoteFile],
        under directory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        manifest.compactMap { file in
            guard let destination = destinationURL(forRemotePath: file.path, under: directory) else {
                return file.path
            }
            let attrs = try? fileManager.attributesOfItem(atPath: destination.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return size == file.size ? nil : file.path
        }
    }

    private static func environmentDirectory(for key: String, environment: [String: String]) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func directoryHasVisibleContents(_ url: URL, fileManager: FileManager) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return !entries.isEmpty
    }

    private static func missingRequirements(
        in directory: URL,
        fileManager: FileManager
    ) -> [OpenClickyLocalModelBundleRequirement] {
        let topLevelNames = Set(
            (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        )

        var missing: [OpenClickyLocalModelBundleRequirement] = []
        if !topLevelNames.contains("config.json") {
            missing.append(.config)
        }

        let hasTokenizerJSON = topLevelNames.contains("tokenizer.json")
        let hasBPE = topLevelNames.contains("merges.txt")
            && (topLevelNames.contains("vocab.json") || topLevelNames.contains("vocab.txt"))
        let hasSentencePiece = topLevelNames.contains("tokenizer.model") || topLevelNames.contains("spiece.model")
        if !(hasTokenizerJSON || hasBPE || hasSentencePiece) {
            missing.append(.tokenizer)
        }

        if !hasSafetensorsWeights(in: directory, fileManager: fileManager) {
            missing.append(.weights)
        }

        return missing
    }

    private static func hasSafetensorsWeights(in directory: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "safetensors" {
                return true
            }
        }
        return false
    }

    private static func directoryAllocatedSize(at directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]),
                  values.isRegularFile == true
            else {
                continue
            }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    private static func isContained(_ url: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == basePath || path.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/")
    }

    private static func existingParentChainIsContained(for destination: URL, under base: URL) -> Bool {
        let fileManager = FileManager.default
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        var current = destination.deletingLastPathComponent().standardizedFileURL

        while current.pathComponents.count >= base.pathComponents.count {
            if fileManager.fileExists(atPath: current.path) {
                let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(resolved, in: resolvedBase) else { return false }
            }
            if current.path == base.path { return true }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }

        return isContained(current, in: base)
    }
}
