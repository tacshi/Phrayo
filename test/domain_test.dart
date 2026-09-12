import 'package:flutter_test/flutter_test.dart';
import 'package:phrayo/core/models.dart';
import 'package:phrayo/services/transcription.dart';
import 'package:phrayo/services/text_processor.dart';

void main() {
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
