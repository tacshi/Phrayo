import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/core/native.g.dart',
    swiftOut: 'ios/Runner/Native.g.swift',
  ),
)
class SegmentMessage {
  String id;
  String text;
  double start;
  double end;
  String? speaker;
  SegmentMessage({
    required this.id,
    required this.text,
    required this.start,
    required this.end,
    this.speaker,
  });
}

class SessionMessage {
  String? sttJobJson;
  String? sourceLanguage;
  String? targetLanguage;
  String id;
  String kind;
  String state;
  double seconds;
  double level;
  String transcript;
  String translation;
  String? path;
  String? error;
  List<SegmentMessage> segments;
  SessionMessage({
    this.sttJobJson,
    this.sourceLanguage,
    this.targetLanguage,
    required this.id,
    required this.kind,
    required this.state,
    required this.seconds,
    required this.level,
    required this.transcript,
    required this.translation,
    this.path,
    this.error,
    required this.segments,
  });
}

class CapabilityMessage {
  String? speechStatus;
  bool? vocabularySupported;
  List<String> speechLanguages;
  List<String> installedSpeechLanguages;
  List<String> voices;
  String translationStatus;
  CapabilityMessage({
    this.speechStatus,
    this.vocabularySupported,
    required this.speechLanguages,
    required this.installedSpeechLanguages,
    required this.voices,
    required this.translationStatus,
  });
}

@HostApi()
abstract class PhrayoNative {
  @async
  SessionMessage start(
    String kind,
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  );
  @async
  SessionMessage stop();
  @async
  void pause();
  @async
  void resume();
  @async
  void cancel();
  SessionMessage? snapshot();
  List<SessionMessage> recover();
  void acknowledge(String id);
  @async
  String translate(String text, String source, String target);
  @async
  List<SegmentMessage> transcribe(String path, String source, List<String> transcriptionTerms);
  @async
  CapabilityMessage capabilities(String source, String target, List<String> transcriptionTerms);
  @async
  void prepareLanguages(String source, String target, List<String> transcriptionTerms);
  void speak(String text, String language);
  void play(String path, double start, double? end);
  void stopPlayback();
  void saveSecret(String service, String value);
  String? readSecret(String service);
  void configure(
    String source,
    String target,
    bool localOnly,
    String sttProvider,
    List<String> transcriptionTerms,
  );
  @async
  void share(String text, String? path);
  @async
  String prepareAudio(String path);
  @async
  void shareRecordings(List<String> paths);
  void deleteAudio(String path);
  void openSettings();
}

@FlutterApi()
abstract class PhrayoEvents {
  void sessionChanged(SessionMessage session);
}
