import Foundation

/// Keeps unspaced CJK input inside the model's short-utterance window.
/// Every character is retained; punctuation and spaces are preferred cut points.
enum VoiceTextSegments {
  static func split(_ text: String, language: String) -> [String] {
    let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    let maximum = ["zh", "yue"].contains(language) ? 32 : 96
    var result = [String]()
    var start = 0
    while start < characters.count {
      var end = min(start + maximum, characters.count)
      let punctuation = Set<Character>("。！？!?；;，,、\n")
      if end < characters.count,
        let stop = (start..<end).last(where: { punctuation.contains(characters[$0]) })
      {
        end = stop + 1
      } else if end < characters.count,
        let boundary = (start + maximum / 2..<end).last(where: { characters[$0].isWhitespace })
      {
        end = boundary + 1
      }
      let part = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !part.isEmpty { result.append(part) }
      start = end
    }
    return result
  }
}

enum VoiceAudio {
  static func wav(_ samples: [Float]) throws -> Data {
    guard !samples.isEmpty, samples.count <= (Int(UInt32.max) - 36) / 2 else {
      throw VoiceModelError.invalidAudio
    }
    var result = Data()
    func uint16(_ value: UInt16) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { result.append(contentsOf: $0) }
    }
    func uint32(_ value: UInt32) {
      var v = value.littleEndian
      withUnsafeBytes(of: &v) { result.append(contentsOf: $0) }
    }
    result.append(contentsOf: "RIFF".utf8)
    uint32(UInt32(36 + samples.count * 2))
    result.append(contentsOf: "WAVEfmt ".utf8)
    uint32(16)
    uint16(1)
    uint16(1)
    uint32(24000)
    uint32(48000)
    uint16(2)
    uint16(16)
    result.append(contentsOf: "data".utf8)
    uint32(UInt32(samples.count * 2))
    for sample in samples {
      guard sample.isFinite else { throw VoiceModelError.invalidAudio }
      uint16(UInt16(bitPattern: Int16((max(-1, min(1, sample)) * 32767).rounded())))
    }
    return result
  }
}
