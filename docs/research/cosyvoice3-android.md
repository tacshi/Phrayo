# Android voice runtime

## Build

Requirements: Python 3.12+, CMake 3.28+, Ninja, JDK 21, Android SDK 36 and NDK
28.2.13676358. Source commits, archive checksums and model hashes are pinned in
`native/android-voice/dependencies.json`. Downloaded sources and weights live in
`build/android-native`.

```sh
scripts/build-android-voice-probe.sh
PHRAYO_VULKAN=ON scripts/build-android-voice-probe.sh
PHRAYO_VULKAN=ON PHRAYO_PROFILE=ON scripts/build-android-voice-probe.sh
adb -s DEVICE install -r dist/Phrayo-Voice-Check.apk
python3 scripts/run-android-voice-probe.py --device DEVICE --variant f16 --backend cpu --cold --save-audio
python3 scripts/run-android-voice-probe.py --device DEVICE --variant f16 --backend vulkan --streaming --max-first-frame-ms 15000 --max-underruns 0
```

The probe uses `app.capyvibe.phrayo.voiceprobe`. Keep it visible and the phone
unlocked during measurement. Reports and explicitly exported test audio are
written to its external-files `reports` directory and copied to
`build/android-native/reports`. Stage logs contain timings and tensor dimensions.
Build the main app with `scripts/build-apk.sh --release` or
`scripts/build-apk.sh --debug`.

## Integration

- [cosyvoice.cpp v0.1.3](https://github.com/Lourdle/cosyvoice.cpp/releases/tag/v0.1.3)
  supplies the C API. ONNX reference extraction, server, upstream audio and C++ ICU
  are disabled; Android owns playback and cancellation.
- The [GGUF weights](https://huggingface.co/Lourdle/Fun-CosyVoice3-0.5B-2512-GGUF/tree/ab01740bbbfcc059fd748163787554f7c8977e64)
  are separate downloads: F16 1,724,750,240 bytes; Q8_0 943,933,536 bytes.
- `convert-android-voice-profile.py` preserves the existing LJ025-0076 embedding
  and transcript, transposes mel features, and aligns 419 frames/210 tokens to
  418 frames/209 tokens. GGUF tensors are `feat` F32, `embedding` F32, `tokens` I32
  and UTF-8 `text` I8.
- Japanese preprocessing uses the iOS MeCab/IPADic revisions, pronunciation column
  8, reading column 7, counter normalization and ICU4J number spellout.
- GGML reports Adreno as an integrated GPU. Vulkan selection must accept `IGPU`.
- Ten fixed F16 diffusion-cache slots at 2,048 frames reserve 3.44 GiB before
  weights and workspace. Cache capacity needs to be bounded independently of LLM
  sequence capacity.
- The main app uses F16 CPU inference on one serialized worker. Playback copies
  callbacks into a 24-block queue; cancellation uses a separate control thread.
  The process cache holds at most 12 utterances / 4 MiB and models unload after
  60 seconds idle. Speech segmentation matches iOS's 32-character Mandarin and
  Cantonese / 96-character other-language limits.
- Native Pigeon events run on the main thread. Recording uses 30-second durable
  PCM segments, AAC/M4A export and atomic journals. A microphone foreground
  service provides pause/resume/stop; recovery never restarts capture.
- SenseVoice uses INT8 weights and 512-sample Silero VAD windows, with bounded
  20-second recognition segments. Credentials use Keystore AES-GCM. Models and
  credentials are excluded from Android backup.

## Device measurements

SM-S931B / SM8750, Android 16, approximately 12 GB RAM, 4 KB pages; fixed English
sample, single runs on 2026-09-15. First-frame values are AudioTrack observations,
not acoustic latency or P95. PSS is measured at completion, not peak allocation.

| Configuration | First frame | Audio | Underruns | Ending PSS |
|---|---:|---:|---:|---:|
| F16 CPU, default threading, whole utterance | 64.406 s | 2.8 s | 0 | 1.94 GiB |
| F16 CPU, default threading, warm streaming | 41.596 s | 2.8 s | 2 | 1.94 GiB |
| Q8 CPU, ARM FP16/dotprod, 4 threads, whole utterance | 50.665 s | 3.12 s | 0 | 1.21 GiB |
| F16 Vulkan, default caches, whole utterance | 36.289 s | 1.0 s | 0 | 2.31 GiB |
| F16 Vulkan, F16 caches/10 slots, streaming | 38.767 s | 9.6 s | 8 | 5.76 GiB |
| Q8 Vulkan, F16 caches/10 slots, streaming | 104.459 s | 1.48 s | 1 | 5.03 GiB |

Stage profiling on 2026-09-16 separated correctness from Flow cost. F16 CPU
recognized the complete English fixture: about 1 s LLM, 49 s Flow and 1.66 s
HiFT, with first playback at 53.6 s. Feeding 62 known-good CPU tokens to Vulkan
also produced the complete sentence, but Flow still took about 36 s and first
playback 39.8 s. Vulkan token generation remains incorrect. These are single
runs and do not establish voice acceptance or a latency percentile.

## Integration checks

```sh
cd android
JAVA_HOME=/path/to/jdk21 ./gradlew :app:testDebugUnitTest
JAVA_HOME=/path/to/jdk21 ./gradlew :app:connectedDebugAndroidTest -Ptarget-platform=android-arm64
```

Recording tests require an unlocked phone and make short disposable microphone
captures. OfflineSpeechTest additionally requires the public SenseVoice `en.wav`
fixture at the debug app's `files/fixtures/en.wav`; without it the test skips.
Preparing its models uses the same checksum and loader checks as Settings.

On SM-S931B, native tests verified PCM-to-M4A recovery and decoding, traversal and
symlink rejection, Keystore storage, pause/resume, shared Stop draining,
concurrent discard, English SenseVoice transcription with offsets, and F16
preparation/cancellation/retry/cached playback. ML Kit preparation and English-to-Mandarin
translation passed on the same device. The arm64 debug APK's 11 native libraries and stored ZIP
entries passed 16 KB alignment checks. A 16 KB-page device, 60-minute recording,
full provider credentials, lock-screen interruption matrix, and the second
Snapdragon device remain required for release qualification.

Release acceptance requires correct four-language output, P95 first audible
output ≤5 seconds warm / ≤15 seconds cold, and uninterrupted segmented playback.

## Android dependencies

[SenseVoice through sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html)
provides offline transcription. [ML Kit translation](https://developers.google.com/ml-kit/language/translation/translation-language-support)
lacks Cantonese and requires [Google attribution](https://developers.google.com/ml-kit/language/translation/translation-terms).
All native libraries and APK packaging must satisfy [16 KB alignment](https://developer.android.com/guide/practices/page-sizes).
