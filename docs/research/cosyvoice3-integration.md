# CosyVoice3 integration and provisioning

Verified 2026-09-13. Target: on-device English, Mandarin, Japanese and Cantonese synthesis; primary acceptance device: iRocky / iPhone 15 Pro. This note records reproducible inputs and integration constraints. It does not establish voice quality, device performance or live STT/translation accuracy.

## Pinned synthesis bundle

Use `aufklarer/CosyVoice3-0.5B-MLX-8bit` at revision `c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337`: INT8 LLM, bf16 flow decoder, fp32 vocoder, 24 kHz output. The corrected snapshot avoids the earlier low-bit flow export. Sources: [model card](https://huggingface.co/aufklarer/CosyVoice3-0.5B-MLX-8bit/blob/c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337/README.md), [file metadata](https://huggingface.co/api/models/aufklarer/CosyVoice3-0.5B-MLX-8bit/revision/c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337?blobs=true).

| File | Exact bytes | SHA-256 |
| --- | ---: | --- |
| `llm.safetensors` | 671220880 | `49b3b2ecc7bcff7d554a80012721a2283187477dd5371a140c1c1a89b13b1063` |
| `flow.safetensors` | 664553192 | `f1685d7e476295b104a675aa7e25a2572d5858879a4be0dfdd25253215b8e3d4` |
| `hifigan.safetensors` | 83086548 | `840350956a8403245c738504a0da2a0c2047d5e705173930030013f28d4e3a1e` |
| `config.json` | 2036 | `22fce864f6cb5654c26e0b380d4c2be7e4e724849d11fed91f9a3b615d43f505` |
| `merges.txt` | 1402109 | `ac8ff86a72bee70828fbc1119bc4398c6f3a9a6e490d7b0dbe917be025478bd0` |
| `tokenizer_config.json` | 1287 | `482bd979881423375ca5414e4e0d94cd7c5349dbb17fffd46b4d36d71e62a1bc` |
| `vocab.json` | 2776833 | `ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910` |

These seven files total **1,423,042,885 bytes** (1.423 GB / approximately 1.325 GiB), before the small preset and Japanese dictionary. Weight hashes above come from Hugging Face LFS metadata; the four smaller files were fetched and independently SHA-256 hashed. Weight payloads were not downloaded for this research.

Download each allowlisted file from `https://huggingface.co/aufklarer/CosyVoice3-0.5B-MLX-8bit/resolve/c9ebb1a5dabe0a5c19c76c4cc65fb7593d73c337/<file>`. Phrayo should own the manifest, staging, progress and integrity verification; atomically promote only a complete verified bundle. Pass its local directory to `fromPretrained(modelId:cacheDir:offlineMode:progressHandler:)` with `offlineMode: true`. The generic upstream loader's existence check is not a complete manifest validator. [Loader source](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/AudioCommon/HuggingFaceDownloader.swift)

## Fixed voice without the full LJ Speech download

Neither the official CosyVoice3 model nor this converted bundle ships a curated speaker profile. The port's no-profile overload uses unconditioned synthesis. Do not present that as a supplied, evaluated preset. [Official files](https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512/tree/29e01c4e8d000f4bcd70751be16fa94bf3d85a18), [runtime](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/CosyVoiceTTS.swift)

Use dataset clip **LJ025-0076** as the initial fixed voice reference. The dataset publisher labels its recordings, text and annotations public domain and provides this original recording directly, so no 2.6 GB archive or streaming archive scan is necessary. This is dataset audio, not generated research-demo output. Retain the source/credit in third-party notices. [Dataset license and sample](https://keithito.com/LJ-Speech-Dataset/)

| Property | Value |
| --- | --- |
| URL | `https://keithito.com/LJ-Speech-Dataset/LJ025-0076.wav` |
| Bytes | `370336` |
| SHA-256 | `b31133c05e9667a27db5be539ca089aa99e95ca7bef52040c902ff781680873a` |
| Format | Mono PCM16, 22050 Hz, 185146 frames |
| Duration | 8.396643990929705 seconds |
| Transcript | Many animals of even complex structure which live parasitically within others are wholly devoid of an alimentary cavity. |

The clip's bytes, hash and WAV header were verified in memory. Its timbre and four-language output have not been auditioned. If this reference fails acceptance, replace the reference rather than claiming the voice is improved.

## Preparing the complete conditioning offline

Pin official source `QwenAudio/CosyVoice` at `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`, with its Matcha-TTS submodule `dd9105b34bf2be2230f4aa1e4769fb586a3c824e`. Use official model snapshot `FunAudioLLM/Fun-CosyVoice3-0.5B-2512@29e01c4e8d000f4bcd70751be16fa94bf3d85a18`. Preparation requires only its two audio encoders and text-tokenizer/config files; do not download the training checkpoints or `CosyVoice-BlankEN/model.safetensors`. [Official frontend](https://github.com/QwenAudio/CosyVoice/blob/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc/cosyvoice/cli/frontend.py), [official configuration](https://huggingface.co/FunAudioLLM/Fun-CosyVoice3-0.5B-2512/blob/29e01c4e8d000f4bcd70751be16fa94bf3d85a18/cosyvoice3.yaml)

| Preparation-only asset | Exact bytes | SHA-256 from LFS metadata |
| --- | ---: | --- |
| `campplus.onnx` | 28303423 | `a6ac6a63997761ae2997373e2ee1c47040854b4b759ea41ec48e4e42df0f4d73` |
| `speech_tokenizer_v3.onnx` | 969451503 | `23236a74175dbdda47afc66dbadd5bcb41303c467a57c261cb8539ad9db9208d` |

Instantiate `CosyVoiceFrontEnd` directly with the pinned Qwen tokenizer and Matcha mel extractor; do not instantiate `AutoModel`, which loads synthesis/training weights. `get_qwen_tokenizer(token_path=..., version='cosyvoice3')` needs the small `CosyVoice-BlankEN` tokenizer files. Configure Matcha with `n_fft=1920`, `num_mels=80`, `sampling_rate=24000`, `hop_size=480`, `win_size=1920`, `fmin=0`, `fmax=None`, `center=False`.

Call `frontend_zero_shot('', 'You are a helpful assistant.<|endofprompt|>' + transcript, reference_wav, 24000, '')`. Serialize the resulting `flow_embedding` as 192 float32 values; `flow_prompt_speech_token` as Int32 `[1,T]`; and `prompt_speech_feat.transpose(1,2)` as Float32 `[1,80,M]`. Store the **unframed** reference transcript separately for Swift. Preserve the official frontend's returned lengths; do not pad or trim them again. Store source/model revisions, original audio hash, tensor shapes/dtypes, byte counts and SHA-256 hashes with the generated preset. The finished preset is the app input; encoder models remain development assets. [Extraction and alignment implementation](https://github.com/QwenAudio/CosyVoice/blob/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc/cosyvoice/cli/frontend.py)

An MLX-only preparation route exists: `SpeechTokenizerModel()` plus `CosyVoiceWeightLoader.loadSpeechTokenizer`, `CamPlusPlusSpeaker.fromPretrained` and `extractVoiceProfile(audio:sampleRate:speechTokenizer:camppSpeaker:referenceTranscript:)`. Its speech encoder is `speech_tokenizer.safetensors`, 484039728 bytes, SHA-256 `a3b9b816756469673efe84af9190f6cac4a8946cd7a113b76a35375daaea0e26`, in the synthesis snapshot. The CAM++ CoreML snapshot is `aufklarer/CamPlusPlus-Speaker-CoreML@c3cbd83f0c1028cf753b3e3e67639854218206a1`.

Prefer the official extraction for the shipped preset: the inspected Swift mel extractor pads to a 2048-point FFT, and its CAM++ path crops/tiles to 500 frames. Those differ from the original 1920-point Matcha FFT and full-reference fbank. The faster preparation path requires parity/listening validation, not a claim of equivalence based on its comments. [Swift mel extractor](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/FlowMelExtractor.swift), [Swift speaker extraction](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/CamPlusPlusSpeaker.swift)

## Swift runtime contract and iOS constraints

Pin `soniqo/speech-swift` to **`d655076badd143f99c9ce19642fbea8b643ccc0b`**, observed latest on 2026-09-13. It declares iOS 18 and macOS 15. Import `CosyVoiceTTS` and the minimum required MLX products. The existing MeowSTT cache was inspected read-only; its CosyVoice runtime/profile/weight-loader/LLM source files match this revision byte-for-byte, but its package/downloader files differ. [Pinned package](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Package.swift)

Restore `CosyVoiceVoiceProfile(speakerEmbedding:promptToken:promptFeat:promptText:)`, then use `synthesize(text:voiceProfile:language:instruction:segmentGapSeconds:seed:verbose:)`. For Cantonese pass `instruction: "请用广东话表达。"`; the runtime frames it and selects `instruct2`. Do not inject the special delimiter into user text. Its `language` argument alone does not alter tokenization. [Profile API](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/VoiceCloning.swift), [Cantonese example](https://github.com/QwenAudio/CosyVoice/blob/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc/example.py)

- Model instances are not thread-safe. Serialize load/inference/unload on one worker; protect audio playback with the existing request generation/cancellation mechanism.
- `synthesizeStream` yields one completed waveform, not incremental PCM. The synchronous token loop has no cancellation check. A canceled request must discard output, and a runtime adaptation should check cancellation between token/flow steps if prompt cancellation is needed.
- Split with CJK punctuation and tokenizer limits before synthesis. The port's splitter uses ASCII punctuation and whitespace words, so it does not bound unspaced Cantonese/Mandarin text reliably. Avoid accumulating complete long recordings in memory.
- The loader calls `MetalBudget.pinMemory()` with 90% of recommended working set. Use a deliberate app memory budget; weight size is not peak process memory. Validate loading, repeated synthesis, memory warnings and coexistence with recording on iRocky.
- Check the processed iOS bundle's MLX Metal resources and run a signed Profile/Release device build. A simulator/host build is not evidence of iPhone inference or listening quality. Do not copy an unrelated macOS `default.metallib` into the iOS bundle.

Sources: [runtime](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/CosyVoiceTTS.swift), [generation loop](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/LLM.swift), [splitter](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/VoiceCloning.swift), [memory policy](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/MLXCommon/MetalBudget.swift), [MLX Swift integration](https://github.com/ml-explore/mlx-swift).

### Warm-up and a minimal package adaptation

At the pinned revision, `fromPretrained` unconditionally calls `warmUp()` and `MetalBudget.pinMemory()`; it has no skip flag. Public `init(config:)` does not warm up, but the model's `llm`, `flow`, `hifigan` and `tokenizer` properties are internal, so app code cannot combine that initializer with the public component weight loaders to load a usable model. There is no existing public load-without-warmup API. [Loader and access levels](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/CosyVoiceTTS.swift)

A narrow pinned fork can add `warmUp: Bool = true` and `pinMemory: Bool = true` to `fromPretrained`, guarding those two calls. With warm-up disabled, `CosyVoiceLLM.executeStep` falls back to `forwardStep`, and the flow decoder falls back to direct DiT execution. This is supported by the code shape, but the cold-start/throughput tradeoff still needs measurement; skipping warm-up does not remove the first actual kernel costs. [LLM fallback](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/LLM.swift), [flow fallback](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Sources/CosyVoiceTTS/FlowMatching.swift)

The existing target dependency closure is `CosyVoiceTTS` → `AudioCommon` + `MLXCommon` + MLX products; `AudioCommon` needs `Hub` from `swift-transformers`, and `MLXCommon` needs MLX/MLXNN/MLXFast/MLXFFT. No ASR model, dialogue UI, server or generic chat target is needed. A minimal manifest fork can retain those three source targets and only their package dependencies. Removing the remaining common-source files or Hub calls is a separate code change, not something achieved by importing fewer products. [Pinned package target graph](https://github.com/soniqo/speech-swift/blob/d655076badd143f99c9ce19642fbea8b643ccc0b/Package.swift)

## Japanese frontend

The official CosyVoice3 example requires Japanese to be converted to katakana. Pin `shinjukunian/Mecab-Swift` **0.8.0**, revision **`1f096492e37fc05fc2e7304091f54889974c5368`**; its MeCab submodule is `shinjukunian/mecab@aa318f82798d72e5cb52ba5f6b10f0b780b30d05`. Select SPM products **`Mecab-Swift`** and **`IPADic`**, importing modules `Mecab_Swift` and `IPADic`. The protocol adapter also imports the transitive `Dictionary` module. [Pinned package](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/Package.swift), [CosyVoice requirement](https://github.com/QwenAudio/CosyVoice/blob/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc/example.py)

The copied IPADic resource directory totals **53,051,958 bytes**; `sys.dic` accounts for 49,199,027 bytes. It contains nine files and no dictionary license copy. Preserve the wrapper's MIT notice, MeCab's BSD/COPYING notices, and separately include IPADic's NAIST/ICOT COPYING notice. The package already copies the MeCab notices as resources, but not the IPADic notice. [Pinned tree metadata](https://api.github.com/repos/shinjukunian/Mecab-Swift/git/trees/1f096492e37fc05fc2e7304091f54889974c5368?recursive=1), [wrapper license](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/LICENSE), [MeCab notices](https://github.com/shinjukunian/mecab/blob/aa318f82798d72e5cb52ba5f6b10f0b780b30d05/mecab/COPYING), [IPADic notice](https://github.com/shinjukunian/mecab/blob/aa318f82798d72e5cb52ba5f6b10f0b780b30d05/mecab-ipadic/COPYING)

`Annotation` publicly exposes `base`, `reading`, `partOfSpeech`, `range` and `dictionaryForm`; it does **not** expose `pronunciation`. The internal `Token` knows pronunciation field 8, but the normal IPADic adapter exposes field 7 as `Annotation.reading`. To obtain speech pronunciation without changing the package, set `readingIndex` to 8 through its public dictionary protocol:

```swift
import Foundation
import Dictionary
import IPADic
import Mecab_Swift

struct SpeechIPADic: DictionaryProviding {
    private let base = IPADic()
    var url: URL { base.url }
    var readingIndex: Int { 8 }
    var pronunciationIndex: Int { 8 }
    var dictionaryFormIndex: Int { 6 }
    func partOfSpeech(posID: UInt16) -> PartOfSpeech {
        base.partOfSpeech(posID: posID)
    }
}

let tokenizer = try Tokenizer(dictionary: SpeechIPADic())
let tokens = tokenizer.tokenize(text: text, transliteration: .katakana)
// tokens[i].reading now comes from IPADic's pronunciation column.
```

This snippet uses existing APIs; it was inspected, not compiled. For missing/`*` pronunciations, resolve the matching token range from a normal `Tokenizer(dictionary: IPADic())` pass to obtain field 7, then preserve surface text only when it is safe. Keep punctuation and original gaps using `Annotation.range`; do not silently drop unknown kanji. Test は/へ/を, counters/numbers, kanji compounds, names, prolonged vowels and mixed Latin text. [Annotation API](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/Sources/Mecab-Swift/Annotation.swift), [field selection](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/Sources/Mecab-Swift/Token.swift), [dictionary protocol](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/Sources/Dictionary/Dictionary.swift)

Static iOS check: the Swift 5.3 manifest declares a macOS minimum but does not exclude iOS; its selected targets use Foundation, conditionally available CoreText, C++ MeCab and `iconv`, with no AppKit-only imports found. Dictionary resources use `Bundle.module`. This supports attempting an iOS 26 build, **not** claiming compilation passed. The actual iOS build and processed resource loading remain required. [Manifest and resources](https://github.com/shinjukunian/Mecab-Swift/blob/1f096492e37fc05fc2e7304091f54889974c5368/Package.swift)

## Cantonese across recording and translation

Keep Phrayo's canonical Cantonese language distinct from Mandarin; use `yue` internally and apply provider mappings at each boundary. A Traditional Chinese script setting does not itself select Cantonese speech or colloquial Cantonese translation. The mappings below are recommendations from documented contracts, not live account/device results.

| Boundary | Documented fact | Phrayo mapping / verification boundary |
| --- | --- | --- |
| Soniox streaming and async STT | Supported-language table exposes `zh`, `en`, `ja`, with no `yue`. Soniox explicitly describes Cantonese recognition within Chinese. | Map `yue` input to `language_hints: ["zh"]`, optionally adding Cantonese to supported context fields. Preserve `yue` in app/job metadata. Do not send an undocumented `yue` hint. |
| Soniox translation | Same language-code set; Chinese target is `zh`. No separate Cantonese target is listed. | Do not label generic `target_language: "zh"` output as guaranteed colloquial Cantonese. Use a configured text provider with explicit Cantonese target instructions, or an actual Apple Cantonese pair when available. |
| MOSS hosted `moss-transcribe-diarize-pro` | Transcription API documents model, diarize, keyterms, inputs and async/SSE fields; it documents no language hint. | Omit `language`/`language_hints`. Keep original requested language in local metadata. Cantonese-specific hosted support was not established by the consulted API docs; run a live Cantonese recording check before claiming accuracy. |
| Apple Speech | `supportedLocales()` is the authoritative recognizer locale inventory; support and on-device support are separate checks. | Resolve a returned Cantonese recognizer locale, checking `zh-HK` and `yue`-based aliases as candidates, then verify `supportsOnDeviceRecognition`. These aliases are lookup candidates, not guarantees. |
| Apple Translation | `LanguageAvailability.supportedLanguages` and exact pair `status(from:to:)` determine availability. Apple's published iOS 26 Translate list includes Mandarin but not Cantonese. | Resolve only an explicitly returned Cantonese language (such as a `yue` language), then query the pair. Do not substitute `zh-Hant`, `zh-TW` or `zh-HK` solely because they are Chinese/Traditional/Hong Kong labels. If unsupported, provide a text-provider recovery path. |

Sources: [Soniox STT language codes](https://soniox.com/docs/stt/concepts/supported-languages), [Soniox Chinese/Cantonese claim](https://soniox.com/speech-translation/chinese), [Soniox context](https://soniox.com/docs/stt/concepts/context), [Soniox translation codes](https://soniox.com/docs/translation/supported-languages), [MOSS hosted API](https://platform.mosi.cn/docs/reference/transcriptions/), [Apple Speech locales](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportedlocales()), [Apple Translation availability](https://developer.apple.com/documentation/translation/languageavailability), [Apple iOS 26 language list](https://www.apple.com/au/ios/feature-availability/).

Do not transfer the open-source MOSS 0.9B/SGLang server's optional `language` field into the hosted Pro contract: those are different model/server boundaries. [Open-source deployment contract](https://github.com/OpenMOSS/MOSS-Transcribe-Diarize)

## Original research boundary

The initial research above involved source inspection only. The subsequent implementation and evidence below supersede its pending compilation and preset checks; recommendations about broader accuracy, cancellation and memory testing remain test boundaries.

## Implemented outcome (2026-09-13)

- Pinned speech-swift to `d655076badd143f99c9ce19642fbea8b643ccc0b`, MLX Swift to 0.31.4 (`dc43e62d7055353c7f99fa071a4e71d29dfddc44`) and MeCab-Swift to 0.8.0. No runtime fork was needed. The app builds its Metal library for the actual iOS SDK, with input/toolchain caching.
- Used the Swift extraction route with the public-domain LJ025-0076 reference. The user listened to and approved all four outputs, so this accepted preset was retained; no equivalence to the Python frontend is claimed. Preset SHA-256: `58a6730ed47b9d09cdf8f59b44db4aa5f1733e39f1ad52bb6d0d7976449a1284`. Reference audio SHA-256: `b31133c05e9667a27db5be539ca089aa99e95ca7bef52040c902ff781680873a`.
- Only the seven pinned synthesis/config/tokenizer files are installed (1,423,042,885 bytes). Preparation encoders stay outside the app. The Japanese dictionary and license notices are bundled.
- Actual signed iPhone 15 Pro inference and playback succeeded in English, Mandarin, Japanese and Cantonese. Uncached short sample requests took 7.3–15.4 seconds; prepared sample requests took 80–149 ms using a bounded memory cache. These are request-to-player-start observations, not acoustic latency distributions.
- Apple Cantonese recognition ran on a generated fixture, with two homophone errors. Apple Cantonese translation was unavailable on iRocky; the app uses explicit text-model instructions and does not label Mandarin translation as Cantonese. Cloud-provider mappings have focused payload tests, without live credentials or a microphone accuracy test.
- Explicit `model.unload()` is needed to clear weights retained through compiled model closures. The host probe reduced active MLX memory from about 1.42 GB to 150 KB after unload; the app schedules unloading after 60 idle seconds. Physical peak process memory and recording coexistence remain unmeasured.

See `docs/verification.md` for exact timings, executed commands and remaining validation limits.
