enum SttProvider {
  soniox,
  mossPro;

  String get label => this == soniox ? 'Soniox' : 'MOSS Pro';
  String get secret => this == soniox ? 'soniox' : 'moss';
  String get baseUrl =>
      this == soniox ? 'https://api.soniox.com/v1' : 'https://api.mosi.cn/v1';
  static SttProvider fromName(Object? value) =>
      values.where((p) => p.name == value).firstOrNull ?? soniox;
}
