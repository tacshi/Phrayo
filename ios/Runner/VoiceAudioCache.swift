import Foundation

/// Bounded, process-only speech reuse. No user text or synthesized speech is
/// written to disk; repeated listening survives release of the large model.
struct VoiceAudioCache {
  private struct Entry {
    let key: String
    let data: Data
  }
  private var entries = [Entry]()
  let maximumBytes: Int
  let maximumEntries: Int
  init(maximumBytes: Int = 4 * 1024 * 1024, maximumEntries: Int = 12) {
    self.maximumBytes = maximumBytes
    self.maximumEntries = maximumEntries
  }
  mutating func value(for key: String) -> Data? {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let entry = entries.remove(at: index)
    entries.append(entry)
    return entry.data
  }
  mutating func remember(_ data: Data, for key: String) {
    guard data.count <= maximumBytes, maximumEntries > 0 else { return }
    entries.removeAll { $0.key == key }
    entries.append(Entry(key: key, data: data))
    while entries.count > maximumEntries || entries.reduce(0, { $0 + $1.data.count }) > maximumBytes
    {
      entries.removeFirst()
    }
  }
  mutating func removeAll() { entries.removeAll() }
}
