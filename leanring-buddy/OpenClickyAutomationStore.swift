//
//  OpenClickyAutomationStore.swift
//  OpenClicky
//
//  JSON-backed automation registry + a single 30-second tick scheduler.
//  Persists to ~/Library/Application Support/OpenClicky/automations.json.
//  Uses CompanionManager.submitAgentPromptFromUI(_:) to fire prompts;
//  routes through createAndSelectNewCodexAgentSession(asAgent:) when an
//  automation is bound to a specialist agent slug.
//

import Foundation
import Combine

@MainActor
final class OpenClickyAutomationStore: ObservableObject {
  static let shared = OpenClickyAutomationStore()
  static let skillDiscoveryAutomationName = "App skill discovery"

  static var skillDiscoverySuggestionsURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return appSupport
      .appendingPathComponent("OpenClicky", isDirectory: true)
      .appendingPathComponent("skill-discovery-suggestions.json", isDirectory: false)
  }

  static var skillDiscoveryAutomationPrompt: String {
    """
    OpenClicky scheduled skill discovery pass.

    Goal: find useful Agent Mode skills for the apps and workflows the user is actively using, then surface install/connect options in the OpenClicky Connect tab.

    Be efficient:
    1. Identify likely active apps/workflows from recent OpenClicky logs, current screen/window context if provided, and obvious local project folders. Do not scan huge folders blindly.
    2. Search local skills first under ~/Library/Application Support/OpenClicky/AgentMode/CodexHome/OpenClickyBundledSkills, ~/Library/Application Support/OpenClicky/AgentMode/CodexHome/OpenClickyLearnedSkills, ~/.codex/skills, ~/.agents/skills, ~/Documents/GitHub/*/skills, and any directly relevant repo skill folders. Prefer `find`/metadata over reading every large file.
    3. Only then do targeted web research for public skills or official app integrations that match those apps. Use current sources and avoid broad marketplace scraping.
    4. Recommend only practical, low-risk options that OpenClicky can install locally or connect through existing app/tool routes.

    Write a compact JSON array to:
    \(Self.skillDiscoverySuggestionsURL.path)

    Schema:
    [
      {
        "id": "stable-slug",
        "title": "Skill or integration name",
        "detail": "Why it matches the current apps/workflow",
        "source": "local|online|installed",
        "installPrompt": "Exact OpenClicky Agent Mode prompt to install or connect it"
      }
    ]

    Keep at most 8 suggestions, deduplicate installed skills, and prefer local matches over online ones.
    """
  }

  @Published private(set) var automations: [OpenClickyAutomation] = []

  private let storeURL: URL
  private var timer: Timer?
  private weak var companion: CompanionManager?

  private init() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let dir = appSupport.appendingPathComponent("OpenClicky", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.storeURL = dir.appendingPathComponent("automations.json")
    load()
    ensureSkillDiscoveryAutomationInstalled()
  }

  // MARK: lifecycle

  func bind(companion: CompanionManager) {
    self.companion = companion
    startTimer()
  }

  func startTimer() {
    timer?.invalidate()
    let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor [self] in
        self.tick()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  // MARK: CRUD

  func add(_ automation: OpenClickyAutomation) {
    var a = automation
    a.nextRun = a.computingNextRun(after: Date())
    automations.append(a)
    save()
  }

  func update(_ automation: OpenClickyAutomation) {
    guard let idx = automations.firstIndex(where: { $0.id == automation.id }) else { return }
    guard !isProtectedSystemAutomation(automations[idx]) else { return }
    var a = automation
    a.nextRun = a.computingNextRun(after: Date())
    automations[idx] = a
    save()
  }

  func remove(id: UUID) {
    automations.removeAll { $0.id == id && !isProtectedSystemAutomation($0) }
    save()
  }

  func setEnabled(id: UUID, enabled: Bool) {
    guard let idx = automations.firstIndex(where: { $0.id == id }) else { return }
    automations[idx].enabled = enabled
    automations[idx].nextRun = enabled ? automations[idx].computingNextRun(after: Date()) : nil
    save()
  }

  @discardableResult
  func ensureSkillDiscoveryAutomationInstalled() -> OpenClickyAutomation {
    _ = OpenClickyAgentStore.shared.ensureSkillDiscoveryAgentInstalled()

    if let idx = automations.firstIndex(where: { isProtectedSystemAutomation($0) || $0.name == Self.skillDiscoveryAutomationName }) {
      let existing = automations[idx]
      if existing.name != Self.skillDiscoveryAutomationName ||
          existing.prompt != Self.skillDiscoveryAutomationPrompt ||
          existing.agentSlug != OpenClickyAgentStore.skillDiscoveryAgentSlug {
        var repaired = existing
        repaired.name = Self.skillDiscoveryAutomationName
        repaired.prompt = Self.skillDiscoveryAutomationPrompt
        repaired.agentSlug = OpenClickyAgentStore.skillDiscoveryAgentSlug
        repaired.nextRun = repaired.enabled ? repaired.computingNextRun(after: Date()) : nil
        automations[idx] = repaired
        save()
        return repaired
      }
      return existing
    }

    let automation = OpenClickyAutomation(
      name: Self.skillDiscoveryAutomationName,
      schedule: .interval(seconds: 6 * 60 * 60),
      prompt: Self.skillDiscoveryAutomationPrompt,
      agentSlug: OpenClickyAgentStore.skillDiscoveryAgentSlug,
      enabled: true
    )
    add(automation)
    return automation
  }

  var skillDiscoveryAutomation: OpenClickyAutomation? {
    automations.first(where: { isProtectedSystemAutomation($0) })
  }

  func isProtectedSystemAutomation(_ automation: OpenClickyAutomation) -> Bool {
    automation.name == Self.skillDiscoveryAutomationName || automation.agentSlug == OpenClickyAgentStore.skillDiscoveryAgentSlug
  }

  // MARK: tick

  private func tick() {
    let now = Date()
    var didMutate = false
    for i in automations.indices {
      guard automations[i].enabled else { continue }
      if let next = automations[i].nextRun, next <= now {
        fire(automation: automations[i])
        automations[i].lastRun = now
        automations[i].nextRun = automations[i].computingNextRun(after: now)
        didMutate = true
      } else if automations[i].nextRun == nil {
        automations[i].nextRun = automations[i].computingNextRun(after: now)
        didMutate = true
      }
    }
    if didMutate { save() }
  }

  private func fire(automation: OpenClickyAutomation) {
    guard let companion else { return }
    let prompt = automation.prompt
    if let slug = automation.agentSlug, let agent = OpenClickyAgentStore.shared.agent(slug: slug) {
      let session = companion.createAndSelectNewCodexAgentSession(asAgent: agent)
      session.submitPromptFromUI(prompt, screenContext: nil)
    } else {
      companion.submitAgentPromptFromUI(prompt)
    }
  }

  // MARK: persistence

  private func load() {
    guard let data = try? Data(contentsOf: storeURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let list = try? decoder.decode([OpenClickyAutomation].self, from: data) {
      self.automations = list
    }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
      let data = try encoder.encode(automations)
      try data.write(to: storeURL, options: [.atomic])
    } catch {
      print("automation save failed: \(error)")
    }
  }
}

struct OpenClickySkillDiscoverySuggestion: Codable, Identifiable, Equatable {
  var id: String
  var title: String
  var detail: String
  var source: String
  var installPrompt: String

  var sourceLabel: String {
    switch source.lowercased() {
    case "local": return "Local"
    case "installed": return "Installed"
    case "online": return "Online"
    default: return source.isEmpty ? "Suggested" : source.capitalized
    }
  }
}

@MainActor
final class OpenClickySkillDiscoveryStore: ObservableObject {
  static let shared = OpenClickySkillDiscoveryStore()

  @Published private(set) var suggestions: [OpenClickySkillDiscoverySuggestion] = []

  private let storeURL = OpenClickyAutomationStore.skillDiscoverySuggestionsURL

  private init() {
    reload()
  }

  func reload() {
    guard let data = try? Data(contentsOf: storeURL) else {
      suggestions = []
      return
    }
    if let decoded = try? JSONDecoder().decode([OpenClickySkillDiscoverySuggestion].self, from: data) {
      suggestions = Array(decoded.prefix(8))
    }
  }
}
