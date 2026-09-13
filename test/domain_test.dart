import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/services/transcription.dart';
import 'package:phrayo/services/text_processor.dart';

void main() {
  test(
    'recording title preserves CJK fragments and supplied English spaces',
    () {
      Recording recording(String language, List<String> parts) => Recording(
        id: 'r',
        title: 'Fallback',
        path: '/fixture',
        seconds: 1,
        sourceLanguage: language,
        segments: [
          for (final (index, text) in parts.indexed)
            Segment(id: '$index', text: text, start: 0, end: 1),
        ],
      );
      for (final language in ['zh-CN', 'zh_HK', 'yue-HK', 'ja-JP']) {
        expect(
          recording(language, [
            '今',
            '天',
            '晚',
            '饭',
            '吃',
            '什么',
            '呢',
            '？',
          ]).displayTitle,
          '今天晚饭吃什么呢？',
        );
        expect(
          recording(language, ['用', 'Open', 'AI', ' API', '。']).displayTitle,
          '用OpenAI API。',
        );
        expect(recording(language, [' ', '']).displayTitle, 'Fallback');
      }
      expect(
        recording('en-US', ['Hello', 'world.', ' How are you?']).displayTitle,
        'Hello world. How are you?',
      );
    },
  );

  test('review intervals advance and reset without skipping day one', () {
    final now = DateTime.utc(2026, 9, 9);
    var phrase = Expression(id: 'p', source: '你好', target: 'Hello');
    for (final day in [1, 3, 7, 14, 30, 30]) {
      phrase = phrase.reviewed(true, now);
      expect(phrase.due, now.add(Duration(days: day)));
    }
    phrase = phrase.reviewed(false, now);
    expect(phrase.interval, 0);
    expect(phrase.due, now.add(const Duration(days: 1)));
    expect(phrase.reviewed(true, now).due, now.add(const Duration(days: 1)));
  });
  test('Soniox source timestamps never come from translation tokens', () {
    final result = sonioxSegments([
      {
        'text': 'Hello',
        'start_ms': 0,
        'end_ms': 300,
        'speaker': '1',
        'translation_status': 'original',
      },
      {'text': '你好', 'translation_status': 'translation'},
      {'text': ' there.', 'start_ms': 300, 'end_ms': 700, 'speaker': '1'},
      {'text': 'Thanks.', 'start_ms': 900, 'end_ms': 1200, 'speaker': '2'},
      {'text': '<end>'},
    ]);
    expect(result.length, 2);
    expect(result.first.text, 'Hello there.');
    expect(result.first.end, .7);
    expect(result.last.speaker, '2');
  });
  test('compatible endpoint preserves provider prefixes and rejects credential-bearing URLs', () {
    expect(
      completionEndpoint('https://example.com/api/v1/').toString(),
      'https://example.com/api/v1/chat/completions',
    );
    for (final endpoint in [
      'http://example.com/v1',
      'https://key@example.com/v1',
      'https://example.com/v1?key=secret',
    ]) {
      expect(() => completionEndpoint(endpoint), throwsStateError);
    }
  });
}
