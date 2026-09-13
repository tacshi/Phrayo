import Foundation

/// Shares capture draining between Stop and Cancel. A discard requested while
/// buffers are draining must prevent those buffers from entering processing.
@MainActor
final class RecordingDrain {
  private var task: Task<[URL], Never>?
  private(set) var discarded = false

  func finish(_ drain: @escaping @MainActor () async -> [URL]) async -> [URL]? {
    guard !discarded else { return nil }
    if task == nil { task = Task { await drain() } }
    let urls = await task!.value
    return discarded ? nil : urls
  }

  func discard() async {
    discarded = true
    _ = await task?.value
  }
}
