import Foundation

/// The job dictionary is journaled by the host and handed to Flutter on recovery.
/// Keep its stages and request contract aligned with services/moss.dart.
@MainActor final class MossTranscription {
  static let model = "moss-transcribe-diarize-pro"
  static let legacyModel = "moss-transcribe-diarize"
  static let version = "v20260410-streamparam-20260703"
  private let key: String
  private let session: URLSession
  init(key: String, session: URLSession? = nil) {
    self.key = key
    self.session =
      session
      ?? URLSession(
        configuration: .ephemeral, delegate: NoMossRedirects(), delegateQueue: nil)
  }
  func close() { session.invalidateAndCancel() }

  private func request(
    _ path: String, method: String = "GET", body: Data? = nil,
    upload: URL? = nil, contentType: String? = nil
  ) async throws -> [String: Any] {
    try Task.checkCancellation()
    var request = URLRequest(url: URL(string: "https://api.mosi.cn/v1\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = upload == nil ? 120 : 7200
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    request.httpBody = body
    let data: Data
    let response: URLResponse
    if let upload {
      (data, response) = try await session.upload(for: request, fromFile: upload)
    } else {
      (data, response) = try await session.data(for: request)
    }
    guard let response = response as? HTTPURLResponse else { throw appError("invalid_response") }
    if method == "DELETE", response.statusCode == 404 { return [:] }
    guard (200..<300).contains(response.statusCode) else {
      switch response.statusCode {
      case 401, 402, 403: throw appError("auth_error")
      case 413: throw appError("moss_file_too_large")
      case 429: throw appError("rate_limit")
      default: throw appError("network_error")
      }
    }
    if method == "DELETE" { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw appError("invalid_response")
    }
    return object
  }

  func run(audio: URL, initial: [String: Any], persist: ([String: Any]) throws -> Void)
    async throws -> [SegmentMessage]
  {
    var job = initial
    if ["submission_unknown", "upload_unknown"].contains(job["stage"] as? String ?? "") {
      throw appError("moss_submission_unknown")
    }
    if job["fileId"] == nil {
      let boundary = UUID().uuidString
      let upload = try await Task.detached {
        try Self.multipart(audio: audio, boundary: boundary)
      }.value
      defer { try? FileManager.default.removeItem(at: upload) }
      try Task.checkCancellation()
      job["stage"] = "upload_unknown"
      try persist(job)
      let response = try await request(
        "/files", method: "POST", upload: upload,
        contentType: "multipart/form-data; boundary=\(boundary)")
      guard let id = response["id"] as? String, !id.isEmpty else {
        throw appError("invalid_response")
      }
      job["fileId"] = id
      job["stage"] = "uploaded"
      try persist(job)
    }
    if job["remoteId"] == nil {
      try Task.checkCancellation()
      job["stage"] = "submission_unknown"
      try persist(job)
      var payload: [String: Any] = [
        "model": job["model"] ?? Self.legacyModel, "file_id": job["fileId"]!,
        "diarize": true, "response_format": "json", "async": true,
      ]
      if job["model"] == nil { payload["version"] = Self.version }
      if let version = job["version"] { payload["version"] = version }
      if let terms = job["transcriptionTerms"] as? [String], !terms.isEmpty {
        payload["keyterms"] = terms
      }
      let body = try JSONSerialization.data(withJSONObject: payload)
      let response = try await request(
        "/audio/transcriptions", method: "POST", body: body,
        contentType: "application/json")
      guard let id = (response["task_id"] ?? response["id"]) as? String, !id.isEmpty else {
        throw appError("invalid_response")
      }
      job["remoteId"] = id
      job["stage"] = "processing"
      try persist(job)
    }
    guard let id = job["remoteId"] as? String,
      let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    else { throw appError("invalid_response") }
    while true {
      let response = try await request("/audio/tasks/\(escaped)")
      let status = (response["status"] as? String ?? "").uppercased()
      if ["SUCCESS", "COMPLETED"].contains(status) { return try Self.segments(response) }
      if ["FAILED", "FAILURE", "ERROR"].contains(status) {
        job["stage"] = "remote_failed"
        try persist(job)
        throw appError("moss_transcription_failed")
      }
      guard ["PENDING", "QUEUED", "PROCESSING", "RUNNING"].contains(status) else {
        throw appError("invalid_response")
      }
      let retry = min(30, max(1, (response["retry_after"] as? NSNumber)?.doubleValue ?? 3))
      try await Task.sleep(for: .seconds(retry))
    }
  }

  func cleanup(_ job: [String: Any]) async throws {
    if let id = job["fileId"] as? String,
      let escaped = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    {
      _ = try await request("/files/\(escaped)", method: "DELETE")
    }
  }

  static func segments(_ payload: [String: Any]) throws -> [SegmentMessage] {
    func seconds(_ value: Any?) throws -> Double {
      guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0
      else {
        throw appError("invalid_response")
      }
      return number.doubleValue
    }
    var segments = [SegmentMessage]()
    if payload["segments"] != nil && !(payload["segments"] is [[String: Any]]) {
      throw appError("invalid_response")
    }
    for row in payload["segments"] as? [[String: Any]] ?? [] {
      guard let raw = row["text"] as? String else { throw appError("invalid_response") }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      let start = try seconds(row["start"])
      let end = try seconds(row["end"])
      guard end >= start else { throw appError("invalid_response") }
      let speaker = row["speaker"].flatMap { $0 is NSNull ? nil : String(describing: $0) }
      segments.append(
        SegmentMessage(
          id: "moss-\(segments.count)", text: text,
          start: start, end: end, speaker: speaker))
    }
    if segments.isEmpty, let raw = payload["text"] as? String,
      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      segments.append(
        SegmentMessage(
          id: "moss-0", text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
          start: 0, end: try seconds(payload["duration"])))
    }
    guard !segments.isEmpty else { throw appError("no_speech") }
    return segments
  }

  nonisolated private static func multipart(audio: URL, boundary: String) throws -> URL {
    let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 512 * 1024 * 1024 else { throw appError("moss_file_too_large") }
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    do {
      let writer = try FileHandle(forWritingTo: output)
      let reader = try FileHandle(forReadingFrom: audio)
      defer {
        try? writer.close()
        try? reader.close()
      }
      try writer.write(
        contentsOf: Data(
          ("--\(boundary)\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\naudio\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
            .utf8))
      while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
        try writer.write(contentsOf: data)
      }
      try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
      return output
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
  }
}

private final class NoMossRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
