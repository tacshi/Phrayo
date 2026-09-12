# Runtime and data contracts

## Audio ownership

`PhrayoHost` owns one native session. Flutter, the foreground App Shortcut and the Live Activity stop intent share that instance. The microphone tap copies input buffers to a serial capture queue. That queue rotates CAF files without restarting the input engine and converts a separate stream to 16 kHz mono PCM16 for Soniox.

A packet stream transfers capture events to the main actor in order. Stop drains the capture queue and packet stream before finalizing the WebSocket, so the last audio buffers cannot be dropped when UI state changes. Audio is exported to M4A before speech/text processing. A session journal records state and source languages independently of Flutter startup. An interrupted export retains CAF segments for a later export attempt.

The Action Button uses a foreground App Intent. It does not observe physical key-release events. A 1.5-second silence window, 10-second no-speech timeout and 60-second short-session limit are application policies. The level-based detector and its thresholds still require physical-device tuning.

Audio references are stored as `<session UUID>/recording.m4a`, relative to the current app audio directory. Legacy absolute paths are rebased only when they match the app's known layout. Traversal and symlink escapes are rejected. Deletion cleans the native audio before removing its database row, leaving failed operations available for retry. Startup retries audio cleanup for retained deletion tombstones, including records deleted by older versions before their native cleanup failed.

## Providers

- Soniox real time: `wss://stt-rt.soniox.com/transcribe-websocket`, `stt-rt-v5`, ordered final and provisional tokens, empty-frame stream completion.
- MOSS Pro: `https://api.mosi.cn/v1`, `moss-transcribe-diarize-pro` for new jobs. Existing jobs retain the legacy `moss-transcribe-diarize` / `v20260410-streamparam-20260703` contract. Upload with `purpose=audio`, submit asynchronously, poll `/audio/tasks/{id}`, and preserve source segment timing and speaker IDs. Speaking and shortcuts submit after capture stops and use Apple translation.
- Soniox recordings: `/v1/files` and `/v1/transcriptions`, `stt-async-v5`, source token timestamps and speaker metadata.
- Apple: file-based `SpeechAnalyzer` with `SpeechTranscriber`, or installed `DictationTranscriber` where supported; installed-language `TranslationSession`; `AVSpeechSynthesizer`.
- Text models: preset cloud Providers (OpenAI, OpenRouter, DeepSeek, Groq and Mistral) with fixed HTTPS Chat Completions endpoints. Connection testing authenticates and loads the model list before selection; OpenRouter also checks `/key` because its model catalog is public. Tests do not save drafts or invoke generation. Changing the provider or key invalidates the model selection. SSE text deltas and complete JSON validation are used for summaries and practice materials. A truncated response cannot be treated as a complete structured result.

Text-model keys are indexed by provider inside the existing `llm` Keychain item. Legacy raw keys are migrated only when the saved base URL matches a known preset; custom/local URLs are not redirected to a different provider. Model-list access does not establish generation access or quota for every returned model.

Model discovery follows the official [OpenAI](https://developers.openai.com/api/reference/typescript/resources/models/methods/list), [OpenRouter](https://openrouter.ai/docs/guides/overview/models), [DeepSeek](https://api-docs.deepseek.com/api/list-models), [Groq](https://console.groq.com/docs/models) and [Mistral](https://docs.mistral.ai/api/endpoint/models) APIs.

No cloud API is called in on-device-only mode. Missing resources preserve the audio and surface a recovery action. Translated Soniox tokens are never assigned source-audio timestamps. Summary references are checked against actual input segment IDs.

## Persistence and task recovery

Drift stores typed domain JSON in a versioned SQLite envelope. Compare-and-swap writes protect against stale revisions. Native imports use insert-if-absent and deletion tombstones. Deleting a recording removes its source versions and audio associations while retaining saved expression text. Tombstones retain only internal IDs to reject delayed native events.

A Soniox job stores its file ID, remote transcription ID, input revision and stage. The app persists submission uncertainty before creating a remote transcription, uses a unique client reference, and searches all result pages when reconciling an uncertain submission. It does not blindly submit a second paid transcription. Result commit and the cleanup stage are written transactionally; cleanup failure resumes deletion rather than retranscription. Cancel and delete coordinate through the active task's completion.

The app does not promise unrestricted background processing. A paused remote job is resumed by opening the recording and choosing Transcribe. Failure to reconcile an unknown remote submission is shown explicitly. Upload interruptions before the server returns a file ID are a remaining provider-boundary validation case.

## References used

The existing MeowSTT client informed async task lifecycle and cleanup. Soundcore informed PCM formatting and Soniox stream completion. No saved credentials, private recordings or application data from either project were read or copied.

- [Soniox models](https://soniox.com/docs/stt/models)
- [Soniox token and translation timing](https://soniox.com/docs/translation/stt-translation)
- [Soniox transcription listing](https://soniox.com/docs/api-reference/stt/transcriptions/get_transcriptions)
- [Apple recording intent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Apple TranslationSession](https://developer.apple.com/documentation/translation/translationsession)

### STT selection and recovery

Settings persist the STT provider separately from the text model, defaulting to Soniox. Soniox and MOSS credentials occupy separate Keychain entries. On-device-only mode prevents both cloud providers from being called.

Each durable job retains its provider; legacy jobs belong to Soniox. MOSS native speaking jobs are journaled with the same stages and identifiers as Flutter jobs, then imported transactionally before the native journal is acknowledged. Results commit before upload cleanup. MOSS has no task-list reconciliation or task deletion in the MeowSTT integration: uncertain submissions remain blocked from automatic resubmission, and cleanup deletes known uploaded files only. Users can inspect their MOSS account, discard the task, and explicitly retry.

### Retranslation and custom vocabulary

The speaking editor invalidates translation and explanation on edits, then uses `TextProcessor.translate` when Translate is tapped. Default-style Apple translation remains available without a text model. Session ownership and request revisions prevent late results from replacing an edited draft.

`AppSettings.transcriptionTerms` holds one ordered list of up to 20 terms, each at most 30 Unicode scalars. Save trims whitespace, removes empty and exact duplicate entries, and rejects excess terms or length. Settings default to an empty list. Pigeon carries vocabulary explicitly for session start, file transcription, availability, preparation, and native configuration. Native defaults supply the saved list to shortcuts; active sessions keep their own snapshot.

New transcription jobs snapshot terms and the MOSS model before upload. Resumed jobs retain that snapshot; old jobs without vocabulary use an empty list. Soniox sends `context.terms`; MOSS sends `keyterms`. Empty lists omit the provider field. Terms bias recognition and are not post-processing replacement rules or translation mappings.

With vocabulary, Apple selects DictationTranscriber where the source locale is supported and sets `AnalysisContext.contextualStrings[.general]` before analysis. Availability and preparation use the same selection. Missing assets require preparation; unsupported Dictation locales retain SpeechTranscriber, with vocabulary unavailability exposed in resource checks and local speaking results. Empty vocabulary restores the original engine preference.
