const languages = {
  'zh-CN': '中文（普通话）',
  'yue-HK': '粵語（香港）',
  'en-US': 'English (US)',
  'en-GB': 'English (UK)',
  'en-NZ': 'English (NZ)',
  'ja-JP': '日本語',
  'ko-KR': '한국어',
  'fr-FR': 'Français',
  'de-DE': 'Deutsch',
  'es-ES': 'Español',
  'it-IT': 'Italiano',
  'pt-BR': 'Português',
  'ar-SA': 'العربية',
  'hi-IN': 'हिन्दी',
  'vi-VN': 'Tiếng Việt',
  'th-TH': 'ไทย',
  'id-ID': 'Bahasa Indonesia',
};

bool isCantonese(String locale) {
  final code = locale.replaceAll('_', '-').toLowerCase();
  return code == 'yue' ||
      code.startsWith('yue-') ||
      code == 'zh-hk' ||
      code == 'zh-hant-hk';
}

/// Soniox recognizes Cantonese within its documented Chinese language code.
String sonioxLanguageCode(String locale) => isCantonese(locale)
    ? 'zh'
    : locale.replaceAll('_', '-').split('-').first.toLowerCase();

Map<String, Object> sonioxContext(String source, List<String> terms) => {
  if (terms.isNotEmpty) 'terms': terms,
  if (isCantonese(source))
    'general': [
      {'key': 'language', 'value': 'Cantonese (Hong Kong)'},
      {
        'key': 'instructions',
        'value': 'Preserve colloquial Cantonese wording in Traditional Chinese characters.',
      },
    ],
};
