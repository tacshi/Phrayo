import AVFoundation
import Speech
import SwiftUI
import Translation

func appError(_ code: String) -> Error {
  NSError(domain: "Phrayo", code: 1, userInfo: [NSLocalizedDescriptionKey: code])
}

@available(iOS 26.0, *)
enum AppleSpeech {
  static func prefersDictation(hasTerms: Bool, supportsSpeech: Bool, supportsDictation: Bool)
    -> Bool
  {
    supportsDictation && (hasTerms || !supportsSpeech)
  }

  // Selection is shared by recognition, availability checks, and asset preparation.
  static func selection(_ source: String, _ terms: [String]) async throws -> (
    dictation: Bool, locale: Locale
  ) {
    let requested = Locale(identifier: source)
    let speechCandidate =
      SpeechTranscriber.isAvailable
      ? await SpeechTranscriber.supportedLocale(equivalentTo: requested) : nil
    let dictationCandidate = await DictationTranscriber.supportedLocale(equivalentTo: requested)
    let speech = speechCandidate.flatMap {
      SpeechLanguage.isCantonese(source) && !SpeechLanguage.isCantonese($0.identifier) ? nil : $0
    }
    let dictation = dictationCandidate.flatMap {
      SpeechLanguage.isCantonese(source) && !SpeechLanguage.isCantonese($0.identifier) ? nil : $0
    }
    if prefersDictation(
      hasTerms: !terms.isEmpty, supportsSpeech: speech != nil, supportsDictation: dictation != nil),
      let dictation
    {
      return (true, dictation)
    }
    if let speech { return (false, speech) }
    throw appError("language_unsupported")
  }

  static func module(_ source: String, terms: [String], requireInstalled: Bool = true) async throws
    -> any SpeechModule
  {
    let selected = try await selection(source, terms)
    let installed =
      selected.dictation
      ? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales
    if requireInstalled && !installed.contains(selected.locale) {
      throw appError("resources_missing")
    }
    if selected.dictation {
      return DictationTranscriber(
        locale: selected.locale, contentHints: [], transcriptionOptions: [.punctuation],
        reportingOptions: [], attributeOptions: [.audioTimeRange])
    }
    return SpeechTranscriber(locale: selected.locale, preset: .transcription)
  }

  static func prepare(_ source: String, terms: [String]) async throws {
    let module = try await module(source, terms: terms, requireInstalled: false)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
      try await request.downloadAndInstall()
    }
  }

  static func vocabularyContext(_ terms: [String]) -> AnalysisContext {
    let context = AnalysisContext()
    context.contextualStrings[.general] = terms
    return context
  }

  static func transcribe(_ path: String, _ source: String, terms: [String]) async throws
    -> [SegmentMessage]
  {
    let module = try await module(source, terms: terms)
    let analyzer = SpeechAnalyzer(modules: [module])
    if module is DictationTranscriber, !terms.isEmpty {
      try await analyzer.setContext(vocabularyContext(terms))
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    if let transcriber = module as? SpeechTranscriber {
      let task = Task { () throws -> [SegmentMessage] in
        var output = [SegmentMessage]()
        for try await r in transcriber.results where r.isFinal {
          output.append(
            SegmentMessage(
              id: UUID().uuidString, text: String(r.text.characters), start: r.range.start.seconds,
              end: CMTimeRangeGetEnd(r.range).seconds))
        }
        return output
      }
      do {
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        return try await task.value
      } catch {
        task.cancel()
        throw error
      }
    }
    let transcriber = module as! DictationTranscriber
    let task = Task { () throws -> [SegmentMessage] in
      var output = [SegmentMessage]()
      for try await r in transcriber.results where r.isFinal {
        output.append(
          SegmentMessage(
            id: UUID().uuidString, text: String(r.text.characters), start: r.range.start.seconds,
            end: CMTimeRangeGetEnd(r.range).seconds))
      }
      return output
    }
    do {
      try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
      return try await task.value
    } catch {
      task.cancel()
      throw error
    }
  }
  static func translate(_ text: String, _ source: String, _ target: String) async throws -> String {
    if source == target
      || (SpeechLanguage.isCantonese(source) && SpeechLanguage.isCantonese(target))
    {
      return text
    }
    let pair = try await translationPair(source, target)
    let status = await LanguageAvailability().status(
      from: pair.source, to: pair.target)
    guard status == .installed else {
      throw appError(status == .unsupported ? "language_unsupported" : "resources_missing")
    }
    let session = TranslationSession(
      installedSource: pair.source, target: pair.target)
    return try await session.translate(text).targetText
  }

  static func translationPair(_ source: String, _ target: String) async throws
    -> (source: Locale.Language, target: Locale.Language)
  {
    let supported =
      (SpeechLanguage.isCantonese(source) || SpeechLanguage.isCantonese(target))
      ? await LanguageAvailability().supportedLanguages : []
    func language(_ code: String) throws -> Locale.Language {
      guard SpeechLanguage.isCantonese(code) else { return Locale.Language(identifier: code) }
      // zh-HK may be accepted as a regional alias for Mandarin. Only an
      // explicitly advertised Yue language establishes Cantonese translation.
      guard let cantonese = supported.first(where: { $0.minimalIdentifier.hasPrefix("yue") })
      else { throw appError("cantonese_translation_model") }
      return cantonese
    }
    return (try language(source), try language(target))
  }
}

@available(iOS 26.0, *)
struct PrepareTranslationView: View {
  let source: String
  let target: String
  let completion: (Error?) -> Void
  @State private var completed = false
  var body: some View {
    ProgressView().padding(48)
      .translationTask(
        source: Locale.Language(identifier: source), target: Locale.Language(identifier: target)
      ) { session in
        do {
          try await session.prepareTranslation()
          finish(nil)
        } catch { finish(error) }
      }
      .onDisappear { if !completed { finish(appError("cancelled")) } }
  }
  private func finish(_ error: Error?) {
    guard !completed else { return }
    completed = true
    completion(error)
  }
}

// Use scalar counts on both sides of the bridge, including non-BMP characters.
enum TranscriptionVocabulary {
  static func normalize(_ terms: [String]) throws -> [String] {
    var seen = Set<Data>()
    let normalized = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert(Data($0.utf8)).inserted }
    guard normalized.count <= 20 else { throw appError("vocabulary_too_many") }
    guard normalized.allSatisfy({ $0.unicodeScalars.count <= 30 }) else {
      throw appError("vocabulary_too_long")
    }
    return normalized
  }
  static func load(from defaults: UserDefaults = .standard) -> [String] {
    defaults.stringArray(forKey: "transcriptionTerms") ?? []
  }
  static func save(_ terms: [String], to defaults: UserDefaults = .standard) throws {
    defaults.set(try normalize(terms), forKey: "transcriptionTerms")
  }
}
