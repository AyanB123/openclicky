import Foundation

nonisolated struct OpenClickyLocalSpeechModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String
    let detail: String
    let sizeDescription: String
    let isRecommended: Bool
}

nonisolated struct OpenClickyLocalBrainModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let subtitle: String
    let detail: String
    let isRecommended: Bool
}

nonisolated enum OpenClickyLocalRuntimeCatalog {
    static let defaultSpeechModelID = "parakeet-tdt-v3"
    static let defaultBrainModelID = "validated-local-catalog"

    static let speechModels: [OpenClickyLocalSpeechModelOption] = [
        OpenClickyLocalSpeechModelOption(
            id: "parakeet-tdt-v3",
            label: "Parakeet TDT v3",
            subtitle: "Local multilingual STT",
            detail: "Recommended local speech target from the Osaurus intake: on-device FluidAudio transcription for most users.",
            sizeDescription: "~600 MB",
            isRecommended: true
        ),
        OpenClickyLocalSpeechModelOption(
            id: "parakeet-tdt-v2",
            label: "Parakeet TDT v2",
            subtitle: "Local English STT",
            detail: "English-focused alternate with higher recall for English-only dictation.",
            sizeDescription: "~600 MB",
            isRecommended: false
        )
    ]

    static let brainModels: [OpenClickyLocalBrainModelOption] = [
        OpenClickyLocalBrainModelOption(
            id: "validated-local-catalog",
            label: "OpenClicky local pick",
            subtitle: "Validate before install",
            detail: "Use a curated local MLX/vMLX model only after OpenClicky validates the current catalog and hardware fit.",
            isRecommended: true
        ),
        OpenClickyLocalBrainModelOption(
            id: "bring-local-endpoint",
            label: "Local endpoint",
            subtitle: "OpenAI-compatible",
            detail: "Use a local server such as LM Studio, Ollama, llama.cpp, or vLLM through Advanced Providers.",
            isRecommended: false
        )
    ]

    static func speechModel(withID modelID: String?) -> OpenClickyLocalSpeechModelOption {
        if let modelID, let match = speechModels.first(where: { $0.id == modelID }) {
            return match
        }
        return speechModels.first { $0.id == defaultSpeechModelID } ?? speechModels[0]
    }

    static func brainModel(withID modelID: String?) -> OpenClickyLocalBrainModelOption {
        if let modelID, let match = brainModels.first(where: { $0.id == modelID }) {
            return match
        }
        return brainModels.first { $0.id == defaultBrainModelID } ?? brainModels[0]
    }

    static func fluidAudioModelCacheDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    }

    static func hasFluidAudioModelCache(fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let directory = fluidAudioModelCacheDirectory(fileManager: fileManager)
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let children = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return children.contains { !$0.hasPrefix(".") }
    }
}
