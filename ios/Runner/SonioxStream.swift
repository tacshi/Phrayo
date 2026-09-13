import Foundation

@MainActor final class SonioxStream {
  private let socket: URLSessionWebSocketTask
  private let input: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private var sender: Task<Void, Error>?
  private var reader: Task<Void, Error>?
  private var finals = [[String: Any]]()
  private var finished = false
  var onText: ((String, String, [SegmentMessage]) -> Void)?
  var failure: Error?
  init(key: String, source: String, target: String, terms: [String]) {
    socket = URLSession.shared.webSocketTask(
      with: URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!)
    let pair = AsyncStream<Data>.makeStream()
    input = pair.stream
    continuation = pair.continuation
    socket.resume()
    sender = Task {
      let config = Self.configuration(key: key, source: source, target: target, terms: terms)
      try await socket.send(
        .string(String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8)!))
      for await data in input {
        try Task.checkCancellation()
        try await socket.send(.data(data))
      }
      try await socket.send(.string(""))
    }
    reader = Task { [weak self] in
      guard let self else { return }
      do {
        while !finished {
          let message = try await socket.receive()
          let data: Data
          switch message {
          case .string(let value): data = Data(value.utf8)
          case .data(let value): data = value
          @unknown default: continue
          }
          guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw appError("invalid_response")
          }
          if object["error_code"] != nil { throw appError("soniox_failed") }
          let tokens = object["tokens"] as? [[String: Any]] ?? []
          finals.append(contentsOf: tokens.filter { $0["is_final"] as? Bool == true })
          render(finals + tokens.filter { $0["is_final"] as? Bool != true })
          finished = object["finished"] as? Bool == true
        }
      } catch {
        failure = error
        throw error
      }
    }
  }
  static func configuration(key: String, source: String, target: String, terms: [String])
    -> [String: Any]
  {
    var config: [String: Any] = [
      "api_key": key, "model": "stt-rt-v5", "audio_format": "pcm_s16le", "sample_rate": 16000,
      "num_channels": 1, "language_hints": [SpeechLanguage.sonioxCode(source)],
      "enable_language_identification": true,
      "translation": ["type": "one_way", "target_language": SpeechLanguage.sonioxCode(target)],
    ]
    if SpeechLanguage.sonioxCode(source) == SpeechLanguage.sonioxCode(target)
      || SpeechLanguage.isCantonese(target)
    {
      config.removeValue(forKey: "translation")
    }
    let context = SpeechLanguage.sonioxContext(source: source, terms: terms)
    if !context.isEmpty { config["context"] = context }
    return config
  }
  func append(_ data: Data) { continuation.yield(data) }
  func finish() async throws {
    continuation.yield(Data(repeating: 0, count: 6400))
    continuation.finish()
    let timeout = Task {
      try await Task.sleep(for: .seconds(20))
      socket.cancel(with: .goingAway, reason: nil)
    }
    defer {
      timeout.cancel()
      socket.cancel(with: .normalClosure, reason: nil)
    }
    try await sender?.value
    try await reader?.value
    guard finished else { throw appError("soniox_failed") }
  }
  func cancel() {
    continuation.finish()
    sender?.cancel()
    reader?.cancel()
    socket.cancel(with: .goingAway, reason: nil)
  }
  private func render(_ tokens: [[String: Any]]) {
    var source = ""
    var target = ""
    var segments = [SegmentMessage]()
    for (index, t) in tokens.enumerated() {
      guard let text = t["text"] as? String, !text.hasPrefix("<") else { continue }
      if t["translation_status"] as? String == "translation" {
        target += text
      } else {
        source += text
        if let start = t["start_ms"] as? Double, let end = t["end_ms"] as? Double {
          segments.append(
            SegmentMessage(
              id: "token-\(index)", text: text, start: start / 1000, end: end / 1000,
              speaker: (t["speaker"] as? String)))
        }
      }
    }
    onText?(source, target, segments)
  }
}
