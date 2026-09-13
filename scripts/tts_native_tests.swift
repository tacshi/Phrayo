import Foundation

private enum Failure: Error { case expected }
private actor PendingAudio {
  var waiting: CheckedContinuation<Data, Error>?
  func synthesize() async throws -> Data {
    try await withCheckedThrowingContinuation { waiting = $0 }
  }
  func waitUntilRequested() async {
    while waiting == nil { await Task.yield() }
  }
  func finish(fail: Bool = false) {
    if fail {
      waiting?.resume(throwing: Failure.expected)
    } else {
      waiting?.resume(returning: Data([1]))
    }
    waiting = nil
  }
}

@main struct VoiceTests {
  @MainActor static func main() async throws {
    precondition(SpeechLanguage.sonioxCode("yue-HK") == "zh")
    precondition(SpeechLanguage.isCantonese("zh_HK"))
    precondition(!SpeechLanguage.isCantonese("zh-TW"))
    precondition(SpeechLanguage.needsTextTranslation(source: "en-US", target: "yue-HK"))
    precondition(!SpeechLanguage.needsTextTranslation(source: "yue-HK", target: "yue-HK"))
    precondition(
      (SpeechLanguage.sonioxContext(source: "yue-HK", terms: ["唔該"])["terms"] as? [String]) == [
        "唔該"
      ])
    print("PASS: Cantonese provider mapping preserves language identity")
    precondition(VoiceModel.downloadBytes == 1_423_042_885)
    let source = String(repeating: "我想訂聽晚兩個人嘅位，唔該。", count: 8)
    let chunks = VoiceTextSegments.split(source, language: "yue")
    precondition(chunks.allSatisfy { $0.count <= 32 })
    precondition(chunks.joined() == source)
    let pcm = try VoiceAudio.wav([0, 0.5, -0.5, 1, -1])
    precondition(pcm.count == 54 && String(data: pcm.prefix(4), encoding: .utf8) == "RIFF")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let descriptor = VoiceModel.File(
      name: "fixture", bytes: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try Data("abc".utf8).write(to: fixture)
    precondition(VoiceModel.matches(descriptor, at: fixture))
    try Data("abd".utf8).write(to: fixture)
    precondition(!VoiceModel.matches(descriptor, at: fixture), "Same-size corruption was accepted")
    print("PASS: pinned integrity, CJK text preservation, and PCM WAV encoding")
    var audioCache = VoiceAudioCache(maximumBytes: 6, maximumEntries: 2)
    audioCache.remember(Data([1, 2, 3]), for: "zh:phrase")
    audioCache.remember(Data([4, 5, 6]), for: "yue:phrase")
    precondition(audioCache.value(for: "zh:phrase") == Data([1, 2, 3]))
    audioCache.remember(Data([7, 8, 9]), for: "en:phrase")
    precondition(audioCache.value(for: "yue:phrase") == nil)
    precondition(audioCache.value(for: "zh:phrase") != nil)
    audioCache.remember(Data(repeating: 0, count: 7), for: "oversize")
    precondition(audioCache.value(for: "oversize") == nil)
    print("PASS: speech reuse is language-separated and bounded by memory")
    var voice = SpeechVoiceSelection()
    precondition(voice.prepare(text: "你好", language: "yue-HK", installed: true))
    precondition(voice.usesNeural(text: "你好", language: "yue-HK", installed: false),
      "Failed preparation silently switched to a system voice")
    precondition(!voice.usesNeural(text: "Hello", language: "en-US", installed: false))
    voice.clear()
    precondition(!voice.usesNeural(text: "你好", language: "yue-HK", installed: false))
    print("PASS: preparation failure retains the selected voice for retries")
    let playback = SpeechPlayback()
    var heard = [Int]()
    let first = PendingAudio()
    let stopped = Task {
      try await playback.run(synthesize: { try await first.synthesize() }) { _ in heard.append(1) }
    }
    await first.waitUntilRequested()
    playback.cancel()
    await first.finish()
    try await stopped.value
    precondition(heard.isEmpty, "Stopped inference started audio")

    let second = PendingAudio()
    let superseded = Task {
      try await playback.run(synthesize: { try await second.synthesize() }) { _ in heard.append(2) }
    }
    await second.waitUntilRequested()
    try await playback.run(synthesize: { Data([3]) }) { _ in heard.append(3) }
    await second.finish()
    try await superseded.value
    precondition(heard == [3], "A superseded request replaced newer playback")

    let third = PendingAudio()
    let cancelledFailure = Task {
      try await playback.run(synthesize: { try await third.synthesize() }) { _ in heard.append(4) }
    }
    await third.waitUntilRequested()
    playback.cancel()  // The same boundary used before starting recording.
    await third.finish(fail: true)
    try await cancelledFailure.value
    precondition(heard == [3], "Cancelled synthesis entered fallback")
    do {
      try await playback.run(synthesize: { throw Failure.expected }) { _ in heard.append(5) }
      preconditionFailure("Active synthesis failure was hidden")
    } catch Failure.expected {}
    precondition(heard == [3])
    print("PASS: stop, replacement, recording cancellation, and observable synthesis errors")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileA = VoiceModel.File(
      name: "a", bytes: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let fileB = VoiceModel.File(
      name: "b", bytes: 3,
      sha256: "3608bca1e44ea6c4d268eb6db02260269892c0b42b86bbf1e77a6fa16c3c9282")
    let initial = VoiceModelStore(root: root, files: [fileA]) { _, destination, _ in
      try Data("abc".utf8).write(to: destination)
    }
    let availability = VoiceAvailability()
    precondition(availability.status(of: initial) == "download")
    availability.setPreparing(true)
    precondition(availability.status(of: initial) == "downloading")
    availability.setPreparing(false)
    try initial.publish(await initial.prepare { _ in })
    precondition(initial.isInstalled)
    precondition(availability.status(of: initial) == "ready")
    precondition(VoiceAvailability().status(of: initial) == "ready",
      "A new process must reuse the persisted verification receipt")
    let failed = VoiceModelStore(root: root, files: [fileA, fileB]) { _, _, _ in
      throw Failure.expected
    }
    do {
      _ = try await failed.prepare { _ in }
      preconditionFailure("Failed download was accepted")
    } catch Failure.expected {}
    precondition(initial.isInstalled, "Failed new component removed the installed voice")
    precondition(
      VoiceModel.matches(fileA, at: failed.staging.appendingPathComponent("a")),
      "Completed staging file was lost")
    let corrupt = VoiceModelStore(root: root, files: [fileA, fileB]) { _, destination, _ in
      try Data("bad".utf8).write(to: destination)
    }
    do {
      _ = try await corrupt.prepare { _ in }
      preconditionFailure("Corrupt download was accepted")
    } catch VoiceModelError.invalidDownload {}
    precondition(initial.isInstalled)
    let repaired = VoiceModelStore(root: root, files: [fileA, fileB]) { _, destination, _ in
      try Data("xyz".utf8).write(to: destination)
    }
    try repaired.publish(await repaired.prepare { _ in })
    precondition(repaired.isInstalled)
    precondition(!FileManager.default.fileExists(atPath: repaired.staging.path))
    print(
      "PASS: actual model store preserves installed/staged files, rejects corruption, and publishes retries"
    )
    try Data("x".utf8).write(to: repaired.directory.appendingPathComponent("a"))
    precondition(availability.status(of: repaired) == "repair",
      "Availability accepted an incomplete installed file")
    try Data("abc".utf8).write(to: repaired.directory.appendingPathComponent("a"))
    repaired.invalidate()
    precondition(availability.status(of: repaired) == "repair",
      "Playback failure did not invalidate the readiness receipt")
    print("PASS: voice availability reuses installation receipts and detects interrupted/invalid resources")
  }
}
