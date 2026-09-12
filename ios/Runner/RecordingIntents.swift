import AppIntents

struct StartSpeakingIntent: AudioRecordingIntent {
  static var title: LocalizedStringResource = "Start speaking"
  static var supportedModes: IntentModes { .foreground }
  @MainActor func perform() async throws -> some IntentResult {
    do {
      try await PhrayoHost.shared.startShortcut()
      return .result(dialog: "")
    } catch {
      switch error.localizedDescription {
      case "permission_granted_retry":
        return .result(dialog: "Microphone enabled. Run the shortcut again.")
      case "microphone_denied":
        return .result(dialog: "Allow microphone access in Phrayo settings.")
      case "live_activity_disabled":
        return .result(dialog: "Enable Live Activities in Phrayo settings.")
      case "recording_active": return .result(dialog: "Finish the current recording first.")
      default: return .result(dialog: "Open Phrayo and try again.")
      }
    }
  }
}
struct PhrayoShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: StartSpeakingIntent(), phrases: ["Start speaking with \(.applicationName)"],
      shortTitle: "Start speaking", systemImageName: "mic.fill")
  }
}
