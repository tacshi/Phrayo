import Dictionary
import Foundation
import IPADic
import Mecab_Swift

/// IPADic's pronunciation column handles particles such as は→ワ and へ→エ.
private struct SpeechIPADic: DictionaryProviding {
  private let base = IPADic()
  var url: URL { base.url }
  var readingIndex: Int { 8 }
  var pronunciationIndex: Int { 8 }
  var dictionaryFormIndex: Int { 6 }
  func partOfSpeech(posID: UInt16) -> PartOfSpeech { base.partOfSpeech(posID: posID) }
}

enum JapaneseReadingError: Error { case unknownKanji }

final class JapaneseSpeechText {
  private let pronunciation: Tokenizer
  private let ordinary: Tokenizer
  init() throws {
    pronunciation = try Tokenizer(dictionary: SpeechIPADic())
    ordinary = try Tokenizer(dictionary: IPADic())
  }
  func readings(_ text: String) throws -> String {
    let input = Self.normalizeCounters(Self.spellNumbers(text))
    let primary = pronunciation.tokenize(text: input, transliteration: .katakana)
    let fallback = ordinary.tokenize(text: input, transliteration: .katakana)
    let fallbackReadings = Dictionary(
      uniqueKeysWithValues: fallback.map { ($0.range.lowerBound, $0.reading) })
    return try primary.map { token in
      var reading = token.reading
      if reading.isEmpty || reading == "*" || Self.containsKanji(reading) {
        reading = fallbackReadings[token.range.lowerBound] ?? token.base
      }
      if reading.isEmpty || reading == "*" { reading = token.base }
      reading = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
      guard !Self.containsKanji(reading) else { throw JapaneseReadingError.unknownKanji }
      return reading
    }.joined(separator: " ")
  }
  private static func normalizeCounters(_ text: String) -> String {
    let expression = try! NSRegularExpression(pattern: "[〇零一二三四五六七八九十百千万億兆]+[人本]")
    let people = ["一": "ひとり", "二": "ふたり"]
    let bottles = [
      "一": "いっぽん", "二": "にほん", "三": "さんぼん", "四": "よんほん", "五": "ごほん",
      "六": "ろっぽん", "七": "ななほん", "八": "はっぽん", "九": "きゅうほん", "十": "じゅっぽん",
    ]
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .reversed()
    {
      guard let range = Range(match.range, in: result) else { continue }
      let value = String(result[range])
      let number = String(value.dropLast())
      let suffix = result[range.upperBound...]
      // These compounds use ニン rather than the ordinary person counter.
      if value.last == "人", ["前", "称", "三脚"].contains(where: { suffix.hasPrefix($0) }) { continue }
      // Leave proper-name compounds such as 三本木 to the dictionary.
      if value.last == "本", let next = suffix.first,
        containsKanji(String(next)), !["分", "目", "入"].contains(String(next))
      {
        continue
      }
      if let reading = (value.last == "人" ? people : bottles)[number] {
        result.replaceSubrange(range, with: reading)
      }
    }
    return result
  }
  private static func containsKanji(_ text: String) -> Bool {
    text.unicodeScalars.contains {
      (0x3400...0x4dbf).contains($0.value) || (0x4e00...0x9fff).contains($0.value)
        || (0x20000...0x3134f).contains($0.value) || $0.value == 0x3005 || $0.value == 0x3007
    }
  }
  private static func spellNumbers(_ text: String) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ja-JP")
    formatter.numberStyle = .spellOut
    let expression = try! NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?")
    var result = text
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .reversed()
    {
      guard let range = Range(match.range, in: result), let value = Double(result[range]),
        value.isFinite,
        let spoken = formatter.string(from: NSNumber(value: value))
      else { continue }
      result.replaceSubrange(range, with: spoken)
    }
    return result
  }
}
