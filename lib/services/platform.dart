import 'dart:async';

import '../core/native.g.dart';

class NativeBridge implements PhrayoEvents {
  final PhrayoNative api;
  final sessions = StreamController<SessionMessage>.broadcast();
  final ttsDownloads = StreamController<double?>.broadcast();
  Stream<double?> get ttsDownloadProgress => ttsDownloads.stream;
  SessionMessage? current;
  String? navigatedShortcutId;
  NativeBridge({PhrayoNative? api}) : api = api ?? PhrayoNative() {
    PhrayoEvents.setUp(this);
  }
  @override
  void sessionChanged(SessionMessage session) {
    current = session;
    sessions.add(session);
  }

  @override
  void ttsProgress(double? fraction) {
    if (!ttsDownloads.isClosed) ttsDownloads.add(fraction);
  }

  Future<void> dispose() async {
    PhrayoEvents.setUp(null);
    await sessions.close();
    await ttsDownloads.close();
  }
}
