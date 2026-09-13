import Foundation

enum SpeechLanguage {
  static func isCantonese(_ locale: String) -> Bool {
    let code = locale.replacingOccurrences(of: "_", with: "-").lowercased()
    return code == "yue" || code.hasPrefix("yue-") || code == "zh-hk" || code == "zh-hant-hk"
  }
  static func sonioxCode(_ locale: String) -> String {
    if isCantonese(locale) { return "zh" }
    return locale.replacingOccurrences(of: "_", with: "-").split(separator: "-")
      .first.map { String($0).lowercased() } ?? locale.lowercased()
  }
  static func sonioxContext(source: String, terms: [String]) -> [String: Any] {
    var context: [String: Any] = [:]
    if !terms.isEmpty { context["terms"] = terms }
    if isCantonese(source) {
      context["general"] = [
        ["key": "language", "value": "Cantonese (Hong Kong)"],
        [
          "key": "instructions",
          "value": "Preserve colloquial Cantonese wording in Traditional Chinese characters.",
        ],
      ]
    }
    return context
  }
  static func needsTextTranslation(source: String, target: String) -> Bool {
    source != target && (isCantonese(source) || isCantonese(target))
      && !(isCantonese(source) && isCantonese(target))
  }
}
