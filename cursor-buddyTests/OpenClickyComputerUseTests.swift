import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyComputerUseTests {
    @Test func nativeComputerUseStatusSummarizesReadiness() throws {
        let permissions = OpenClickyComputerUsePermissionStatus(
            accessibilityGranted: true,
            screenRecordingGranted: true,
            skyLightKeyboardPathAvailable: true
        )
        let focusedWindow = OpenClickyComputerUseWindowInfo(
            id: 42,
            pid: 1234,
            owner: "Safari",
            name: "OpenClicky Test",
            bounds: OpenClickyComputerUseWindowBounds(x: 10, y: 20, width: 800, height: 600),
            zIndex: 9,
            isOnScreen: true,
            layer: 0
        )

        let status = OpenClickyComputerUseStatus(
            enabled: true,
            permissions: permissions,
            runningAppCount: 4,
            visibleWindowCount: 7,
            focusedWindow: focusedWindow,
            lastErrorMessage: nil
        )

        #expect(status.isReadyForComputerUse)
        #expect(status.summary == "Enabled · AX ready · screen ready · SkyLight keyboard ready · Safari")
        #expect(status.focusedTargetSummary == "Safari — OpenClicky Test · pid 1234 · window 42")
    }

    @Test func nativeComputerUseStatusCallsOutDisabledMode() throws {
        let status = OpenClickyComputerUseStatus(
            enabled: false,
            permissions: OpenClickyComputerUsePermissionStatus(
                accessibilityGranted: true,
                screenRecordingGranted: true,
                skyLightKeyboardPathAvailable: false
            ),
            runningAppCount: 0,
            visibleWindowCount: 0,
            focusedWindow: nil,
            lastErrorMessage: nil
        )

        #expect(!status.isReadyForComputerUse)
        #expect(status.summary == "Disabled · enable in OpenClicky settings")
    }

    @Test func nativeComputerUseWindowNotesIncludeStableAgentMetadata() throws {
        let window = OpenClickyComputerUseWindowInfo(
            id: 77,
            pid: 2468,
            owner: "Xcode",
            name: "ContentView.swift",
            bounds: OpenClickyComputerUseWindowBounds(x: 12.5, y: 40.0, width: 900.0, height: 700.0),
            zIndex: 20,
            isOnScreen: true,
            layer: 0
        )

        #expect(window.agentContextNote == "CUA Swift target window id 77, pid 2468, owner Xcode, title ContentView.swift, bounds x:12 y:40 width:900 height:700, z-index 20.")
        #expect(window.captureLabel == "CUA Swift focused window (Xcode - ContentView.swift)")
    }

    @Test func realtimeCompositeAppCommandKeepsOnlyTheAppTarget() throws {
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and play AC/DC Back to Black?"
            ) == "Spotify"
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Can you open Spotify and can you play AC/DC Back to Black?"
            ) == "Spotify"
        )
        #expect(
            CompanionManager.testLocalAppOpenTarget(
                from: "Open Chrome and go to amazon.co.uk"
            ) == nil
        )
    }

    @Test func spokenPlayButtonRequestsMapToARealKey() throws {
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press the play button in Spotify.")?.key == "space")
        #expect(CompanionManager.testNativeKeyPress(from: "Press play in Spotify.")?.modifiers == [])
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.key == "k")
        #expect(CompanionManager.testNativeKeyPress(from: "Press command k in Spotify.")?.modifiers == ["command"])
    }

    @Test func compositeAppCommandsPreserveTheFollowUpAction() throws {
        let spotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and play AC/DC Back in Black."
        )
        #expect(spotifyAction?.appName == "Spotify")
        #expect(spotifyAction?.actionText == "play AC/DC Back in Black")

        let politeSpotifyAction = CompanionManager.testCompositeAppAction(
            from: "Open Spotify and can you play AC/DC Back in Black?"
        )
        #expect(politeSpotifyAction?.appName == "Spotify")
        #expect(politeSpotifyAction?.actionText == "play AC/DC Back in Black")

        let mailAction = CompanionManager.testCompositeAppAction(
            from: "Open Mail and search for invoices."
        )
        #expect(mailAction?.appName == "Mail")
        #expect(mailAction?.actionText == "search for invoices")
    }

    @Test func realtimeTwoIsTheDefaultVoiceInteractionModel() throws {
        #expect(OpenClickyModelCatalog.defaultVoiceResponseModelID == "gpt-realtime-2")
        #expect(OpenClickyModelCatalog.defaultCodexActionsModelID != OpenClickyModelCatalog.defaultVoiceResponseModelID)
    }
}
