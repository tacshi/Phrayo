import AVFoundation
import CosyVoiceTTS
import CryptoKit
import Foundation
import MLX

actor LocalTTSService {
  static let shared = LocalTTSService()
  nonisolated private let store = VoiceModelStore(
    root: FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
        "TTS", isDirectory: true))
  private var engine: Engine?
  private var engineDirectory: URL?
  private var engineLoad: (id: UUID, directory: URL, task: Task<Engine, Error>)?
  private var preparation: (id: UUID, task: Task<Void, Error>)?
  nonisolated private let availability = VoiceAvailability()
  private var audioCache = VoiceAudioCache()
  private var releaseTask: Task<Void, Never>?
  private var releaseID: UUID?

  nonisolated static func code(_ locale: String) -> String {
    if SpeechLanguage.isCantonese(locale) { return "yue" }
    return locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(
      String.init)?.lowercased() ?? locale
  }
  nonisolated static func isCovered(_ locale: String) -> Bool {
    ["en", "zh", "ja", "yue"].contains(code(locale))
  }
  nonisolated func hasResources(for language: String) -> Bool {
    Self.isCovered(language) && store.isInstalled
  }
  nonisolated static func sample(_ language: String) -> String {
    switch code(language) {
    case "zh": return "我想订一张明天晚上的双人餐桌。"
    case "yue": return "我想訂聽晚兩個人嘅位，唔該。"
    case "ja": return "明日の夜、二人分の席を予約したいです。"
    case "es": return "Practica un poco cada día y di lo que quieres decir."
    case "fr": return "Pratiquez un peu chaque jour et dites ce que vous voulez dire."
    case "pt": return "Pratique um pouco todos os dias e diga o que quer dizer."
    case "vi": return "Luyện tập một chút mỗi ngày và nói điều bạn muốn nói."
    case "th": return "ฝึกฝนวันละนิด แล้วพูดสิ่งที่คุณอยากพูด"
    case "id": return "Berlatihlah sedikit setiap hari dan katakan apa yang ingin kamu katakan."
    case "de": return "Übe jeden Tag ein wenig und sage, was du sagen möchtest."
    case "ko": return "매일 조금씩 연습하고 하고 싶은 말을 해 보세요."
    case "it": return "Esercitati un po’ ogni giorno e di’ quello che vuoi dire."
    case "ar": return "تدرّب قليلاً كل يوم وقل ما تريد قوله."
    case "hi": return "हर दिन थोड़ा अभ्यास करें और जो कहना चाहते हैं, कहें।"
    default: return "I'd like to book a table for two tomorrow evening."
    }
  }
  nonisolated private static func instruction(_ code: String) -> String {
    switch code {
    case "zh": return "请用普通话自然清楚地表达。"
    case "yue": return "请用广东话表达。"
    case "ja": return "日本語で自然にはっきり話してください。"
    default: return "Speak clearly and naturally in English."
    }
  }

  nonisolated func status(language: String) -> String {
    guard Self.isCovered(language) else { return "unsupported" }
    // This must not queue behind inference or load the model. Installation
    // already verified the files and synthesized a sample before publication.
    return availability.status(of: store)
  }

  func prepare(languages: [String], progress: @escaping @Sendable (Double) -> Void) async throws {
    guard languages.contains(where: Self.isCovered) else { return }
    if let current = preparation { return try await current.task.value }
    let id = UUID()
    availability.setPreparing(true)
    let task = Task {
      let directory = try await self.store.prepare(progress: progress)
      try Task.checkCancellation()
      let candidate = try await self.loadEngine(at: directory)
      var samples = [(String, Data)]()
      for language in languages where Self.isCovered(language) {
        try Task.checkCancellation()
        let key = Self.cacheKey(Self.sample(language), language)
        let data: Data
        if let cached = self.audioCache.value(for: key) {
          data = cached
        } else {
          data = try candidate.synthesize(text: Self.sample(language), code: Self.code(language))
        }
        samples.append((key, data))
      }
      try Task.checkCancellation()
      try self.store.publish(directory)
      self.engineDirectory = self.store.directory
      for (key, audio) in samples { self.audioCache.remember(audio, for: key) }
      self.scheduleRelease()
      progress(1)
    }
    preparation = (id, task)
    defer {
      if preparation?.id == id {
        preparation = nil
        availability.setPreparing(false)
      }
    }
    try await task.value
  }
  func cancelPreparation() { preparation?.task.cancel() }

  func synthesizeWAV(text: String, language: String) async throws -> Data {
    guard hasResources(for: language) else { throw VoiceModelError.unsupportedLanguage }
    try Task.checkCancellation()
    let key = Self.cacheKey(text, language)
    if let audio = audioCache.value(for: key) { return audio }
    do {
      try Task.checkCancellation()
      let engine = try await loadEngine(at: store.directory)
      defer { scheduleRelease() }
      try Task.checkCancellation()
      if let audio = audioCache.value(for: key) { return audio }
      let audio = try engine.synthesize(text: text, code: Self.code(language))
      audioCache.remember(audio, for: key)
      return audio
    } catch {
      if !(error is CancellationError), !(error is JapaneseReadingError) {
        store.invalidate()
        audioCache.removeAll()
        release()
      }
      throw error
    }
  }
  nonisolated private static func cacheKey(_ text: String, _ language: String) -> String {
    Self.code(language) + "\u{0}" + text
  }
  private func loadEngine(at directory: URL) async throws -> Engine {
    releaseTask?.cancel()
    releaseID = nil
    if let engine, engineDirectory == directory { return engine }
    if let current = engineLoad {
      do {
        let loaded = try await current.task.value
        if engineLoad?.id == current.id {
          engine = loaded
          engineDirectory = current.directory
          engineLoad = nil
        }
        if current.directory == directory { return loaded }
      } catch {
        if engineLoad?.id == current.id { engineLoad = nil }
        if current.directory == directory { throw error }
      }
      return try await loadEngine(at: directory)
    }
    let id = UUID()
    let task = Task { try await Engine.open(directory: directory) }
    engineLoad = (id, directory, task)
    do {
      let loaded = try await task.value
      if engineLoad?.id == id {
        engine = loaded
        engineDirectory = directory
        engineLoad = nil
      }
      return loaded
    } catch {
      if engineLoad?.id == id { engineLoad = nil }
      throw error
    }
  }
  func release() {
    releaseTask?.cancel()
    releaseID = nil
    engine?.model.unload()
    engine = nil
    engineDirectory = nil
    Memory.clearCache()
  }
  private func scheduleRelease() {
    releaseTask?.cancel()
    let id = UUID()
    releaseID = id
    releaseTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(60)) } catch { return }
      await self?.releaseIfIdle(id)
    }
  }
  private func releaseIfIdle(_ id: UUID) {
    guard releaseID == id else { return }
    release()
  }

  // The engine never leaves this actor except through its shared loading task.
  private final class Engine: @unchecked Sendable {
    let model: CosyVoiceTTSModel
    let profile: CosyVoiceVoiceProfile
    private var japanese: JapaneseSpeechText?
    init(model: CosyVoiceTTSModel, profile: CosyVoiceVoiceProfile) {
      self.model = model
      self.profile = profile
    }
    deinit { model.unload() }
    static func open(directory: URL) async throws -> Engine {
      Memory.cacheLimit = 64 * 1024 * 1024
      guard
        let url = Bundle.main.url(
          forResource: "cosyvoice3-lj025-0076", withExtension: "json", subdirectory: "VoiceAssets")
      else { throw VoiceModelError.invalidProfile }
      let data = try Data(contentsOf: url)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard digest == "58a6730ed47b9d09cdf8f59b44db4aa5f1733e39f1ad52bb6d0d7976449a1284" else {
        throw VoiceModelError.invalidProfile
      }
      let p = try JSONDecoder().decode(StoredVoiceProfile.self, from: data)
      guard p.speakerEmbedding.count == 192, !p.promptTokens.isEmpty, p.featureFrames > 0,
        p.promptFeatures.count == 80 * p.featureFrames,
        p.speakerEmbedding.allSatisfy(\.isFinite), p.promptFeatures.allSatisfy(\.isFinite)
      else { throw VoiceModelError.invalidProfile }
      let profile = CosyVoiceVoiceProfile(
        speakerEmbedding: p.speakerEmbedding,
        promptToken: MLXArray(p.promptTokens, [1, p.promptTokens.count]),
        promptFeat: MLXArray(p.promptFeatures, [1, 80, p.featureFrames]), promptText: p.transcript)
      let model = try await CosyVoiceTTSModel.fromPretrained(
        modelId: VoiceModel.repository, cacheDir: directory, offlineMode: true)
      Memory.clearCache()
      return Engine(model: model, profile: profile)
    }
    func synthesize(text: String, code: String) throws -> Data {
      var spoken = text
      if code == "ja" {
        if japanese == nil { japanese = try JapaneseSpeechText() }
        spoken = try japanese!.readings(text)
      }
      var samples = [Float]()
      for part in VoiceTextSegments.split(spoken, language: code) {
        try Task.checkCancellation()
        let audio = model.synthesize(
          text: part, voiceProfile: profile, language: code,
          instruction: LocalTTSService.instruction(code), seed: 42)
        guard audio.allSatisfy(\.isFinite), audio.contains(where: { abs($0) > 0.00001 })
        else { throw VoiceModelError.invalidAudio }
        if !samples.isEmpty { samples.append(contentsOf: repeatElement(0, count: 2400)) }
        samples.append(contentsOf: audio)
      }
      try Task.checkCancellation()
      return try VoiceAudio.wav(samples)
    }
  }
  private struct StoredVoiceProfile: Decodable {
    let speakerEmbedding: [Float]
    let promptTokens: [Int32]
    let promptFeatures: [Float]
    let featureFrames: Int
    let transcript: String
  }
}
