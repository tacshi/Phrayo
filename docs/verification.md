# Verification — 2026-09-09

## Slide up to cancel speaking — 2026-09-13

- Added release-to-cancel above the held microphone, reversible hover highlighting, entry haptics, accessible Start/Stop/Cancel, and English/Simplified Chinese/Traditional Chinese instructions. The microphone remains stationary when capture starts.
- Cancellation retains pointer/session ownership across delayed startup and cleanup. Cancelled session events cannot restore text or replace a newer session. Native cancellation during the automatic-stop drain prevents export/processing and drains capture once.
- 38 focused Flutter tests passed across the recording-gesture, widget, retranslation, and speaking-language suites, including 23 gesture cases. Coverage includes startup/failure/retry/disposal, multi-touch, stale events, hit margins, accessibility activation, and narrow/compact layouts at 200% text scale. The existing layout fixture now supplies a voice-status response instead of leaving a platform timeout pending.
- The four checks in `bash scripts/test-recording-native.sh` passed: cancellation during draining, cancellation before a queued stop, shared draining for ordinary/repeated stops, and independent ownership for the next recording. These use controlled capture completions, not microphone input.
- Focused Dart analysis reported no issues. `flutter build ios --simulator --debug --no-pub` compiled the native guard and built the simulator app.
- Physical iPhone finger movement, perceived haptics, microphone shutdown, and audio-file cleanup remain unverified. No physical-device installation or microphone capture was performed for this change.

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


## Initial Piper voice fixes (2026-09-13, superseded below)

- Settings loads voice status on entry and target-language changes; a persistent Listening voice section exposes preparation, preview and repair. Stale language responses are ignored.
- Neural readiness verifies non-silent finite model output. Failed synthesis is returned to Flutter; unsupported or unprepared languages retain system playback. Playback cancellation invalidates pending inference.
- Shared model and Japanese dictionary installation use separate validated staging directories. Failed downloads and validation leave installed components intact.
- The shared Xcode scheme and installer provision the G2P framework with locked dependencies and an input/toolchain cache.

Focused regression commands:

```sh
flutter test --no-pub test/tts_settings_test.dart
bash scripts/test-tts-native.sh
python3 -m unittest scripts/test_voice_framework.py scripts/test_install_ios.py
```

The explicit live smoke entry point runs through Flutter (including for Debug), downloads resources only into the chosen simulator/app sandbox, and starts neural preview playback:

```sh
flutter run --debug --no-pub -d <simulator-id> -t scripts/voice_smoke.dart
```

It does not read recordings or saved credentials. Use `lib/main.dart` for normal app builds. A successful smoke run establishes synthesis and audio-player startup, not physical-device voice quality.

Executed results:

- All 6 voice widget regressions passed; the focused existing provider/settings/navigation checks also passed. Focused analysis reported no issues.
- Native Swift cancellation, replacement, error propagation and transactional-resource regression harness passed.
- All 15 installer/framework tests passed.
- A normal `flutter build ios --release --no-codesign --no-pub -t lib/main.dart` succeeded with the generated G2P framework temporarily absent; the shared scheme recreated the framework and its input fingerprint. The final build uses the normal app entry point.
- The iOS 26.5 iPhone 17 Pro simulator smoke passed for English, Chinese and Japanese: actual downloads, model verification and native audio-player startup succeeded. A live main-thread callback error found during the first run was fixed in deterministic Pigeon regeneration; the repeated run had no platform-thread errors.
- Simulator UI inspection confirmed the visible Listening voice section, Neural voice ready status and Preview voice action.
- Physical-device installation, sound quality and hardware performance remain unverified. The built Release artifact is unsigned.

## CosyVoice 3 replacement and Cantonese (2026-09-13)

- Replaced the rejected Piper/Mera voice with CosyVoice 3 for English, Mandarin, Japanese and Cantonese. The user approved the four generated voice samples. Japanese uses the bundled MeCab/IPADic pronunciation frontend, including common counters; unresolved kanji produces a recovery error instead of guessed speech.
- The immutable download contains seven files totaling 1,423,042,885 bytes from `aufklarer/CosyVoice3-0.5B-MLX-8bit@c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337`. Each file is SHA-256 checked before publication. The bundled preset uses public-domain LJ Speech clip LJ025-0076; encoders and source recordings are not phone downloads. Source pins and notices are recorded in `docs/research/cosyvoice3-integration.md` and `ios/Runner/VoiceAssets`.
- Cantonese is a separate source/target language. Soniox receives its documented Chinese hint plus Cantonese context, while the app retains Cantonese identity. Translation uses the configured text model when Apple does not explicitly support Cantonese; local-only mode retains its network restriction.
- All 33 focused Flutter tests passed across Cantonese, voice settings, speaking-page retranslation, recording translation and vocabulary. The standalone Swift harness passed playback cancellation/replacement/errors, actual model-store corruption/retry/preservation, bounded audio reuse, CJK segmentation, WAV encoding and Cantonese mapping. All 12 installer tests passed.
- A real Japanese dictionary probe checked the displayed sample, pronunciation particles, Arabic numbers/counters and mixed Latin text. The two additional RunnerTests methods were not separately executed through XCTest.
- Signed Profile smoke tests on iRocky (iPhone 15 Pro, iOS 27.0) completed native inference and audio-player startup in all four languages. Pinned files were copied into app staging for this hardware pass, so it does not establish device network-download performance. Existing user settings and credentials were not read or overwritten.

| Language | Uncached sample playback request | Prepared sample playback request |
| --- | ---: | ---: |
| English | 15,434 ms | 149 ms |
| Mandarin | 11,223 ms | 80 ms |
| Japanese | 13,448 ms | 81 ms |
| Cantonese | 7,281 ms | 82 ms |

These single-run measurements cover the Flutter request through native audio-player startup, not an external acoustic measurement or P50/P95 benchmark. The fast path reuses verified/prepared WAV data in a process-only cache bounded to 4 MB / 12 entries. New phrases still require synthesis; preparation took 7.2–9.5 seconds in the final run, with a 99-second Cantonese outlier in the earlier run. Long text, interruptions, Bluetooth and concurrent recording require broader physical validation.

- The final on-device Apple Cantonese check transcribed a generated audio fixture as `我想定聽晚兩個人嘅胃唔該。`, versus the spoken `我想訂聽晚兩個人嘅位，唔該。`: the recognition path works, with two homophone errors in this sample. The fixture was deleted after the check. No microphone recording or live Soniox/MOSS/text-provider test was performed.
- iRocky reported Cantonese on-device recognition ready and Apple Cantonese translation unsupported. The recovery path requests online mode and a configured text model instead of substituting Mandarin.
- MLX's allocator cache is capped at 64 MB. A host synthesis/unload probe reduced active MLX allocation from 1,421,366,104 to 150,236 bytes and cached allocation from 69,440,308 to zero. The app explicitly unloads the model after 60 idle seconds; this is a host memory result, not a full iPhone process-memory measurement.
- The final normal signed Release build (`lib/main.dart`, 219.9 MB) was installed and launched successfully on iRocky, replacing the Profile test harness. Deep/strict code-sign verification passed with the system trust store. The processed bundle contains the matching approved preset, iOS MLX Metal library and real Japanese dictionary, with no stale Piper bundle or Debug kernel. Targeted Dart analysis passed after correcting the smoke test's sole lint; `git diff --check` passed.

Reproducible focused commands:

```sh
flutter test --no-pub test/cantonese_test.dart test/tts_settings_test.dart test/speak_retranslation_test.dart test/translation_test.dart test/vocabulary_test.dart
bash scripts/test-tts-native.sh
python3 -m unittest scripts/test_install_ios.py
flutter build ios --release --no-pub -t lib/main.dart
```

`scripts/voice_smoke.dart` is an explicit test entry point with isolated settings. Its optional `VOICE_TEST_AUDIO_ID` refers only to a deliberately staged generated fixture, which the harness deletes. Use Profile/Release for standalone physical-device tests and restore `lib/main.dart` afterward.

## Speaking preparation and recording-title spacing (2026-09-13)

- Completed speaking translations now prepare the installed local voice immediately. The speaker action shows a progress indicator and `Preparing audio…` until ready, or `Retry audio` after a failure. Preparation never plays sound or downloads resources. Listen reuses the prepared WAV from the existing bounded cache.
- Translation edits, language changes, and recording start cancel stale preparation; editing also cancels a pending playback retry. Rebuilds do not restart synthesis. A cancelled engine load still schedules idle unloading.
- Recording titles preserve the recognizer's text boundaries for Mandarin, Cantonese and Japanese, including mixed Latin fragments such as `A` + `pp`. This removes app-inserted inter-character spaces in existing recordings while retaining supplied spaces and English word separation.
- The title widget and preparation-before-Listen regressions failed before these fixes. All 29 focused Flutter tests passed, covering stale completions, silent preparation, retry/cancellation, saved expressions, retranslation, retained drafts across navigation and the Chinese preparation layout at 320 points / 200% text size. Targeted Dart analysis reported no issues. The standalone native playback/cache/cancellation harness passed, including a guard that retains the selected neural voice after a preparation failure instead of silently switching to a system voice.
- A signed Profile fixture (`scripts/speech_latency_smoke.dart`) passed on iRocky / iPhone 15 Pro: an unprepared Cantonese phrase reached native player startup in **6,837 ms**; another phrase took **8,616 ms** to prepare through the actual speech button, then reached player startup in **85 ms**. These are single requests through Flutter and the native player, not acoustic onset or P50/P95. Preparation moves inference ahead of the tap; it does not eliminate synthesis time.
- The normal signed Release app (`lib/main.dart`, 219.9 MB) was rebuilt and installed on iRocky after the probe. Processed-bundle validation and deep/strict code-sign verification passed. The final native object files were compiled after the voice-retry guard was added.

## Speaking language dropdowns (2026-09-13)

- Both language labels on Speak now open the existing language list. Changes save through the shared settings controller, retain the input draft and clear stale translated text/audio without automatically translating again. The selectors are disabled during capture, transcription and their own save.
- An already mounted Settings page follows source/target changes and refreshes the target voice status, preventing later settings edits from restoring an old language pair.
- All 16 focused language, retranslation, speech-preparation and voice-settings tests passed. Coverage includes native configuration and database persistence, failed saves, late translation results, recording/paused/processing locks, and selecting from the menu at 320 points / 200% Chinese text. Targeted Dart analysis and rendered layout checks passed.
- The normal signed Release app was rebuilt, passed processed-bundle verification and was installed on iRocky. Dropdown interaction was verified with widget tests; no physical tap test was performed.

## Voice availability without repeated synthesis (2026-09-13)

- Settings uses the installed model's persisted verification receipt and file sizes instead of loading CosyVoice and generating a sample on each fresh process/language check. Availability runs outside the synthesis actor, so a status request does not wait behind inference. Explicit installation still verifies hashes and a generated sample before publication; playback failures invalidate the receipt and retain repair/retry behavior.
- The quick availability lookup no longer displays `Checking voice…` or its progress bar. Actual downloads and preview generation retain their progress indicators. Missing or truncated files still report Download/Repair.
- The focused Settings regression reproduced the old visible check before the fix. All 11 Settings/language tests passed afterward, along with native tests for fresh-instance receipt reuse, download state, missing/invalid resources, cancellation, and the existing cache/store guarantees. Targeted Dart analysis passed.
- The signed Profile `scripts/voice_status_smoke.dart` fixture passed on iRocky / iPhone 15 Pro. Five fresh Settings-page instances (English, Mandarin, Japanese, Cantonese, English again) reached the ready-state frame in **42, 4, 8, 6 and 3 ms**; their native availability requests took **38, 3, 3, 5 and 2 ms**. The fresh process did not load CosyVoice or synthesize samples. These are individual measured requests/frames, not a latency distribution.
- The normal signed Release app (`lib/main.dart`) was rebuilt and installed on iRocky after the fixture. Processed-bundle and deep/strict signature verification passed.
