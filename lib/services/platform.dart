import 'dart:async';

import '../core/native.g.dart';

class NativeBridge implements PhrayoEvents {
  final PhrayoNative api;
  final sessions = StreamController<SessionMessage>.broadcast();
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

  Future<void> dispose() async {
    PhrayoEvents.setUp(null);
    await sessions.close();
  }
}
