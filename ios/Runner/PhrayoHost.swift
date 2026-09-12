import AVFoundation
import ActivityKit
import Flutter
import Security
import Speech
import SwiftUI
import Translation
import UIKit

@MainActor
final class PhrayoHost: NSObject, @preconcurrency PhrayoNative, AVSpeechSynthesizerDelegate,
  AVAudioPlayerDelegate
{
  static let shared = PhrayoHost()
  var events: PhrayoEvents?
  private var session: SessionMessage?
  private var capture: AudioCapture?
  private struct Packet: Sendable {
    let data: Data
    let seconds: Double
    let level: Double
  }
  private var packetContinuation: AsyncStream<Packet>.Continuation?
  private var packetTask: Task<Void, Never>?
  private var cloud: SonioxStream?
  private var source = "zh-CN", target = "en-US"
  private var localOnly = false
  private var sttProvider = "soniox"
  private var transcriptionTerms = [String]()
  private var mossJob: [String: Any]?
  private var stopTask: Task<SessionMessage, Error>?
  private var activity: Activity<RecordingAttributes>?
  private let synthesizer = AVSpeechSynthesizer()
  private var player: AVAudioPlayer?
  private var playbackStop: Task<Void, Never>?
  private var lastVoiced = 0.0, heardVoice = false
  private var lastActivityUpdate = 0.0
  private var pendingPermission = false
  private var starting = false
  private var receivedFirstBuffer = false
  private let root: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Audio", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()
  private override init() {
    super.init()
    synthesizer.delegate = self
    source = UserDefaults.standard.string(forKey: "source") ?? "zh-CN"
    target = UserDefaults.standard.string(forKey: "target") ?? "en-US"
    localOnly = UserDefaults.standard.bool(forKey: "localOnly")
    NotificationCenter.default.addObserver(
      self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification,
      object: nil)
  }
  var isActive: Bool { ["recording", "paused", "processing"].contains(session?.state ?? "") }
  func startShortcut() async throws {
    _ = try await start(
      kind: "shortcut", source: UserDefaults.standard.string(forKey: "source") ?? "zh-CN",
      target: UserDefaults.standard.string(forKey: "target") ?? "en-US",
      localOnly: UserDefaults.standard.bool(forKey: "localOnly"),
      sttProvider: UserDefaults.standard.string(forKey: "sttProvider") ?? "soniox",
      transcriptionTerms: TranscriptionVocabulary.load())
  }
  func start(
    kind: String, source: String, target: String, localOnly: Bool, sttProvider: String,
    transcriptionTerms: [String]
  )
    async throws
    -> SessionMessage
  {
    if isActive, let session {
      guard session.state != "processing",
        session.kind == kind
          || (["speaking", "shortcut"].contains(session.kind)
            && ["speaking", "shortcut"].contains(kind))
      else { throw appError("recording_active") }
      return session
    }
    guard !starting else { throw appError("starting") }
    starting = true
    defer { starting = false }
    let permission = AVAudioApplication.shared.recordPermission
    if permission == .undetermined {
      guard !pendingPermission else { throw appError("permission_pending") }
      pendingPermission = true
      let allowed = await AVAudioApplication.requestRecordPermission()
      pendingPermission = false
      throw appError(allowed ? "permission_granted_retry" : "microphone_denied")
    }
    guard permission == .granted else { throw appError("microphone_denied") }
    try stopPlayback()
    self.source = source
    self.target = target
    self.localOnly = localOnly
    self.sttProvider = sttProvider
    self.transcriptionTerms = try TranscriptionVocabulary.normalize(transcriptionTerms)
    mossJob = nil
    stopTask = nil
    receivedFirstBuffer = false
    lastVoiced = 0
    heardVoice = false
    lastActivityUpdate = 0
    let id = UUID().uuidString
    let folder = root.appendingPathComponent(id, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try (folder as NSURL).setResourceValue(
      URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
    session = SessionMessage(
      sourceLanguage: source, targetLanguage: target, id: id, kind: kind, state: "recording",
      seconds: 0, level: 0, transcript: "", translation: "", segments: [])
    if !localOnly && sttProvider == "mossPro" && kind != "recording" {
      mossJob = [
        "provider": "mossPro", "recordingId": id, "revision": 0, "stage": "pending",
        "model": MossTranscription.model, "transcriptionTerms": self.transcriptionTerms,
      ]
    }
    try journal()
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(
        .playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
      try audio.setActive(true)
      if ActivityAuthorizationInfo().areActivitiesEnabled {
        activity = try Activity.request(
          attributes: RecordingAttributes(id: id),
          content: ActivityContent(
            state: .init(started: Date(), seconds: 0, paused: false), staleDate: nil), pushType: nil
        )
      } else if kind == "shortcut" {
        throw appError("live_activity_disabled")
      }
      if !localOnly, sttProvider == "soniox", kind != "recording",
        let key = try readSecret(service: "soniox"), !key.isEmpty
      {
        cloud = SonioxStream(
          key: key, source: source, target: target, terms: self.transcriptionTerms)
        cloud?.onText = { [weak self] text, translation, segments in
          guard let self, self.session?.id == id else { return }
          self.session?.transcript = text
          self.session?.translation = translation
          self.session?.segments = segments
          self.emit()
        }
      }
      let capture = AudioCapture(folder: folder)
      self.capture = capture
      let (packets, continuation) = AsyncStream<Packet>.makeStream()
      packetContinuation = continuation
      capture.onBuffer = { data, seconds, level in
        continuation.yield(Packet(data: data, seconds: seconds, level: level))
      }
      packetTask = Task { @MainActor [weak self] in
        for await packet in packets {
          guard let self, self.session?.id == id, self.session?.state == "recording" else {
            continue
          }
          let seconds = packet.seconds
          let level = packet.level
          if !self.receivedFirstBuffer {
            self.receivedFirstBuffer = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
          self.session?.seconds = seconds
          self.session?.level = min(1, level * 8)
          self.cloud?.append(packet.data)
          if level > 0.012 {
            self.heardVoice = true
            self.lastVoiced = seconds
          }
          if seconds - self.lastActivityUpdate >= 1 {
            self.lastActivityUpdate = seconds
            try? self.journal()
            self.updateActivity()
          }
          self.emit()
          if kind != "recording", seconds >= 60 {
            Task { _ = try? await self.stop() }
          } else if kind == "shortcut" {
            if !self.heardVoice, seconds >= 10 {
              Task { try? await self.cancel() }
            } else if self.heardVoice, seconds - self.lastVoiced >= 1.5 {
              Task { _ = try? await self.stop() }
            }
          }
        }
      }
      capture.onFailure = { [weak self] _ in
        Task { @MainActor in await self?.preserveInterruption("audio_save_failed") }
      }
      try capture.start()
      emit()
      return session!
    } catch {
      cloud?.cancel()
      cloud = nil
      if let capture { _ = await capture.finish() }
      capture = nil
      packetContinuation?.finish()
      await packetTask?.value
      packetTask = nil
      packetContinuation = nil
      session?.state = "failed"
      session?.error = error.localizedDescription
      try? journal()
      await endActivity()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      emit()
      throw error
    }
  }
  func stop() async throws -> SessionMessage {
    if let stopTask { return try await stopTask.value }
    guard let current = session else { throw appError("no_recording") }
    guard current.state == "recording" || current.state == "paused" else { return current }
    let task = Task { @MainActor () throws -> SessionMessage in
      let urls = await capture?.finish() ?? []
      packetContinuation?.finish()
      await packetTask?.value
      packetTask = nil
      packetContinuation = nil
      capture = nil
      session?.state = "processing"
      session?.level = 0
      emit()
      await endActivity()
      let output = root.appendingPathComponent(current.id).appendingPathComponent("recording.m4a")
      session?.path = "\(current.id)/recording.m4a"
      do {
        try await AudioCapture.export(urls, to: output)
        try journal()
        if current.kind != "recording" {
          if !localOnly && sttProvider == "mossPro" {
            guard let key = try readSecret(service: "moss"), !key.isEmpty else {
              throw appError("moss_missing")
            }
            let moss = MossTranscription(key: key)
            defer { moss.close() }
            let segments = try await moss.run(audio: output, initial: mossJob!) { job in
              self.mossJob = job
              try self.journal()
            }
            session?.segments = segments
            session?.transcript = segments.map(\.text).joined(separator: " ")
          } else {
            do {
              if let cloud { try await cloud.finish() } else { throw appError("use_local") }
            } catch {
              cloud?.cancel()
              let segments = try await AppleSpeech.transcribe(
                output.path, source, terms: transcriptionTerms)
              let transcript = segments.map(\.text).joined()
              session?.segments = segments
              session?.transcript = transcript
              if !transcriptionTerms.isEmpty,
                let selection = try? await AppleSpeech.selection(source, transcriptionTerms),
                !selection.dictation
              {
                session?.error = "vocabulary_unavailable"
              }
              let translated = try await AppleSpeech.translate(transcript, source, target)
              session?.translation = translated
            }
          }
          if session?.translation.isEmpty == true, session?.transcript.isEmpty == false {
            let text = session!.transcript
            let translated = try await AppleSpeech.translate(text, source, target)
            session?.translation = translated
          }
          if session?.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw appError("no_speech")
          }
        }
        if mossJob != nil { mossJob?["stage"] = "cleanup" }
        // Persist the completed result while keeping capture blocked during cleanup.
        try journal(completed: true)
        // Cleanup failures are handed to Flutter as cleanup-only jobs.
        if let job = mossJob, let key = try readSecret(service: "moss"), !key.isEmpty {
          let moss = MossTranscription(key: key)
          defer { moss.close() }
          do {
            try await moss.cleanup(job)
            mossJob = nil
            try journal(completed: true)
          } catch { /* Keep the journaled cleanup job for retry. */  }
        }
        session?.state = "saved"
        try journal()
        for url in urls { try? FileManager.default.removeItem(at: url) }
      } catch {
        session?.state = "interrupted"
        session?.error = error.localizedDescription
        try? journal()
      }
      cloud?.cancel()
      cloud = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      emit()
      return session!
    }
    stopTask = task
    return try await task.value
  }
  func pause() async throws {
    guard session?.kind == "recording", session?.state == "recording" else { return }
    capture?.setPaused(true)
    session?.state = "paused"
    try journal()
    updateActivity()
    emit()
  }
  func resume() async throws {
    guard session?.state == "paused" else { return }
    capture?.setPaused(false)
    session?.state = "recording"
    try journal()
    updateActivity()
    emit()
  }
  func cancel() async throws {
    if stopTask != nil, session?.state == "processing", mossJob != nil {
      stopTask?.cancel()
      _ = try await stopTask?.value
      // Preserve the audio and remote identifiers for cleanup/recovery.
      return
    }
    if stopTask != nil, session?.state == "processing" { _ = try await stopTask?.value }
    session?.state = "cancelled"
    cloud?.cancel()
    cloud = nil
    if let capture { _ = await capture.finish() }
    capture = nil
    packetContinuation?.finish()
    await packetTask?.value
    packetTask = nil
    packetContinuation = nil
    await endActivity()
    if let id = session?.id {
      try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }
    session?.state = "cancelled"
    session?.level = 0
    stopTask = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    emit()
  }
  func snapshot() throws -> SessionMessage? { session }
  func recover() throws -> [SessionMessage] {
    let folders =
      (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    return folders.compactMap { folder in
      guard folder.lastPathComponent != session?.id || !isActive,
        let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        j["acknowledged"] as? Bool != true
      else { return nil }
      let output = folder.appendingPathComponent("recording.m4a")
      let storedState = j["state"] as? String ?? "interrupted"
      return SessionMessage(
        sttJobJson: j["sttJobJson"] as? String,
        sourceLanguage: j["source"] as? String, targetLanguage: j["target"] as? String,
        id: folder.lastPathComponent, kind: j["kind"] as? String ?? "recording",
        state: FileManager.default.fileExists(atPath: output.path)
          ? (["recording", "paused", "processing"].contains(storedState)
            ? "interrupted" : storedState) : "interrupted", seconds: j["seconds"] as? Double ?? 0,
        level: 0, transcript: j["transcript"] as? String ?? "",
        translation: j["translation"] as? String ?? "",
        path: "\(folder.lastPathComponent)/recording.m4a",
        error: FileManager.default.fileExists(atPath: output.path) ? nil : "recover_audio",
        segments: (j["segments"] as? [[String: Any]] ?? []).compactMap { value in
          guard let id = value["id"] as? String, let text = value["text"] as? String,
            let start = value["start"] as? Double, let end = value["end"] as? Double
          else { return nil }
          return SegmentMessage(
            id: id, text: text, start: start, end: end, speaker: value["speaker"] as? String)
        })
    }
  }
  func acknowledge(id: String) throws {
    guard UUID(uuidString: id) != nil else { throw appError("invalid_id") }
    let url = root.appendingPathComponent(id).appendingPathComponent("session.json")
    guard let data = try? Data(contentsOf: url),
      var j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    j["acknowledged"] = true
    try JSONSerialization.data(withJSONObject: j).write(to: url, options: .atomic)
  }
  func ensureAudio(_ path: String) async throws {
    let url = try audioURL(path)
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    let chunks = try FileManager.default.contentsOfDirectory(
      at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "caf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    try await AudioCapture.export(chunks, to: url)
  }
  func translate(text: String, source: String, target: String) async throws -> String {
    try await AppleSpeech.translate(text, source, target)
  }
  func transcribe(path: String, source: String, transcriptionTerms: [String]) async throws
    -> [SegmentMessage]
  {
    try await ensureAudio(path)
    return try await AppleSpeech.transcribe(
      audioURL(path).path, source, terms: try TranscriptionVocabulary.normalize(transcriptionTerms))
  }
  func capabilities(source: String, target: String, transcriptionTerms: [String]) async throws
    -> CapabilityMessage
  {
    let selected = try? await AppleSpeech.selection(source, transcriptionTerms)
    let dictation = selected?.dictation ?? !SpeechTranscriber.isAvailable
    let locales =
      dictation
      ? await DictationTranscriber.supportedLocales : await SpeechTranscriber.supportedLocales
    let installed =
      dictation
      ? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales
    let status = await LanguageAvailability().status(
      from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
    let name: String
    switch status {
    case .installed: name = "installed"
    case .supported: name = "download"
    case .unsupported: name = "unsupported"
    @unknown default: name = "unsupported"
    }
    let speechStatus =
      selected.map { installed.contains($0.locale) ? "ready" : "download" } ?? "unsupported"
    return CapabilityMessage(
      speechStatus: speechStatus, vocabularySupported: selected?.dictation ?? false,
      speechLanguages: locales.map(\.identifier),
      installedSpeechLanguages: installed.map(\.identifier),
      voices: AVSpeechSynthesisVoice.speechVoices().map(\.language), translationStatus: name)
  }
  func prepareLanguages(source: String, target: String, transcriptionTerms: [String]) async throws {
    try await AppleSpeech.prepare(source, terms: transcriptionTerms)
    if source != target {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        guard let presenter = presenter() else {
          continuation.resume(throwing: appError("open_app"))
          return
        }
        var host: UIHostingController<PrepareTranslationView>?
        let view = PrepareTranslationView(source: source, target: target) { error in
          host?.dismiss(animated: true)
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
        host = UIHostingController(rootView: view)
        host?.isModalInPresentation = true
        presenter.present(host!, animated: true)
      }
    }
  }
  func speak(text: String, language: String) throws {
    guard !isActive else { throw appError("recording_active") }
    try stopPlayback()
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try AVAudioSession.sharedInstance().setActive(true)
    guard
      let voice = AVSpeechSynthesisVoice(language: language)
        ?? AVSpeechSynthesisVoice.speechVoices().first(where: {
          $0.language.split(separator: "-").first == language.split(separator: "-").first
        })
    else {
      throw appError("voice_missing")
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    synthesizer.speak(utterance)
  }
  func play(path: String, start: Double, end: Double?) throws {
    guard !isActive else { throw appError("recording_active") }
    try stopPlayback()
    let url = try audioURL(path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw appError("recover_audio") }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try AVAudioSession.sharedInstance().setActive(true)
    player = try AVAudioPlayer(contentsOf: url)
    player?.delegate = self
    player?.currentTime = max(0, start)
    player?.play()
    if let end {
      playbackStop = Task {
        try? await Task.sleep(for: .seconds(max(0, end - start)))
        if !Task.isCancelled {
          player?.stop()
          deactivatePlaybackIfIdle()
        }
      }
    }
  }
  func stopPlayback() throws {
    playbackStop?.cancel()
    player?.stop()
    synthesizer.stopSpeaking(at: .immediate)
    deactivatePlaybackIfIdle()
  }
  private func deactivatePlaybackIfIdle() {
    guard !isActive, !synthesizer.isSpeaking, player?.isPlaying != true else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) { Task { @MainActor [weak self] in self?.deactivatePlaybackIfIdle() } }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) { Task { @MainActor [weak self] in self?.deactivatePlaybackIfIdle() } }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in self?.deactivatePlaybackIfIdle() }
  }
  func saveSecret(service: String, value: String) throws {
    guard ["soniox", "moss", "llm"].contains(service) else { throw appError("invalid_service") }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.capyvibe.phrayo", kSecAttrAccount as String: service,
    ]
    if value.isEmpty {
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw appError("keychain_failed")
      }
      return
    }
    let update = [kSecValueData as String: Data(value.utf8)]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = Data(value.utf8)
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      status = SecItemAdd(item as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw appError("keychain_failed") }
  }
  func readSecret(service: String) throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "app.capyvibe.phrayo", kSecAttrAccount as String: service,
      kSecReturnData as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw appError("keychain_failed")
    }
    return String(data: data, encoding: .utf8)
  }
  func configure(
    source: String, target: String, localOnly: Bool, sttProvider: String,
    transcriptionTerms: [String]
  ) throws {
    try TranscriptionVocabulary.save(transcriptionTerms)
    if !isActive {
      self.source = source
      self.target = target
      self.localOnly = localOnly
    }
    UserDefaults.standard.set(source, forKey: "source")
    UserDefaults.standard.set(target, forKey: "target")
    UserDefaults.standard.set(localOnly, forKey: "localOnly")
    UserDefaults.standard.set(sttProvider, forKey: "sttProvider")
  }
  func share(text: String, path: String?) async throws {
    var items: [Any] = [text]
    if let path {
      try await ensureAudio(path)
      items.append(try audioURL(path))
    }
    guard let presenter = presenter() else { throw appError("open_app") }
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    vc.popoverPresentationController?.sourceView = presenter.view
    vc.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
    presenter.present(vc, animated: true)
  }
  func shareRecordings(paths: [String]) async throws {
    guard !paths.isEmpty else { return }
    var items: [URL] = []
    for path in paths {
      try await ensureAudio(path)
      items.append(try audioURL(path))
    }
    guard let presenter = presenter() else { throw appError("open_app") }
    let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
    vc.popoverPresentationController?.sourceView = presenter.view
    vc.popoverPresentationController?.sourceRect = CGRect(
      x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      vc.completionWithItemsHandler = { _, _, _, _ in continuation.resume() }
      presenter.present(vc, animated: true)
    }
  }
  func prepareAudio(path: String) async throws -> String {
    try await ensureAudio(path)
    return try audioURL(path).path
  }
  func deleteAudio(path: String) throws {
    let url = try audioURL(path)
    guard url.deletingLastPathComponent().lastPathComponent != session?.id || !isActive else {
      throw appError("recording_active")
    }
    if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
      do {
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
      } catch { throw appError("audio_delete_failed") }
    }
    if url.deletingLastPathComponent().lastPathComponent == session?.id {
      session = nil
      stopTask = nil
    }
  }
  func openSettings() throws {
    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
  }
  private func audioURL(_ path: String) throws -> URL {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count >= 2, !parts.contains(".."), !parts.contains("."),
      parts.last == "recording.m4a", UUID(uuidString: parts[parts.count - 2]) != nil
    else { throw appError("invalid_audio_path") }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    if path.hasPrefix("/") {
      let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        .deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
      // Older versions persisted container-absolute paths. Rebase only our
      // known audio layout; never follow a caller-supplied path outside it.
      guard
        parent.path == base.path
          || Array(parts.dropLast(2).suffix(3)) == ["Library", "Application Support", "Audio"]
      else { throw appError("invalid_audio_path") }
    } else {
      guard parts.count == 2 else { throw appError("invalid_audio_path") }
    }
    let url = base.appendingPathComponent(parts[parts.count - 2])
      .appendingPathComponent("recording.m4a")
    guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path
    else { throw appError("invalid_audio_path") }
    return url
  }
  private func presenter() -> UIViewController? {
    var result = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(
      \.windows
    ).first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = result?.presentedViewController { result = presented }
    return result
  }
  private func journal(completed: Bool = false) throws {
    session?.sttJobJson = try mossJob.map {
      String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)!
    }
    guard let s = session else { return }
    var j: [String: Any] = [
      "id": s.id, "kind": s.kind, "state": completed ? "saved" : s.state, "seconds": s.seconds,
      "transcript": s.transcript, "translation": s.translation, "source": source, "target": target,
      "transcriptionTerms": transcriptionTerms,
      "segments": s.segments.map { segment -> [String: Any] in
        var value: [String: Any] = [
          "id": segment.id, "text": segment.text, "start": segment.start, "end": segment.end,
        ]
        if let speaker = segment.speaker { value["speaker"] = speaker }
        return value
      },
    ]
    if let sttJobJson = s.sttJobJson { j["sttJobJson"] = sttJobJson }
    try JSONSerialization.data(withJSONObject: j).write(
      to: root.appendingPathComponent(s.id).appendingPathComponent("session.json"), options: .atomic
    )
  }
  private func emit() {
    if let session, let events { Task { try? await events.sessionChanged(session: session) } }
  }
  private func updateActivity() {
    guard let session, let activity else { return }
    Task {
      await activity.update(
        ActivityContent(
          state: .init(
            started: Date().addingTimeInterval(-session.seconds), seconds: session.seconds,
            paused: session.state == "paused"), staleDate: nil))
    }
  }
  private func endActivity() async {
    if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
    activity = nil
  }
  @objc private func interrupted(_ note: Notification) {
    guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      type == AVAudioSession.InterruptionType.began.rawValue
    else { return }
    Task { await preserveInterruption("audio_interrupted") }
  }
  @objc private func routeChanged(_ note: Notification) {
    guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      [
        AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
        AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
      ].contains(reason)
    else { return }
    Task { await preserveInterruption("audio_route_changed") }
  }
  private func preserveInterruption(_ code: String) async {
    guard session?.state == "recording" || session?.state == "paused" else { return }
    _ = try? await stop()
    session?.state = "interrupted"
    session?.error = code
    try? journal()
    emit()
  }
}
