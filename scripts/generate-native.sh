#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dart run pigeon --input pigeons/native.dart
python3 - <<'PY'
from pathlib import Path
p = Path('ios/Runner/Native.g.swift')
s = p.read_text()
# Pigeon 28 emits nonisolated async Flutter API methods. Under Swift's generic
# executor semantics they leave the caller's MainActor before sending a message.
# Native-to-Flutter sends must remain on the platform thread.
for declaration in ('protocol PhrayoEventsProtocol {', 'class PhrayoEvents: PhrayoEventsProtocol {'):
    if s.count(declaration) != 1:
        raise SystemExit('Pigeon event declarations changed; review MainActor generation.')
    s = s.replace(declaration, '@MainActor\n' + declaration)
p.write_text(s)
PY
dart format lib/core/native.g.dart
