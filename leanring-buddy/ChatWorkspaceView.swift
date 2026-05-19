//
//  ChatWorkspaceView.swift
//  OpenClicky
//
//  Three-pane composer: collapsible-to-zero conversation sidebar | chat
//  pane (header bar + embedded CodexHUDView body, no inner header/composer)
//  + ChatGPT-style composer at the bottom | optional memory drawer.
//

import SwiftUI

struct ChatWorkspaceView: View {
  @ObservedObject var companionManager: CompanionManager
  var openMemory: () -> Void
  var prepareVoiceFollowUp: () -> Void
  var dismiss: () -> Void

  @AppStorage("openClickyAgentHUDSidebarVisible") private var sidebarVisible: Bool = false
  @AppStorage(AppBundleConfiguration.userAppFontDefaultsKey) private var appFontRawValue = OpenClickyResponseCaptionFont.fallback.rawValue
  @AppStorage(AppBundleConfiguration.userAppBodyFontSizeDefaultsKey) private var appBodyFontSize = 13.0
  @AppStorage(AppBundleConfiguration.userAppSubtextFontSizeDefaultsKey) private var appSubtextFontSize = 11.0
  @State private var memoryDrawerOpen: Bool = false
  @State private var draft: String = ""

  // OpenClicky panel palette.
  private static let paneBg = DS.Colors.background
  private static let textPrimary = DS.Colors.textPrimary
  private static let textSecondary = DS.Colors.textSecondary
  private static let accent = DS.Colors.accentText

  private var appFont: OpenClickyResponseCaptionFont {
    OpenClickyResponseCaptionFont.resolved(appFontRawValue)
  }

  private var bodyFontSize: CGFloat { CGFloat(appBodyFontSize) }
  private var subtextFontSize: CGFloat { CGFloat(appSubtextFontSize) }

  private func appUIFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
    appFont.swiftUIFont(size: size, weight: weight)
  }

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        ConversationSidebarView(companion: companionManager)
          .transition(.move(edge: .leading).combined(with: .opacity))
        Divider().background(Color.black.opacity(0.4)).frame(width: 1)
      }

      VStack(spacing: 0) {
        ChatHeaderBar(
          companion: companionManager,
          session: companionManager.codexAgentSession,
          sidebarVisible: $sidebarVisible,
          memoryDrawerOpen: $memoryDrawerOpen,
          openMemory: openMemory
        )

        CodexHUDView(
          companionManager: companionManager,
          openMemory: openMemory,
          prepareVoiceFollowUp: prepareVoiceFollowUp,
          close: dismiss,
          chromeMode: .embedded
        )

        composer
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Self.paneBg)

      if memoryDrawerOpen {
        Divider().background(Color.black.opacity(0.4)).frame(width: 1)
        MemoryDrawerView(
          companion: companionManager,
          isOpen: $memoryDrawerOpen
        )
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .background(Self.paneBg)
    .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
    .animation(.easeInOut(duration: 0.18), value: memoryDrawerOpen)
  }

  // MARK: ChatGPT-style composer

  private var composer: some View {
    HStack(spacing: 10) {
      Button(action: {}) {
        Image(systemName: "plus")
          .font(appUIFont(size: max(13, subtextFontSize + 1), weight: .semibold))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
          .background(
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .help("Attach")

      TextField("Ask anything", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(appUIFont(size: max(13, bodyFontSize), weight: .medium))
        .foregroundColor(Self.textPrimary)
        .lineLimit(1...6)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onSubmit(send)

      Button(action: prepareVoiceFollowUp) {
        Image(systemName: "waveform")
          .font(appUIFont(size: max(14, subtextFontSize + 2), weight: .medium))
          .foregroundColor(Self.textSecondary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Voice")

      // model pill (mirrors header picker, smaller)
      modelPill

      Button(action: send) {
        Image(systemName: "arrow.up.circle.fill")
          .font(appUIFont(size: max(22, bodyFontSize + 9), weight: .medium))
          .foregroundColor(canSend ? Self.accent : Self.textSecondary.opacity(0.5))
      }
      .buttonStyle(.plain)
      .disabled(!canSend)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .padding(.top, 4)
  }

  private var modelPill: some View {
    let label = currentModelLabel
    return Text(label)
      .font(appUIFont(size: max(11, subtextFontSize), weight: .medium))
      .foregroundColor(Self.textSecondary)
      .padding(.horizontal, max(8, subtextFontSize * 0.72))
      .padding(.vertical, max(4, subtextFontSize * 0.40))
      .background(
        Capsule().fill(Color.white.opacity(0.05))
      )
  }

  private var currentModelLabel: String {
    let id = companionManager.codexAgentSession.model
    let pool = OpenClickyModelCatalog.voiceResponseModels + OpenClickyModelCatalog.codexActionsModels
    return pool.first(where: { $0.id == id })?.label ?? id
  }

  private var canSend: Bool {
    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    companionManager.submitNewAgentTaskFromUI(trimmed, source: "chat_workspace_prompt")
    draft = ""
  }
}
