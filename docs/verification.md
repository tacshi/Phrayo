# Verification — 2026-09-09

## Executed

- Flutter/Dart dependency resolution and Pigeon/Drift code generation.
- `flutter analyze`: no issues at the last completed analysis pass.
- `flutter test`: 16 tests passed, covering review intervals, endpoint validation, Soniox source timing, fragmented SSE, incomplete responses, database revision guards, native reimport deletion protection, task cleanup recovery, responsive navigation and Traditional Chinese at 200% text scale.
- iOS simulator Debug build completed, including the Live Activity extension.
- Unsigned physical-device Release build completed (21.4 MB). The processed bundle passed identity, iOS minimum, localized name, audio-mode, privacy-resource and Live Activity checks.
- App installed and launched through `flutter run` on an iPhone 17 Pro simulator running iOS 26.5. Native bridge initialization completed; the initial page was visually inspected.
- Three native XCTest cases passed: concatenating synthetic audio segments into one playable M4A, rejecting an empty export, and rejecting deletion outside the audio store.
- Logo SVG/PDF and 24/40/60/1024-pixel variants generated. The app icon is opaque RGB, without an alpha channel or baked-in system corners.

## Physical-device and live-provider acceptance still required

Use a signed Profile/Release build for independent launch and lock-screen checks. No provider keys were supplied for this project, and no existing project's credentials were used.

- First microphone grant, denied permission and repeated short presses without unintended recording.
- Foreground/cold-start Action Button, system-required unlock, Live Activity stop and disabled Live Activities.
- At least 60 minutes of microphone recording, including pause/resume, incoming call interruption and Bluetooth route changes.
- Real Soniox streaming and async transcription; expired keys, balance/rate limits, interrupted uploads and submission reconciliation.
- One actual user-selected Chat Completions provider, including rewrites, source-linked summaries and generated exercises.
- Downloaded Apple language assets followed by a full airplane-mode Chinese → English → playback → save → practice flow.
- Physical iPad layout and VoiceOver interaction.
- Fifty representative utterances including names, numbers, negation and mixed languages; report trigger-to-first-audio and release-to-visible-final-translation P50/P95. No latency numbers or speech accuracy claims have been inferred from synthetic tests.

## Release boundary

Signing, TestFlight/App Store submission, a published privacy-policy URL and the final App Store privacy disclosures have not been performed. A successful unsigned build does not establish installation or physical-device behavior.

## Recording deletion regression

- Reproduced the old absolute-path failure with the native resolver: a relocated container produced `invalid_audio_path`.
- Reproduced the UI failure ordering: native cleanup failure occurred after the list row was already removed.
- Seven focused Dart tests passed, including retaining the row when cleanup fails and retrying previously deleted audio from tombstones at startup.
- Two targeted native XCTest cases passed on an iOS simulator: legacy-container/relative paths with idempotent deletion, and traversal/symlink rejection.
- New recordings use relative references. Existing absolute references remain compatible. Native audio cleanup now precedes removal of the database record.
- The installed physical-device build still needs updating and a deletion recheck; the user's live device audio was not accessed.

## Recording detail layout

The phone detail now opens on the root navigator with one app bar. The player uses the actual duration and recording date; no artificial waveform or progress is shown. Transcript/key-point tabs and on-demand passage selection replace the always-visible action grid. Five focused layout/deletion tests passed, covering phone, iPad and large text. `screenshots/recording-detail-redesign.png` is a Flutter-rendered Chinese dark-mode preview with synthetic sample text, not a physical-device capture.

## Selectable STT models

- Settings now expose STT model / 语音转文字模型 / 語音轉文字模型, with Soniox and MOSS Pro and separate credentials. Soniox remains the migration default.
- 31 focused Flutter tests passed across STT, service lifecycle, provider settings and cross-page behavior. The final STT-only run passed 12 tests, including one additional cleanup credential/offline regression (32 distinct focused tests in total).
- Coverage includes MOSS model access, multipart/submission payloads, timestamps and speakers, polling/cancellation, ambiguous submissions, provider-bound cleanup, native-job import, stale revisions, credential switching/removal, and both Chinese scripts at 200% text size.
- The iOS simulator workspace build passed. Three focused native MOSS tests passed through Xcode: parsing, journal-before-submission with upload cleanup, and refusal to repeat uncertain submissions. Native capture stays in processing until cleanup finishes; completed results are journaled before cleanup.
- MOSS/Soniox HTTP tests use synthetic responses. No live provider credentials or physical microphone/shortcut flows were exercised for this change. The earlier physical-device Release build does not validate these new STT changes.

## Retranslation and custom vocabulary — 2026-09-12

- Speaking-page edits can be translated with the configured text model or Apple translation. Focused widget tests cover late responses, repeated native session events, failure/retry, whitespace input, saved-state behavior, and tab preservation.
- Custom vocabulary persists across settings/provider changes and native shortcut configuration. Tests cover normalization, Unicode limits, validation without truncation, Save/Cancel, both Chinese scripts at 200% text size, provider payload omission for empty terms, job snapshots across retries, and local-only credential/network isolation.
- MOSS connection validation and new submissions use `moss-transcribe-diarize-pro`; legacy submissions retain their original model/version contract. Native and Dart request tests verify vocabulary fields and recovery behavior.
- 56 focused Flutter tests passed across two final runs (26 vocabulary/retranslation/settings tests and 30 existing speech/translation/service/layout regressions). `flutter analyze` reported no issues.
- Xcode built the iOS 26.5 simulator app and all 12 RunnerTests passed. After the final native exact-Unicode deduplication adjustment, the two affected Apple-selection/vocabulary tests passed again with a rebuilt simulator app.
- Provider requests used synthetic responses. Live Soniox/MOSS recognition, Apple language downloads/recognition quality, physical microphone input, and Action Button/shortcut execution remain unverified. Simulator compilation and payload tests do not establish transcription accuracy improvements.

## Recording transcript editing — 2026-09-12

- Recording details now offers Edit transcript in the overflow menu. The editor saves all passage corrections together or cancels without changes, preserving segment IDs, timestamps, speaker labels, and audio references.
- Changed text updates the recording title and invalidates translation/key points. Unchanged saves preserve generated content. The original revision is archived; saved expressions remain intact. Revision checks and pending-job checks reject conflicting edits without losing the editor draft.
- 21 focused tests passed: six new editing/database/localization cases, twelve existing translation/database cases, and three recording detail layouts. The layout tests now settle disposal timers before completing. `flutter analyze` reported no issues.
- Verified editing and retranslation through widget tests with an in-memory database and a stub system translator, including both Chinese scripts at 200% text size. No native code changed; no iOS build or physical-device test was run for this increment.

## Initial commit checks — 2026-09-12

- Ran the complete Flutter suite (90 cases). Updated one obsolete expectation that required a text model for translation and settled widget teardown timers in the two failing test files. All 12 cases in those files passed on the focused rerun; the remaining 78 cases passed in the full run.
- All 12 installer routing tests passed using fake tools. Final `flutter analyze` reported no issues. Removed one trailing-whitespace-only line from the installer script before staging.

## Recording translation controls and saving — 2026-09-12

- Recording translation style and Translate/Translate again now share one row, with a 12-point gap and vertical padding. The button width is bounded so both controls remain usable on narrow screens.
- Save to Expressions stores the complete transcript/translation pair, recording languages, passage IDs, and source audio range. A transaction prevents duplicate content and rejects stale recording revisions. Saved state updates after library deletion or retranslation.
- All 22 focused translation/edit/detail tests passed, including five new cases for phone/tablet and Chinese 200% text layouts, audio metadata, repeated taps, deletion, and saving a new translation. No native code changed; physical-device appearance remains unverified.
