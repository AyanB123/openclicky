# OpenClicky Settings Simplification — Profiles + Config File

**Status:** Design spec (no code yet)
**Date:** 2026-06-21
**Author:** drafted with Claude, for Jason
**Decision captured:** 3 profiles — **Local / Realtime / Quality**. Spec only.

---

## 1. Problem

The app exposes **~50 independent settings** across **8 tabs**, in a **2,933-line**
`OpenClickySettingsWindowManager.swift`, backed by **~52 UserDefaults keys** + 7 Keychain
secrets. There is **no notion of a "mode"** — configuring the app for a given way of working
means hand-tuning a dozen scattered toggles and keeping them mutually consistent (STT provider,
response model, TTS provider, voice, activation mode, realtime on/off, …).

But the app really only has **3–4 coherent ways to run**. We should make those first-class,
collapse the day-to-day UI to a handful of controls, and push the long tail into a config file.

## 2. Goals / Non-goals

**Goals**
- A single **profile switch** that atomically sets the whole provider matrix.
- Drastically smaller in-app settings surface (target: ~10 visible controls, not ~50).
- Move rarely-changed / power-user settings (including **model IDs**) into a user-editable
  `config.toml`, read through the precedence layer that already exists.
- Make model-ID changes a config edit, not a recompile (defuses the hardcoded-model-drift class
  of bug — same family as the `wire_api="chat"` break).

**Non-goals (this round)**
- No new provider/runtime features. Profiles only orchestrate backends **that already work today**.
- No removal of `ClaudeAPI` HTTP fallback or the SDK/app-server-first ordering (money rule).
- No fully-offline MLX inference as a *default* (it's currently partial — see §4 Local note).

## 3. The revert lesson (why this approach, specifically)

Git history: `e5baeff "add local-first settings structure"` was **reverted the same day**
(`dbc47a1`), then re-shipped differently as `e9c6f6c "add production local voice settings"`.
The reverted attempt introduced **new setup / "runtime lab" UI and hardcoded model catalogs ahead
of any working backend**.

**Rule for this work:** the profile switch is a *re-organisation of existing working settings*,
not a vehicle for new features. It must only flip keys that already drive shipping code paths.

## 4. The three profiles

A profile = a named bundle that, when applied, writes a fixed set of existing UserDefaults keys.
Exact provider raw-values below are taken from the current enums.

| Axis | **Local** | **Realtime** | **Quality** |
|---|---|---|---|
| Intent | No API keys / private, cheap | Lowest latency, full-duplex convo | Best transcription + reasoning + voice |
| STT (`openClickyVoiceTranscriptionProvider`) | `parakeet` (local) | `openai` (Realtime built-in) | `deepgram` (or `assemblyai`) |
| Response model (`selectedVoiceResponseModel`) | Claude via Agent SDK (local Code sign-in) | `gpt-realtime-2` (speech-to-speech) | `claude-sonnet-4-6` / Opus, or `gpt-5.5` |
| TTS (`openClickyTTSProvider`) | `microsoft_edge` (free, no key) | `openai_realtime` | `elevenlabs` |
| Realtime duplex | off | **on** | off |
| Activation (`openClickyVoiceActivationMode`) | push-to-talk | continuous | push-to-talk |
| Cloud keys required | none | OpenAI | Deepgram/AssemblyAI + Anthropic + ElevenLabs |

**Provider enum reference (confirmed raw values):**
- STT `BuddyTranscriptionProviderID`: `automatic` / `parakeet` / `apple` / `assemblyai` / `deepgram` / `openai`
  (`BuddyTranscriptionProvider.swift:11-17`)
- TTS `OpenClickyTTSProvider`: `openai_realtime` / `elevenlabs` / `cartesia` / `deepgram` / `microsoft_edge`
  (`ElevenLabsTTSClient.swift:3830-3835`)

**Important nuance on "Local":** there are two flavours.
1. **No-API-key (recommended shipping default):** Parakeet (local STT) + **Claude Agent SDK**
   (uses the existing local Claude Code sign-in — no per-token key, per the money rule) + Microsoft
   Edge TTS (free). Reasoning still reaches Anthropic, but via the already-paid local sign-in.
2. **Fully offline:** Parakeet + local **MLX** model + Edge TTS. This is currently **partial** —
   the in-app `mlx_lm` server only speaks `/v1/chat/completions`, and Codex now requires
   `wire_api="responses"`, so MLX-via-Codex is blocked until a Responses-capable local server
   exists. Ship flavour (1) as the default; expose (2) as a documented TOML opt-in, not the default.

Why "Realtime" is its own profile: `CompanionManager.initialVoiceResponseModelID()`
(`CompanionManager.swift:1657-1680`) already contains a migration that flips the default to the
speech-to-speech Realtime path *specifically because* the Deepgram→text-model→TTS hop had "the
several-second first-audio delay the user is rejecting." The latency difference is real and
profile-worthy.

## 5. Data model

```swift
// New, pure value type (nonisolated, Sendable) — no behaviour, just data.
nonisolated struct OpenClickyProfile: Identifiable, Equatable, Sendable {
    let id: String                 // "local" | "realtime" | "quality" | custom
    let displayName: String        // user-facing, freely renamable
    let sttProvider: String        // BuddyTranscriptionProviderID raw value
    let responseModelID: String    // OpenClickyModelCatalog model id
    let ttsProvider: String        // OpenClickyTTSProvider raw value
    let ttsVoiceID: String?        // provider-specific; nil = leave current
    let realtimeEnabled: Bool
    let activationMode: String      // openClickyVoiceActivationMode raw value
    let agentModelID: String?       // clickyCodexModel for Agent Mode, optional
    // Optional per-profile overrides that otherwise live in config.toml:
    let reasoningEffort: String?
    let workerBaseURL: String?
}
```

**Apply = atomically write existing keys** (no other app code changes needed — every consumer
already reads these keys):

| Profile field | Existing key written | Today's writer (for reference) |
|---|---|---|
| sttProvider | `openClickyVoiceTranscriptionProvider` | `AppBundleConfiguration.userVoiceTranscriptionProviderDefaultsKey` |
| responseModelID | `selectedVoiceResponseModel` | `CompanionManager.setSelectedModel` (:1682) |
| ttsProvider | `openClickyTTSProvider` | `userTTSProviderDefaultsKey` |
| ttsVoiceID | `openClickyElevenLabsVoiceID` / `openClickyOpenAIRealtimeVoiceID` / `openClickyMicrosoftEdgeVoiceID` / `openClickyDeepgramTTSVoice` / `openClickyCartesiaVoiceID` | per-provider |
| activationMode | `openClickyVoiceActivationMode` | `userVoiceActivationModeDefaultsKey` |
| agentModelID | `clickyCodexModel` | `CodexAgentSession` (:572,617) |
| reasoningEffort | `clickyCodexReasoningEffort` | `CodexHomeManager` |
| workerBaseURL | `clickyAgentBaseURL` | `ClickyCodexBackend.configuredWorkerBaseURL` |

A new key `openClickyActiveProfileID` records the current selection. Applying a profile is one
function: `applyProfile(_:)` → set the keys above → post the existing change notifications the
settings UI already fires.

## 6. Config file

### 6.1 Reuse the existing precedence
`AppBundleConfiguration` already layers: **Keychain → UserDefaults → Info.plist → env →
`~/.config/openclicky/secrets.env` (or `$OPENCLICKY_SECRETS_FILE`) → Swift defaults**
(`AppBundleConfiguration.swift:328,404-409`). We extend the *same* idea with a sibling
`~/.config/openclicky/config.toml` (override env var `$OPENCLICKY_CONFIG_FILE`).

Precedence for non-secret values becomes: **UserDefaults (in-app changes) → `config.toml` →
Swift defaults.** The file overrides built-in defaults; explicit in-app changes still win, so the
UI never fights the file.

### 6.2 Shape
```toml
# ~/.config/openclicky/config.toml
active_profile = "local"

[profiles.local]
display_name = "Local"
stt = "parakeet"
response_model = "claude-agent-sdk"     # resolves to SDK-first Claude
tts = "microsoft_edge"
realtime = false
activation = "push_to_talk"

[profiles.realtime]
display_name = "Realtime"
stt = "openai"
response_model = "gpt-realtime-2"
tts = "openai_realtime"
realtime = true
activation = "continuous"

[profiles.quality]
display_name = "Quality"
stt = "deepgram"
response_model = "claude-sonnet-4-6"
tts = "elevenlabs"
realtime = false
activation = "push_to_talk"

# Long-tail / power-user knobs that leave the UI entirely:
[models]
codex_default = "gpt-5.4"               # was hardcoded; edit here on model drift
point_detector = "gpt-5.4-mini"
computer_use  = "claude-sonnet-4-6"

[agent]
reasoning_effort = "medium"
worker_base_url  = "https://api.openai.com/v1"
sandbox_mode     = "danger-full-access"

[agent.mcp]
developer_docs = false
composio       = false
computer_use   = false
cua_driver_command = ""

[computer_use]
backend = "native_swift"
# … the ~11 CUA knobs

[ui]
typography_preset = "default"           # collapses 3 font-size sliders
theme = "system"

[advanced]
deepgram_endpointing_ms = 300
speculative_prefire = true
desktop_notifications = true
```

The app ships these three profiles as **built-in Swift defaults**; the file only needs to exist if
the user wants to override model IDs, add a 4th profile, or tweak the long tail. Built-in profiles
must never require the file to be present.

## 7. What stays in the app vs. moves to the file

**Stays in the in-app UI (target ~10 controls):**
- **Profile selector** — hero control, segmented, top of the panel.
- Inside the active profile: the 1–3 things actually flipped often — TTS **voice** picker,
  **mic device**, push-to-talk vs continuous (if not implied by profile).
- **Connections** — API keys (one screen; Keychain-backed as today).
- **Permissions** — status, mostly read-only.
- **"Advanced…"** button that reveals/opens `config.toml`.

**Moves to `config.toml` (delete from UI, with sign-off per dead-code rule):**
- **Model IDs** (`OpenClickyModelCatalog` defaults, `CodexPointDetector:13`, `CodexAgentSession:395`,
  `ElementLocationDetector:39`) → `[models]`.
- Agent Mode: reasoning effort, worker base URL, sandbox, **all MCP toggles/commands**
  (`openClickyMCP*`, `clickyCodexReasoningEffort`, `clickyAgentBaseURL`).
- The ~11 Computer Use knobs (`openClickyComputerUseBackend`, `openClickyNativeComputerUseEnabled`, …).
- Typography: collapse `openClickyAppTitleFontSize` / `…BodyFontSize` / `…SubtextFontSize` /
  `…LineSpacing` into one `typography_preset`.
- Tuning: `deepgram_endpointing` (currently hardcoded `300`), `openClickySpeculativePreFireEnabled`,
  AssemblyAI proxy URL, latency/pre-fire.
- Diagnostics / logging / widgets toggles (`openClickyWidgets*`, notifications).

## 8. UI changes

1. Replace the 8-tab layout with: **[ Profiles ] [ Connections ] [ Permissions ] [ Advanced… ]**.
2. Profiles screen: 3 large segmented options + a short summary of what each sets + the 1–3 inline
   overrides + a "what this uses" readout (so it's obvious which keys/credentials are needed).
3. "Advanced…" opens `config.toml` in the user's editor (and offers "Reveal in Finder"). No giant
   form. Power users edit text; everyone else never sees it.
4. Keep the old detailed views behind a hidden/dev flag during migration; delete after a release.

## 9. Sequencing (low-risk, each step shippable)

1. **Schema + built-in defaults.** Add `OpenClickyProfile`, the three defaults, `applyProfile(_:)`,
   `openClickyActiveProfileID`. No UI. Unit-test that apply writes the expected keys.
2. **Wire the selector** into the panel; apply atomically over existing keys. Old tabs still present.
3. **Collapse the UI** behind the new 4-section layout; move detailed views behind a dev flag.
4. **`config.toml` reader** through the existing precedence layer; move `[models]` + long-tail keys
   to read file→default. Model IDs stop being hardcoded.
5. **Delete** now-dead UI + keys (explicit sign-off; list them first).

Steps 1–2 alone deliver the "flick between modes" win with zero provider-code changes.

## 10. Risks / open questions

- **`response_model = "claude-agent-sdk"`** is a pseudo-id — needs a clean way to express "Claude,
  SDK-first" as a catalog entry vs. a concrete model id. Decide: sentinel id vs. a `(provider, sdkFirst)`
  pair in the profile.
- **Voice IDs are provider-specific.** Switching TTS provider via profile must pick a sane default
  voice for that provider (each has its own `…VoiceID` key). Profiles should carry the voice or
  fall back to a per-provider default; never leave a stale cross-provider voice id.
- **Partial-profile application.** If a profile needs a missing key (e.g. Quality without an
  ElevenLabs key), surface it on the Profiles screen ("needs ElevenLabs key") instead of silently
  failing over — directly fixes the current silent-fallback issue.
- **TOML parsing dependency.** Codex config is *rendered* TOML, but we don't currently *parse* TOML
  in-app. Either add a small TOML reader or use the existing `secrets.env` style (KEY=VALUE) for the
  long-tail and reserve TOML for profiles only. Decide before step 4.
- **Migration of existing installs.** One-time map current scattered keys → nearest profile
  (similar to the existing realtime-default migration at `CompanionManager.swift:1657`).

## 11. Why this is cheap

- The file-config precedence **already exists** (`secrets.env`); we extend, not invent.
- TOML **rendering** already exists (`ClickyCodexConfigTemplate`).
- A profile is just "set 6–8 existing UserDefaults keys atomically" — **no provider code changes**
  for the core win.
- It simultaneously **retires the hardcoded-model-ID drift risk** by moving model IDs into config.
