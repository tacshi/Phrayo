import ActivityKit
import Foundation

struct RecordingAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    let started: Date
    let seconds: Double
    let paused: Bool
  }
  let id: String
}
