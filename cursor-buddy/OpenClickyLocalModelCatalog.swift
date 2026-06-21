import Foundation

enum OpenClickyLocalModelUseCase: String, CaseIterable, Codable, Equatable, Sendable {
    case smallest
    case general
    case vision

    var label: String {
        switch self {
        case .smallest:
            return "Smallest"
        case .general:
            return "General"
        case .vision:
            return "Vision"
        }
    }
}

enum OpenClickyLocalModelRuntimeRequirement: Equatable, Sendable {
    case externalOpenAICompatibleServer

    var label: String {
        switch self {
        case .externalOpenAICompatibleServer:
            return "External local server required"
        }
    }

    var detail: String {
        switch self {
        case .externalOpenAICompatibleServer:
            return "OpenClicky can install this MLX bundle, but Agent Mode still needs a separate OpenAI-compatible local vMLX/MLX server to run it."
        }
    }
}

struct OpenClickyLocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    let useCase: OpenClickyLocalModelUseCase
    let modelType: String?
    let releasedAt: String?
    let estimatedDownloadBytes: Int64?
    let minimumRecommendedMemoryGB: Int?
    let isRecommended: Bool
    let runtimeRequirement: OpenClickyLocalModelRuntimeRequirement

    init(
        id: String,
        name: String,
        description: String,
        useCase: OpenClickyLocalModelUseCase,
        modelType: String? = nil,
        releasedAt: String? = nil,
        estimatedDownloadBytes: Int64? = nil,
        minimumRecommendedMemoryGB: Int? = nil,
        isRecommended: Bool = false,
        runtimeRequirement: OpenClickyLocalModelRuntimeRequirement = .externalOpenAICompatibleServer
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.useCase = useCase
        self.modelType = modelType
        self.releasedAt = releasedAt
        self.estimatedDownloadBytes = estimatedDownloadBytes
        self.minimumRecommendedMemoryGB = minimumRecommendedMemoryGB
        self.isRecommended = isRecommended
        self.runtimeRequirement = runtimeRequirement
    }

    var huggingFaceURL: URL {
        URL(string: "https://huggingface.co/\(id)")!
    }

    var localDirectory: URL {
        OpenClickyLocalModelStore.localDirectory(for: id)
    }

    var formattedEstimatedDownloadSize: String? {
        guard let estimatedDownloadBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: estimatedDownloadBytes, countStyle: .file)
    }
}

enum OpenClickyLocalModelCatalog {
    /// Installable bundles sourced from Osaurus' MLX/vMLX catalog. Keeping
    /// this catalog separate from OpenClicky's selectable model catalog avoids
    /// promising local Agent Mode inference before the runtime server exists.
    static let models: [OpenClickyLocalModel] = [
        OpenClickyLocalModel(
            id: "OsaurusAI/gemma-4-E2B-it-qat-MXFP4",
            name: "Gemma 4 E2B QAT MXFP4",
            description: "Smallest Gemma 4 QAT multimodal bundle for Apple Silicon installs.",
            useCase: .smallest,
            modelType: "gemma4",
            releasedAt: "2026-06-09",
            estimatedDownloadBytes: 4_034_648_904,
            minimumRecommendedMemoryGB: 8,
            isRecommended: true
        ),
        OpenClickyLocalModel(
            id: "OsaurusAI/gemma-4-E4B-it-qat-MXFP4",
            name: "Gemma 4 E4B QAT MXFP4",
            description: "Compact Gemma 4 QAT multimodal bundle for broader local vision-capable installs on Apple Silicon.",
            useCase: .vision,
            modelType: "gemma4",
            releasedAt: "2026-06-09",
            estimatedDownloadBytes: 5_939_858_062,
            minimumRecommendedMemoryGB: 12,
            isRecommended: true
        ),
        OpenClickyLocalModel(
            id: "OsaurusAI/gemma-4-12B-it-qat-MXFP4",
            name: "Gemma 4 12B QAT MXFP4",
            description: "Mainstream Gemma 4 QAT multimodal bundle for 16 GB and larger Macs.",
            useCase: .vision,
            modelType: "gemma4_unified",
            releasedAt: "2026-06-09",
            estimatedDownloadBytes: 7_942_459_418,
            minimumRecommendedMemoryGB: 16,
            isRecommended: true
        ),
        OpenClickyLocalModel(
            id: "OsaurusAI/LFM2.5-8B-A1B-MXFP8",
            name: "LFM2.5 8B A1B MXFP8",
            description: "Liquid AI hybrid MoE bundle for fast general local chat on Apple Silicon.",
            useCase: .general,
            modelType: "lfm2_moe",
            releasedAt: "2026-05-29",
            estimatedDownloadBytes: 8_750_686_392,
            minimumRecommendedMemoryGB: 16,
            isRecommended: true
        ),
        OpenClickyLocalModel(
            id: "OsaurusAI/Qwen3.6-27B-MXFP4",
            name: "Qwen 3.6 27B MXFP4",
            description: "Larger Qwen 3.6 vision bundle for high-quality local installs on higher-memory Macs.",
            useCase: .vision,
            modelType: "qwen3_5",
            releasedAt: "2026-05-20",
            estimatedDownloadBytes: 15_234_047_427,
            minimumRecommendedMemoryGB: 32,
            isRecommended: false
        )
    ]

    static func model(withID modelID: String) -> OpenClickyLocalModel? {
        models.first { $0.id.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    static var recommendedModels: [OpenClickyLocalModel] {
        models.filter(\.isRecommended)
    }
}
