import 'package:phrayo/core/native.g.dart';

/// Unrelated widget tests have an already prepared local voice.
class ReadySpeechNative extends PhrayoNative {
  @override
  Future<void> prepareSpeech(String text, String language) async {}
  @override
  Future<void> cancelSpeechPreparation() async {}
}
