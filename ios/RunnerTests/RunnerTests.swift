import AVFoundation
import Speech
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {
  func testJapaneseVoiceReadingsUseParticlesAndCommonCounters() throws {
    let speech = try JapaneseSpeechText()
    let particles = try speech.readings("今日は東京へ行きます。")
    XCTAssertTrue(particles.contains("ワ"))
    XCTAssertTrue(particles.contains("エ"))
    let counters = try speech.readings("2人で3本の傘を買います。").replacingOccurrences(of: " ", with: "")
    XCTAssertTrue(counters.contains("フタリ"))
    XCTAssertTrue(counters.contains("サンボン"))
    XCTAssertFalse(counters.contains("ニニン"))
  }

  @MainActor
  func testCantoneseSonioxConfigurationPreservesDialectAndDoesNotRequestMandarinTranslation() {
    let source = SonioxStream.configuration(
      key: "test", source: "yue-HK", target: "en-US", terms: ["唔該"])
    XCTAssertEqual(source["language_hints"] as? [String], ["zh"])
    XCTAssertEqual((source["translation"] as? [String: String])?["target_language"], "en")
    let context = source["context"] as? [String: Any]
    XCTAssertEqual(context?["terms"] as? [String], ["唔該"])
    XCTAssertNotNil(context?["general"])
    let target = SonioxStream.configuration(
      key: "test", source: "en-US", target: "yue-HK", terms: [])
    XCTAssertNil(target["translation"])
  }

  func testVocabularyNormalizationAndShortcutPersistence() throws {
    let name = "PhrayoVocabularyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    XCTAssertEqual(TranscriptionVocabulary.load(from: defaults), [])
    try TranscriptionVocabulary.save([" Phrayo ", "", "Phrayo", "洗漱台"], to: defaults)
    XCTAssertEqual(TranscriptionVocabulary.load(from: defaults), ["Phrayo", "洗漱台"])
    XCTAssertNoThrow(try TranscriptionVocabulary.normalize([String(repeating: "😀", count: 30)]))
    XCTAssertThrowsError(try TranscriptionVocabulary.normalize([String(repeating: "😀", count: 31)]))
    XCTAssertThrowsError(try TranscriptionVocabulary.normalize((0...20).map { "term\($0)" }))
    XCTAssertEqual(try TranscriptionVocabulary.normalize(["é", "e\u{301}"]).count, 2)
    try TranscriptionVocabulary.save([], to: defaults)
    XCTAssertEqual(TranscriptionVocabulary.load(from: defaults), [])
  }

  @MainActor func testSonioxVocabularyConfiguration() {
    let config = SonioxStream.configuration(
      key: "test", source: "zh-CN", target: "en-US", terms: ["洗漱台"])
    XCTAssertEqual((config["context"] as? [String: [String]])?["terms"], ["洗漱台"])
    XCTAssertNotNil(config["translation"])
    let empty = SonioxStream.configuration(key: "test", source: "en-US", target: "en-US", terms: [])
    XCTAssertNil(empty["context"])
    XCTAssertNil(empty["translation"])
  }

  @MainActor func testSonioxStreamGroupsCharacterTokensIntoSentences() {
    let tokens: [[String: Any]] = [
      ["text": "我", "start_ms": 1000, "end_ms": 1100, "is_final": true],
      ["text": "现", "start_ms": 1100, "end_ms": 1200, "is_final": true],
      ["text": "在", "start_ms": 1200, "end_ms": 1300, "is_final": true],
      ["text": "Now", "translation_status": "translation"],
      ["text": "说", "start_ms": 1300, "end_ms": 1400, "is_final": true],
      ["text": "。", "start_ms": 1400, "end_ms": 1450, "is_final": true],
      ["text": "好", "start_ms": 1500, "end_ms": 1600],
      ["text": "的", "start_ms": 3500, "end_ms": 3600],
      ["text": "<end>"],
    ]
    let segments = SonioxStream.segments(tokens)
    XCTAssertEqual(segments.map(\.text), ["我现在说。", "好", "的"])
    XCTAssertEqual(segments.first?.start, 1)
    XCTAssertEqual(segments.first?.end, 1.45)
  }

  func testAppleDictionarySelectionAndContext() {
    XCTAssertTrue(
      AppleSpeech.prefersDictation(hasTerms: true, supportsSpeech: true, supportsDictation: true))
    XCTAssertFalse(
      AppleSpeech.prefersDictation(hasTerms: false, supportsSpeech: true, supportsDictation: true))
    XCTAssertFalse(
      AppleSpeech.prefersDictation(hasTerms: true, supportsSpeech: true, supportsDictation: false))
    XCTAssertTrue(
      AppleSpeech.prefersDictation(hasTerms: false, supportsSpeech: false, supportsDictation: true))
    XCTAssertEqual(
      AppleSpeech.vocabularyContext(["Phrayo"]).contextualStrings[.general], ["Phrayo"])
  }

  @MainActor func testMossProVocabularySnapshot() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MossStubURLProtocol.self]
    let client = MossTranscription(key: "test-key", session: URLSession(configuration: config))
    defer {
      client.close()
      MossStubURLProtocol.handler = nil
    }
    var job: [String: Any] = [
      "stage": "uploaded", "fileId": "file", "model": MossTranscription.model,
      "transcriptionTerms": ["Phrayo"],
    ]
    MossStubURLProtocol.handler = { request in
      if request.url!.path == "/v1/audio/transcriptions" {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
          }
        }
        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(payload["model"] as? String, MossTranscription.model)
        XCTAssertEqual(payload["keyterms"] as? [String], ["Phrayo"])
        XCTAssertNil(payload["version"])
        XCTAssertEqual(job["stage"] as? String, "submission_unknown")
        return (200, ["task_id": "task"])
      }
      return (200, ["status": "SUCCESS", "segments": [["text": "Phrayo", "start": 0, "end": 1]]])
    }
    _ = try await client.run(audio: URL(fileURLWithPath: "/unused"), initial: job) { job = $0 }
    XCTAssertEqual(job["transcriptionTerms"] as? [String], ["Phrayo"])
    XCTAssertEqual(job["model"] as? String, MossTranscription.model)
  }

  @MainActor func testMossSegmentsPreserveTimingAndRejectMalformedResults() throws {
    let segments = try MossTranscription.segments([
      "segments": [
        ["text": " Hello. ", "start": 0.25, "end": 1.5, "speaker": "one"]
      ]
    ])
    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].text, "Hello.")
    XCTAssertEqual(segments[0].start, 0.25)
    XCTAssertEqual(segments[0].end, 1.5)
    XCTAssertEqual(segments[0].speaker, "one")
    XCTAssertThrowsError(
      try MossTranscription.segments([
        "segments": [
          ["text": "Hi", "start": 1.0, "end": 0.5]
        ]
      ]))
    XCTAssertThrowsError(try MossTranscription.segments(["segments": "bad"]))
    XCTAssertThrowsError(try MossTranscription.segments(["segments": []]))
  }

  @MainActor func testMossSubmissionIsJournaledAndCleanupOnlyDeletesUpload() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MossStubURLProtocol.self]
    let client = MossTranscription(key: "test-key", session: URLSession(configuration: config))
    defer {
      client.close()
      MossStubURLProtocol.handler = nil
    }
    var job: [String: Any] = ["stage": "uploaded", "fileId": "file"]
    var requests = [String]()
    MossStubURLProtocol.handler = { request in
      let path = request.url!.path
      requests.append("\(request.httpMethod!) \(path)")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
      if path == "/v1/audio/transcriptions" {
        XCTAssertEqual(job["stage"] as? String, "submission_unknown")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
          stream.open()
          defer { stream.close() }
          var buffer = [UInt8](repeating: 0, count: 4096)
          while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
          }
        }
        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(payload["model"] as? String, MossTranscription.legacyModel)
        XCTAssertEqual(payload["version"] as? String, MossTranscription.version)
        XCTAssertEqual(payload["file_id"] as? String, "file")
        XCTAssertEqual(payload["async"] as? Bool, true)
        return (200, ["task_id": "task"])
      }
      if request.httpMethod == "DELETE" { return (404, [:]) }
      return (200, ["status": "SUCCESS", "segments": [["text": "Hi", "start": 0, "end": 1]]])
    }
    let segments = try await client.run(audio: URL(fileURLWithPath: "/unused"), initial: job) {
      job = $0
    }
    XCTAssertEqual(segments[0].text, "Hi")
    XCTAssertEqual(job["remoteId"] as? String, "task")
    try await client.cleanup(job)
    XCTAssertEqual(
      requests,
      ["POST /v1/audio/transcriptions", "GET /v1/audio/tasks/task", "DELETE /v1/files/file"])
  }

  @MainActor func testMossUncertainSubmissionCannotCreateAnotherTask() async {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MossStubURLProtocol.self]
    let client = MossTranscription(key: "test-key", session: URLSession(configuration: config))
    defer {
      client.close()
      MossStubURLProtocol.handler = nil
    }
    MossStubURLProtocol.handler = { _ in
      XCTFail("Must not submit again")
      return (500, [:])
    }
    for stage in ["submission_unknown", "upload_unknown"] {
      do {
        _ = try await client.run(audio: URL(fileURLWithPath: "/unused"), initial: ["stage": stage])
        { _ in }
        XCTFail("Uncertain submission must require recovery")
      } catch { XCTAssertEqual(error.localizedDescription, "moss_submission_unknown") }
    }
  }

  func testSegmentsExportIntoOnePlayableTimeline() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    var paths = [URL]()
    for (index, duration) in [0.25, 0.35].enumerated() {
      let path = folder.appendingPathComponent("\(index).caf")
      let file = try AVAudioFile(forWriting: path, settings: format.settings)
      let frames = AVAudioFrameCount(duration * 48000)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      for i in 0..<Int(frames) {
        buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * Double.pi * 440 / 48000) * 0.1)
      }
      try file.write(from: buffer)
      paths.append(path)
    }
    let output = folder.appendingPathComponent("recording.m4a")
    try await AudioCapture.export(paths, to: output)
    let duration = try await AVURLAsset(url: output).load(.duration)
    XCTAssertEqual(duration.seconds, 0.6, accuracy: 0.05)
    let decoded = try AVAudioFile(forReading: output)
    XCTAssertGreaterThan(decoded.length, 0)
  }
  func testEmptyRecordingCannotExportAsSuccess() async {
    do {
      try await AudioCapture.export(
        [],
        to: FileManager.default.temporaryDirectory.appendingPathComponent(
          UUID().uuidString + ".m4a"))
      XCTFail("Empty export must fail")
    } catch { XCTAssertEqual(error.localizedDescription, "no_audio") }
  }
  @MainActor func testAudioDeletionRejectsPathsOutsideTheAudioStore() {
    XCTAssertThrowsError(try PhrayoHost.shared.deleteAudio(path: "/tmp/recording.m4a"))
  }
  @MainActor func testLegacyContainerPathDeletesCurrentAudioAndRetryIsSafe() async throws {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Audio")
    let id = UUID().uuidString
    let folder = root.appendingPathComponent(id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let audio = folder.appendingPathComponent("recording.m4a")
    try Data([1, 2, 3]).write(to: audio)
    let resolved = try await PhrayoHost.shared.prepareAudio(path: "\(id)/recording.m4a")
    XCTAssertEqual(
      URL(fileURLWithPath: resolved).resolvingSymlinksInPath(), audio.resolvingSymlinksInPath())
    let old =
      "/private/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Library/Application Support/Audio/\(id)/recording.m4a"
    try PhrayoHost.shared.deleteAudio(path: old)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    XCTAssertNoThrow(try PhrayoHost.shared.deleteAudio(path: old))
  }

  @MainActor func testAudioDeletionRejectsTraversalAndSymlinkEscape() throws {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Audio")
    let id = UUID().uuidString
    let link = root.appendingPathComponent(id)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: outside)
    }
    let audio = outside.appendingPathComponent("recording.m4a")
    try Data([1]).write(to: audio)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try PhrayoHost.shared.deleteAudio(path: "\(id)/../\(id)/recording.m4a"))
    XCTAssertThrowsError(try PhrayoHost.shared.deleteAudio(path: "\(id)/recording.m4a"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
  }

}

private final class MossStubURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let (status, body) = try Self.handler!(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
