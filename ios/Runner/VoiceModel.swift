import CryptoKit
import Foundation

/// Immutable model inputs. Speech generation always opens these local files in
/// offline mode; only explicit preparation is allowed to download them.
enum VoiceModel {
  static let id = "cosyvoice3-c9ebb1a5-v1"
  static let repository = "aufklarer/CosyVoice3-0.5B-MLX-8bit"
  static let revision = "c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337"
  struct File: Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
    var url: URL {
      URL(
        string:
          "https://huggingface.co/\(VoiceModel.repository)/resolve/\(VoiceModel.revision)/\(name)")!
    }
  }
  static let files: [File] = [
    File(
      name: "llm.safetensors", bytes: 671_220_880,
      sha256: "49b3b2ecc7bcff7d554a80012721a2283187477dd5371a140c1c1a89b13b1063"),
    File(
      name: "flow.safetensors", bytes: 664_553_192,
      sha256: "f1685d7e476295b104a675aa7e25a2572d5858879a4be0dfdd25253215b8e3d4"),
    File(
      name: "hifigan.safetensors", bytes: 83_086_548,
      sha256: "840350956a8403245c738504a0da2a0c2047d5e705173930030013f28d4e3a1e"),
    File(
      name: "config.json", bytes: 2036,
      sha256: "22fce864f6cb5654c26e0b380d4c2be7e4e724849d11fed91f9a3b615d43f505"),
    File(
      name: "merges.txt", bytes: 1_402_109,
      sha256: "ac8ff86a72bee70828fbc1119bc4398c6f3a9a6e490d7b0dbe917be025478bd0"),
    File(
      name: "tokenizer_config.json", bytes: 1287,
      sha256: "482bd979881423375ca5414e4e0d94cd7c5349dbb17fffd46b4d36d71e62a1bc"),
    File(
      name: "vocab.json", bytes: 2_776_833,
      sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
  ]
  static var downloadBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

  static func matches(_ file: File, at url: URL, hash: Bool = true) -> Bool {
    guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.bytes) else {
      return false
    }
    guard hash else { return true }
    guard let input = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? input.close() }
    var digest = SHA256()
    do {
      while let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
        digest.update(data: data)
      }
      return digest.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    } catch { return false }
  }

}

/// Keeps completed, hash-verified staging files across network failures. The
/// installed model is published only after the full bundle passes inference.
struct VoiceModelStore: Sendable {
  typealias Fetch =
    @Sendable (VoiceModel.File, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
  let root: URL
  let files: [VoiceModel.File]
  private let fetch: Fetch
  init(root: URL, files: [VoiceModel.File] = VoiceModel.files, fetch: Fetch? = nil) {
    self.root = root
    self.files = files
    self.fetch =
      fetch ?? { file, target, progress in
        try await Self.download(file, to: target, progress: progress)
      }
  }
  var directory: URL { root.appendingPathComponent(VoiceModel.id, isDirectory: true) }
  var staging: URL { root.appendingPathComponent(".download-\(VoiceModel.id)", isDirectory: true) }
  var isInstalled: Bool {
    guard
      (try? String(contentsOf: directory.appendingPathComponent("verified"), encoding: .utf8))
        == VoiceModel.id
    else { return false }
    return files.allSatisfy {
      VoiceModel.matches($0, at: directory.appendingPathComponent($0.name), hash: false)
    }
  }

  func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    if isInstalled { return directory }
    let manager = FileManager.default
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    var modelRoot = root
    var attributes = URLResourceValues()
    attributes.isExcludedFromBackup = true
    try? modelRoot.setResourceValues(attributes)
    var completed: Int64 = 0
    for file in files {
      try Task.checkCancellation()
      let target = staging.appendingPathComponent(file.name)
      if !VoiceModel.matches(file, at: target) {
        let previous = directory.appendingPathComponent(file.name)
        if VoiceModel.matches(file, at: previous) {
          try? manager.removeItem(at: target)
          try manager.copyItem(at: previous, to: target)
        } else {
          let base = completed
          let total = files.reduce(0) { $0 + $1.bytes }
          try await fetch(file, target) { count in
            progress(min(1, Double(base + count) / Double(total)))
          }
          guard VoiceModel.matches(file, at: target) else { throw VoiceModelError.invalidDownload }

        }
      }
      completed += file.bytes
      progress(Double(completed) / Double(files.reduce(0) { $0 + $1.bytes }))
    }
    return staging
  }

  private static func download(
    _ file: VoiceModel.File, to target: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let delegate = VoiceDownloadProgress(progress)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (temp, response) = try await session.download(from: file.url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { throw VoiceModelError.invalidDownload }
    try Task.checkCancellation()
    try? FileManager.default.removeItem(at: target)
    try FileManager.default.moveItem(at: temp, to: target)
  }

  func publish(_ prepared: URL) throws {
    if prepared == directory { return }
    guard
      files.allSatisfy({
        VoiceModel.matches($0, at: prepared.appendingPathComponent($0.name))
      })
    else { throw VoiceModelError.invalidDownload }
    try VoiceModel.id.write(
      to: prepared.appendingPathComponent("verified"), atomically: true, encoding: .utf8)
    let manager = FileManager.default
    if manager.fileExists(atPath: directory.path) {
      _ = try manager.replaceItemAt(directory, withItemAt: prepared)
    } else {
      try manager.moveItem(at: prepared, to: directory)
    }
  }
  func invalidate() {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("verified"))
  }
}

/// Availability is readable while the synthesis actor is busy. The persisted
/// receipt and file sizes are sufficient here; inference remains an explicit
/// preparation/playback operation. All mutable state is protected by the lock.
final class VoiceAvailability: @unchecked Sendable {
  private let lock = NSLock()
  private var preparing = false

  func setPreparing(_ value: Bool) { lock.withLock { preparing = value } }

  func status(of store: VoiceModelStore) -> String {
    if lock.withLock({ preparing }) { return "downloading" }
    if store.isInstalled { return "ready" }
    return FileManager.default.fileExists(atPath: store.directory.path) ? "repair" : "download"
  }
}

private final class VoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
  let progress: @Sendable (Int64) -> Void
  init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    progress(totalBytesWritten)
  }
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}
enum VoiceModelError: Error {
  case invalidDownload, invalidProfile, invalidAudio, unsupportedLanguage
}
