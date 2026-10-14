import 'dart:convert';

import 'llm_provider.dart';
import 'stt_provider.dart';
export 'stt_provider.dart';

class Expression {
  final bool googleTranslation;
  final String id, source, target, sourceLanguage, targetLanguage;
  final String? recordingId, audioPath;
  final List<String> sourceIds;
  final double? audioStart, audioEnd;
  final int revision, interval;
  final DateTime created, due;
  Expression({
    this.googleTranslation = false,
    required this.id,
    required this.source,
    required this.target,
    this.sourceLanguage = 'zh-CN',
    this.targetLanguage = 'en-US',
    this.recordingId,
    this.audioPath,
    this.sourceIds = const [],
    this.audioStart,
    this.audioEnd,
    this.revision = 0,
    this.interval = 0,
    DateTime? created,
    DateTime? due,
  }) : created = created ?? DateTime.now(),
       due = due ?? DateTime.now();
  Map<String, dynamic> toJson() => {
    'googleTranslation': googleTranslation,
    'id': id,
    'source': source,
    'target': target,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'recordingId': recordingId,
    'audioPath': audioPath,
    'sourceIds': sourceIds,
    'audioStart': audioStart,
    'audioEnd': audioEnd,
    'revision': revision,
    'interval': interval,
    'created': created.toIso8601String(),
    'due': due.toIso8601String(),
  };
  factory Expression.fromJson(Map<String, dynamic> j) => Expression(
    googleTranslation: j['googleTranslation'] == true,
    id: j['id'],
    source: j['source'],
    target: j['target'],
    sourceLanguage: j['sourceLanguage'],
    targetLanguage: j['targetLanguage'],
    recordingId: j['recordingId'],
    audioPath: j['audioPath'],
    sourceIds: (j['sourceIds'] as List? ?? []).cast<String>(),
    audioStart: (j['audioStart'] as num?)?.toDouble(),
    audioEnd: (j['audioEnd'] as num?)?.toDouble(),
    revision: j['revision'] ?? 0,
    interval: j['interval'] ?? 0,
    created: DateTime.parse(j['created']),
    due: DateTime.parse(j['due']),
  );
  Expression reviewed(bool known, DateTime now) {
    const days = [1, 3, 7, 14, 30];
    final next = known ? (interval + 1).clamp(0, days.length) : 0;
    return Expression.fromJson({
      ...toJson(),
      'interval': next,
      'due': now
          .add(Duration(days: known ? days[interval.clamp(0, 4)] : 1))
          .toIso8601String(),
    });
  }
}

class Segment {
  final String id, text;
  final double start, end;
  final String? speaker;
  Segment({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.speaker,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'start': start,
    'end': end,
    'speaker': speaker,
  };
  factory Segment.fromJson(Map<String, dynamic> j) => Segment(
    id: j['id'],
    text: j['text'],
    start: (j['start'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
    speaker: j['speaker'],
  );
}

enum TranslationStyle {
  standard,
  conversational,
  professional,
  polite,
  concise;

  String get prompt => switch (this) {
    standard => 'Use natural, neutral language.',
    conversational => 'Use conversational, everyday language.',
    professional => 'Use precise, professional language.',
    polite => 'Use polite, considerate language without adding commitments.',
    concise => 'Use concise language without omitting meaning.',
  };
}

class Recording {
  final bool googleTranslation;
  final String id, title, path, state;
  final String translation;
  final TranslationStyle translationStyle;
  final String sourceLanguage, targetLanguage;
  final double seconds;
  final int revision;
  final DateTime created;
  final List<Segment> segments;
  final List<Map<String, dynamic>> summary;
  Recording({
    this.googleTranslation = false,
    required this.id,
    required this.title,
    required this.path,
    required this.seconds,
    this.sourceLanguage = "zh-CN",
    this.targetLanguage = "en-US",
    this.state = 'saved',
    this.translation = '',
    this.translationStyle = TranslationStyle.standard,
    this.revision = 0,
    DateTime? created,
    this.segments = const [],
    this.summary = const [],
  }) : created = created ?? DateTime.now();
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'path': path,
    'seconds': seconds,
    'sourceLanguage': sourceLanguage,
    'targetLanguage': targetLanguage,
    'state': state,
    'translation': translation,
    'googleTranslation': googleTranslation,
    'translationStyle': translationStyle.name,
    'revision': revision,
    'created': created.toIso8601String(),
    'segments': segments.map((s) => s.toJson()).toList(),
    'summary': summary,
  };
  String get displayTitle {
    // Apple recognition can emit individual characters, including fragments of
    // Latin words inside CJK speech. Preserve its spacing for these languages.
    final language = sourceLanguage.replaceAll('_', '-').split('-').first;
    final transcript = ['zh', 'yue', 'ja'].contains(language)
        ? segments.map((segment) => segment.text).join().trim()
        : segments
              .map((segment) => segment.text.trim())
              .where((text) => text.isNotEmpty)
              .join(' ');
    return transcript.isEmpty ? title.trim() : transcript;
  }

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
    id: j['id'],
    title: j['title'],
    path: j['path'],
    seconds: (j['seconds'] as num).toDouble(),
    sourceLanguage: j['sourceLanguage'] ?? 'zh-CN',
    targetLanguage: j['targetLanguage'] ?? 'en-US',
    state: j['state'],
    translation: j['translation'] ?? '',
    googleTranslation: j['googleTranslation'] == true,
    translationStyle:
        TranslationStyle.values
            .where((s) => s.name == j['translationStyle'])
            .firstOrNull ??
        TranslationStyle.standard,
    revision: j['revision'] ?? 0,
    created: DateTime.parse(j['created']),
    segments: (j['segments'] as List)
        .map((s) => Segment.fromJson(Map<String, dynamic>.from(s)))
        .toList(),
    summary: (j['summary'] as List? ?? [])
        .map((s) => Map<String, dynamic>.from(s))
        .toList(),
  );
}

class AppSettings {
  final String source, target, locale, model;
  final LlmProvider? provider;
  final SttProvider sttProvider;
  final bool localOnly;
  final List<String> transcriptionTerms;

  /// Off by default: on-device synthesis is heavy, so translation audio is
  /// generated only when asked for unless this is turned on.
  final bool autoGenerateVoice;
  const AppSettings({
    this.source = 'zh-CN',
    this.target = 'en-US',
    this.locale = '',
    this.provider,
    this.sttProvider = SttProvider.soniox,
    this.model = '',
    this.localOnly = false,
    this.transcriptionTerms = const [],
    this.autoGenerateVoice = false,
  });
  bool get usesTextModel =>
      !localOnly && provider != null && model.trim().isNotEmpty;
  String get baseUrl => provider?.baseUrl ?? '';
  Map<String, dynamic> toJson() => {
    'source': source,
    'target': target,
    'locale': locale,
    'provider': provider?.name,
    'sttProvider': sttProvider.name,
    'model': model,
    'localOnly': localOnly,
    'transcriptionTerms': transcriptionTerms,
    'autoGenerateVoice': autoGenerateVoice,
  };
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final provider = j.containsKey('provider')
        ? LlmProvider.fromName(j['provider'])
        : LlmProvider.fromBaseUrl(j['baseUrl']);
    return AppSettings(
      source: j['source'] ?? 'zh-CN',
      target: j['target'] ?? 'en-US',
      locale: j['locale'] ?? '',
      provider: provider,
      sttProvider: SttProvider.fromName(j['sttProvider']),
      model: provider == null ? '' : j['model'] ?? '',
      localOnly: j['localOnly'] ?? false,
      transcriptionTerms: List<String>.unmodifiable(
        (j['transcriptionTerms'] as List? ?? const []).cast<String>(),
      ),
      autoGenerateVoice: j['autoGenerateVoice'] == true,
    );
  }
}

String encode(Object value) => jsonEncode(value);
