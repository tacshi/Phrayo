# 句芽 · Phrayo

A Flutter app for turning something you want to say into an expression you can practise. iPhone and iPad require iOS 26 or later. Bundle ID: `app.capyvibe.phrayo`.

## Run

Flutter 3.47.2 / Dart 3.13.2 and Xcode 26.6 were used for development. Dependencies are locked in `pubspec.lock`; iOS plugins use Flutter's generated Swift package.

```sh
flutter pub get
flutter run -d <device-id>
```

Use Flutter or Xcode for Debug launches. For standalone device testing, select Profile or Release and configure signing for both Runner and PhrayoActivity in `ios/Runner.xcworkspace`.

To build and install on physical devices with the same device picker as 115Lab:

```sh
scripts/install-ios.sh                         # Release; choose devices interactively
scripts/install-ios.sh --all --no-clean --launch
scripts/install-ios.sh --profile --device <udid> --launch
scripts/install-ios.sh --debug --device <udid>  # Runs through Flutter
scripts/install-ios.sh --skip-build --device <udid> --launch
```

Release/Profile build once and install to the selected devices. Configure signing for both targets first. The script defaults to a clean build; use `--no-clean` to reuse artifacts. Debug always runs through Flutter on one device. Noninteractive runs with multiple devices require an explicit `--device` or `--all`. See `scripts/install-ios.sh --help` for all options.

## First use

1. Choose spoken and target languages in Settings.
2. Prepare the selected offline languages while online. Availability depends on the device and language pair.
3. For online speech recognition, select Soniox or MOSS Pro under STT model and test the provider’s key. For text actions, choose OpenAI, OpenRouter, DeepSeek, Groq or Mistral, enter the provider’s key, test the connection, then choose a returned model and save. Changing the provider or key requires another test.
4. Hold the microphone to speak. After granting microphone permission the first time, press again to begin.
5. To use Action Button, select the Phrayo “Start speaking” shortcut in iPhone Settings. Unlock when the system requests it. Live Activities must be enabled for the recording shortcut.

Keys are saved in the device Keychain. On-device-only mode does not call either STT provider or the text model. Recordings, expressions and practice history remain in the app's local store; cloud processing sends the requested audio or text to the configured provider.

## Features

- Hold-to-speak translation, editable source text, system speech playback and explicit text rewrites.
- Saved expressions, source-clip playback, active recall, recorded attempts and spaced review.
- Native segmented audio capture, pause/resume, recoverable M4A export and long-recording transcription.
- Speaker/segment selection, source-linked key points and generated practice expressions.
- English, Simplified Chinese and Traditional Chinese; dark appearance, large text and adaptive iPad layouts.
- App Shortcut and interactive recording Live Activity.

Apple recognition processes the saved audio after capture. Soniox provides the live transcript/translation. MOSS Pro transcribes after recording stops, then uses Apple translation for speaking and shortcuts. The app does not implement local MOSS models, account subscriptions, cross-device sync or pronunciation scoring.

## Code and generated files

- `lib/core`, `lib/data`: domain records, Riverpod state and Drift persistence.
- `lib/services`: provider protocols, streamed text parsing and durable STT tasks.
- `lib/ui`: the three primary screens, practice and settings.
- `ios/Runner`: native capture, Apple Speech/Translation, Soniox WebSocket, Keychain and App Intents.
- `ios/PhrayoActivity`: the Live Activity extension.
- `pigeons/native.dart`: the authoritative Dart/Swift bridge schema.

Regenerate checked-in outputs after changing their schemas:

```sh
dart run pigeon --input pigeons/native.dart
dart run build_runner build
dart format lib test pigeons
```

`Phrayo.png` is the logo used by the app. `swift scripts/render_brand.swift` generates the opaque iOS icon and 24/40/60-pixel previews from it. Older SVG/PDF and alternate-color exports in `assets/brand` are not used by the app. The Xcode project is checked in; `scripts/configure_ios.rb` documents its target/resource setup and requires the `xcodeproj` Ruby gem only when rerun.

## Checks

```sh
flutter analyze
flutter test
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination 'platform=iOS Simulator,id=<id>' \
  -only-testing:RunnerTests test
```

See [verification record](docs/verification.md) for executed checks and remaining device/provider acceptance. Build success is not a claim of validated microphone, Action Button or offline model performance.

### Correct transcription and add vocabulary

Edit the text on the speaking page, then tap **Translate**. In recording details, use **… → Edit transcript** to correct passages, then open **Translation** to translate again. Choose **Save to Expressions** below a recording translation to keep it with its source audio. The app uses your configured text model or system translation; translation styles require a text model.

Open **Settings → Custom vocabulary** to enter one word or phrase per line (up to 20 terms, 30 characters each). Saved terms apply to new speech sessions and transcription jobs, including shortcuts. Soniox and MOSS Pro accept the full list. System transcription prefers Apple's dictionary-capable engine where the language is supported; use the language preparation control if its resources need downloading.
