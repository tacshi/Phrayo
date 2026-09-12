enum LlmProvider {
  openAi('OpenAI', 'https://api.openai.com/v1'),
  openRouter('OpenRouter', 'https://openrouter.ai/api/v1'),
  deepSeek('DeepSeek', 'https://api.deepseek.com/v1'),
  groq('Groq', 'https://api.groq.com/openai/v1'),
  mistral('Mistral', 'https://api.mistral.ai/v1');

  const LlmProvider(this.label, this.baseUrl);

  final String label, baseUrl;

  static LlmProvider? fromName(String? name) {
    for (final provider in values) {
      if (provider.name == name) return provider;
    }
    return null;
  }

  static LlmProvider? fromBaseUrl(String? baseUrl) {
    final normalized = baseUrl?.trim().replaceFirst(RegExp(r'/+$'), '');
    for (final provider in values) {
      if (provider.baseUrl == normalized) return provider;
    }
    if (normalized == 'https://api.deepseek.com') return deepSeek;
    return null;
  }
}
