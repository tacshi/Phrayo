import Foundation

/// A failed background preparation must not silently change the chosen voice
/// when invalidating its resources makes it appear no longer installed.
struct SpeechVoiceSelection {
  private var prepared: (text: String, language: String)?

  func usesNeural(text: String, language: String, installed: Bool) -> Bool {
    installed || (prepared?.text == text && prepared?.language == language)
  }

  mutating func prepare(text: String, language: String, installed: Bool) -> Bool {
    let neural = usesNeural(text: text, language: language, installed: installed)
    prepared = neural ? (text, language) : nil
    return neural
  }

  mutating func clear() { prepared = nil }
}

/// Owns synthesis until it is handed to the audio player. Stopping or replacing
/// playback invalidates late results even when an inference cannot be cancelled.
@MainActor
final class SpeechPlayback {
  private var generation = 0
  private var pending: Task<Data, Error>?

  func cancel() {
    generation += 1
    pending?.cancel()
    pending = nil
  }

  func run(
    synthesize: @escaping @Sendable () async throws -> Data,
    play: (Data) throws -> Void
  ) async throws {
    cancel()
    let request = generation
    let task = Task { try await synthesize() }
    pending = task
    defer { if generation == request { pending = nil } }
    do {
      let audio = try await task.value
      guard generation == request, !task.isCancelled else { return }
      try play(audio)
    } catch {
      guard generation == request, !task.isCancelled else { return }
      throw error
    }
  }
}
