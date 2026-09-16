import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/native.g.dart';

class NativeBridge implements PhrayoEvents {
  Future<void> cancelTranscription(String path) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      await const MethodChannel('app.capyvibe.phrayo/android')
          .invokeMethod<void>('cancelTranscription', path);
    }
  }

  final PhrayoNative api;
  final sessions = StreamController<SessionMessage>.broadcast();
  final ttsDownloads = StreamController<double?>.broadcast();
  Stream<double?> get ttsDownloadProgress => ttsDownloads.stream;
  SessionMessage? current;
  final _cancelledSessions = <String>{};
  String? navigatedShortcutId;
  NativeBridge({PhrayoNative? api}) : api = api ?? PhrayoNative() {
    PhrayoEvents.setUp(this);
  }
  @override
  void sessionChanged(SessionMessage session) {
    if (_cancelledSessions.contains(session.id)) return;
    if (session.state == 'cancelled') _cancelledSessions.add(session.id);
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
