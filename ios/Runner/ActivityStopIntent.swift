import AppIntents

struct ActivityStopIntent: AudioRecordingIntent, LiveActivityIntent {
  static var title: LocalizedStringResource = "Stop recording"
  @MainActor func perform() async throws -> some IntentResult {
    #if !ACTIVITY_EXTENSION
      _ = try await PhrayoHost.shared.stop()
    #endif
    return .result()
  }
}
